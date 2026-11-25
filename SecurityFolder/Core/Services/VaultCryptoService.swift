import CryptoKit
import Foundation
@preconcurrency import LocalAuthentication
import Security

enum VaultCryptoError: LocalizedError {
    case biometricUnavailable
    case biometricKeyMissing
    case keyUnavailable
    case keychainFailure(OSStatus)
    case invalidEncryptedFile
    case corruptEncryptedChunk

    var errorDescription: String? {
        switch self {
        case .biometricUnavailable:
            return String(localized: "当前设备不可用 Face ID / Touch ID。")
        case .biometricKeyMissing:
            return String(localized: "默认生物识别空间的密钥还没有完成绑定。")
        case .keyUnavailable, .keychainFailure:
            return String(localized: "当前空间的加密密钥不可用，请先重新解锁。")
        case .invalidEncryptedFile:
            return String(localized: "文件密文格式无效，无法读取。")
        case .corruptEncryptedChunk:
            return String(localized: "文件分块解密失败，数据可能已损坏。")
        }
    }
}

final class VaultCryptoService {
    nonisolated static let shared = VaultCryptoService()

    nonisolated private static let fileMagic = Data("SVLT".utf8)
    nonisolated private static let fileVersion: UInt8 = 1

    nonisolated(unsafe) private let fileManager = FileManager.default
    private let chunkSize = 1_024 * 1_024
    private let stateQueue = DispatchQueue(label: "SecurityFolder.VaultCryptoService.State")

    nonisolated(unsafe) private var activeKeys: [VaultSpaceKind: SymmetricKey] = [:]
    nonisolated(unsafe) private var temporaryFilesByPath: [String: URL] = [:]
    nonisolated(unsafe) private var temporaryFileGeneration = 0
    nonisolated(unsafe) private var lockGeneration = 0

    private init() {}

