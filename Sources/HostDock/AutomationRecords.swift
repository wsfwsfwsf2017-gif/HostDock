import AppKit
import Combine
import Foundation
import HostDockCore
import Network

struct AutomationRecordHeader: Codable, Identifiable, Sendable {
    var id = UUID()
    var sessionID: UUID?
    let name: String
    let host: String
    let username: String
    let serverKey: String
    let startedAt: Date
    var endedAt: Date?
    var endReason: String?
    var truncated = false
}

struct AutomationRecordEvent: Codable, Identifiable, Sendable {
    enum Kind: String, Codable { case request, result, terminal, ended }
    var id = UUID()
    let sequence: Int
    let time: Date
    let kind: Kind
    var requestID: UUID?
    var title = ""
    var detail = ""
    var result: ControlValue?
    var failure: ControlFailure?
    var data: Data?
}

struct AutomationProtection: Codable, Identifiable, Sendable {
    var id: String { serverKey }
    let serverKey: String
    let host: String
    let until: Date
    var sessionIDs: Set<UUID>
}

struct AutomationRecordSnapshot: Sendable {
    var headers: [AutomationRecordHeader] = []
    var sizes: [UUID: Int] = [:]
    var issues: [String] = []
}

enum AutomationRecordWrite: Sendable {
    case header(AutomationRecordHeader), event(UUID, Data), remove(UUID), protections([AutomationProtection])
    var recordID: UUID? {
        switch self { case .header(let header): header.id; case .event(let id, _), .remove(let id): id; case .protections: nil }
    }
}

protocol AutomationRecordStorage: Sendable {
    func loadRecords() async throws -> AutomationRecordSnapshot
    func loadEvents(_ id: UUID) async throws -> [AutomationRecordEvent]
    func loadProtections() async throws -> [AutomationProtection]
    func write(_ command: AutomationRecordWrite) async throws
    func flush() async throws
}

