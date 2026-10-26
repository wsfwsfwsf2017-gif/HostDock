import Combine
import CryptoKit
import Darwin
import Foundation
import HostDockCore
import Network

struct ConnectionEndpoint: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var username: String

    func validated() throws -> Self {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !user.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "\0" }),
              !user.contains(where: { $0.isNewline || $0 == "\0" }), (1...65535).contains(port) else {
            throw HostDockError("请填写有效的服务器地址、端口（1–65535）和用户名。")
        }
        return Self(host: host, port: port, username: user)
    }

    var identity: String { "\(host.lowercased())\0\(port)\0\(username)" }
    var address: String { "\(username)@\(host.contains(":") ? "[\(host)]" : host):\(port)" }
}

enum AuthenticationKind: String, Codable, CaseIterable, Sendable {
    case password, rsaKey
    var title: String { self == .password ? "密码" : "RSA 私钥" }
}

enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    case direct, jumpServer
    var title: String { self == .direct ? "普通 SSH" : "JumpServer" }
    var defaultPort: Int { self == .direct ? 22 : 2222 }
    var defaultAuthentication: AuthenticationKind { self == .direct ? .password : .rsaKey }
}

struct JumpServerConfiguration: Codable, Hashable, Sendable {
    var username = ""
    var targetUsername = ""
    var targetHost = ""
    var portalURL: String?
    var accessProfileID: UUID?
    var loginUsername: String { "\(username)@\(targetUsername)@\(targetHost)" }

    func validated() throws -> Self {
        let result = Self(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                          targetUsername: targetUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                          targetHost: targetHost.trimmingCharacters(in: .whitespacesAndNewlines), portalURL: portalURL, accessProfileID: accessProfileID)
        guard [result.username, result.targetUsername].allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }),
              IPv4Address(result.targetHost) != nil || IPv6Address(result.targetHost) != nil else {
            throw HostDockError("请填写 JumpServer 账号、目标服务器账号及有效的目标 IP 地址。")
        }
        if let portalURL = result.portalURL { _ = try JumpServerAddress(portalURL) }
        return result
    }
}

struct JumpServerAddress {
    let host: String
    let portalURL: String?
    init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("://") {
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw HostDockError("请输入有效的堡垒机登录网址，不要在网址中包含账号或密码。")
            }
            self.host = host.lowercased(); portalURL = value
        } else {
            guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" || $0 == "\0" }),
                  !value.contains(":") || IPv6Address(value) != nil else {
                throw HostDockError("请输入堡垒机登录网址、IP 或域名，勿在 IP 或域名后附加 SSH 端口。")
            }
            host = value.lowercased(); portalURL = nil
        }
    }
}

struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var endpoint: ConnectionEndpoint
    var rememberPassword = true
    var localStartDirectory: String?
    var remoteStartDirectory: String?
    var authenticationKind = AuthenticationKind.password
    var privateKeyPath: String?
    var lastValidatedAt: Date?
    var keyRequiresPassphrase = false
    var connectionMode = ConnectionMode.direct
    var jumpServer: JumpServerConfiguration?

    var targetHost: String { connectionMode == .jumpServer ? jumpServer?.targetHost ?? endpoint.host : endpoint.host }
    var targetUsername: String { connectionMode == .jumpServer ? jumpServer?.targetUsername ?? endpoint.username : endpoint.username }
    var displayAddress: String { "\(targetHost) · \(targetUsername)" }
    var displaySubtitle: String { displayAddress }

    var credentialAccount: String {
        let hash = SHA256.hash(data: Data(endpoint.identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = "\(id.uuidString):\(hash)"
        guard authenticationKind == .rsaKey else { return base }
        let path = ((privateKeyPath ?? "") as NSString).expandingTildeInPath
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return base + ":rsa:" + key
    }

    func validated() throws -> Self {
        var result = self
        if connectionMode == .jumpServer {
            guard let jumpServer else { throw HostDockError("请补齐 JumpServer 目标服务器信息。") }
            let configuration = try jumpServer.validated()
            result.jumpServer = configuration
            result.endpoint.username = configuration.loginUsername
        } else { result.jumpServer = nil }
        result.endpoint = try result.endpoint.validated()
        guard !result.endpoint.host.contains("://"), !result.endpoint.host.contains("/"), !result.endpoint.host.contains("@") else {
            throw HostDockError("服务器地址请填写 IP 或域名，SSH 端口在端口栏填写。")
        }
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.name.isEmpty { result.name = result.displayAddress }
        result.localStartDirectory = try Self.validateDirectory(localStartDirectory)
        result.remoteStartDirectory = try Self.validateDirectory(remoteStartDirectory)
        if authenticationKind == .rsaKey {
            guard let path = privateKeyPath, path.hasPrefix("/") || path.hasPrefix("~/"), !path.contains("\0") else {
                throw HostDockError("请选择有效的 RSA 私钥文件。")
            }
        }
        return result
    }

    enum CodingKeys: String, CodingKey {
        case id, name, endpoint, rememberPassword, localStartDirectory, remoteStartDirectory
        case authenticationKind, privateKeyPath, lastValidatedAt, keyRequiresPassphrase
        case connectionMode, jumpServer
    }
    init(id: UUID = UUID(), name: String, endpoint: ConnectionEndpoint, rememberPassword: Bool = true,
         localStartDirectory: String? = nil, remoteStartDirectory: String? = nil,
         authenticationKind: AuthenticationKind = .password, privateKeyPath: String? = nil,
         lastValidatedAt: Date? = nil, keyRequiresPassphrase: Bool = false,
         connectionMode: ConnectionMode = .direct, jumpServer: JumpServerConfiguration? = nil) {
        self.id = id; self.name = name; self.endpoint = endpoint; self.rememberPassword = rememberPassword
        self.localStartDirectory = localStartDirectory; self.remoteStartDirectory = remoteStartDirectory
        self.authenticationKind = authenticationKind; self.privateKeyPath = privateKeyPath
        self.lastValidatedAt = lastValidatedAt; self.keyRequiresPassphrase = keyRequiresPassphrase
        self.connectionMode = connectionMode; self.jumpServer = jumpServer
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(ConnectionEndpoint.self, forKey: .endpoint)
        rememberPassword = try c.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? true
        localStartDirectory = try c.decodeIfPresent(String.self, forKey: .localStartDirectory)
        remoteStartDirectory = try c.decodeIfPresent(String.self, forKey: .remoteStartDirectory)
        authenticationKind = try c.decodeIfPresent(AuthenticationKind.self, forKey: .authenticationKind) ?? .password
        privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath)
        lastValidatedAt = try c.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        keyRequiresPassphrase = try c.decodeIfPresent(Bool.self, forKey: .keyRequiresPassphrase) ?? false
        connectionMode = try c.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .direct
        jumpServer = try c.decodeIfPresent(JumpServerConfiguration.self, forKey: .jumpServer)
    }

    private static func validateDirectory(_ path: String?) throws -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard !path.contains("\0"), path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            throw HostDockError("默认目录请输入绝对路径、~ 或 ~/ 开头的路径。")
        }
        return path
    }
}

struct ConnectionFormDraft {
    var profile: ConnectionProfile
    var port: String
    var jumpServer: JumpServerConfiguration
    var gatewayAddress: String
    var gatewayOverride: String

    init(_ profile: ConnectionProfile) {
        self.profile = profile
        port = String(profile.endpoint.port)
        jumpServer = profile.jumpServer ?? JumpServerConfiguration()
        gatewayAddress = jumpServer.portalURL ?? profile.endpoint.host
        let portalHost = try? JumpServerAddress(gatewayAddress).host
        gatewayOverride = profile.connectionMode == .jumpServer && portalHost != profile.endpoint.host ? profile.endpoint.host : ""
        if profile.connectionMode == .jumpServer && jumpServer.targetUsername.isEmpty { jumpServer.targetUsername = "ssta" }
    }

