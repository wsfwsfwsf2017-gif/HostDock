import Darwin
import Foundation
import OSLog

enum DiagnosticEvent: String, Codable, Sendable {
    case runStarted, runEnded, operationStarted, operationFinished, cancelled
    case viewRecordClicked, popoverDismissRequested, popoverDisappeared
    case recordTabCreateRequested, recordTabCreated, recordTabLocated, recordTabClosed, recordViewAppeared, recordViewDisappeared
    case tabSelected, layoutChanged, paneFocused, tabScrollStarted, tabScrollFinished
}

enum DiagnosticOperation: String, Codable, Sendable {
    case connect, disconnect, terminal, recordLoad, transfer, fileOperation, editorSave
    case automationConnect, automationExec, automationTerminal, automationFiles, automationClose, automationCancel
}

enum DiagnosticOrigin: String, Codable, Sendable { case interactive, automation }
enum DiagnosticFailure: String, Codable, Sendable {
    case cancelled, authentication, keyFile, keyFormat, keyPassphrase, hostTrust, network, sftp, protectedServer, conflict, io, other
}

struct DiagnosticSpan: Sendable {
    let id = UUID()
    let object: UUID?
    let operation: DiagnosticOperation
    let origin: DiagnosticOrigin?
    let started = ProcessInfo.processInfo.systemUptime
}

struct DiagnosticEntry: Codable, Sendable {
    let sequence: Int
    let time: TimeInterval
    let uptime: TimeInterval
    let event: DiagnosticEvent
    var object: Int?
    var related: Int?
    var operation: DiagnosticOperation?
    var origin: DiagnosticOrigin?
    var layout: Int?
    var tabs: Int?
    var count: Int?
    var durationMS: Int?
    var failure: DiagnosticFailure?
}

struct DiagnosticRun: Codable, Sendable {
    let id: UUID
    let startedAt: TimeInterval
    let launchTime: TimeInterval
    let processID: Int
    let bundleID: String
    let version: String
    let build: String
    let binaryUUID: UUID?
    let osVersion: [Int]
    var normalExit = false

    static func current(launchDate: Date = Date(), bundle: Bundle = .main) -> DiagnosticRun {
        let info = bundle.url(forResource: "BuildInfo", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func number(_ key: String) -> String {
            let value = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
            return !value.isEmpty && value.allSatisfy({ $0.isNumber || $0 == "." }) ? value : "development"
        }
        return DiagnosticRun(id: UUID(), startedAt: Date().timeIntervalSince1970, launchTime: launchDate.timeIntervalSince1970,
            processID: Int(getpid()), bundleID: "app.hostdock.mac", version: number("CFBundleShortVersionString"),
            build: number("CFBundleVersion"), binaryUUID: info?["mainUUID"].flatMap(UUID.init(uuidString:)),
            osVersion: [os.majorVersion, os.minorVersion, os.patchVersion])
    }
}

struct DiagnosticStatus: Sendable {
    let previousRun: DiagnosticRun?
    let writeError: Bool
    let damagedFiles: Bool
    let crashStatus: DiagnosticCrashStatus
}

// This service never publishes UI state or reads views. Only typed, allowlisted fields reach disk.
final class DiagnosticLog: @unchecked Sendable {
    static let disabled = DiagnosticLog(directory: nil)
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/HostDock/Diagnostics")
    }
    let run: DiagnosticRun
    private let directory: URL?
    private let reportsDirectory: URL
    private let queue = DispatchQueue(label: "HostDock.Diagnostics")
    private let systemLog: Logger?
    private let fileLimit: Int
    private let totalLimit: Int
    private let retention: TimeInterval
    private var previous: DiagnosticRun?
    private var crash: DiagnosticCrashSummary?
    private var crashStatus = DiagnosticCrashStatus.notApplicable
    private var writeError = false
    private var damagedFiles = false
    private var sequence = 0
    private var segment = 0
    private var aliases: [UUID: Int] = [:]
    private var aliasSequence = 0
    private var prepared = false

