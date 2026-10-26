import Foundation
import CryptoKit

public struct FileChangedError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "远端文件已变化，请重新载入、另存为或明确覆盖。" }
}

public enum ConflictDecision: Sendable { case skip, overwrite, cancel }

public struct FileConflict: Sendable {
    public let source: FileEntry
    public let destination: FileEntry
}

public enum TransferEvent: Sendable {
    case progress(path: String, bytes: UInt64, total: UInt64)
    case completed(String)
    case skipped(path: String, reason: String)
    case warning(String)
}

public struct TransferEngine: Sendable {
    public typealias EventHandler = @Sendable (TransferEvent) async -> Void
    public typealias ConflictHandler = @Sendable (FileConflict) async -> ConflictDecision
    public init() {}

    public func replaceContents(_ data: Data, at path: String, in store: any FileStore,
                                expectedDigest: String?, overwriteChanged: Bool = false) async throws {
        let directory = FilePath.parent(try FilePath.normalize(path))
        guard try await store.canonicalDirectory(at: directory) == directory else { throw HostDockError("目标目录已改变。") }
        let original = try await store.metadata(at: path)
        guard original == nil || original?.kind == .file else { throw HostDockError("目标不是普通文件。") }
        if !overwriteChanged {
            if original != nil {
                guard let expectedDigest, try await FileOperations.digest(at: path, in: store) == expectedDigest else { throw FileChangedError() }
            } else if expectedDigest != nil { throw FileChangedError() }
        }
        let temporary = try FilePath.join(directory, name: ".hostdock-\(UUID()).part")
        let writer = try await store.createWriter(at: temporary)
        do {
            if let mode = original?.permissions, let created = try await store.metadata(at: temporary)?.permissions,
               created & ~mode != 0 { try await store.setPermissions(mode, at: temporary) }
            for offset in stride(from: 0, to: data.count, by: 64 * 1024) {
                try Task.checkCancellation()
                try await writer.write(data.subdata(in: offset..<min(data.count, offset + 64 * 1024)))
            }
            try await writer.close()
            if let permissions = original?.permissions { try await store.setPermissions(permissions, at: temporary) }
            let staged = try await FileOperations.digest(at: temporary, in: store)
            guard staged == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
                throw HostDockError("编辑内容上传校验失败，原文件保留。")
            }
            if let expectedDigest, original != nil, !overwriteChanged,
               try await FileOperations.digest(at: path, in: store) != expectedDigest { throw FileChangedError() }
            try Task.checkCancellation()
            try await commit(temporary, to: path, replacing: original, in: store, retainBackup: true, onEvent: { _ in })
        } catch {
            try? await writer.close()
            try? await store.removeFile(at: temporary)
            throw error
        }
    }

    public func transfer(
        _ entries: [FileEntry], from source: any FileStore, to destination: any FileStore,
        directory: String,
        onConflict: @escaping ConflictHandler = { _ in .skip },
        onEvent: @escaping EventHandler = { _ in }
    ) async throws {
        let root = try await destination.canonicalDirectory(at: directory)
        for entry in FilePath.topLevelSelection(entries) {
            try Task.checkCancellation()
            try await copy(entry, from: source, to: destination, directory: root,
                           onConflict: onConflict, onEvent: onEvent)
        }
    }

    private func copy(
        _ selected: FileEntry, from source: any FileStore, to destination: any FileStore,
        directory: String, onConflict: @escaping ConflictHandler, onEvent: @escaping EventHandler
    ) async throws {
        try Task.checkCancellation()
        guard let entry = try await source.metadata(at: selected.path) else {
            throw HostDockError("源文件已不存在：\(selected.path)")
        }
        guard entry.kind == .file || entry.kind == .directory else {
            await onEvent(.skipped(path: entry.path, reason: "符号链接或特殊文件"))
            return
        }
        let target = try FilePath.join(directory, name: entry.name)
        let existing = try await destination.metadata(at: target)
        if let existing, existing.kind != entry.kind {
            await onEvent(.skipped(path: target, reason: "目标类型不同，保留原项目"))
            return
        }
        if entry.kind == .directory {
            if existing == nil { try await destination.createDirectory(at: target) }
            guard try await destination.canonicalDirectory(at: target) == target else {
                throw HostDockError("目标目录指向其他位置，已停止：\(target)")
            }
            for child in try await source.list(at: entry.path) {
                guard try FilePath.join(entry.path, name: child.name) == child.path else {
                    await onEvent(.skipped(path: child.path, reason: "非法子路径"))
                    continue
                }
                try await copy(child, from: source, to: destination, directory: target,
                               onConflict: onConflict, onEvent: onEvent)
            }
            await onEvent(.completed(target))
        } else {
            if let existing {
                switch await onConflict(FileConflict(source: entry, destination: existing)) {
                case .skip:
                    await onEvent(.skipped(path: target, reason: "保留同名文件"))
                    return
                case .cancel: throw CancellationError()
                case .overwrite: break
                }
            }
            try await copyFile(entry, target: target, existing: existing,
                               source: source, destination: destination, onEvent: onEvent)
            await onEvent(.completed(target))
        }
    }

    private func copyFile(
        _ entry: FileEntry, target: String, existing: FileEntry?,
        source: any FileStore, destination: any FileStore, onEvent: @escaping EventHandler
    ) async throws {
        let directory = FilePath.parent(target)
        guard try await destination.canonicalDirectory(at: directory) == directory else {
            throw HostDockError("目标目录已改变，已停止：\(directory)")
        }
        let temporary = try FilePath.join(directory, name: ".hostdock-\(UUID().uuidString).part")
        let reader = try await source.openReader(at: entry.path)
        var writer: (any FileWriter)?
        var ownsTemporary = false
        do {
            writer = try await destination.createWriter(at: temporary)
            ownsTemporary = true
            var count: UInt64 = 0
            await onEvent(.progress(path: entry.path, bytes: 0, total: entry.size))
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(upToCount: 64 * 1024)
                if chunk.isEmpty { break }
                try await writer?.write(chunk)
                count += UInt64(chunk.count)
                await onEvent(.progress(path: entry.path, bytes: count, total: entry.size))
            }
            try await writer?.close()
            writer = nil
            try await reader.close()
            guard count == entry.size, let staged = try await destination.metadata(at: temporary),
                  staged.kind == .file, staged.size == count else {
                throw HostDockError("文件大小校验失败，源文件可能已改变：\(entry.path)")
            }
            try Task.checkCancellation()
            try await commit(temporary, to: target, replacing: existing, in: destination, onEvent: onEvent)
        } catch {
            try? await reader.close()
            try? await writer?.close()
            if ownsTemporary {
                do { try await destination.removeFile(at: temporary) }
                catch { await onEvent(.warning("临时文件未能清理，请在连接恢复后检查：\(temporary)")) }
            }
            throw error
        }
    }

    private func commit(
        _ temporary: String, to target: String, replacing existing: FileEntry?,
        in store: any FileStore, retainBackup: Bool = false, onEvent: @escaping EventHandler
    ) async throws {
        guard try await store.metadata(at: target) == existing else {
            throw HostDockError("目标在传输期间发生变化，已保留原文件：\(target)")
        }
        var backup: String?
        do {
            if existing != nil {
                backup = try FilePath.join(FilePath.parent(target), name: ".hostdock-backup-\(UUID().uuidString)")
                try await store.move(from: target, to: backup!)
            }
            try await store.move(from: temporary, to: target)
        } catch {
            let originalError = error
            if let backup {
                do {
                    if try await store.metadata(at: backup) != nil {
                        guard try await store.metadata(at: target) == nil else {
                            throw HostDockError("目标路径已占用")
                        }
                        try await store.move(from: backup, to: target)
                    }
                } catch {
                    throw HostDockError("提交失败；原文件备份可能仍在 \(backup)。请恢复连接后检查，勿删除备份。")
                }
            }
            throw originalError
        }
        if let backup, !retainBackup {
            do { try await store.removeFile(at: backup) }
            catch { await onEvent(.warning("传输已完成，但旧文件备份未能清理：\(backup)")) }
        }
    }
}