    mutating func changeMode(to mode: ConnectionMode, secret: inout String) {
        guard mode != profile.connectionMode else { return }
        if port == String(profile.connectionMode.defaultPort) { port = String(mode.defaultPort) }
        profile.connectionMode = mode
        if mode == .jumpServer && jumpServer.targetUsername.isEmpty { jumpServer.targetUsername = "ssta" }
        if gatewayAddress.isEmpty { gatewayAddress = profile.endpoint.host }
        profile.authenticationKind = mode.defaultAuthentication
        profile.keyRequiresPassphrase = false
        secret = ""
    }

    func resolved() throws -> ConnectionProfile {
        guard let port = Int(port), (1...65535).contains(port) else { throw HostDockError("请输入有效端口（1–65535）。") }
        var result = profile
        result.endpoint.port = port
        result.jumpServer = profile.connectionMode == .jumpServer ? jumpServer : nil
        if profile.connectionMode == .jumpServer {
            let address = try JumpServerAddress(gatewayAddress)
            result.endpoint.host = gatewayOverride.isEmpty ? address.host : gatewayOverride
            result.jumpServer?.portalURL = address.portalURL
        }
        if result.authenticationKind == .password { result.privateKeyPath = nil; result.keyRequiresPassphrase = false }
        if let jumpServer = result.jumpServer { result.endpoint.username = try jumpServer.validated().loginUsername }
        return result
    }
    func validated() throws -> ConnectionProfile { try resolved().validated() }

    mutating func useAccess(_ access: JumpServerAccessProfile) {
        jumpServer.accessProfileID = access.id; jumpServer.username = access.username; jumpServer.portalURL = access.portalURL
        profile.jumpServer = jumpServer; profile.authenticationKind = .rsaKey
        profile.privateKeyPath = access.privateKeyPath; profile.keyRequiresPassphrase = access.keyRequiresPassphrase
        port = String(access.port); gatewayAddress = access.portalURL ?? access.host
        gatewayOverride = (try? JumpServerAddress(gatewayAddress).host) == access.host ? "" : access.host
    }
}

struct RecentConnection: Identifiable, Codable, Equatable, Sendable {
    var name: String
    var endpoint: ConnectionEndpoint
    var lastConnected: Date
    var connectionMode: ConnectionMode?
    var jumpServer: JumpServerConfiguration?
    var authenticationKind: AuthenticationKind?
    var privateKeyPath: String?
    var id: String { endpoint.identity }

    func draft() -> ConnectionProfile {
        ConnectionProfile(name: name, endpoint: endpoint, authenticationKind: authenticationKind ?? .password,
                          privateKeyPath: privateKeyPath, connectionMode: connectionMode ?? .direct, jumpServer: jumpServer)
    }
}

struct ConnectionDocument: Codable, Equatable, Sendable {
    var version = 5
    var profiles: [ConnectionProfile] = []
    var recent: [RecentConnection] = []
    var jumpServerAccessProfiles: [JumpServerAccessProfile] = []
    enum CodingKeys: String, CodingKey { case version, profiles, recent, jumpServerAccessProfiles }
    init(profiles: [ConnectionProfile] = [], recent: [RecentConnection] = [], jumpServerAccessProfiles: [JumpServerAccessProfile] = []) {
        self.profiles = profiles; self.recent = recent; self.jumpServerAccessProfiles = jumpServerAccessProfiles
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        profiles = try c.decode([ConnectionProfile].self, forKey: .profiles)
        recent = try c.decode([RecentConnection].self, forKey: .recent)
        jumpServerAccessProfiles = try c.decodeIfPresent([JumpServerAccessProfile].self, forKey: .jumpServerAccessProfiles) ?? []
    }
}

