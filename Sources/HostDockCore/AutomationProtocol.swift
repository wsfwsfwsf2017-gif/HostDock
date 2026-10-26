import Foundation

public enum ControlValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([ControlValue]), object([String: ControlValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ControlValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ControlValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct ControlFailure: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public struct ControlRequest: Codable, Sendable {
    public var version = 1
    public var id = UUID()
    public var command: String
    public var arguments: [String: String]
    public var paths: [String]
    public init(command: String, arguments: [String: String] = [:], paths: [String] = []) {
        self.command = command; self.arguments = arguments; self.paths = paths
    }
    public func required(_ key: String) throws -> String {
        guard let value = arguments[key], !value.isEmpty, !value.contains("\0") else { throw ControlFailure("INVALID_ARGUMENT", "缺少有效参数 --\(key)。") }
        return value
    }
    public func uuid(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try required(key)) else { throw ControlFailure("INVALID_ARGUMENT", "--\(key) 必须是记录或会话的完整 ID。") }
        return id
    }
    public static func parse(_ args: [String], input: String? = nil) throws -> Self {
        let pairs = ["profiles", "sessions", "terminal", "files"]
        guard let first = args.first else { throw ControlFailure("INVALID_ARGUMENT", "请使用 --help 查看命令。") }
        var index = 1
        var command = first
        if pairs.contains(first) {
            guard args.count > 1, !args[1].hasPrefix("--") else { throw ControlFailure("INVALID_ARGUMENT", "缺少子命令。") }
            command += "." + args[1]; index = 2
        }
        let supported = ["status", "profiles.list", "sessions.list", "connect", "disconnect", "close", "exec", "cancel", "terminal.read", "terminal.send", "terminal.key", "files.list", "files.upload", "files.download"]
        guard supported.contains(command) else { throw ControlFailure("INVALID_ARGUMENT", "未知命令，请使用 --help。") }
        var request = Self(command: command)
        let flags = ["profile", "session", "path", "destination", "command", "text", "key", "timeout", "tail", "side", "request"]
        while index < args.count {
            let key = args[index]
            if key == "--json" { index += 1; continue }
            if key == "--enter" { request.arguments["enter"] = "true"; index += 1; continue }
            if key == "--stdin" {
                guard ["exec", "terminal.send"].contains(command), let input else { throw ControlFailure("INVALID_ARGUMENT", "--stdin 仅供 exec 或 terminal send 读取 UTF-8 文本。") }
                request.arguments[command == "exec" ? "command" : "text"] = input
                index += 1; continue
            }
            guard key.hasPrefix("--"), index + 1 < args.count else { throw ControlFailure("INVALID_ARGUMENT", "参数需要使用 --名称 值。") }
            let name = String(key.dropFirst(2))
            if name == "source" { request.paths.append(args[index + 1]) }
            else {
                guard flags.contains(name), request.arguments[name] == nil else { throw ControlFailure("INVALID_ARGUMENT", "未知或重复参数：\(key)。") }
                request.arguments[name] = args[index + 1]
            }
            index += 2
        }
        return request
    }
}

public struct ControlResponse: Codable, Sendable {
    public var version = 1
    public let requestID: UUID
    public let ok: Bool
    public let result: ControlValue?
    public let error: ControlFailure?
    public init(_ id: UUID, result: ControlValue) { requestID = id; ok = true; self.result = result; error = nil }
    public init(_ id: UUID, error: ControlFailure, result: ControlValue? = nil) { requestID = id; ok = false; self.result = result; self.error = error }
}
