import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

private struct DiagnosticFixture {
    let root: URL
    var directory: URL { root.appendingPathComponent("logs") }
    var reports: URL { root.appendingPathComponent("reports") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HostDock-diagnostic-test-\(UUID()).noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func run() -> DiagnosticRun {
        DiagnosticRun(id: UUID(), startedAt: Date().timeIntervalSince1970, launchTime: Date().timeIntervalSince1970,
            processID: Int(getpid()), bundleID: "app.hostdock.mac", version: "1.2.3", build: "9", binaryUUID: UUID(), osVersion: [15, 0, 0])
    }
    func log(run: DiagnosticRun? = nil, fileLimit: Int = 2 * 1024 * 1024, totalLimit: Int = 20 * 1024 * 1024) -> DiagnosticLog {
        DiagnosticLog(directory: directory, run: run ?? self.run(), reportsDirectory: reports, fileLimit: fileLimit, totalLimit: totalLimit)
    }
    func entries() throws -> [DiagnosticEntry] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.flatMap { file in
                try Data(contentsOf: file).split(separator: 10).map { try JSONDecoder().decode(DiagnosticEntry.self, from: Data($0)) }
            }.sorted { $0.sequence < $1.sequence }
    }
    func crash(_ run: DiagnosticRun, secret: String = "PRIVATE_SENTINEL") throws -> Data {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        let body: [String: Any] = [
            "bundleInfo": ["CFBundleIdentifier": run.bundleID, "CFBundleShortVersionString": run.version, "CFBundleVersion": run.build],
            "pid": run.processID, "procLaunch": formatter.string(from: Date(timeIntervalSince1970: run.launchTime)),
            "procPath": "/Users/\(secret)/Applications/HostDock.app", "userID": 501, "private": secret,
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "message": secret], "faultingThread": 0,
            "usedImages": [["uuid": run.binaryUUID!.uuidString, "path": "/Users/\(secret)/binary"]],
            "threads": [["frames": [["symbol": "StackLayout.makeChildren", "imageIndex": 0, "imageOffset": 42],
                                      ["symbol": "/Users/\(secret)/file", "imageIndex": 0, "imageOffset": 99]], "registers": secret]]
        ]
        return Data("{\"app_name\":\"HostDock\"}\n".utf8) + (try JSONSerialization.data(withJSONObject: body))
    }
}

