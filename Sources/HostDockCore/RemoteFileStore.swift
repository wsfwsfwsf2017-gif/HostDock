import Citadel
import Foundation
import NIOCore

public actor RemoteFileStore: FileStore {
    private let client: SFTPClient
    private var knownHiddenPaths: Set<String> = []
    public init(client: SFTPClient) { self.client = client }

    public func canonicalDirectory(at path: String) async throws -> String {
        let realPath = try await sftpRequest(client) { try await client.getRealPath(atPath: path) }
        guard try await metadata(at: realPath)?.kind == .directory else {
            throw HostDockError("远端目录不存在或无法访问：\(path)")
        }
        return try FilePath.normalize(realPath)
    }

    public func list(at path: String) async throws -> [FileEntry] {
        let packets = try await sftpRequest(client) { try await client.listDirectory(atPath: path) }
        var entries: [FileEntry] = []
        for component in packets.flatMap(\.components) {
            if component.filename == "." || component.filename == ".." { continue }
            let child = try FilePath.join(path, name: component.filename)
            entries.append(entry(path: child, attributes: component.attributes))
        }
        // 部分网关过滤 READDIR 的点文件，补齐本会话已明确访问过且仍存在的路径。
        let seen = Set(entries.map(\.path))
        for child in Array(knownHiddenPaths) where FilePath.parent(child) == path && !seen.contains(child) {
            if let value = try await metadata(at: child) { entries.append(value) }
        }
        return FilePath.sort(entries)
    }

    public func metadata(at path: String) async throws -> FileEntry? {
        do {
            let value = entry(path: path, attributes: try await sftpRequest(client) {
                try await client.getAttributes(at: path, followSymlinks: false)
            })
            if value.name.hasPrefix(".") { knownHiddenPaths.insert(path) }
            return value
        } catch SFTPError.errorStatus(let status) where status.errorCode.rawValue == 2 {
            knownHiddenPaths.remove(path); return nil
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            knownHiddenPaths.remove(path); return nil
        }
    }

    public func createDirectory(at path: String) async throws {
        try await sftpRequest(client) { try await client.createDirectory(atPath: path) }
        guard try await metadata(at: path)?.kind == .directory else {
            throw HostDockError("远端目录创建失败，请检查权限：\(path)")
        }
    }

    public func move(from: String, to: String) async throws {
        guard let original = try await metadata(at: from), try await metadata(at: to) == nil else {
            throw HostDockError("远端改名失败：源文件不存在或目标已被占用。\(to)")
        }
        try await sftpRequest(client) { try await client.rename(at: from, to: to) }
        // Citadel 0.12.1 does not inspect RENAME's status packet; verify both paths.
        guard try await metadata(at: from) == nil, let moved = try await metadata(at: to),
              moved.kind == original.kind, moved.size == original.size else {
            throw HostDockError("远端改名未成功，请检查权限和目标路径：\(to)")
        }
        if original.kind == .directory {
            for path in Array(knownHiddenPaths) where FilePath.isInside(path, directory: from) {
                knownHiddenPaths.remove(path)
                knownHiddenPaths.insert(to + path.dropFirst(from.count))
            }
        }
    }

    public func removeFile(at path: String) async throws {
        if try await metadata(at: path) == nil { return }
        try await sftpRequest(client) { try await client.remove(at: path) }
        guard try await metadata(at: path) == nil else {
            throw HostDockError("远端文件清理失败：\(path)")
        }
    }

    public func removeEmptyDirectory(at path: String) async throws {
        guard path != "/" else { throw HostDockError("不能删除根目录。") }
        guard try await list(at: path).isEmpty else { throw HostDockError("目录非空，保留：\(path)") }
        try await sftpRequest(client) { try await client.rmdir(at: path) }
        guard try await metadata(at: path) == nil else { throw HostDockError("空目录清理失败：\(path)") }
    }

    public func setPermissions(_ permissions: UInt32, at path: String) async throws {
        guard permissions <= 0o7777, let entry = try await metadata(at: path),
              entry.kind == .file || entry.kind == .directory else { throw HostDockError("只能修改普通文件或目录的有效权限。") }
        var attributes = SFTPFileAttributes()
        attributes.permissions = permissions
        let change = attributes
        try await sftpRequest(client) { try await client.setAttributes(at: path, to: change) }
        guard try await metadata(at: path)?.permissions == permissions else { throw HostDockError("远端权限修改未成功或服务端不支持。") }
    }

    public func openReader(at path: String) async throws -> any FileReader {
        guard try await metadata(at: path)?.kind == .file else {
            throw HostDockError("只支持读取普通文件：\(path)")
        }
        let file = try await sftpRequest(client) { try await client.openFile(filePath: path, flags: .read) }
        return RemoteReader(file: file, client: client)
    }

    public func createWriter(at path: String) async throws -> any FileWriter {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o600
        let file = try await sftpRequest(client) { try await client.openFile(
            filePath: path, flags: [.write, .create, .forceCreate], attributes: attributes) }
        return RemoteWriter(file: file, client: client)
    }

    private func entry(path: String, attributes: SFTPFileAttributes) -> FileEntry {
        let kind: FileKind = switch (attributes.permissions ?? 0) & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .file
        case 0o120000: .symbolicLink
        default: .other
        }
        return FileEntry(path: path, kind: kind, size: attributes.size ?? 0,
                         modified: attributes.accessModificationTime?.modificationTime,
                         permissions: attributes.permissions.map { $0 & 0o7777 },
                         owner: attributes.uidgid?.userId, group: attributes.uidgid?.groupId)
    }
}

private actor RemoteReader: FileReader {
    let file: SFTPFile
    let client: SFTPClient
    var offset: UInt64 = 0
    init(file: SFTPFile, client: SFTPClient) { self.file = file; self.client = client }
    func read(upToCount count: Int) async throws -> Data {
        let buffer = try await sftpRequest(client) { try await file.read(from: offset, length: UInt32(count)) }
        let data = Data(buffer.readableBytesView)
        offset += UInt64(data.count)
        return data
    }
    func close() async throws { try await sftpRequest(client) { try await file.close() } }
}

private actor RemoteWriter: FileWriter {
    let file: SFTPFile
    let client: SFTPClient
    var offset: UInt64 = 0
    init(file: SFTPFile, client: SFTPClient) { self.file = file; self.client = client }
    func write(_ data: Data) async throws {
        try await sftpRequest(client) { try await file.write(ByteBuffer(bytes: data), at: offset) }
        offset += UInt64(data.count)
    }
    func close() async throws { try await sftpRequest(client) { try await file.close() } }
}

private func sftpRequest<T>(_ client: SFTPClient, _ operation: () async throws -> T) async throws -> T {
    let start = ContinuousClock.now
    // Closing the SFTP channel also releases Citadel's outstanding response promises.
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(30)); try await client.close() }
        catch {}
    }
    defer { deadline.cancel() }
    do { return try await operation() }
    catch {
        if start.duration(to: .now) >= .seconds(30) {
            throw HostDockError("SFTP 请求超过 30 秒未响应，文件通道已关闭，请重新连接。")
        }
        throw error
    }
}
