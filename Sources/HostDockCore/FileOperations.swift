import CryptoKit
import Foundation

public enum FileOperations {
    public static func digest(at path: String, in store: any FileStore) async throws -> String {
        let reader = try await store.openReader(at: path)
        do {
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try await reader.read(upToCount: 64 * 1024)
                if data.isEmpty { break }
                hash.update(data: data)
            }
            try await reader.close()
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { try? await reader.close(); throw error }
    }

    public static func read(at path: String, in store: any FileStore, limit: Int) async throws -> Data {
        guard let entry = try await store.metadata(at: path), entry.kind == .file, entry.size <= UInt64(limit) else {
            throw HostDockError("仅支持不超过 \(limit / 1024 / 1024) MiB 的普通文件，请改用下载。")
        }
        let reader = try await store.openReader(at: path)
        do {
            var result = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(upToCount: 64 * 1024)
                if chunk.isEmpty { break }
                guard result.count + chunk.count <= limit else { throw HostDockError("文件超过编辑大小限制。") }
                result.append(chunk)
            }
            try await reader.close()
            return result
        } catch { try? await reader.close(); throw error }
    }

    public static func remove(_ entries: [FileEntry], in store: any FileStore) async throws {
        for selected in FilePath.topLevelSelection(entries) {
            try Task.checkCancellation()
            guard selected.path != "/", let entry = try await store.metadata(at: selected.path) else {
                throw HostDockError("不能删除根目录或不存在的项目。")
            }
            if entry.kind == .directory {
                guard try await store.canonicalDirectory(at: entry.path) == entry.path else { throw HostDockError("目录已指向其他路径，已停止删除。") }
                let children = try await store.list(at: entry.path)
                for child in children {
                    guard try FilePath.join(entry.path, name: child.name) == child.path else { throw HostDockError("子路径非法，已停止删除。") }
                }
                try await remove(children, in: store)
                try await store.removeEmptyDirectory(at: entry.path)
            } else if entry.kind == .file || entry.kind == .symbolicLink {
                try await store.removeFile(at: entry.path)
            } else { throw HostDockError("不删除特殊文件：\(entry.path)") }
        }
    }

    public static func verify(_ entry: FileEntry, from source: any FileStore, at target: String, in destination: any FileStore) async throws {
        try Task.checkCancellation()
        guard let current = try await source.metadata(at: entry.path), let copied = try await destination.metadata(at: target),
              current.kind == entry.kind, copied.kind == current.kind else { throw HostDockError("复制验证失败，已保留来源。") }
        if current.kind == .file {
            guard current.size == copied.size,
                  try await digest(at: current.path, in: source) == digest(at: target, in: destination) else {
                throw HostDockError("内容校验不一致，已保留来源。")
            }
        } else if current.kind == .directory {
            for child in try await source.list(at: current.path) {
                try await verify(child, from: source, at: FilePath.join(target, name: child.name), in: destination)
            }
        } else { throw HostDockError("符号链接或特殊文件未复制，已保留来源。") }
    }
}
