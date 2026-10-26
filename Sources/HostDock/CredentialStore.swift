import CryptoKit
import Darwin
import Foundation
import HostDockCore

protocol CredentialStore: Sendable {
    func read(account: String) async throws -> String?
    func save(_ password: String, account: String) async throws
    func remove(account: String) async throws
}

actor EncryptedFileCredentialStore: CredentialStore {
    private struct Document: Codable {
        var version = 1
        var items: [String: Data] = [:]
    }

    let directory: URL
    private var documentURL: URL { directory.appendingPathComponent("credentials.json") }
    private var keyURL: URL { directory.appendingPathComponent("credentials.key") }

    init(directory: URL = FileConnectionStorage.defaultURL.deletingLastPathComponent()) {
        self.directory = directory
    }

    func read(account: String) throws -> String? {
        let (document, key) = try load()
        guard let encrypted = document.items[account], let key else { return nil }
        return try decrypt(encrypted, account: account, key: key)
    }

    func save(_ password: String, account: String) throws {
        var (document, key) = try load()
        if key == nil {
            key = try loadKey(create: true)
        }
        guard let key, let encrypted = try AES.GCM.seal(Data(password.utf8), using: key,
            authenticating: Data(account.utf8)).combined else {
            throw HostDockError("无法加密密码，本次密码未保存。")
        }
        document.items[account] = encrypted
        try write(try JSONEncoder().encode(document), to: documentURL)
    }

    func remove(account: String) throws {
        var (document, _) = try load()
        guard document.items.removeValue(forKey: account) != nil else { return }
        try write(try JSONEncoder().encode(document), to: documentURL)
    }

    private func load() throws -> (Document, SymmetricKey?) {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return (Document(), try loadKey(create: false))
        }
        let document: Document
        do {
            try requireRegularFile(documentURL)
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: documentURL))
            guard document.version == 1 else { throw HostDockError("密码库版本暂不受支持。") }
        } catch {
            throw HostDockError("本机密码库无法读取，原文件已保留。请手动输入密码。")
        }
        guard let key = try loadKey(create: false) else {
            throw HostDockError("本机密码库的密钥丢失，原文件已保留。请手动输入密码。")
        }
        // 修改前验证所有条目，避免损坏的密码库被一次保存静默覆盖。
        for (account, encrypted) in document.items { _ = try decrypt(encrypted, account: account, key: key) }
        return (document, key)
    }

    private func loadKey(create: Bool) throws -> SymmetricKey? {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            try requireRegularFile(keyURL)
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else { throw HostDockError("本机密码密钥损坏，原文件已保留。请手动输入密码。") }
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try write(key.withUnsafeBytes { Data($0) }, to: keyURL)
        return key
    }

    private func decrypt(_ data: Data, account: String, key: SymmetricKey) throws -> String {
        do {
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(account.utf8))
            guard let password = String(data: clear, encoding: .utf8) else { throw HostDockError("密码编码无效。") }
            return password
        } catch {
            throw HostDockError("本机密码无法解密，原文件已保留。请手动输入密码。")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HostDockError("密码库路径不是普通文件，已停止读取和覆盖。")
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: url.path) { try requireRegularFile(url) }
        let temporary = directory.appendingPathComponent(".credentials-\(UUID()).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HostDockError("无法保存本机密码，请检查目录权限。")
        }
        defer { try? manager.removeItem(at: temporary) }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