private func diagnosticProcess(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

@Suite(.serialized)
struct DiagnosticsTests {
    @Test func concurrentEventsAreOrderedPrivateAndBounded() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.clean() }
        let log = fixture.log(), object = UUID()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { log.record(.tabSelected, id: object, critical: true) } }
        }
        log.flush()
        let entries = try fixture.entries()
        #expect(entries.count == 101 && entries.map(\.sequence) == Array(1...101))
        #expect(Set(entries.dropFirst().compactMap(\.object)) == [1])
        #expect(!String(decoding: try JSONEncoder().encode(entries), as: UTF8.self).contains(object.uuidString))
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil) {
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func rotationRetentionCorruptionAndWriteFailure() throws {
        let fixture = try DiagnosticFixture(); defer { fixture.clean() }
        let log = fixture.log(fileLimit: 512, totalLimit: 2048)
        for _ in 0..<100 { log.record(.layoutChanged, layout: 4, critical: true) }
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        let sizes = try files.map { (try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! NSNumber).intValue }
        #expect(sizes.reduce(0, +) <= 2048)
        for file in files where file.pathExtension == "jsonl" { #expect(try Data(contentsOf: file).count <= 512) }
        let oldID = UUID(), old = fixture.directory.appendingPathComponent("events-\(oldID)-0.jsonl")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -15 * 86400)], ofItemAtPath: old.path)
        log.record(.tabSelected, critical: true)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let corrupt = fixture.directory.appendingPathComponent("run-\(UUID()).json")
        try Data("broken".utf8).write(to: corrupt)
        #expect(fixture.log().status().damagedFiles)
        #expect(try Data(contentsOf: corrupt) == Data("broken".utf8))
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data("do not alter".utf8).write(to: blocked)
        let failure = DiagnosticLog(directory: blocked)
        failure.record(.viewRecordClicked, critical: true)
        #expect(failure.status().writeError)
        #expect(try Data(contentsOf: blocked) == Data("do not alter".utf8))
        #expect(throws: (any Error).self) { try log.export(to: fixture.root.appendingPathComponent("missing/output.zip")) }
        let outside = fixture.root.appendingPathComponent("outside"); try Data("untouched".utf8).write(to: outside)
        let link = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
        #expect(DiagnosticLog(directory: link).status().writeError)
        #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
    }

    @Test func completedSpansRetireWithoutReusingOrChangingObjectReferences() throws {
        let fixture = try DiagnosticFixture(); defer { fixture.clean() }
        let log = fixture.log(), object = UUID()
        log.record(.tabSelected, id: object, critical: true)
        for _ in 0..<100 { let span = log.begin(.recordLoad, id: object); log.finish(span) }
        log.flush()
        let entries = try fixture.entries()
        let starts = entries.filter { $0.event == .operationStarted }, ends = entries.filter { $0.event == .operationFinished }
        #expect(starts.compactMap(\.object) == Array(2...101))
        #expect(ends.compactMap(\.object) == starts.compactMap(\.object))
        #expect(starts.allSatisfy { $0.related == 1 } && ends.allSatisfy { $0.related == 1 })
    }

    @Test func crashMatchingAndExportOnlyIncludeAllowlistedFields() throws {
        let fixture = try DiagnosticFixture(); defer { fixture.clean() }
        let run = fixture.run(), secret = "SYNTHETIC_SECRET_192.0.2.29_password"
        let data = try fixture.crash(run, secret: secret)
        let summary = try #require(try DiagnosticCrashSummary.parse(data, for: run))
        #expect(summary.exception == "EXC_BAD_ACCESS" && summary.frames.count == 2 && summary.frames[1].symbol == nil)
        #expect(!String(decoding: try JSONEncoder().encode(summary), as: UTF8.self).contains(secret))
        var mismatches = [fixture.run()]
        var changedPID = run
        changedPID = DiagnosticRun(id: run.id, startedAt: run.startedAt, launchTime: run.launchTime, processID: run.processID + 1,
            bundleID: run.bundleID, version: run.version, build: run.build, binaryUUID: run.binaryUUID, osVersion: run.osVersion)
        mismatches.append(changedPID)
        for mismatch in mismatches { #expect(try DiagnosticCrashSummary.parse(data, for: mismatch) == nil) }
        let old = fixture.log(run: run); old.record(.viewRecordClicked, critical: true); old.flush()
        let report = fixture.reports.appendingPathComponent("HostDock-test.ips"); try data.write(to: report)
        let next = fixture.log(); next.flush()
        #expect(next.status().previousRun?.id == run.id && next.status().crashStatus == .matched)
        let archive = fixture.root.appendingPathComponent("diagnostics.zip")
        try next.export(to: archive)
        let listing = try diagnosticProcess("/usr/bin/zipinfo", ["-1", archive.path])
        #expect(listing.0 == 0)
        #expect(!String(decoding: listing.1, as: UTF8.self).contains("__MACOSX"))
        let extracted = fixture.root.appendingPathComponent("extracted")
        #expect(try diagnosticProcess("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]).0 == 0)
        let items = try FileManager.default.contentsOfDirectory(at: extracted.appendingPathComponent("HostDock-Diagnostics"), includingPropertiesForKeys: nil)
        for item in items {
            let text = String(decoding: try Data(contentsOf: item), as: UTF8.self)
            #expect(!text.contains(secret) && !text.contains("/Users/") && !text.contains("procPath") && !text.contains("registers"))
        }
        #expect((try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: report) == data)
        next.markNormalExit()
        let another = fixture.log()
        #expect(another.status().previousRun?.id == run.id)
    }

    @Test func truncatedEventFileExportsValidPrefixAndPreservesOriginal() throws {
        let fixture = try DiagnosticFixture(); defer { fixture.clean() }
        let log = fixture.log(); log.record(.viewRecordClicked, critical: true)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
        var bytes = try Data(contentsOf: file); bytes.append(Data("{incomplete_PRIVATE_SENTINEL".utf8)); try bytes.write(to: file)
        let archive = fixture.root.appendingPathComponent("diagnostics.zip")
        try log.export(to: archive)
        #expect(log.status().damagedFiles)
        #expect(try Data(contentsOf: file) == bytes)
        let extracted = fixture.root.appendingPathComponent("extracted")
        #expect(try diagnosticProcess("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]).0 == 0)
        let contents = extracted.appendingPathComponent("HostDock-Diagnostics")
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: contents.appendingPathComponent("summary.json"))) as! [String: Any]
        #expect(summary["incomplete"] as? Bool == true)
        for file in try FileManager.default.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil) {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("PRIVATE_SENTINEL"))
        }
        let run = fixture.run()
        try Data("malformed".utf8).write(to: fixture.reports.appendingPathComponent("HostDock-broken.ips"))
        #expect(DiagnosticCrashSummary.find(for: run, in: fixture.reports).status == .invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.reports.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.reports.path) }
        #expect(DiagnosticCrashSummary.find(for: run, in: fixture.reports).status == .unreadable)
    }

    @Test @MainActor func applicationOperationsNeverLogSensitiveInputs() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let log = DiagnosticLog(directory: fixture.root.appendingPathComponent("diagnostics"))
        var profile = fixture.profiles[0]
        let secret = "PRIVATE_INPUT_SENTINEL"
        profile.name = secret; profile.endpoint = ConnectionEndpoint(host: "\(secret).example", port: 22, username: secret)
        profile.lastValidatedAt = Date()
        let transport = FakeSessionConnection(home: fixture.remote(0))
        await transport.configureExecution(result: SSHCommandResult(stdout: Data(secret.utf8), stderr: Data(secret.utf8)))
        let credentials = MemoryCredentialStore(); try await credentials.save(secret, account: profile.credentialAccount)
        let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile])))
        let app = AppModel(catalog: catalog, credentials: credentials,
            preferences: UserDefaults(suiteName: "HostDock-diagnostic-\(UUID())")!,
            editors: RemoteEditors(drafts: EditDraftStore(directory: fixture.root.appendingPathComponent("drafts"))),
            automationRecords: AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("records")), diagnostics: log),
            diagnostics: log, makeConnection: { transport })
        let preferences = UserDefaults(suiteName: "HostDock-diagnostic-controller-\(UUID())")!
        app.automation = AutomationController(app: app, defaults: preferences, socketURL: fixture.root.appendingPathComponent("control.sock"))
        await app.automation.setEnabled(true)
        let response = await app.automation.handle(ControlRequest(command: "connect", arguments: ["profile": profile.id.uuidString]))
        try #require(response.ok)
        let session = try #require(app.backgroundSessions.first)
        #expect(await app.automation.handle(ControlRequest(command: "exec", arguments: ["session": session.id.uuidString, "command": secret])).ok)
        #expect(await app.automation.handle(ControlRequest(command: "terminal.send", arguments: ["session": session.id.uuidString, "text": secret])).ok)
        do { try await session.runFileOperation(secret) { throw HostDockError(secret) }; Issue.record("预期合成文件操作失败") }
        catch { #expect(error is HostDockError) }
        let document = try RemoteDocument(session: session, path: fixture.remote(0) + "/payload.txt", contents: Data(secret.utf8),
            drafts: EditDraftStore(directory: fixture.root.appendingPathComponent("private-drafts")))
        document.text = secret + " changed"
        #expect(await document.save(overwrite: true))
        let record = try #require(app.automationRecords.record(sessionID: session.id))
        app.showRecord(record); try await waitUntil { record.loaded && !record.loading }
        app.setLayout(.quad); app.closeRecord(record.id)
        let root = fixture.root.appendingPathComponent("diagnostics")
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains(secret) && !text.contains(fixture.root.path) && !text.contains(profile.id.uuidString))
        }
        let archive = fixture.root.appendingPathComponent("diagnostics.zip")
        try log.export(to: archive)
        let extracted = fixture.root.appendingPathComponent("extracted")
        #expect(try diagnosticProcess("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]).0 == 0)
        for file in try FileManager.default.contentsOfDirectory(at: extracted.appendingPathComponent("HostDock-Diagnostics"), includingPropertiesForKeys: nil) {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(secret))
        }
        await app.closeAllTabs(); await app.automation.setEnabled(false); await app.shutdown(); log.flush()
    }

    @Test func criticalBreadcrumbSurvivesKilledChildWithoutPretendingItWasACrash() throws {
        let fixture = try DiagnosticFixture(); defer { fixture.clean() }
        let binary = fixture.root.appendingPathComponent("HostDockProbe")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = try diagnosticProcess("/usr/bin/xcrun", ["swiftc", root.appendingPathComponent("Sources/HostDock/Diagnostics.swift").path,
            root.appendingPathComponent("Sources/HostDock/DiagnosticReports.swift").path, root.appendingPathComponent("Tests/DiagnosticsProbe/main.swift").path,
            "-o", binary.path])
        try #require(result.0 == 0, Comment(rawValue: String(decoding: result.1, as: UTF8.self)))
        #expect(try diagnosticProcess(binary.path, [fixture.directory.path, "kill"]).0 == 9)
        let before = try fixture.entries()
        #expect(before.last?.event == .viewRecordClicked)
        let restored = fixture.log(); restored.flush()
        #expect(restored.status().previousRun != nil && restored.status().crashStatus == .notFound)
        restored.markNormalExit()
        let fresh = try DiagnosticFixture(); defer { fresh.clean() }
        let normal = fresh.log(); normal.markNormalExit()
        #expect(fresh.log().status().previousRun == nil)
    }
}