    init(directory: URL?, run: DiagnosticRun = .current(), reportsDirectory: URL? = nil,
         fileLimit: Int = 2 * 1024 * 1024, totalLimit: Int = 20 * 1024 * 1024,
         retention: TimeInterval = 14 * 86400, systemLogging: Bool = false) {
        self.directory = directory; self.run = run
        self.reportsDirectory = reportsDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports")
        self.fileLimit = fileLimit; self.totalLimit = totalLimit; self.retention = retention
        systemLog = systemLogging ? Logger(subsystem: "app.hostdock.mac", category: "diagnostics") : nil
        if directory != nil {
            queue.sync {
                do {
                    try prepare()
                    let runs = try files().filter { $0.lastPathComponent.hasPrefix("run-") }.compactMap { file -> DiagnosticRun? in
                        do {
                            let value = try JSONDecoder().decode(DiagnosticRun.self, from: read(file, limit: 4096))
                            guard file.lastPathComponent == "run-\(value.id).json", value.bundleID == "app.hostdock.mac",
                                  Self.isVersion(value.version), Self.isVersion(value.build), value.osVersion.count == 3,
                                  value.osVersion.allSatisfy({ $0 >= 0 }), value.startedAt.isFinite, value.launchTime.isFinite else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            return value
                        }
                        catch { damagedFiles = true; return nil }
                    }
                    previous = runs.filter { !$0.normalExit && $0.id != run.id }.max { $0.startedAt < $1.startedAt }
                    try saveRun(run)
                    prepared = true
                } catch { reportWriteFailure() }
            }
            record(.runStarted, critical: true)
            queue.async { self.scanCrashReports() }
        }
    }

    func status() -> DiagnosticStatus {
        queue.sync { DiagnosticStatus(previousRun: previous, writeError: writeError, damagedFiles: damagedFiles, crashStatus: crashStatus) }
    }

    func begin(_ operation: DiagnosticOperation, id: UUID? = nil, origin: DiagnosticOrigin? = nil) -> DiagnosticSpan {
        let span = DiagnosticSpan(object: id, operation: operation, origin: origin)
        record(.operationStarted, id: span.id, relatedID: id, operation: operation, origin: origin, critical: true)
        return span
    }

    func finish(_ span: DiagnosticSpan, failure: DiagnosticFailure? = nil, count: Int? = nil) {
        record(.operationFinished, id: span.id, relatedID: span.object, operation: span.operation, origin: span.origin,
               count: count, durationMS: Int(max(0, ProcessInfo.processInfo.systemUptime - span.started) * 1000), failure: failure)
        if directory != nil { queue.async { self.aliases.removeValue(forKey: span.id) } }
    }

