import Darwin
import Foundation

public actor LocalFileStore: FileStore {
    public init() {}

    public func canonicalDirectory(at path: String) throws -> String {
        let url = URL(fileURLWithPath: try FilePath.normalize(path)).resolvingSymlinksInPath()
        guard try metadata(at: url.path)?.kind == .directory else {
            throw HostDockError("目录不存在或无法访问：\(path)")
        }
        return url.path
    }

    public func list(at path: String) throws -> [FileEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        return try FilePath.sort(names.compactMap { name in
            let child = try FilePath.join(path, name: name)
            return try metadata(at: child)
        })
    }

    public func metadata(at path: String) throws -> FileEntry? {
        var info = stat()
        // FileManager also reads extended attributes, which can block on cloud-backed files.
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError(path: path)
        }
        let kind: FileKind = switch info.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symbolicLink
        default: .other
        }
        return FileEntry(path: path, kind: kind,
                         size: UInt64(max(0, info.st_size)),
                         modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                         permissions: UInt32(info.st_mode & 0o7777), owner: info.st_uid, group: info.st_gid)
    }

    public func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    public func move(from: String, to: String) throws {
        // renamex_np prevents a concurrently-created destination from being overwritten.
        guard renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else { throw posixError(path: to) }
    }

    public func removeFile(at path: String) throws {
        guard unlink(path) == 0 else {
            if errno == ENOENT { return }
            throw posixError(path: path)
        }
    }

    public func removeEmptyDirectory(at path: String) async throws {
        guard path != "/", rmdir(path) == 0 else { throw posixError(path: path) }
        guard try metadata(at: path) == nil else { throw HostDockError("目录删除未成功。") }
    }

    public func setPermissions(_ permissions: UInt32, at path: String) async throws {
        guard permissions <= 0o7777 else { throw HostDockError("权限请输入 0000–7777 的八进制值。") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posixError(path: path) }
        defer { Darwin.close(fd) }
        guard fchmod(fd, mode_t(permissions)) == 0 else { throw posixError(path: path) }
        guard try metadata(at: path)?.permissions == permissions else { throw HostDockError("本机权限修改未成功。") }
    }

    public func openReader(at path: String) throws -> any FileReader {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path: path) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw HostDockError("只支持读取普通文件：\(path)")
        }
        return LocalReader(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    public func createWriter(at path: String) throws -> any FileWriter {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError(path: path) }
        return LocalWriter(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    private func posixError(path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}

private actor LocalReader: FileReader {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func read(upToCount count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
    func close() throws { try handle.close() }
}

private actor LocalWriter: FileWriter {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() throws { try handle.synchronize(); try handle.close() }
}
