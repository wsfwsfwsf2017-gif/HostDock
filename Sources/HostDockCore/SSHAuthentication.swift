import CCryptoBoringSSL
import Citadel
import Crypto
import Foundation

public enum SSHAuthentication: Sendable {
    case password(String)
    case rsaKey(path: String, passphrase: String?)

    func method(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .password(let password): return .passwordBased(username: username, password: password)
        case .rsaKey(let path, let passphrase):
            let (data, text) = try RSAKeyInfo.read(path)
            let encrypted = try RSAKeyInfo.isEncrypted(text)
            if encrypted && (passphrase?.isEmpty ?? true) { throw SSHConnectionFailure.keyPassphrase }
            if text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
                do { return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(
                    sshRsa: text, decryptionKey: passphrase.map { Data($0.utf8) })) }
                catch { throw encrypted ? SSHConnectionFailure.keyPassphrase : SSHConnectionFailure.keyFormat }
            }
            // BoringSSL 已由 Citadel 引入；只在内存解析 PEM，不转换或复制用户私钥文件。
            let key = try data.withUnsafeBytes { bytes -> Insecure.RSA.PrivateKey in
                guard let bio = CCryptoBoringSSL_BIO_new_mem_buf(bytes.baseAddress, bytes.count) else { throw SSHConnectionFailure.keyFormat }
                defer { CCryptoBoringSSL_BIO_free(bio) }
                var phrase = Array((passphrase ?? "").utf8CString)
                let parsed = phrase.withUnsafeMutableBufferPointer { buffer in
                    CCryptoBoringSSL_PEM_read_bio_PrivateKey(bio, nil, { output, size, _, context in
                        guard let output, let context else { return 0 }
                        let value = context.assumingMemoryBound(to: CChar.self)
                        let count = min(Int(size), strlen(value))
                        memcpy(output, value, count)
                        return Int32(count)
                    }, buffer.baseAddress)
                }
                guard let parsed else {
                    throw encrypted ? SSHConnectionFailure.keyPassphrase : SSHConnectionFailure.keyFormat
                }
                defer { CCryptoBoringSSL_EVP_PKEY_free(parsed) }
                guard let rsa = CCryptoBoringSSL_EVP_PKEY_get0_RSA(parsed), CCryptoBoringSSL_RSA_bits(rsa) >= 2048 else {
                    throw SSHConnectionFailure.keyFormat
                }
                var n: UnsafePointer<BIGNUM>?, e: UnsafePointer<BIGNUM>?, d: UnsafePointer<BIGNUM>?
                CCryptoBoringSSL_RSA_get0_key(rsa, &n, &e, &d)
                guard let n, let e, let d,
                      let modulus = CCryptoBoringSSL_BN_dup(n), let exponent = CCryptoBoringSSL_BN_dup(e),
                      let secret = CCryptoBoringSSL_BN_dup(d) else { throw SSHConnectionFailure.keyFormat }
                return Insecure.RSA.PrivateKey(privateExponent: secret, publicExponent: exponent, modulus: modulus)
            }
            return .rsa(username: username, privateKey: key)
        }
    }
}

public struct RSAKeyInfo: Sendable {
    public let requiresPassphrase: Bool
    public static func inspect(path: String) throws -> Self {
        let (_, text) = try read(path)
        let encrypted = try isEncrypted(text)
        if !encrypted { _ = try SSHAuthentication.rsaKey(path: path, passphrase: nil).method(username: "HostDock-key-check") }
        return Self(requiresPassphrase: encrypted)
    }
    fileprivate static func read(_ path: String) throws -> (Data, String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        guard let info = try? FileManager.default.attributesOfItem(atPath: url.path), info[.type] as? FileAttributeType == .typeRegular,
              (info[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw SSHConnectionFailure.keyFile }
        return (data, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    fileprivate static func isEncrypted(_ text: String) throws -> Bool {
        if text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let lines = text.components(separatedBy: .newlines)
            guard lines.last == "-----END OPENSSH PRIVATE KEY-----",
                  let data = Data(base64Encoded: lines.dropFirst().dropLast().joined()),
                  data.starts(with: Data("openssh-key-v1\0".utf8)) else { throw SSHConnectionFailure.keyFormat }
            var offset = 15
            func integer() throws -> Int {
                guard offset + 4 <= data.count else { throw SSHConnectionFailure.keyFormat }
                let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; offset += 4
                return Int(value)
            }
            func string() throws -> Data {
                let count = try integer()
                guard count <= data.count - offset else { throw SSHConnectionFailure.keyFormat }
                defer { offset += count }; return data.subdata(in: offset..<(offset + count))
            }
            let cipher = try string(), kdf = try string(); _ = try string()
            guard try integer() == 1 else { throw SSHConnectionFailure.keyFormat }
            let publicKey = try string(), body = try string()
            guard offset == data.count, body.count >= 16, publicKey.count >= 11,
                  publicKey.prefix(11) == Data([0, 0, 0, 7]) + Data("ssh-rsa".utf8) else { throw SSHConnectionFailure.keyFormat }
            if cipher == Data("none".utf8) { guard kdf == Data("none".utf8) else { throw SSHConnectionFailure.keyFormat }; return false }
            guard kdf == Data("bcrypt".utf8), ["aes256-ctr", "aes128-ctr"].contains(String(decoding: cipher, as: UTF8.self)) else { throw SSHConnectionFailure.keyFormat }
            return true
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first, ["-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----"].contains(header),
              lines.last == header.replacingOccurrences(of: "BEGIN", with: "END"),
              let body = Data(base64Encoded: lines.dropFirst().dropLast().filter { !$0.contains(":") }.joined()), body.count >= 32 else {
            throw SSHConnectionFailure.keyFormat
        }
        return text.contains("ENCRYPTED")
    }
}

public enum SSHConnectionFailure: String, LocalizedError, Sendable {
    case network = "网络连接失败，请检查地址、端口及 VPN。"
    case authentication = "服务器拒绝了认证，请通过修改认证更新密码或私钥。"
    case keyFile = "无法读取私钥文件，请检查路径及访问权限。"
    case keyFormat = "私钥格式无效或不是受支持的 RSA 私钥（至少 2048 位）。"
    case keyPassphrase = "无法解锁私钥，请核对密钥口令；若口令正确，请检查密钥文件是否损坏。"
    case hostKey = "主机指纹未获信任，连接已取消。"
    case sftp = "SSH 已通过认证，但 SFTP 无法打开或读取目录。请检查资产文件访问权限。"
    public var errorDescription: String? { rawValue }
}
