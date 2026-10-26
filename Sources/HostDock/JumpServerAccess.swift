import CryptoKit
import Foundation
import HostDockCore

struct JumpServerAccessProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 2222
    var username = ""
    var privateKeyPath = ""
    var portalURL: String?
    var keyRequiresPassphrase = false
    var rememberPassphrase = true
    var lastValidatedAt: Date?

    var authenticationIdentity: String {
        [host.lowercased(), String(port), username,
         ((privateKeyPath as NSString).expandingTildeInPath as NSString).standardizingPath].joined(separator: "\0")
    }
    var credentialAccount: String {
        let hash = SHA256.hash(data: Data(authenticationIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "jumpserver:\(id.uuidString):rsa:\(hash)"
    }
    var displayName: String { name.isEmpty ? host : name }

    func validated() throws -> Self {
        var result = self
        let endpoint = try ConnectionEndpoint(host: host, port: port, username: username).validated()
        let address = try JumpServerAddress(endpoint.host)
        guard address.portalURL == nil, privateKeyPath.hasPrefix("/") || privateKeyPath.hasPrefix("~/"),
              !privateKeyPath.contains("\0") else { throw HostDockError("请填写 SSH 网关地址并选择本机私钥。") }
        result.host = endpoint.host; result.username = endpoint.username
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let portalURL { guard try JumpServerAddress(portalURL).portalURL != nil else { throw HostDockError("管理网页请输入完整的 HTTP 或 HTTPS 网址。") } }
        return result
    }

    func applying(to original: ConnectionProfile) throws -> ConnectionProfile {
        let access = try validated()
        guard original.connectionMode == .jumpServer, var jump = original.jumpServer else { throw HostDockError("请选择 JumpServer 目标服务器。") }
        var profile = original
        jump.accessProfileID = id; jump.username = access.username; jump.portalURL = access.portalURL
        profile.jumpServer = jump
        profile.endpoint = ConnectionEndpoint(host: access.host, port: access.port, username: jump.loginUsername)
        profile.authenticationKind = .rsaKey; profile.privateKeyPath = access.privateKeyPath
        profile.keyRequiresPassphrase = access.keyRequiresPassphrase
        return try profile.validated()
    }

    init() {}
    init(profile: ConnectionProfile) {
        name = "堡垒机 · " + profile.endpoint.host
        host = profile.endpoint.host; port = profile.endpoint.port
        username = profile.jumpServer?.username ?? ""
        privateKeyPath = profile.privateKeyPath ?? ""
        portalURL = profile.jumpServer?.portalURL
        keyRequiresPassphrase = profile.keyRequiresPassphrase
        lastValidatedAt = profile.lastValidatedAt
    }
    func matches(_ profile: ConnectionProfile) -> Bool {
        profile.connectionMode == .jumpServer && profile.authenticationKind == .rsaKey
            && authenticationIdentity == JumpServerAccessProfile(profile: profile).authenticationIdentity
    }
}

extension ConnectionDocument {
    func validateAccessReferences() throws {
        guard Set(jumpServerAccessProfiles.map(\.id)).count == jumpServerAccessProfiles.count else { throw HostDockError("堡垒机配置包含重复项目。") }
        var identities = Set<String>()
        for profile in profiles {
            var resolved = profile
            if let id = profile.jumpServer?.accessProfileID {
                guard let access = jumpServerAccessProfiles.first(where: { $0.id == id }), profile.authenticationKind == .rsaKey else {
                    throw HostDockError("服务器引用的堡垒机配置不存在或认证类型不匹配。")
                }
                resolved = try access.applying(to: profile)
            }
            guard identities.insert(resolved.endpoint.identity).inserted else { throw HostDockError("这份堡垒机配置会使服务器记录重复，原配置已保留。") }
        }
        for item in recent {
            if let id = item.jumpServer?.accessProfileID, !jumpServerAccessProfiles.contains(where: { $0.id == id }) {
                throw HostDockError("历史记录引用的堡垒机配置不存在，原文件已保留。")
            }
        }
    }

    mutating func migrateJumpServerAccess() {
        for index in profiles.indices where profiles[index].connectionMode == .jumpServer && profiles[index].authenticationKind == .rsaKey {
            let profile = profiles[index]
            let access = jumpServerAccessProfiles.first(where: { $0.matches(profile) }) ?? JumpServerAccessProfile(profile: profile)
            if !jumpServerAccessProfiles.contains(where: { $0.id == access.id }) { jumpServerAccessProfiles.append(access) }
            profiles[index].jumpServer?.accessProfileID = access.id
        }
        for index in recent.indices {
            if let access = jumpServerAccessProfiles.first(where: { $0.matches(recent[index].draft()) }) {
                recent[index].jumpServer?.accessProfileID = access.id
            }
        }
    }
}