    func record(_ event: DiagnosticEvent, id: UUID? = nil, relatedID: UUID? = nil, operation: DiagnosticOperation? = nil,
                origin: DiagnosticOrigin? = nil, layout: Int? = nil, tabs: Int? = nil, count: Int? = nil,
                durationMS: Int? = nil, failure: DiagnosticFailure? = nil, critical: Bool = false) {
        guard directory != nil else { return }
        let time = Date().timeIntervalSince1970, uptime = ProcessInfo.processInfo.systemUptime
        let write: @Sendable () -> Void = { [self] in
            do {
                if !prepared { try prepare(); try saveRun(run); prepared = true }
                sequence += 1
                let entry = DiagnosticEntry(sequence: sequence, time: time, uptime: uptime, event: event,
                    object: alias(id), related: alias(relatedID), operation: operation, origin: origin, layout: layout,
                    tabs: tabs, count: count, durationMS: durationMS, failure: failure)
                var data = try JSONEncoder().encode(entry); data.append(10)
                guard data.count <= fileLimit else { throw POSIXError(.EFBIG) }
                if try fileSize(eventURL()) + data.count > fileLimit { segment += 1 }
                try append(data, to: eventURL())
                try prune()
                systemLog?.notice("event=\(event.rawValue, privacy: .public) sequence=\(entry.sequence)")
            } catch { reportWriteFailure() }
        }
        if critical { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    func markNormalExit() {
        guard directory != nil else { return }
        record(.runEnded, critical: true)
        queue.sync {
            do { var ended = run; ended.normalExit = true; try saveRun(ended) }
            catch { reportWriteFailure() }
        }
    }

    func flush() { queue.sync {} }

    private static func isVersion(_ value: String) -> Bool {
        value == "development" || (!value.isEmpty && value.utf8.count < 32 && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 })
    }

    private func alias(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        if let value = aliases[id] { return value }
        aliasSequence += 1; aliases[id] = aliasSequence; return aliasSequence
    }
    private func reportWriteFailure() {
        if !writeError { systemLog?.error("Diagnostic file write failed") }
        writeError = true
    }
    private func prepare() throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw POSIXError(.ELOOP) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func eventURL() -> URL { directory!.appendingPathComponent("events-\(run.id)-\(segment).jsonl") }
    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory!, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.range(of: #"^(run-[0-9A-Fa-f-]{36}\.json|events-[0-9A-Fa-f-]{36}-[0-9]+\.jsonl)$"#, options: .regularExpression) != nil
        }
    }
    private func fileSize(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw POSIXError(.ELOOP) }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw POSIXError(.EFBIG) }
        return data
    }
    private func append(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EACCES) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }
    private func saveRun(_ value: DiagnosticRun) throws {
        let temp = directory!.appendingPathComponent(".run-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        try append(JSONEncoder().encode(value), to: temp)
        guard Darwin.rename(temp.path, directory!.appendingPathComponent("run-\(value.id).json").path) == 0 else { throw POSIXError(.EIO) }
    }
    private func prune() throws {
        var candidates: [(url: URL, size: Int, time: Date)] = []
        for file in try files() {
            let size = try fileSize(file)
            let time = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date ?? .distantPast
            candidates.append((file, size, time))
        }
        var total = candidates.reduce(0) { $0 + $1.size }
        for file in candidates.sorted(by: { $0.time < $1.time }) {
            guard file.url != eventURL(), file.url.lastPathComponent != "run-\(run.id).json" else { continue }
            if Date().timeIntervalSince(file.time) > retention || total > totalLimit {
                try FileManager.default.removeItem(at: file.url); total -= file.size
            }
        }
    }

    private func scanCrashReports() {
        guard let previous else { crashStatus = .notApplicable; return }
        let result = DiagnosticCrashSummary.find(for: previous, in: reportsDirectory)
        crash = result.summary; crashStatus = result.status
    }

    func export(to destination: URL) throws {
        let snapshot: (Data, [String: Data]) = try queue.sync {
            guard directory != nil else { throw POSIXError(.ENOENT) }
            scanCrashReports()
            let runs = [previous, run].compactMap { $0 }
            var entries: [String: Data] = [:]
            var incomplete = damagedFiles
            for file in try files() where runs.contains(where: { file.lastPathComponent.contains($0.id.uuidString) }) && file.pathExtension == "jsonl" {
                do {
                    let data = try read(file, limit: fileLimit)
                    var valid = Data()
                    for line in data.split(separator: 10) {
                        do { valid.append(try JSONEncoder().encode(JSONDecoder().decode(DiagnosticEntry.self, from: Data(line)))); valid.append(10) }
                        catch { incomplete = true }
                    }
                    if data.last != nil && data.last != 10 { incomplete = true }
                    entries[file.lastPathComponent] = valid
                } catch { incomplete = true }
            }
            let overview = DiagnosticExport(runs: runs, crashStatus: crashStatus, crash: crash, writeError: writeError, incomplete: incomplete)
            damagedFiles = incomplete
            return (try JSONEncoder().encode(overview), entries)
        }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("HostDock-diagnostics-\(UUID()).noindex")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let contents = stage.appendingPathComponent("HostDock-Diagnostics")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, data) in snapshot.1.merging(["summary.json": snapshot.0], uniquingKeysWith: { _, value in value }) {
            try append(data, to: contents.appendingPathComponent(name))
        }
        let archive = stage.appendingPathComponent("diagnostics.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", contents.path, archive.path]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        let data = try Data(contentsOf: archive)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".HostDock-diagnostics-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try append(data, to: temporary)
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
    }
}

private struct DiagnosticExport: Codable {
    let runs: [DiagnosticRun]
    let crashStatus: DiagnosticCrashStatus
    let crash: DiagnosticCrashSummary?
    let writeError: Bool
    let incomplete: Bool
}
