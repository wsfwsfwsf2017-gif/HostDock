import AppKit
import Combine
import Foundation
import HostDockCore
import SwiftUI

@MainActor
final class AutomationController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var changing = false
    @Published private(set) var notice: String?
    @Published private(set) var activeCount = 0
    private weak var app: AppModel?
    private let defaults: UserDefaults
    private let socketURL: URL
    private var server: ControlServer?
    private var tasks: [UUID: Task<ControlResponse, Never>] = [:]
    private var requests: [UUID: ControlRequest] = [:]
    private var executing: Set<UUID> = []
    private var pendingConnections: [UUID: (attempt: UUID, created: Bool)] = [:]
    init(app: AppModel, defaults: UserDefaults = .standard, socketURL: URL = ControlSocket.url) {
        self.app = app; self.defaults = defaults; self.socketURL = socketURL
    }
    func restore() async { if defaults.bool(forKey: "HostDock.AutomationEnabled") { await setEnabled(true) } }
    func setEnabled(_ value: Bool) async {
        guard !changing, enabled != value else { return }
        changing = true; notice = nil
        defer { changing = false }
        if value {
            let listener = ControlServer(url: socketURL)
            do {
                try await listener.start { [weak self] request in
                    guard let self else { return ControlResponse(request.id, error: ControlFailure("DISABLED", "请先在设置中开启「允许 AI 操作 HostDock」。")) }
                    return await self.handle(request)
                }
                guard app?.shuttingDown == false, !Task.isCancelled else { await listener.stop(); return }
                server = listener; enabled = true
                defaults.set(true, forKey: "HostDock.AutomationEnabled")
            } catch { notice = error.localizedDescription }
        } else {
            await shutdown()
            defaults.set(false, forKey: "HostDock.AutomationEnabled")
        }
    }
    func shutdown() async {
        enabled = false
        let current = Array(tasks.values)
        for task in current { task.cancel() }
        for task in current { _ = await task.value }
        for (id, pending) in pendingConnections {
            if let session = app?.sessions.first(where: { $0.id == id }), !session.connected, session.connectionAttemptID == pending.attempt {
                if pending.created { await app?.closeSession(session) } else { session.cancelConnection() }
            }
        }
        pendingConnections.removeAll()
        await server?.stop(); server = nil
    }
    func handle(_ request: ControlRequest) async -> ControlResponse {
        guard enabled, app?.shuttingDown == false else { return ControlResponse(request.id, error: ControlFailure("DISABLED", "请先在设置中开启「允许 AI 操作 HostDock」。")) }
        guard request.version == 1, tasks[request.id] == nil, tasks.count < 32 else {
            return ControlResponse(request.id, error: ControlFailure("INVALID_REQUEST", "协议版本不兼容、请求 ID 重复或请求过多。"))
        }
        let task = Task { @MainActor [weak self] in
            do {
                guard let self else { throw CancellationError() }
                let result = try await self.perform(request)
                try Task.checkCancellation()
                if case .object(let fields) = result, fields["state"] == .string("needs_user_action") {
                    return ControlResponse(request.id, error: ControlFailure("NEEDS_USER_ACTION", "请在 HostDock 中核对服务器指纹或更新认证。"), result: result)
                }
                return ControlResponse(request.id, result: result)
            } catch {
                let failure = error is CancellationError ? ControlFailure("CANCELLED", "本次请求已取消，临时文件会完成清理。")
                    : error as? ControlFailure ?? ControlFailure("OPERATION_FAILED", error.localizedDescription)
                return ControlResponse(request.id, error: failure)
            }
        }
        tasks[request.id] = task; requests[request.id] = request; activeCount = tasks.count
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        tasks.removeValue(forKey: request.id); requests.removeValue(forKey: request.id); activeCount = tasks.count
        return result
    }
    private func session(_ request: ControlRequest) throws -> SessionModel {
        let id = try request.uuid("session")
        guard let session = app?.sessions.first(where: { $0.id == id }) else { throw ControlFailure("SESSION_NOT_FOUND", "指定会话不存在。") }
        return session
    }
    private func summary(_ session: SessionModel) -> ControlValue {
        .object(["id": .string(session.id.uuidString), "profileId": .string(session.profile.id.uuidString), "name": .string(session.profile.name),
                 "host": .string(session.profile.targetHost), "username": .string(session.profile.targetUsername), "connected": .bool(session.connected),
                 "state": .string(session.status), "terminalReady": .bool(session.terminalReady), "transferring": .bool(session.transferring),
                 "progress": .number(session.progress), "needsAttention": .bool(session.needsAttention)])
    }
    private func perform(_ request: ControlRequest) async throws -> ControlValue {
        guard let app else { throw ControlFailure("APP_UNAVAILABLE", "应用正在退出。") }
        switch request.command {
        case "status":
            return .object(["enabled": .bool(enabled), "sessions": .number(Double(app.sessions.count)), "requests": .array(requests.values.filter { $0.id != request.id }.map {
                .object(["id": .string($0.id.uuidString), "command": .string($0.command), "sessionId": $0.arguments["session"].map(ControlValue.string) ?? .null])
            })])
        case "profiles.list":
            await app.refreshSavedConnections()
            return .array(app.catalog.profiles.map { profile in
                .object(["id": .string(profile.id.uuidString), "name": .string(profile.name), "host": .string(profile.targetHost),
                         "username": .string(profile.targetUsername), "mode": .string(profile.connectionMode.rawValue), "ready": .bool(app.readyProfileIDs.contains(profile.id))])
            })
        case "sessions.list": return .array(app.sessions.map(summary))
        case "connect": return try await connect(request, app: app)
        case "cancel":
            let id = try request.uuid("request")
            guard id != request.id, let task = tasks[id] else { throw ControlFailure("REQUEST_NOT_FOUND", "指定请求已结束或不存在。") }
            task.cancel()
            return .object(["requestId": .string(id.uuidString), "cancelling": .bool(true)])
        default: break
        }
        let session = try session(request)
        session.automationRequests += 1
        defer { session.automationRequests -= 1 }
        if request.command == "close" { await app.closeSession(session); return .object(["closed": .bool(true)]) }
        if request.command == "disconnect" { await session.shutdown(); return summary(session) }
        if request.command == "terminal.read" {
            let tail = try integer(request.arguments["tail"] ?? "200", range: 1...2000)
            let text = String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self)
            return .object(["text": .string(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(tail).joined(separator: "\n")),
                            "ready": .bool(session.terminalReady), "connected": .bool(session.connected)])
        }
        guard session.connected, !session.disconnecting else { throw ControlFailure("SESSION_OFFLINE", "指定服务器已断开，请先重新连接。") }
        switch request.command {
        case "exec":
            guard !executing.contains(session.id) else { throw ControlFailure("BUSY", "该会话已有一条 AI 命令正在执行。") }
            let text = try request.required("command")
            guard let timeout = Double(request.arguments["timeout"] ?? "30"), timeout.isFinite, (0.1...3600).contains(timeout), text.utf8.count <= 65_536 else { throw ControlFailure("INVALID_ARGUMENT", "命令过长或超时参数无效。") }
            executing.insert(session.id); defer { executing.remove(session.id) }
            let result = try await session.connection.execute(text, timeout: timeout)
            return .object(["stdout": .string(String(data: result.stdout, encoding: .utf8) ?? result.stdout.base64EncodedString()),
                            "stderr": .string(String(data: result.stderr, encoding: .utf8) ?? result.stderr.base64EncodedString()),
                            "stdoutEncoding": .string(String(data: result.stdout, encoding: .utf8) == nil ? "base64" : "utf8"),
                            "stderrEncoding": .string(String(data: result.stderr, encoding: .utf8) == nil ? "base64" : "utf8"), "exitCode": .number(Double(result.exitCode))])
        case "terminal.send", "terminal.key":
            let generation = session.connectionGeneration
            session.startTerminal()
            for _ in 0..<1000 {
                try Task.checkCancellation()
                if session.terminalReady { break }
                guard session.connected else { throw ControlFailure("SESSION_OFFLINE", "原会话已断开。") }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard session.connected, session.connectionGeneration == generation else { throw ControlFailure("SESSION_CHANGED", "原连接已变化，终端输入未发送。") }
            guard session.terminalReady else { throw ControlFailure("TERMINAL_UNAVAILABLE", "终端尚未就绪。") }
            let data: Data
            if request.command == "terminal.send" {
                let text = try request.required("text")
                guard text.utf8.count <= 65_536 else { throw ControlFailure("INVALID_ARGUMENT", "单次终端输入不超过 64 KiB。") }
                data = Data((text + (request.arguments["enter"] == "true" ? "\r" : "")).utf8)
            } else {
                let keys = ["ctrl-c": "\u{03}", "enter": "\r", "tab": "\t", "escape": "\u{1b}", "up": "\u{1b}[A", "down": "\u{1b}[B"]
                guard let key = keys[try request.required("key")] else { throw ControlFailure("INVALID_ARGUMENT", "支持 ctrl-c、enter、tab、escape、up、down。") }
                data = Data(key.utf8)
            }
            try await session.connection.writeTerminal(data)
            return .object(["sent": .bool(true), "bytes": .number(Double(data.count))])
        case "files.list":
            let side = request.arguments["side"] ?? "remote"
            guard ["remote", "local"].contains(side), let store = (side == "local" ? session.local : session.remote).store else { throw ControlFailure("INVALID_ARGUMENT", "side 只能为 local 或 remote。") }
            let path = try FilePath.normalize(try request.required("path"))
            let generation = session.connectionGeneration
            let entries = try await store.list(at: path)
            guard generation == session.connectionGeneration else { throw ControlFailure("SESSION_CHANGED", "原连接已变化。") }
            return .array(entries.map { entry in
                .object(["name": .string(entry.name), "path": .string(entry.path), "type": .string(entry.kind == .directory ? "directory" : entry.kind == .file ? "file" : entry.kind == .symbolicLink ? "symlink" : "other"), "size": .number(Double(entry.size))])
            })
        case "files.upload", "files.download":
            let upload = request.command == "files.upload"
            let generation = session.connectionGeneration
            guard !request.paths.isEmpty, request.paths.count <= 1000, let source = (upload ? session.local : session.remote).store else { throw ControlFailure("INVALID_ARGUMENT", "请通过 --source 提供来源绝对路径。") }
            var entries: [FileEntry] = []
            for value in request.paths {
                let path = try FilePath.normalize(upload ? (value as NSString).expandingTildeInPath : value)
                guard let entry = try await source.metadata(at: path) else { throw ControlFailure("NOT_FOUND", "来源文件不存在：\(path)") }
                entries.append(entry)
            }
            let destination = try FilePath.normalize(try request.required("destination"))
            guard session.connected, generation == session.connectionGeneration else { throw ControlFailure("SESSION_CHANGED", "原连接已变化，传输未开始。") }
            try await FileActions(session: session, remote: !upload).copy(entries, source: source, sourceRemote: !upload, toRemote: upload, directory: destination, cut: false)
            return .object(["completed": .number(Double(session.completed)), "skipped": .number(Double(session.skipped))])
        default: throw ControlFailure("INVALID_ARGUMENT", "不支持的自动化命令。")
        }
    }
    private func connect(_ request: ControlRequest, app: AppModel) async throws -> ControlValue {
        let id = try request.uuid("profile")
        guard let profile = app.catalog.profiles.first(where: { $0.id == id }) else { throw ControlFailure("PROFILE_NOT_FOUND", "指定保存记录不存在。") }
        if let existing = app.sessions.first(where: { $0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint }), existing.connected {
            app.selectedSessionID = existing.id
            return summary(existing)
        }
        guard !app.sessions.contains(where: { ($0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint) && $0.busy }) else { throw ControlFailure("BUSY", "该服务器正在连接或清理中。") }
        await app.refreshSavedConnections()
        guard app.readyProfileIDs.contains(id) else {
            app.useDraft(profile); app.connectionPickerPresented = true
            throw ControlFailure("AUTH_REQUIRED", "请在应用中补齐并验证认证资料。")
        }
        try Task.checkCancellation()
        if let existing = app.sessions.first(where: { $0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint }) {
            if existing.connected { app.selectedSessionID = existing.id; return summary(existing) }
            guard !existing.busy else { throw ControlFailure("BUSY", "已有连接正在处理，未接管或取消它。") }
        }
        guard !app.pickerBusy else { throw ControlFailure("BUSY", "连接弹窗正在处理其他连接，请稍后重试。") }
        let created = !app.sessions.contains(where: { $0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint })
        let session = try app.connect(profile: profile, password: nil, rememberPassword: true)
        session.automationRequests += 1
        defer { session.automationRequests -= 1 }
        do {
            for _ in 0..<9000 {
                try Task.checkCancellation()
                if session.connected { app.connectionPickerPresented = false; return summary(session) }
                if session.hostTrustRequest != nil || session.passwordRequired {
                    pendingConnections[session.id] = (session.connectionAttemptID, created)
                    app.presentPendingAutomation(session, created: created)
                    return .object(["state": .string("needs_user_action"), "sessionId": .string(session.id.uuidString), "message": .string("请在 HostDock 中核对指纹或更新认证，然后通过 sessions list 查看状态。")])
                }
                if !session.connecting { throw ControlFailure("CONNECT_FAILED", session.connectionError ?? "连接未完成，请在应用中检查认证。") }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ControlFailure("TIMEOUT", "连接超时。")
        } catch {
            if !session.connected { if created { await app.closeSession(session) } else { session.cancelConnection() } }
            throw error
        }
    }
    private func integer(_ value: String, range: ClosedRange<Int>) throws -> Int {
        guard let number = Int(value), range.contains(number) else { throw ControlFailure("INVALID_ARGUMENT", "数值参数超出允许范围。") }
        return number
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var controller: AutomationController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("AI 与自动化", systemImage: "terminal").font(.title2.bold())
            Toggle("允许 AI 操作 HostDock", isOn: Binding(get: { controller.enabled }, set: { value in Task { await controller.setEnabled(value) } }))
                .disabled(controller.changing)
            Text("允许 AI 或命令行程序通过 HostDock 连接服务器、执行命令和传输文件。")
                .font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = controller.notice { DockNotice(text: notice) }
        }.padding(26).frame(width: 560).background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
    }
}