    var biometricUnlockAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private var biometricDisplayName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID:
            return String(localized: "Face ID")
        case .touchID:
            return String(localized: "Touch ID")
        case .opticID:
            return String(localized: "Optic ID")
        default:
            return String(localized: "生物识别")
        }
    }

    func hasWrappedKey(for space: VaultSpaceKind) -> Bool {
        keychainItemExists(for: wrappedAccount(for: space))
    }

    /// 认证后返回空间密钥；由 Session 确认请求仍有效后再激活密钥。
    func biometricKeyData(space: VaultSpaceKind, context: LAContext) async throws -> Data {
        guard biometricUnlockAvailable else {
            throw VaultCryptoError.biometricUnavailable
        }
        context.localizedReason = String.localizedStringWithFormat(
            String(localized: "使用 %@ 解锁%@"),
            biometricDisplayName,
            SpaceDisplaySettings.displayName(for: space)
        )
        let account = biometricAccount(for: space)
        let service = keychainService
        // Keychain waits synchronously for Face ID. Keep that wait off the UI thread,
        // and return only the key bytes; the session decides whether the request is still valid.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecItemNotFound {
                    continuation.resume(throwing: VaultCryptoError.biometricKeyMissing)
                } else if status != errSecSuccess {
                    continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
                } else if let data = item as? Data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: VaultCryptoError.biometricKeyMissing)
                }
            }
        }
    }

    func activateBiometricKey(_ data: Data, for space: VaultSpaceKind) {
        setActiveKey(SymmetricKey(data: data), for: space)
    }

    /// 使用密码解锁空间；仅解包已存在的空间 DEK，不隐式生成新密钥。
    func unlock(space: VaultSpaceKind, passcode: String) throws {
        guard let wrappedKeyData = try keychainData(for: wrappedAccount(for: space)) else {
            throw VaultCryptoError.keyUnavailable
        }

        let wrappingKey = wrappingKey(for: space, passcode: passcode)
        let sealedBox = try AES.GCM.SealedBox(combined: wrappedKeyData)
        var rawKeyData = try AES.GCM.open(sealedBox, using: wrappingKey)
        defer { zeroize(&rawKeyData) }
        setActiveKey(SymmetricKey(data: rawKeyData), for: space)
        try saveBiometricKeyIfMissing(rawKeyData, for: space)
    }

    /// 只校验密码能否解开该空间的主密钥，不加载密钥，也不清除其他空间已加载的密钥。
    func verifyPasscode(_ passcode: String, for space: VaultSpaceKind) -> Bool {
        guard let wrappedKeyData = try? keychainData(for: wrappedAccount(for: space)),
              let sealedBox = try? AES.GCM.SealedBox(combined: wrappedKeyData),
              var rawKeyData = try? AES.GCM.open(sealedBox, using: wrappingKey(for: space, passcode: passcode)) else {
            return false
        }
        zeroize(&rawKeyData)
        return true
    }

    /// 首次设置密码时创建空间主密钥；若该空间已经有密钥，则只做重包裹。
    func configurePasscode(for space: VaultSpaceKind, newPasscode: String) throws {
        guard !keychainItemExists(for: wrappedAccount(for: space)) else {
            throw VaultCryptoError.keyUnavailable
        }

        let newKey = SymmetricKey(size: .bits256)
        var rawKeyData = newKey.rawData
        defer { zeroize(&rawKeyData) }
        try saveWrappedKey(rawKeyData, for: space, passcode: newPasscode)
        try saveBiometricKey(rawKeyData, for: space)
        setActiveKey(newKey, for: space)
    }

    /// 修改空间密码时不重加密媒体，只重新包裹现有 DEK。
    func changePasscode(for space: VaultSpaceKind, oldPasscode: String, newPasscode: String) throws {
        guard let wrappedKeyData = try keychainData(for: wrappedAccount(for: space)) else {
            throw VaultCryptoError.keyUnavailable
        }

        let oldWrappingKey = wrappingKey(for: space, passcode: oldPasscode)
        let sealedBox = try AES.GCM.SealedBox(combined: wrappedKeyData)
        var rawKeyData = try AES.GCM.open(sealedBox, using: oldWrappingKey)
        defer { zeroize(&rawKeyData) }
        try saveWrappedKey(rawKeyData, for: space, passcode: newPasscode)
        try saveBiometricKey(rawKeyData, for: space)
        setActiveKey(SymmetricKey(data: rawKeyData), for: space)
    }

    func lock() {
        clearTemporaryFiles(clearActiveKeys: true)
        MediaThumbnailService.shared.clearCache()
    }

    func clearTemporaryFilesPreservingKeys() {
        clearTemporaryFiles(clearActiveKeys: false)
    }

    func clearTemporaryFile(relativePath: String) {
        let temporaryURL = stateQueue.sync {
            temporaryFilesByPath.removeValue(forKey: relativePath)
        }

        if let temporaryURL {
            removeManagedTemporaryFile(at: temporaryURL)
        }
    }

    private func clearTemporaryFiles(clearActiveKeys: Bool) {
        let temporaryFiles = stateQueue.sync {
            let files = Array(temporaryFilesByPath.values)
            temporaryFilesByPath.removeAll()
            temporaryFileGeneration &+= 1
            if clearActiveKeys {
                activeKeys.removeAll()
                lockGeneration &+= 1
            }
            return files
        }

        temporaryFiles.forEach { url in
            try? fileManager.removeItem(at: url)
        }

        try? fileManager.removeItem(at: temporaryDirectory)
    }

    func wipeAllPersistentKeys() {
        lock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }

    func encryptImportedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        space: VaultSpaceKind,
        progress: ((_ processedUnits: Int64, _ totalUnits: Int64) -> Void)? = nil
    ) throws {
        let key = try activeKey(for: space)
        try encryptFile(from: sourceURL, to: destinationURL, using: key, progress: progress)
    }

    func encryptPlaintextData(_ data: Data, to destinationURL: URL, space: VaultSpaceKind) throws {
        let key = try activeKey(for: space)
        try writeEncryptedData(data, to: destinationURL, using: key)
    }

    nonisolated func decryptedData(forEncryptedFileAt encryptedURL: URL, space: VaultSpaceKind) throws -> Data {
        let key = try activeKey(for: space)

        guard fileManager.fileExists(atPath: encryptedURL.path(percentEncoded: false)) else {
            throw VaultCryptoError.invalidEncryptedFile
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            return try Data(contentsOf: encryptedURL)
        }

        var decryptedData = Data()
        let inputHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer {
            try? inputHandle.close()
        }

        _ = try readExact(from: inputHandle, byteCount: Self.fileMagic.count)
        _ = try readExact(from: inputHandle, byteCount: 1)
        _ = try readExact(from: inputHandle, byteCount: 4)

        let chunksStart = try inputHandle.offset()
        let fileEnd = try inputHandle.seekToEnd()
        try inputHandle.seek(toOffset: chunksStart)
        let maxSealedLength = chunkSize + 28

        while true {
            let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
            if lengthData.isEmpty {
                break
            }

            guard lengthData.count == 4 else {
                throw VaultCryptoError.invalidEncryptedFile
            }

            let sealedLength = Int(UInt32(bigEndianData: lengthData))
            let offset = try inputHandle.offset()
            guard sealedLength >= 28,
                  sealedLength <= maxSealedLength,
                  offset <= fileEnd,
                  UInt64(sealedLength) <= fileEnd - offset else {
                throw VaultCryptoError.invalidEncryptedFile
            }
            let combinedData = try readExact(from: inputHandle, byteCount: sealedLength)
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            decryptedData.append(plaintext)
        }

        return decryptedData
    }

    nonisolated func temporaryExportGeneration(for space: VaultSpaceKind) -> Int? {
        stateQueue.sync { activeKeys[space] == nil ? nil : temporaryFileGeneration }
    }

    nonisolated func decryptedTemporaryURL(
        forEncryptedFileAt encryptedURL: URL,
        relativePath: String,
        originalFilename: String,
        space: VaultSpaceKind,
        cacheResult: Bool = true,
        exportGeneration: Int? = nil
    ) throws -> URL {
        let (key, startLockGeneration, startTempGeneration): (SymmetricKey, Int, Int) = try stateQueue.sync {
            guard let key = activeKeys[space] else {
                throw VaultCryptoError.keyUnavailable
            }
            if let exportGeneration, temporaryFileGeneration != exportGeneration {
                throw VaultCryptoError.keyUnavailable
            }
            return (key, lockGeneration, temporaryFileGeneration)
        }

        guard fileManager.fileExists(atPath: encryptedURL.path(percentEncoded: false)) else {
            return encryptedURL
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            return encryptedURL
        }

        if cacheResult {
            let cachedURL = stateQueue.sync { () -> URL? in
                guard lockGeneration == startLockGeneration,
                      exportGeneration == nil || temporaryFileGeneration == exportGeneration else {
                    return nil
                }
                return temporaryFilesByPath[relativePath]
            }
            if let cachedURL,
               fileManager.fileExists(atPath: cachedURL.path(percentEncoded: false)) {
                return cachedURL
            }
        }

        try ensureTemporaryDirectoryExists()
        let itemDirectory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: itemDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let tempURL = itemDirectory.appendingPathComponent(sanitizedTemporaryFilename(from: originalFilename))

        do {
            try decryptFile(
                from: encryptedURL,
                to: tempURL,
                using: key,
                shouldAbort: { [self] in
                    stateQueue.sync {
                        lockGeneration != startLockGeneration
                            || temporaryFileGeneration != startTempGeneration
                            || activeKeys[space] == nil
                    }
                }
            )
            try protectFile(at: tempURL)
        } catch {
            try? fileManager.removeItem(at: itemDirectory)
            throw error
        }

        let (isValid, replacedURL): (Bool, URL?) = stateQueue.sync {
            guard lockGeneration == startLockGeneration,
                  temporaryFileGeneration == startTempGeneration,
                  activeKeys[space] != nil else {
                return (false, nil)
            }
            if cacheResult {
                let previous = temporaryFilesByPath.updateValue(tempURL, forKey: relativePath)
                return (true, previous)
            }
            return (true, nil)
        }
        if !isValid {
            try? fileManager.removeItem(at: itemDirectory)
            throw VaultCryptoError.keyUnavailable
        }
        if let replacedURL, replacedURL != tempURL {
            removeManagedTemporaryFile(at: replacedURL)
        }
        return tempURL
    }

    nonisolated func clearTemporaryURLIfManaged(_ url: URL) {
        removeManagedTemporaryFile(at: url)
    }

    nonisolated private func removeManagedTemporaryFile(at url: URL) {
        let parent = url.deletingLastPathComponent()
        if parent.path(percentEncoded: false) == temporaryDirectory.path(percentEncoded: false) {
            try? fileManager.removeItem(at: url)
        } else if parent.deletingLastPathComponent().path(percentEncoded: false) == temporaryDirectory.path(percentEncoded: false) {
            try? fileManager.removeItem(at: parent)
        }
    }

    nonisolated private func sanitizedTemporaryFilename(from originalFilename: String) -> String {
        let strippedScalars = originalFilename.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value == 0 { return false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            // Strip Unicode bidirectional control/override characters (e.g. RTLO U+202E).
            if (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value)
                || value == 0x200E || value == 0x200F || value == 0x061C {
                return false
            }
            return true
        }
        let cleanedInput = String(String.UnicodeScalarView(strippedScalars))
        var candidate = (cleanedInput as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while candidate.hasPrefix(".") {
            candidate.removeFirst()
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return UUID().uuidString
        }

        let maxUTF8Bytes = 200
        if candidate.utf8.count <= maxUTF8Bytes {
            return candidate
        }

        let nsCandidate = candidate as NSString
        let ext = nsCandidate.pathExtension
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        if !extSuffix.isEmpty, extSuffix.utf8.count < maxUTF8Bytes - 16 {
            let stem = nsCandidate.deletingPathExtension
            let truncatedStem = truncateUTF8(stem, maxBytes: maxUTF8Bytes - extSuffix.utf8.count)
            if !truncatedStem.isEmpty {
                return truncatedStem + extSuffix
            }
        }

        let truncated = truncateUTF8(candidate, maxBytes: maxUTF8Bytes)
        return truncated.isEmpty ? UUID().uuidString : truncated
    }

    nonisolated private func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = ""
        var byteCount = 0
        for character in text {
            let charBytes = String(character).utf8.count
            if byteCount + charBytes > maxBytes {
                break
            }
            result.append(character)
            byteCount += charBytes
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func migrateFileToEncryptedStorageIfNeeded(at fileURL: URL, space: VaultSpaceKind) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return false
        }

        guard try !isEncryptedVaultFile(at: fileURL) else {
            return false
        }

        let key = try activeKey(for: space)
        let destinationURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).migration")

        do {
            try encryptFile(from: fileURL, to: destinationURL, using: key)
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: destinationURL)
            try protectFile(at: fileURL)
            return true
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    /// 读取当前空间媒体文件的明文字节数。
    /// 备份导出需要基于明文大小构建清单，否则导入时无法正确还原文件流。
    func plaintextByteCount(forEncryptedFileAt encryptedURL: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: encryptedURL.path(percentEncoded: false)) else {
            throw VaultCryptoError.invalidEncryptedFile
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            return sourceFileSize(at: encryptedURL)
        }

        let inputHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer {
            try? inputHandle.close()
        }

        _ = try readExact(from: inputHandle, byteCount: Self.fileMagic.count)
        _ = try readExact(from: inputHandle, byteCount: 1)
        _ = try readExact(from: inputHandle, byteCount: 4)

        let chunksStart = try inputHandle.offset()
        let fileEnd = try inputHandle.seekToEnd()
        try inputHandle.seek(toOffset: chunksStart)
        let maxSealedLength = chunkSize + 28

        var plaintextByteCount: Int64 = 0
        while true {
            let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
            if lengthData.isEmpty {
                break
            }

            guard lengthData.count == 4 else {
                throw VaultCryptoError.invalidEncryptedFile
            }

            let sealedLength = Int(UInt32(bigEndianData: lengthData))
            let offset = try inputHandle.offset()
            guard sealedLength >= 28,
                  sealedLength <= maxSealedLength,
                  offset <= fileEnd,
                  UInt64(sealedLength) <= fileEnd - offset else {
                throw VaultCryptoError.invalidEncryptedFile
            }
            try inputHandle.seek(toOffset: offset + UInt64(sealedLength))
            plaintextByteCount += Int64(sealedLength - 28)
        }

        return plaintextByteCount
    }

    /// 逐块解密当前空间媒体文件，并把明文分块回调给调用方。
    /// 这样导出备份时可以直接把“明文块”继续封装到外层导出加密中，而不用在磁盘落一份明文。
    nonisolated func streamPlaintextChunks(
        fromEncryptedFileAt encryptedURL: URL,
        space: VaultSpaceKind,
        onChunk: (Data) throws -> Void
    ) throws {
        let key = try activeKey(for: space)
        guard fileManager.fileExists(atPath: encryptedURL.path(percentEncoded: false)) else {
            throw VaultCryptoError.invalidEncryptedFile
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            let handle = try FileHandle(forReadingFrom: encryptedURL)
            defer {
                try? handle.close()
            }

            while true {
                let didReadChunk = try autoreleasepool { () throws -> Bool in
                    let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                    guard !chunk.isEmpty else { return false }
                    try onChunk(chunk)
                    return true
                }
                if !didReadChunk { break }
            }
            return
        }

        let inputHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer {
            try? inputHandle.close()
        }

        _ = try readExact(from: inputHandle, byteCount: Self.fileMagic.count)
        _ = try readExact(from: inputHandle, byteCount: 1)
        _ = try readExact(from: inputHandle, byteCount: 4)

        let chunksStart = try inputHandle.offset()
        let fileEnd = try inputHandle.seekToEnd()
        try inputHandle.seek(toOffset: chunksStart)
        while true {
            let didReadChunk = try autoreleasepool { () throws -> Bool in
                let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
                guard !lengthData.isEmpty else { return false }

                guard lengthData.count == 4 else {
                    throw VaultCryptoError.invalidEncryptedFile
                }

                let sealedLength = Int(UInt32(bigEndianData: lengthData))
                let offset = try inputHandle.offset()
                guard sealedLength >= 28,
                      sealedLength <= chunkSize + 28,
                      offset <= fileEnd,
                      UInt64(sealedLength) <= fileEnd - offset else {
                    throw VaultCryptoError.invalidEncryptedFile
                }
                let combinedData = try readExact(from: inputHandle, byteCount: sealedLength)
                let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
                let plaintext = try AES.GCM.open(sealedBox, using: key)
                try onChunk(plaintext)
                return true
            }
            if !didReadChunk { break }
        }
    }

    /// 创建一个写入器，把导入备份里解出的明文流重新封装为当前设备可读的加密媒体文件。
    nonisolated func makeEncryptedFileWriter(to destinationURL: URL, space: VaultSpaceKind) throws -> VaultEncryptedFileWriter {
        let key = try activeKey(for: space)
        return try VaultEncryptedFileWriter(
            destinationURL: destinationURL,
            key: key,
            chunkSize: chunkSize,
            fileManager: fileManager,
            fileMagic: Self.fileMagic,
            fileVersion: Self.fileVersion
        )
    }

    /// 创建按需分块解密流读取器，避免把大视频完整解密进内存。
    nonisolated func makeEncryptedStreamReader(
        forEncryptedFileAt encryptedURL: URL,
        space: VaultSpaceKind
    ) throws -> VaultEncryptedStreamReader {
        let key = try activeKey(for: space)
        guard fileManager.fileExists(atPath: encryptedURL.path(percentEncoded: false)) else {
            throw VaultCryptoError.invalidEncryptedFile
        }
        let isEncrypted = try isEncryptedVaultFile(at: encryptedURL)
        return try VaultEncryptedStreamReader(
            fileURL: encryptedURL,
            isEncrypted: isEncrypted,
            key: isEncrypted ? key : nil,
            headerByteCount: Self.fileMagic.count + 1 + 4,
            maxPlaintextChunkSize: chunkSize
        )
    }

    private func encryptFile(
        from sourceURL: URL,
        to destinationURL: URL,
        using key: SymmetricKey,
        progress: ((_ processedUnits: Int64, _ totalUnits: Int64) -> Void)? = nil
    ) throws {
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        let totalUnits = sourceFileSize(at: sourceURL)
        var processedUnits: Int64 = 0

        if fileManager.fileExists(atPath: tempURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(
            atPath: tempURL.path(percentEncoded: false),
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let inputHandle = try FileHandle(forReadingFrom: sourceURL)
        let outputHandle = try FileHandle(forWritingTo: tempURL)
        var outputClosed = false
        defer {
            try? inputHandle.close()
            if !outputClosed {
                try? outputHandle.close()
            }
        }

        do {
            try outputHandle.write(contentsOf: Self.fileMagic)
            try outputHandle.write(contentsOf: data(from: Self.fileVersion))
            try outputHandle.write(contentsOf: data(from: UInt32(chunkSize)))

            while true {
                let chunk = try inputHandle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    break
                }

                let sealedBox = try AES.GCM.seal(chunk, using: key)
                guard let combined = sealedBox.combined else {
                    throw VaultCryptoError.corruptEncryptedChunk
                }

                try outputHandle.write(contentsOf: data(from: UInt32(combined.count)))
                try outputHandle.write(contentsOf: combined)
                processedUnits += Int64(chunk.count)
                progress?(processedUnits, totalUnits)
            }
            try outputHandle.synchronize()
            try outputHandle.close()
            outputClosed = true

            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
            try protectFile(at: destinationURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func writeEncryptedData(_ plaintextData: Data, to destinationURL: URL, using key: SymmetricKey) throws {
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        if fileManager.fileExists(atPath: tempURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(
            atPath: tempURL.path(percentEncoded: false),
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let outputHandle = try FileHandle(forWritingTo: tempURL)
        var outputClosed = false
        defer {
            if !outputClosed {
                try? outputHandle.close()
            }
        }

        do {
            try outputHandle.write(contentsOf: Self.fileMagic)
            try outputHandle.write(contentsOf: data(from: Self.fileVersion))
            try outputHandle.write(contentsOf: data(from: UInt32(chunkSize)))

            var offset = 0
            while offset < plaintextData.count {
                let nextOffset = min(offset + chunkSize, plaintextData.count)
                let chunk = plaintextData.subdata(in: offset..<nextOffset)
                let sealedBox = try AES.GCM.seal(chunk, using: key)
                guard let combined = sealedBox.combined else {
                    throw VaultCryptoError.corruptEncryptedChunk
                }

                try outputHandle.write(contentsOf: data(from: UInt32(combined.count)))
                try outputHandle.write(contentsOf: combined)
                offset = nextOffset
            }
            try outputHandle.synchronize()
            try outputHandle.close()
            outputClosed = true

            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
            try protectFile(at: destinationURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    nonisolated private func decryptFile(
        from encryptedURL: URL,
        to destinationURL: URL,
        using key: SymmetricKey,
        shouldAbort: (() -> Bool)? = nil
    ) throws {
        if !fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }

        if !fileManager.fileExists(atPath: encryptedURL.path(percentEncoded: false)) {
            throw VaultCryptoError.invalidEncryptedFile
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: encryptedURL, to: destinationURL)
            return
        }

        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destinationURL)
        }
        fileManager.createFile(
            atPath: destinationURL.path(percentEncoded: false),
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        let inputHandle = try FileHandle(forReadingFrom: encryptedURL)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }

        do {
            _ = try readExact(from: inputHandle, byteCount: Self.fileMagic.count)
            _ = try readExact(from: inputHandle, byteCount: 1)
            _ = try readExact(from: inputHandle, byteCount: 4)

            let chunksStart = try inputHandle.offset()
            let fileEnd = try inputHandle.seekToEnd()
            try inputHandle.seek(toOffset: chunksStart)
            let maxSealedLength = chunkSize + 28

            while true {
                if shouldAbort?() == true {
                    throw VaultCryptoError.keyUnavailable
                }
                let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
                if lengthData.isEmpty {
                    break
                }

                guard lengthData.count == 4 else {
                    throw VaultCryptoError.invalidEncryptedFile
                }

                let sealedLength = Int(UInt32(bigEndianData: lengthData))
                let offset = try inputHandle.offset()
                guard sealedLength >= 28,
                      sealedLength <= maxSealedLength,
                      offset <= fileEnd,
                      UInt64(sealedLength) <= fileEnd - offset else {
                    throw VaultCryptoError.invalidEncryptedFile
                }
                let combinedData = try readExact(from: inputHandle, byteCount: sealedLength)
                let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
                let plaintext = try AES.GCM.open(sealedBox, using: key)
                if shouldAbort?() == true {
                    throw VaultCryptoError.keyUnavailable
                }
                try outputHandle.write(contentsOf: plaintext)
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    nonisolated func isEncryptedVaultFile(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let magic = try handle.read(upToCount: Self.fileMagic.count) ?? Data()
        return magic == Self.fileMagic
    }

    nonisolated private func activeKey(for space: VaultSpaceKind) throws -> SymmetricKey {
        guard let key = stateQueue.sync(execute: { activeKeys[space] }) else {
            throw VaultCryptoError.keyUnavailable
        }
        return key
    }

    private func setActiveKey(_ key: SymmetricKey, for space: VaultSpaceKind) {
        stateQueue.sync {
            activeKeys[space] = key
        }
    }

    private func saveWrappedKey(_ rawKeyData: Data, for space: VaultSpaceKind, passcode: String) throws {
        let wrappingKey = wrappingKey(for: space, passcode: passcode)
        let sealedBox = try AES.GCM.seal(rawKeyData, using: wrappingKey)
        guard let wrappedKeyData = sealedBox.combined else {
            throw VaultCryptoError.corruptEncryptedChunk
        }

        try saveKeychainData(
            wrappedKeyData,
            account: wrappedAccount(for: space),
            accessControl: nil
        )
    }

    private func saveBiometricKeyIfMissing(_ rawKeyData: Data, for space: VaultSpaceKind) throws {
        guard !keychainItemExists(for: biometricAccount(for: space)) else { return }
        try saveBiometricKey(rawKeyData, for: space)
    }

    private func saveBiometricKey(_ rawKeyData: Data, for space: VaultSpaceKind) throws {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            _ = accessError?.takeRetainedValue()
            throw VaultCryptoError.keychainFailure(errSecParam)
        }

        try saveKeychainData(rawKeyData, account: biometricAccount(for: space), accessControl: accessControl)
    }

    private func saveKeychainData(_ data: Data, account: String, accessControl: SecAccessControl?) throws {
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        if let accessControl {
            attributes[kSecAttrAccessControl as String] = accessControl
            var updateQuery = matchQuery
            updateQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess {
                return
            }
            if updateStatus == errSecItemNotFound {
                let addStatus = SecItemAdd(attributes as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
                }
                return
            }

            let deleteStatus = SecItemDelete(matchQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }

            let reAddStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard reAddStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(reAddStatus))
            }
            return
        }

        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let updateStatus = SecItemUpdate(
            matchQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
            return
        }

        throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
    }

    private func keychainData(for account: String, authenticationContext: LAContext? = nil) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        return item as? Data
    }

    private func keychainItemExists(for account: String) -> Bool {
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
            ] as CFDictionary,
            nil
        )

        return status != errSecItemNotFound
    }

    private func wrappingKey(for space: VaultSpaceKind, passcode: String) -> SymmetricKey {
        var material = Data("SecurityFolder|\(space.rawValue)|\(passcode)".utf8)
        defer { zeroize(&material) }
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    nonisolated private func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
    }

    nonisolated private func protectFile(at url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func sourceFileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    nonisolated private func ensureTemporaryDirectoryExists() throws {
        if !fileManager.fileExists(atPath: temporaryDirectory.path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
    }

    nonisolated private func readExact(from handle: FileHandle, byteCount: Int) throws -> Data {
        guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
            throw VaultCryptoError.invalidEncryptedFile
        }
        return data
    }

    private func data<T>(from value: T) -> Data where T: FixedWidthInteger {
        var bigEndianValue = value.bigEndian
        return Data(bytes: &bigEndianValue, count: MemoryLayout<T>.size)
    }

    private func data(from value: UInt8) -> Data {
        Data([value])
    }

    nonisolated private var temporaryDirectory: URL {
        fileManager.temporaryDirectory.appendingPathComponent("VaultDecryptedCache", isDirectory: true)
    }

    private var keychainService: String {
        "com.cinmouice.SecurityFolder.vault"
    }

    private func biometricAccount(for space: VaultSpaceKind) -> String {
        "space.\(space.rawValue).biometric.key"
    }

    private func wrappedAccount(for space: VaultSpaceKind) -> String {
        "space.\(space.rawValue).wrapped.key"
    }
}

nonisolated final class VaultEncryptedFileWriter {
    private let destinationURL: URL
    private let tempURL: URL
    private let key: SymmetricKey
    private let fileManager: FileManager
    private let fileMagic: Data
    private let fileVersion: UInt8
    private let outputHandle: FileHandle
    private var isFinished = false

    init(
        destinationURL: URL,
        key: SymmetricKey,
        chunkSize: Int,
        fileManager: FileManager,
        fileMagic: Data,
        fileVersion: UInt8
    ) throws {
        self.destinationURL = destinationURL
        self.tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        self.key = key
        self.fileManager = fileManager
        self.fileMagic = fileMagic
        self.fileVersion = fileVersion

        if !fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        if fileManager.fileExists(atPath: tempURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(
            atPath: tempURL.path(percentEncoded: false),
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        outputHandle = try FileHandle(forWritingTo: tempURL)
        try outputHandle.write(contentsOf: fileMagic)
        try outputHandle.write(contentsOf: Data([fileVersion]))

        var chunkSizeValue = UInt32(chunkSize).bigEndian
        let chunkSizeData = Data(bytes: &chunkSizeValue, count: MemoryLayout<UInt32>.size)
        try outputHandle.write(contentsOf: chunkSizeData)
    }

    func append(plaintextChunk: Data) throws {
        guard !isFinished else { return }
        let sealedBox = try AES.GCM.seal(plaintextChunk, using: key)
        guard let combined = sealedBox.combined else {
            throw VaultCryptoError.corruptEncryptedChunk
        }

        var length = UInt32(combined.count).bigEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try outputHandle.write(contentsOf: lengthData)
        try outputHandle.write(contentsOf: combined)
    }

    func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        do {
            try outputHandle.synchronize()
            try outputHandle.close()

            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destinationURL.path(percentEncoded: false))
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    func abort() {
        guard !isFinished else { return }
        isFinished = true
        try? outputHandle.close()
        try? fileManager.removeItem(at: tempURL)
    }

    deinit {
        if !isFinished {
            abort()
        }
    }
}

nonisolated final class VaultEncryptedStreamReader: @unchecked Sendable {
    private struct ChunkEntry {
        let fileOffset: UInt64
        let sealedLength: Int
        let plaintextOffset: Int64
        let plaintextLength: Int64
    }

    let totalPlaintextBytes: Int64

    private let handle: FileHandle
    private let isEncrypted: Bool
    private let key: SymmetricKey?
    private let chunks: [ChunkEntry]
    private let lock = NSLock()
    private var isClosed = false

    init(fileURL: URL, isEncrypted: Bool, key: SymmetricKey?, headerByteCount: Int, maxPlaintextChunkSize: Int) throws {
        self.handle = try FileHandle(forReadingFrom: fileURL)
        self.isEncrypted = isEncrypted
        self.key = key

        if !isEncrypted {
            let endOffset = try handle.seekToEnd()
            self.totalPlaintextBytes = Int64(endOffset)
            self.chunks = []
            return
        }

        try handle.seek(toOffset: UInt64(headerByteCount))
        var scannedChunks: [ChunkEntry] = []
        var plaintextCursor: Int64 = 0
        let fileEnd = try handle.seekToEnd()
        var fileCursor = UInt64(headerByteCount)

        while fileCursor < fileEnd {
            try handle.seek(toOffset: fileCursor)
            let lengthData = try handle.read(upToCount: 4) ?? Data()
            if lengthData.isEmpty { break }
            guard lengthData.count == 4 else {
                try? handle.close()
                throw VaultCryptoError.invalidEncryptedFile
            }
            let sealedLength = Int(UInt32(bigEndianData: lengthData))
            let payloadOffset = fileCursor + 4
            guard sealedLength >= 28,
                  sealedLength - 28 <= maxPlaintextChunkSize,
                  UInt64(sealedLength) <= fileEnd - payloadOffset else {
                try? handle.close()
                throw VaultCryptoError.invalidEncryptedFile
            }
            let plaintextLength = Int64(sealedLength - 28)
            scannedChunks.append(ChunkEntry(
                fileOffset: payloadOffset,
                sealedLength: sealedLength,
                plaintextOffset: plaintextCursor,
                plaintextLength: plaintextLength
            ))
            plaintextCursor += plaintextLength
            fileCursor = payloadOffset + UInt64(sealedLength)
        }

        self.chunks = scannedChunks
        self.totalPlaintextBytes = plaintextCursor
    }

    func readSlice(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, offset < totalPlaintextBytes, length > 0 else {
            return Data()
        }
        let clampedLength = Int(min(Int64(length), totalPlaintextBytes - offset))

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return Data() }

        if !isEncrypted {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: clampedLength) ?? Data()
        }

        guard let key else { throw VaultCryptoError.keyUnavailable }

        var result = Data()
        result.reserveCapacity(clampedLength)
        var currentOffset = offset
        let targetEnd = offset + Int64(clampedLength)

        var chunkIndex = findChunkIndex(forPlaintextOffset: currentOffset)
        while currentOffset < targetEnd, chunkIndex < chunks.count {
            let entry = chunks[chunkIndex]
            try handle.seek(toOffset: entry.fileOffset)
            guard let combined = try handle.read(upToCount: entry.sealedLength),
                  combined.count == entry.sealedLength else {
                throw VaultCryptoError.invalidEncryptedFile
            }
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)

            let localStart = Int(currentOffset - entry.plaintextOffset)
            let localEnd = Int(min(entry.plaintextLength, targetEnd - entry.plaintextOffset))
            if localEnd > localStart, localEnd <= plaintext.count {
                result.append(plaintext.subdata(in: localStart..<localEnd))
            }
            currentOffset = entry.plaintextOffset + entry.plaintextLength
            chunkIndex += 1
        }

        return result
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    deinit {
        close()
    }

    private func findChunkIndex(forPlaintextOffset offset: Int64) -> Int {
        var low = 0
        var high = chunks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let entry = chunks[mid]
            if offset < entry.plaintextOffset {
                high = mid - 1
            } else if offset >= entry.plaintextOffset + entry.plaintextLength {
                low = mid + 1
            } else {
                return mid
            }
        }
        return chunks.count
    }
}

private extension SymmetricKey {
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}

nonisolated private extension UInt32 {
    init(bigEndianData data: Data) {
        self = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
        }
    }
}
