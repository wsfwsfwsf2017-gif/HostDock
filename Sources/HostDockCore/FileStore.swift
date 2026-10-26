import Foundation

public enum FileKind: Sendable, Hashable {
    case file, directory, symbolicLink, other
}

public struct FileEntry: Identifiable, Sendable, Hashable {
    public let path: String
    public let kind: FileKind
    public let size: UInt64
    public let modified: Date?
    public let permissions: UInt32?
    public let owner: UInt32?
    public let group: UInt32?
    public var id: String { path }
    public var name: String { path == "/" ? "/" : String(path.split(separator: "/").last ?? "") }

    public init(path: String, kind: FileKind, size: UInt64 = 0, modified: Date? = nil,
                permissions: UInt32? = nil, owner: UInt32? = nil, group: UInt32? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions; self.owner = owner; self.group = group
    }
}

public struct HostDockError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum FilePath {
    public static func normalize(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw HostDockError("请输入有效的绝对路径。")
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func join(_ directory: String, name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw HostDockError("跳过非法文件名：\(name.debugDescription)")
        }
        let base = try normalize(directory)
        return base + (base == "/" ? "" : "/") + name
    }

    public static func parent(_ path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    public static func isInside(_ path: String, directory: String) -> Bool {
        path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
    }

    public static func sort(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func topLevelSelection(_ entries: [FileEntry]) -> [FileEntry] {
        let unique = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values
        var result: [FileEntry] = []
        for entry in unique.sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { $0.kind == .directory && isInside(entry.path, directory: $0.path) }) {
                result.append(entry)
            }
        }
        return sort(result)
    }
}

public protocol FileReader: Sendable {
    func read(upToCount count: Int) async throws -> Data
    func close() async throws
}

public protocol FileWriter: Sendable {
    func write(_ data: Data) async throws
    func close() async throws
}

public protocol FileStore: Sendable {
    func canonicalDirectory(at path: String) async throws -> String
    func list(at path: String) async throws -> [FileEntry]
    func metadata(at path: String) async throws -> FileEntry?
    func createDirectory(at path: String) async throws
    func move(from: String, to: String) async throws
    func removeFile(at path: String) async throws
    func removeEmptyDirectory(at path: String) async throws
    func setPermissions(_ permissions: UInt32, at path: String) async throws
    func openReader(at path: String) async throws -> any FileReader
    func createWriter(at path: String) async throws -> any FileWriter
}

extension FileStore {
    public func removeEmptyDirectory(at path: String) async throws { throw HostDockError("此存储不支持删除目录。") }
    public func setPermissions(_ permissions: UInt32, at path: String) async throws { throw HostDockError("此存储不支持修改权限。") }
}