actor FileAutomationRecordStorage: AutomationRecordStorage {
    let directory: URL
    private var handles: [UUID: FileHandle] = [:]
    private var ended: Set<UUID> = []
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HostDock/AutomationRecords")) { self.directory = directory }

    private func url(_ id: UUID, _ ext: String) -> URL { directory.appendingPathComponent(id.uuidString + "." + ext) }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func save<T: Encodable>(_ value: T, to target: URL) throws {
        try prepare()
        let temporary = directory.appendingPathComponent(".record-\(UUID()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(value), attributes: [.posixPermissions: 0o600]) else {
            throw HostDockError("无法保存 AI 记录，请检查本机目录权限和剩余空间。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func loadRecords() throws -> AutomationRecordSnapshot {
        guard FileManager.default.fileExists(atPath: directory.path) else { return AutomationRecordSnapshot() }
        var result = AutomationRecordSnapshot()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            do {
                let header = try JSONDecoder().decode(AutomationRecordHeader.self, from: Data(contentsOf: file))
                guard header.id.uuidString == file.deletingPathExtension().lastPathComponent else { throw HostDockError("记录 ID 不一致。") }
                result.headers.append(header)
                if header.endedAt != nil { ended.insert(header.id) }
                result.sizes[header.id] = (try? FileManager.default.attributesOfItem(atPath: url(header.id, "jsonl").path)[.size] as? NSNumber)?.intValue ?? 0
            } catch { result.issues.append("一条 AI 记录无法读取，原文件已保留：\(error.localizedDescription)") }
        }
        return result
    }
    func loadEvents(_ id: UUID) throws -> [AutomationRecordEvent] {
        let file = url(id, "jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 21 * 1024 * 1024 else { throw HostDockError("记录体积异常，原文件已保留。") }
        let data = try Data(contentsOf: file)
        guard data.last == nil || data.last == 10 else { throw HostDockError("记录末尾不完整，原文件已保留。") }
        return try data.split(separator: 10).map { try JSONDecoder().decode(AutomationRecordEvent.self, from: Data($0)) }
    }
    func loadProtections() throws -> [AutomationProtection] {
        let file = directory.appendingPathComponent("protections.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([AutomationProtection].self, from: Data(contentsOf: file))
    }
    func write(_ command: AutomationRecordWrite) throws {
        switch command {
        case .header(let header):
            try save(header, to: url(header.id, "json"))
            if header.endedAt != nil {
                ended.insert(header.id)
                if let handle = handles.removeValue(forKey: header.id) { try handle.synchronize(); try handle.close() }
            }
        case .protections(let values): try save(values, to: directory.appendingPathComponent("protections.json"))
        case .event(let id, let data):
            try prepare()
            let handle: FileHandle
            if let existing = handles[id] { handle = existing }
            else {
                let file = url(id, "jsonl")
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HostDockError("无法写入 AI 记录。") }
                }
                handle = try FileHandle(forWritingTo: file); handles[id] = handle
            }
            let offset = try handle.seekToEnd()
            do { try handle.write(contentsOf: data) }
            catch { try? handle.truncate(atOffset: offset); throw error }
            if ended.contains(id) { try handle.synchronize(); try handle.close(); handles.removeValue(forKey: id) }
        case .remove(let id):
            try handles.removeValue(forKey: id)?.close()
            for file in [url(id, "json"), url(id, "jsonl")] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    func flush() throws { for handle in handles.values { try handle.synchronize() } }
}

@MainActor
final class AutomationRecord: ObservableObject, Identifiable {
    nonisolated let id: UUID
    @Published var header: AutomationRecordHeader
    @Published var loading = false
    @Published var showingTerminal = false
    @Published var notice: String?
    @Published private(set) var revision = 0
    private(set) var events: [AutomationRecordEvent] = []
    private(set) var loaded = false
    private var mirror: TerminalController?
    private var lastPublish = Date.distantPast
    var nextSequence = 0
    var active: Bool { header.endedAt == nil }
    var displayAddress: String { header.host + " · " + header.username }
    var hasTerminal: Bool { events.contains { $0.kind == .terminal } }
    var operations: [AutomationRecordEvent] { events.filter { $0.kind != .terminal } }
    init(_ header: AutomationRecordHeader) { id = header.id; self.header = header }
    func append(_ event: AutomationRecordEvent) {
        guard loaded else { return }
        events.append(event)
        if event.kind == .terminal, let data = event.data { mirror?.feed(data) }
        if event.kind != .terminal || Date().timeIntervalSince(lastPublish) > 0.05 { revision += 1; lastPublish = Date() }
    }
    func beginLoading() { loaded = true; loading = true }
    func finishLoading(_ saved: [AutomationRecordEvent]) {
        events = Array(Dictionary((saved + events).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values)
            .sorted { $0.sequence < $1.sequence }
        nextSequence = max(nextSequence, (events.last?.sequence ?? -1) + 1)
        mirror?.reset()
        for event in events where event.kind == .terminal { if let data = event.data { mirror?.feed(data) } }
        loading = false; revision += 1
    }
    func unload() { loaded = false; events = []; mirror = nil; loading = false }
    func terminal() -> TerminalController {
        if let mirror { return mirror }
        let result = TerminalController(readOnly: true)
        for event in events where event.kind == .terminal { if let data = event.data { result.feed(data) } }
        mirror = result
        return result
    }
}

@MainActor
final class AutomationRecords: ObservableObject {
    @Published private(set) var records: [AutomationRecord] = []
    @Published private(set) var protections: [AutomationProtection] = []
    @Published private(set) var notice: String?
    @Published private(set) var protectionFailure: String?
    private let storage: any AutomationRecordStorage
    private let now: () -> Date
    private let recordLimit: Int
    private let totalLimit: Int
    private var sizes: [UUID: Int] = [:]
    private var pinned: Set<UUID> = []
    private var deleting: Set<UUID> = []
    private var restoreTask: Task<Void, Never>?
    private var restored = false
    private var writer: Task<Void, Never>?
    private var pending: [(UUID, AutomationRecordWrite)] = []
    private var writeFailure: Error?
    private var protectionRevision = 0
    init(storage: any AutomationRecordStorage = FileAutomationRecordStorage(), now: @escaping () -> Date = Date.init,
         recordLimit: Int = 20 * 1024 * 1024, totalLimit: Int = 200 * 1024 * 1024) {
        self.storage = storage; self.now = now; self.recordLimit = recordLimit; self.totalLimit = totalLimit
    }
    static func serverKey(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if let address = IPv4Address(value) { return address.debugDescription }
        if let address = IPv6Address(value) { return address.debugDescription }
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }
    func restore() async {
        if restored { return }
        if let restoreTask { await restoreTask.value; return }
        let task = Task { [self] in
            do {
                let saved = try await storage.loadProtections()
                protections = saved.filter { $0.until > now() }
            } catch { protectionFailure = "AI 保护状态无法读取，服务器操作已暂停，原文件已保留：\(error.localizedDescription)" }
            do {
                let snapshot = try await storage.loadRecords()
                sizes = snapshot.sizes
                notice = snapshot.issues.first
                records = snapshot.headers.sorted { $0.startedAt > $1.startedAt }.map(AutomationRecord.init)
                for record in records where record.active {
                    record.header.endedAt = now(); record.header.endReason = "上次运行已结束"
                    enqueue(.header(record.header))
                }
                prune(required: 0)
            } catch { notice = "AI 历史无法读取，原文件已保留：\(error.localizedDescription)" }
            restored = true
        }
        restoreTask = task; await task.value; restoreTask = nil
    }
    func record(sessionID: UUID) -> AutomationRecord? { records.first { $0.header.sessionID == sessionID } }
    func begin(profile: ConnectionProfile, sessionID: UUID? = nil) -> AutomationRecord {
        prune(required: 0)
        let header = AutomationRecordHeader(sessionID: sessionID, name: profile.name, host: profile.targetHost,
            username: profile.targetUsername, serverKey: Self.serverKey(profile.targetHost), startedAt: now())
        let record = AutomationRecord(header); records.insert(record, at: 0); sizes[record.id] = 0
        enqueue(.header(header)); return record
    }
    func bind(_ record: AutomationRecord, sessionID: UUID) {
        record.header.sessionID = sessionID; enqueue(.header(record.header))
    }
    func emit(_ record: AutomationRecord, kind: AutomationRecordEvent.Kind, requestID: UUID? = nil,
              title: String = "", detail: String = "", result: ControlValue? = nil, failure: ControlFailure? = nil, data: Data? = nil) {
        guard records.contains(where: { $0 === record }), !record.header.truncated, !deleting.contains(record.id) else { return }
        let event = AutomationRecordEvent(sequence: record.nextSequence, time: now(), kind: kind, requestID: requestID,
                                          title: title, detail: detail, result: result, failure: failure, data: data)
        do {
            var encoded = try JSONEncoder().encode(event); encoded.append(10)
            prune(required: encoded.count)
            guard (sizes[record.id] ?? 0) + encoded.count <= recordLimit,
                  sizes.values.reduce(0, +) + encoded.count <= totalLimit else {
                record.header.truncated = true
                record.notice = "记录达到容量上限，后续内容未保存；AI 任务继续运行。"
                enqueue(.header(record.header)); return
            }
            sizes[record.id, default: 0] += encoded.count; record.nextSequence += 1
            record.append(event); enqueue(.event(record.id, encoded))
        } catch { notice = "AI 记录无法编码：\(error.localizedDescription)" }
    }
    func end(sessionID: UUID, reason: String) {
        guard let record = record(sessionID: sessionID), record.active else { return }
        objectWillChange.send()
        emit(record, kind: .ended, title: reason)
        record.header.endedAt = now(); record.header.endReason = reason
        enqueue(.header(record.header)); prune(required: 0)
    }
    func finish(_ record: AutomationRecord) { objectWillChange.send(); enqueue(.header(record.header)); prune(required: 0) }
    func retryProtectionLoad() async {
        do { protections = try await storage.loadProtections().filter { $0.until > now() }; protectionFailure = nil }
        catch { protectionFailure = "AI 保护状态仍无法读取，原文件已保留：\(error.localizedDescription)" }
    }
    func open(_ record: AutomationRecord) async {
        guard !deleting.contains(record.id) else { return }
        pinned.insert(record.id)
        guard !record.loaded else { return }
        record.beginLoading()
        await writer?.value
        do {
            let saved = try await storage.loadEvents(record.id)
            guard pinned.contains(record.id) else { return }
            let unsaved = pending.compactMap { item -> AutomationRecordEvent? in
                guard case .event(let id, let data) = item.1, id == record.id else { return nil }
                return try? JSONDecoder().decode(AutomationRecordEvent.self, from: data)
            }
            record.finishLoading(saved + unsaved)
            if record.header.truncated { record.notice = "此记录达到容量上限，内容不完整。" }
        } catch { record.loading = false; record.notice = "记录无法完整读取，原文件已保留：\(error.localizedDescription)" }
    }
    func closeView(_ id: UUID) { pinned.remove(id); records.first { $0.id == id }?.unload(); prune(required: 0) }
    func delete(_ record: AutomationRecord) async {
        guard !record.active, !pinned.contains(record.id), !deleting.contains(record.id) else { return }
        deleting.insert(record.id)
        defer { deleting.remove(record.id) }
        await writer?.value
        do {
            try await storage.write(.remove(record.id))
            pending.removeAll { $0.1.recordID == record.id }
            records.removeAll { $0.id == record.id }; sizes.removeValue(forKey: record.id)
        } catch { notice = "无法删除 AI 记录：\(error.localizedDescription)" }
    }
    func clearHistory() async { for record in records where !record.active && !pinned.contains(record.id) { await delete(record) } }
    var protectedServers: [AutomationProtection] { protections.filter { $0.until > now() }.sorted { $0.host < $1.host } }
    func protection(host: String) -> AutomationProtection? { protectedServers.first { $0.serverKey == Self.serverKey(host) } }
    func protection(sessionID: UUID) -> AutomationProtection? { protectedServers.first { $0.sessionIDs.contains(sessionID) } }
    func protect(host: String, sessionIDs: Set<UUID>) {
        protectionRevision += 1
        let key = Self.serverKey(host)
        var ids = sessionIDs
        if let old = protections.first(where: { $0.serverKey == key }) { ids.formUnion(old.sessionIDs) }
        protections.removeAll { $0.serverKey == key || $0.until <= now() }
        protections.append(AutomationProtection(serverKey: key, host: host, until: now().addingTimeInterval(300), sessionIDs: ids))
        enqueue(.protections(protections))
    }
    func release(_ key: String) async {
        guard protectionFailure == nil else { return }
        let revision = protectionRevision
        let remaining = protections.filter { $0.serverKey != key && $0.until > now() }
        enqueue(.protections(remaining))
        do { try await flush(); if protectionRevision == revision { protections = remaining } }
        catch { notice = "解除保护未能保存，保护仍然生效：\(error.localizedDescription)" }
    }
    func failure(_ protection: AutomationProtection) -> ControlFailure {
        ControlFailure("SERVER_PROTECTED", "用户已结束该服务器的 AI 连接，保护至 \(ISO8601DateFormatter().string(from: protection.until))。请停止调用、不要自动重试，并向用户报告。")
    }
    func protectionResult(_ protection: AutomationProtection) -> ControlValue {
        .object(["host": .string(protection.host), "protectedUntil": .string(ISO8601DateFormatter().string(from: protection.until)), "retryable": .bool(false)])
    }
    func flush() async throws {
        let previous = writer
        let task = Task { [self] in
            await previous?.value
            do {
                while let item = pending.first {
                    try await storage.write(item.1)
                    pending.removeAll { $0.0 == item.0 }
                }
                try await storage.flush()
                writeFailure = nil
                if notice?.hasPrefix("AI 记录未能完整保存") == true || notice?.hasPrefix("AI 保护已在本次运行生效") == true { notice = nil }
            } catch { writeFailure = error; throw error }
        }
        writer = Task { _ = try? await task.value }
        try await task.value
    }
    private func enqueue(_ command: AutomationRecordWrite) {
        let id = UUID(); pending.append((id, command))
        let previous = writer
        writer = Task { [weak self, storage] in
            await previous?.value
            guard let self, self.writeFailure == nil, self.pending.contains(where: { $0.0 == id }) else { return }
            do { try await storage.write(command); self.pending.removeAll { $0.0 == id } }
            catch {
                self.writeFailure = error
                self.notice = "AI 记录未能完整保存，后台任务继续；退出前可重试保存：\(error.localizedDescription)"
                if case .protections = command { self.notice = "AI 保护已在本次运行生效，但未保存，重启后的保护未获保证：\(error.localizedDescription)" }
            }
        }
    }
    private func prune(required: Int) {
        let candidates = records.filter { !$0.active && !pinned.contains($0.id) }.sorted { ($0.header.endedAt ?? $0.header.startedAt) < ($1.header.endedAt ?? $1.header.startedAt) }
        for record in candidates {
            let expired = (record.header.endedAt ?? record.header.startedAt) < now().addingTimeInterval(-30 * 86400)
            guard expired || sizes.values.reduce(0, +) + required > totalLimit else { continue }
            records.removeAll { $0.id == record.id }; sizes.removeValue(forKey: record.id)
            enqueue(.remove(record.id))
        }
    }
}
