import Darwin
import SwiftUI

struct StoredVaultBackupFilesView: View {
    @State private var files: [StoredVaultBackupFile] = []
    @State private var selectedFileIDs: Set<StoredVaultBackupFile.ID> = []
    @State private var isSelecting = false
    @State private var sharePayload: SharePayload?
    private struct SharePayload: Identifiable {
        let id = UUID()
        let urls: [URL]
    }
    @State private var pendingDeleteFiles: [StoredVaultBackupFile] = []
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    private let store = VaultBackupFileStore.shared
    private let byteFormatter = ByteCountFormatter()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView(
                    String(localized: "未找到备份文件"),
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text(String(localized: "生成备份后会显示在这里。"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(files) { file in
                    backupFileRow(file)
                }
            }
        }
        .navigationTitle(String(localized: "当前备份文件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !files.isEmpty {
                    Button(isSelecting ? String(localized: "完成") : String(localized: "选择")) {
                        withAnimation(.snappy(duration: 0.18)) {
                            isSelecting.toggle()
                            if !isSelecting {
                                selectedFileIDs.removeAll()
                            }
                        }
                    }
                }
            }

            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(String(localized: "导出")) {
                        exportSelectedFiles()
                    }
                    .disabled(selectedFiles.isEmpty)

                    Spacer()

                    Button(String(localized: "删除"), role: .destructive) {
                        requestDelete(selectedFiles)
                    }
                    .disabled(selectedFiles.isEmpty)
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(activityItems: payload.urls, onPresented: {
                #if DEBUG
                VaultBackupFilesDebugLog.mark("shareSheet.presented", "fileCount=\(payload.urls.count)")
                #endif
            }, onFinish: { completed in
                #if DEBUG
                VaultBackupFilesDebugLog.mark("shareSheet.dismissed", "completed=\(completed) fileCount=\(payload.urls.count)")
                #endif
            })
        }
        .confirmationDialog(
            String(localized: "删除备份文件？"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除"), role: .destructive) {
                #if DEBUG
                VaultBackupFilesDebugLog.mark("delete.confirmed", "fileCount=\(pendingDeleteFiles.count)")
                #endif
                deletePendingFiles()
            }
            Button(String(localized: "取消"), role: .cancel) {
                #if DEBUG
                VaultBackupFilesDebugLog.mark("delete.cancelled", "fileCount=\(pendingDeleteFiles.count)")
                #endif
                pendingDeleteFiles.removeAll()
            }
        } message: {
            Text(String(localized: "这些备份文件只会从本机 App 存储中删除，不会影响媒体库内容。"))
        }
        .alert(String(localized: "操作失败"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue {
                    errorMessage = nil
                }
            }
        )) {
            Button(String(localized: "知道了"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: reloadFiles)
    }

    private var selectedFiles: [StoredVaultBackupFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    private func backupFileRow(_ file: StoredVaultBackupFile) -> some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: selectedFileIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedFileIDs.contains(file.id) ? .blue : .secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(file.fileName)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Text(byteFormatter.string(fromByteCount: file.byteCount))
                    Text(dateFormatter.string(from: file.createdAt))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !isSelecting {
                Button(String(localized: "导出")) {
                    exportFiles([file], action: "singleExport")
                }
                .buttonStyle(.bordered)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            toggleSelection(for: file)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            backupFileDeleteSwipeButton(for: file)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            backupFileDeleteSwipeButton(for: file)
        }
    }

    @ViewBuilder
    private func backupFileDeleteSwipeButton(for file: StoredVaultBackupFile) -> some View {
        Button(role: .destructive) {
            requestDelete([file])
        } label: {
            Label(String(localized: "删除"), systemImage: "trash")
        }
        .tint(.red)
    }

    private func toggleSelection(for file: StoredVaultBackupFile) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
        } else {
            selectedFileIDs.insert(file.id)
        }
    }

    private func exportSelectedFiles() {
        exportFiles(selectedFiles, action: "batchExport")
    }

    private func exportFiles(_ files: [StoredVaultBackupFile], action: String) {
        guard !files.isEmpty else { return }
        #if DEBUG
        VaultBackupFilesDebugLog.mark("\(action).begin", "fileCount=\(files.count)")
        #endif
        do {
            let directoryURL = try store.backupFilesDirectory()
            let validURLs = files.compactMap { file -> URL? in
                let exists = fileExists(at: file.url)
                let bytes = fileSize(at: file.url)
                let inside = file.url.standardizedFileURL.path.hasPrefix(directoryURL.standardizedFileURL.path + "/")
                #if DEBUG
                VaultBackupFilesDebugLog.mark(
                    "\(action).file",
                    "name=\(file.fileName) ext=\(file.url.pathExtension) exists=\(exists) bytes=\(bytes) insideBackupFiles=\(inside)"
                )
                #endif
                return exists && bytes > 0 && inside && file.url.pathExtension.lowercased() == "vault" ? file.url : nil
            }
            guard !validURLs.isEmpty else {
                #if DEBUG
                VaultBackupFilesDebugLog.mark("\(action).error", "reason=noValidFiles")
                #endif
                errorMessage = String(localized: "操作失败")
                return
            }
            #if DEBUG
            VaultBackupFilesDebugLog.mark("\(action).share.requested", "fileCount=\(validURLs.count)")
            #endif
            sharePayload = SharePayload(urls: validURLs)
        } catch {
            #if DEBUG
            VaultBackupFilesDebugLog.mark("\(action).error", VaultBackupFilesDebugLog.errorDetails(error))
            #endif
            errorMessage = error.localizedDescription
        }
    }

    private func requestDelete(_ files: [StoredVaultBackupFile]) {
        #if DEBUG
        VaultBackupFilesDebugLog.mark("delete.request", "fileCount=\(files.count)")
        files.forEach { file in
            VaultBackupFilesDebugLog.mark(
                "delete.request.file",
                "name=\(file.fileName) ext=\(file.url.pathExtension) exists=\(fileExists(at: file.url)) bytes=\(fileSize(at: file.url))"
            )
        }
        #endif
        pendingDeleteFiles = files
        showingDeleteConfirmation = !files.isEmpty
        #if DEBUG
        VaultBackupFilesDebugLog.mark("delete.confirmation.present", "fileCount=\(pendingDeleteFiles.count)")
        #endif
    }

    private func deletePendingFiles() {
        do {
            let deletedIDs = Set(pendingDeleteFiles.map(\.id))
            #if DEBUG
            VaultBackupFilesDebugLog.mark("delete.perform.begin", "fileCount=\(pendingDeleteFiles.count)")
            #endif
            try store.deleteBackupFiles(pendingDeleteFiles)
            #if DEBUG
            pendingDeleteFiles.forEach { file in
                VaultBackupFilesDebugLog.mark(
                    "delete.perform.after",
                    "name=\(file.fileName) exists=\(fileExists(at: file.url)) bytes=\(fileSize(at: file.url))"
                )
            }
            VaultBackupFilesDebugLog.mark("delete.perform.finish", "fileCount=\(pendingDeleteFiles.count)")
            #endif
            pendingDeleteFiles.removeAll()
            selectedFileIDs.subtract(deletedIDs)
            reloadFiles()
        } catch {
            #if DEBUG
            VaultBackupFilesDebugLog.mark("delete.perform.error", VaultBackupFilesDebugLog.errorDetails(error))
            #endif
            errorMessage = error.localizedDescription
        }
    }

    private func reloadFiles() {
        do {
            #if DEBUG
            VaultBackupFilesDebugLog.mark("view.reload.begin")
            #endif
            files = try store.listBackupFiles()
            #if DEBUG
            VaultBackupFilesDebugLog.mark("view.reload.finish", "fileCount=\(files.count)")
            #endif
            selectedFileIDs = selectedFileIDs.intersection(Set(files.map(\.id)))
            if files.isEmpty {
                isSelecting = false
            }
        } catch {
            #if DEBUG
            VaultBackupFilesDebugLog.mark("view.reload.error", VaultBackupFilesDebugLog.errorDetails(error))
            #endif
            errorMessage = error.localizedDescription
        }
    }

    private func fileExists(at url: URL) -> Bool {
        fileSize(at: url) >= 0
    }

    private func fileSize(at url: URL) -> Int64 {
        var fileStat = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileStat) }) == 0 else {
            return -1
        }
        return Int64(fileStat.st_size)
    }
}
