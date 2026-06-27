import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum VaultCryptoError: LocalizedError {
    case biometricUnavailable
    case biometricKeyMissing
    case keyUnavailable
    case invalidEncryptedFile
    case corruptEncryptedChunk

    var errorDescription: String? {
        switch self {
        case .biometricUnavailable:
            return String(localized: "当前设备不可用 Face ID / Touch ID。")
        case .biometricKeyMissing:
            return String(localized: "默认生物识别空间的密钥还没有完成绑定。")
        case .keyUnavailable:
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

    /// 使用当前空间绑定的生物识别保护密钥直接解锁，不再依赖明文密码。
    func unlockWithBiometrics(space: VaultSpaceKind) throws {
        guard biometricUnlockAvailable else {
            throw VaultCryptoError.biometricUnavailable
        }

        let context = LAContext()
        context.localizedReason = String.localizedStringWithFormat(
            String(localized: "使用 %@ 解锁%@"),
            biometricDisplayName,
            SpaceDisplaySettings.displayName(for: space)
        )
        guard let keyData = try keychainData(for: biometricAccount(for: space), authenticationContext: context) else {
            throw VaultCryptoError.biometricKeyMissing
        }

        setActiveKey(SymmetricKey(data: keyData), for: space)
    }

    /// 使用密码解锁空间；如果该空间首次配置密码，会同步生成该空间的 DEK 与生物识别入口。
    func unlock(space: VaultSpaceKind, passcode: String) throws {
        try ensureWrappedKeyExists(for: space, passcode: passcode)
        guard let wrappedKeyData = try keychainData(for: wrappedAccount(for: space)) else {
            throw VaultCryptoError.keyUnavailable
        }

        let wrappingKey = wrappingKey(for: space, passcode: passcode)
        let sealedBox = try AES.GCM.SealedBox(combined: wrappedKeyData)
        let rawKeyData = try AES.GCM.open(sealedBox, using: wrappingKey)
        setActiveKey(SymmetricKey(data: rawKeyData), for: space)
        try saveBiometricKeyIfMissing(rawKeyData, for: space)
    }

    /// 首次设置密码时创建空间主密钥；若该空间已经有密钥，则只做重包裹。
    func configurePasscode(for space: VaultSpaceKind, newPasscode: String) throws {
        guard !keychainItemExists(for: wrappedAccount(for: space)) else {
            throw VaultCryptoError.keyUnavailable
        }

        let newKey = SymmetricKey(size: .bits256)
        let rawKeyData = newKey.rawData
        try saveWrappedKey(rawKeyData, for: space, passcode: newPasscode)
        try saveBiometricKey(rawKeyData, for: space)
        setActiveKey(newKey, for: space)
    }

    /// 修改空间密码时不重加密媒体，只重新包裹现有 DEK。
    func changePasscode(for space: VaultSpaceKind, oldPasscode: String, newPasscode: String) throws {
        try ensureWrappedKeyExists(for: space, passcode: oldPasscode)
        guard let wrappedKeyData = try keychainData(for: wrappedAccount(for: space)) else {
            throw VaultCryptoError.keyUnavailable
        }

        let oldWrappingKey = wrappingKey(for: space, passcode: oldPasscode)
        let sealedBox = try AES.GCM.SealedBox(combined: wrappedKeyData)
        let rawKeyData = try AES.GCM.open(sealedBox, using: oldWrappingKey)
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
            try? fileManager.removeItem(at: temporaryURL)
        }
    }

    private func clearTemporaryFiles(clearActiveKeys: Bool) {
        let temporaryFiles = stateQueue.sync {
            let files = Array(temporaryFilesByPath.values)
            temporaryFilesByPath.removeAll()
            if clearActiveKeys {
                activeKeys.removeAll()
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

    func decryptedData(forEncryptedFileAt encryptedURL: URL, space: VaultSpaceKind) throws -> Data {
        let key = try activeKey(for: space)

        guard fileManager.fileExists(atPath: encryptedURL.path()) else {
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

        while true {
            let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
            if lengthData.isEmpty {
                break
            }

            guard lengthData.count == 4 else {
                throw VaultCryptoError.invalidEncryptedFile
            }

            let sealedLength = Int(UInt32(bigEndianData: lengthData))
            let combinedData = try readExact(from: inputHandle, byteCount: sealedLength)
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            decryptedData.append(plaintext)
        }

        return decryptedData
    }

    nonisolated func decryptedTemporaryURL(
        forEncryptedFileAt encryptedURL: URL,
        relativePath: String,
        originalFilename: String,
        space: VaultSpaceKind,
        cacheResult: Bool = true
    ) throws -> URL {
        guard fileManager.fileExists(atPath: encryptedURL.path()) else {
            return encryptedURL
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            return encryptedURL
        }

        if cacheResult {
            if let cachedURL = stateQueue.sync(execute: { temporaryFilesByPath[relativePath] }),
               fileManager.fileExists(atPath: cachedURL.path()) {
                return cachedURL
            }
        }

        let key = try activeKey(for: space)
        try ensureTemporaryDirectoryExists()
        let tempURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((originalFilename as NSString).pathExtension)

        try decryptFile(from: encryptedURL, to: tempURL, using: key)
        try protectFile(at: tempURL)

        if cacheResult {
            stateQueue.sync {
                temporaryFilesByPath[relativePath] = tempURL
            }
        }
        return tempURL
    }

    nonisolated func clearTemporaryURLIfManaged(_ url: URL) {
        guard url.deletingLastPathComponent().path() == temporaryDirectory.path() else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    func migrateFileToEncryptedStorageIfNeeded(at fileURL: URL, space: VaultSpaceKind) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path()) else {
            return false
        }

        guard try !isEncryptedVaultFile(at: fileURL) else {
            return false
        }

        let key = try activeKey(for: space)
        let destinationURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).migration")

        try encryptFile(from: fileURL, to: destinationURL, using: key)
        try fileManager.removeItem(at: fileURL)
        try fileManager.moveItem(at: destinationURL, to: fileURL)
        try protectFile(at: fileURL)
        return true
    }

    /// 读取当前空间媒体文件的明文字节数。
    /// 备份导出需要基于明文大小构建清单，否则导入时无法正确还原文件流。
    func plaintextByteCount(forEncryptedFileAt encryptedURL: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: encryptedURL.path()) else {
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
            guard sealedLength >= 28 else {
                throw VaultCryptoError.invalidEncryptedFile
            }
            _ = try readExact(from: inputHandle, byteCount: sealedLength)
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
        guard fileManager.fileExists(atPath: encryptedURL.path()) else {
            throw VaultCryptoError.invalidEncryptedFile
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            let handle = try FileHandle(forReadingFrom: encryptedURL)
            defer {
                try? handle.close()
            }

            while true {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    break
                }
                try onChunk(chunk)
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

        while true {
            let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
            if lengthData.isEmpty {
                break
            }

            guard lengthData.count == 4 else {
                throw VaultCryptoError.invalidEncryptedFile
            }

            let sealedLength = Int(UInt32(bigEndianData: lengthData))
            let combinedData = try readExact(from: inputHandle, byteCount: sealedLength)
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            try onChunk(plaintext)
        }
    }

    /// 创建一个写入器，把导入备份里解出的明文流重新封装为当前设备可读的加密媒体文件。
    func makeEncryptedFileWriter(to destinationURL: URL, space: VaultSpaceKind) throws -> VaultEncryptedFileWriter {
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

        if fileManager.fileExists(atPath: tempURL.path()) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(atPath: tempURL.path(), contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: sourceURL)
        let outputHandle = try FileHandle(forWritingTo: tempURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
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
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
        try protectFile(at: destinationURL)
    }

    private func writeEncryptedData(_ plaintextData: Data, to destinationURL: URL, using key: SymmetricKey) throws {
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        if fileManager.fileExists(atPath: tempURL.path()) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(atPath: tempURL.path(), contents: nil)
        let outputHandle = try FileHandle(forWritingTo: tempURL)
        defer {
            try? outputHandle.close()
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
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
        try protectFile(at: destinationURL)
    }

    nonisolated private func decryptFile(from encryptedURL: URL, to destinationURL: URL, using key: SymmetricKey) throws {
        if !fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path()) {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        if !fileManager.fileExists(atPath: encryptedURL.path()) {
            throw VaultCryptoError.invalidEncryptedFile
        }

        guard try isEncryptedVaultFile(at: encryptedURL) else {
            if fileManager.fileExists(atPath: destinationURL.path()) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: encryptedURL, to: destinationURL)
            return
        }

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }
        fileManager.createFile(atPath: destinationURL.path(), contents: nil)

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

            while true {
                let lengthData = try inputHandle.read(upToCount: 4) ?? Data()
                if lengthData.isEmpty {
                    break
                }

                guard lengthData.count == 4 else {
                    throw VaultCryptoError.invalidEncryptedFile
                }

                let sealedLength = Int(UInt32(bigEndianData: lengthData))
                let combinedData = try readExact(from: inputHandle, byteCount: sealedLength)
                let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
                let plaintext = try AES.GCM.open(sealedBox, using: key)
                try outputHandle.write(contentsOf: plaintext)
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    nonisolated private func isEncryptedVaultFile(at url: URL) throws -> Bool {
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

    private func ensureWrappedKeyExists(for space: VaultSpaceKind, passcode: String) throws {
        if keychainItemExists(for: wrappedAccount(for: space)) {
            return
        }

        let newKey = SymmetricKey(size: .bits256)
        let rawKeyData = newKey.rawData
        try saveWrappedKey(rawKeyData, for: space, passcode: passcode)
        try saveBiometricKeyIfMissing(rawKeyData, for: space)
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
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        )

        try saveKeychainData(rawKeyData, account: biometricAccount(for: space), accessControl: accessControl)
    }

    private func saveKeychainData(_ data: Data, account: String, accessControl: SecAccessControl?) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        if let accessControl {
            attributes[kSecAttrAccessControl as String] = accessControl
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let deleteStatus = SecItemDelete(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService,
                    kSecAttrAccount as String: account
                ] as CFDictionary
            )

            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }

            let reAddStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard reAddStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(reAddStatus))
            }
            return
        }

        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
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

        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private func wrappingKey(for space: VaultSpaceKind, passcode: String) -> SymmetricKey {
        let material = Data("SecurityFolder|\(space.rawValue)|\(passcode)".utf8)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    nonisolated private func protectFile(at url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path())
    }

    private func sourceFileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path()),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    nonisolated private func ensureTemporaryDirectoryExists() throws {
        if !fileManager.fileExists(atPath: temporaryDirectory.path()) {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
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

final class VaultEncryptedFileWriter {
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

        if !fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path()) {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        if fileManager.fileExists(atPath: tempURL.path()) {
            try fileManager.removeItem(at: tempURL)
        }

        fileManager.createFile(atPath: tempURL.path(), contents: nil)
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
        try outputHandle.close()

        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destinationURL.path())
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

private extension SymmetricKey {
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}

nonisolated private extension UInt32 {
    init(bigEndianData data: Data) {
        self = data.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: UInt32.self).bigEndian
        }
    }
}