protocol ConnectionStorage: Sendable {
    func load() throws -> ConnectionDocument
    func save(_ document: ConnectionDocument) throws
}

struct FileConnectionStorage: ConnectionStorage {
    let url: URL
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HostDock/connections.json")
    }

    func load() throws -> ConnectionDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConnectionDocument() }
        let document = try JSONDecoder().decode(ConnectionDocument.self, from: Data(contentsOf: url))
        guard (1...5).contains(document.version) else { throw HostDockError("连接记录版本暂不受支持。") }
        return document
    }

    func save(_ document: ConnectionDocument) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".connections-\(UUID().uuidString).tmp")
        if FileManager.default.fileExists(atPath: url.path),
           let previous = try? JSONDecoder().decode(ConnectionDocument.self, from: Data(contentsOf: url)), previous.version < document.version {
            let backup = directory.appendingPathComponent("connections-v\(previous.version)-\(UUID()).json")
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let data = try JSONEncoder().encode(document)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HostDockError("无法写入连接记录，请检查本机目录权限。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

@MainActor
final class ConnectionCatalog: ObservableObject {
    @Published private(set) var document = ConnectionDocument()
    @Published private(set) var loadError: String?
    private let storage: any ConnectionStorage
    var profiles: [ConnectionProfile] { document.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var recent: [RecentConnection] { document.recent.sorted { $0.lastConnected > $1.lastConnected } }
    var accessProfiles: [JumpServerAccessProfile] { document.jumpServerAccessProfiles }

    init(storage: any ConnectionStorage = FileConnectionStorage(url: FileConnectionStorage.defaultURL)) {
        self.storage = storage
        do {
            var loaded = try storage.load()
            guard (1...5).contains(loaded.version) else { throw HostDockError("连接记录版本暂不受支持。") }
            loaded.profiles = try loaded.profiles.map { try $0.validated() }
            guard Set(loaded.profiles.map(\.id)).count == loaded.profiles.count,
                  Set(loaded.profiles.map { $0.endpoint.identity }).count == loaded.profiles.count else {
                throw HostDockError("连接记录包含重复项目。")
            }
            loaded.recent = try loaded.recent.map { recent in
                var result = recent
                let profile = try recent.draft().validated()
                result.endpoint = profile.endpoint
                result.jumpServer = profile.jumpServer
                return result
            }
            var seen = Set<String>()
            loaded.recent = Array(loaded.recent.sorted { $0.lastConnected > $1.lastConnected }
                .filter { seen.insert($0.id).inserted }.prefix(20))
            if loaded.version < 5 { loaded.migrateJumpServerAccess() }
            loaded.jumpServerAccessProfiles = try loaded.jumpServerAccessProfiles.map { try $0.validated() }
            try loaded.validateAccessReferences()
            document = loaded
        } catch {
            loadError = "无法读取连接记录，原文件已保留。\(error.localizedDescription)"
        }
    }

    func profile(for endpoint: ConnectionEndpoint) -> ConnectionProfile? {
        document.profiles.first { $0.endpoint == endpoint }
    }

    func save(_ profile: ConnectionProfile, accessProfile: JumpServerAccessProfile? = nil, replaceAccess: Bool = false) throws {
        let profile = try validate(profile)
        var next = document
        next.profiles.removeAll { $0.id == profile.id }
        next.profiles.append(profile)
        if let accessProfile {
            let access = try accessProfile.validated()
            guard profile.jumpServer?.accessProfileID == access.id, access.matches(profile) else { throw HostDockError("堡垒机配置与验证目标不一致。") }
            if replaceAccess { next.jumpServerAccessProfiles.removeAll { $0.id == access.id } }
            if !next.jumpServerAccessProfiles.contains(where: { $0.id == access.id }) { next.jumpServerAccessProfiles.append(access) }
        }
        try commit(next)
    }

    func resolve(_ requested: ConnectionProfile, accessProfile: JumpServerAccessProfile? = nil) throws -> (profile: ConnectionProfile, access: JumpServerAccessProfile?) {
        guard requested.connectionMode == .jumpServer, requested.authenticationKind == .rsaKey,
              let id = requested.jumpServer?.accessProfileID else { return (try requested.validated(), nil) }
        guard let access = accessProfile?.id == id ? accessProfile : accessProfiles.first(where: { $0.id == id }) else {
            throw HostDockError("找不到关联的堡垒机，请重新选择堡垒机配置。")
        }
        return (try access.applying(to: requested), access)
    }

    func saveAccessProfile(_ requested: JumpServerAccessProfile) throws {
        let access = try requested.validated()
        var next = document
        next.jumpServerAccessProfiles.removeAll { $0.id == access.id }; next.jumpServerAccessProfiles.append(access)
        try commit(next)
    }

    func authenticationAccounts(profile: ConnectionProfile, access: JumpServerAccessProfile?) -> [String] {
        guard let access else { return [profile.credentialAccount] }
        if !access.rememberPassphrase { return [access.credentialAccount] }
        var accounts = [access.credentialAccount]
        // 仅复用同一堡垒机身份的旧凭据，成功验证后再建立共享条目。
        let legacy = profiles.filter { $0.rememberPassword && access.matches($0) && $0.jumpServer?.accessProfileID == access.id }
            .sorted { ($0.lastValidatedAt ?? .distantPast) > ($1.lastValidatedAt ?? .distantPast) }
        if access.matches(profile) { accounts.append(profile.credentialAccount) }
        accounts += legacy.map(\.credentialAccount)
        var seen = Set<String>()
        return accounts.filter { seen.insert($0).inserted }
    }

    func removeAccessProfile(_ access: JumpServerAccessProfile) throws {
        guard !profiles.contains(where: { $0.jumpServer?.accessProfileID == access.id }),
              !recent.contains(where: { $0.jumpServer?.accessProfileID == access.id }) else {
            throw HostDockError("这份堡垒机配置仍被服务器或历史记录使用，请先移除关联。")
        }
        var next = document; next.jumpServerAccessProfiles.removeAll { $0.id == access.id }; try commit(next)
    }

    func validate(_ profile: ConnectionProfile) throws -> ConnectionProfile {
        guard loadError == nil else { throw HostDockError("连接记录读取失败，已停止写入以保留原文件。") }
        let profile = try profile.validated()
        guard !document.profiles.contains(where: { $0.id != profile.id && $0.endpoint == profile.endpoint }) else {
            throw HostDockError("这台服务器和用户名已保存，请编辑已有记录。")
        }
        return profile
    }

    func remove(_ profile: ConnectionProfile) throws {
        var next = document
        next.profiles.removeAll { $0.id == profile.id }
        try commit(next)
    }

    func recordSuccess(profile: ConnectionProfile, at date: Date = Date()) throws {
        let profile = try profile.validated()
        let endpoint = profile.endpoint
        var next = document
        next.recent.removeAll { $0.endpoint == endpoint }
        next.recent.insert(RecentConnection(name: profile.name, endpoint: endpoint, lastConnected: date,
            connectionMode: profile.connectionMode, jumpServer: profile.jumpServer,
            authenticationKind: profile.authenticationKind, privateKeyPath: profile.privateKeyPath), at: 0)
        next.recent = Array(next.recent.sorted { $0.lastConnected > $1.lastConnected }.prefix(20))
        try commit(next)
    }

    func clearHistory() throws {
        var next = document
        next.recent = []
        try commit(next)
    }

    private func commit(_ next: ConnectionDocument) throws {
        guard loadError == nil else { throw HostDockError("连接记录读取失败，已停止写入以保留原文件。") }
        var next = next
        next.version = 5
        try next.validateAccessReferences()
        try storage.save(next)
        document = next
    }
}
