import Foundation

enum DiagnosticCrashStatus: String, Codable, Sendable {
    case notApplicable, matched, notFound, unreadable, invalid
    var title: String {
        switch self {
        case .notApplicable: return ""
        case .matched: return "已关联 macOS 崩溃报告"
        case .notFound: return "暂无匹配的 macOS 崩溃报告"
        case .unreadable: return "无法读取 macOS 崩溃报告，已有诊断事件仍可导出"
        case .invalid: return "部分系统报告无法解析，原文件已保留"
        }
    }
}

struct DiagnosticCrashSummary: Codable, Sendable {
    struct Frame: Codable, Sendable {
        let imageUUID: UUID?
        let offset: UInt64
        let symbol: String?
    }
    let exception: String
    let signal: String?
    let thread: Int
    let frames: [Frame]

    static func parse(_ data: Data, for run: DiagnosticRun) throws -> DiagnosticCrashSummary? {
        let object: [String: Any]
        if let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { object = whole }
        else {
            guard let newline = data.firstIndex(of: 10),
                  let body = try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = body
        }
        guard let bundle = object["bundleInfo"] as? [String: Any], bundle["CFBundleIdentifier"] as? String == run.bundleID,
              bundle["CFBundleShortVersionString"] as? String == run.version,
              bundle["CFBundleVersion"] as? String == run.build,
              object["pid"] as? Int == run.processID,
              let launched = object["procLaunch"] as? String,
              let date = launchDate(launched), abs(date.timeIntervalSince1970 - run.launchTime) < 5,
              let expectedUUID = run.binaryUUID, let images = object["usedImages"] as? [[String: Any]],
              images.contains(where: { ($0["uuid"] as? String).flatMap(UUID.init(uuidString:)) == expectedUUID }),
              let exception = object["exception"] as? [String: Any], let kind = exception["type"] as? String,
              let index = object["faultingThread"] as? Int, let threads = object["threads"] as? [[String: Any]],
              threads.indices.contains(index), let rawFrames = threads[index]["frames"] as? [[String: Any]] else { return nil }
        let knownExceptions = ["EXC_BAD_ACCESS", "EXC_CRASH", "EXC_BREAKPOINT", "EXC_BAD_INSTRUCTION", "EXC_RESOURCE", "EXC_GUARD", "EXC_SOFTWARE", "EXC_ARITHMETIC"]
        let knownSignals = ["SIGSEGV", "SIGABRT", "SIGBUS", "SIGTRAP", "SIGILL", "SIGKILL", "SIGTERM", "SIGFPE"]
        let signal = exception["signal"] as? String
        let frames = rawFrames.prefix(128).map { frame -> Frame in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil }
            let uuid = (image?["uuid"] as? String).flatMap(UUID.init(uuidString:))
            let symbol = frame["symbol"] as? String
            // Symbols are useful; report messages, process paths, registers and image paths are not exported.
            let safeSymbol = symbol.flatMap { value -> String? in
                guard value.utf8.count <= 1024, !value.contains("/"), !value.contains("\\"),
                      !value.contains("@"), !value.contains("://"), value.range(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: .regularExpression) == nil else { return nil }
                return value
            }
            return Frame(imageUUID: uuid, offset: (frame["imageOffset"] as? NSNumber)?.uint64Value ?? 0, symbol: safeSymbol)
        }
        return DiagnosticCrashSummary(exception: knownExceptions.contains(kind) ? kind : "OTHER",
            signal: signal.flatMap { knownSignals.contains($0) ? $0 : nil }, thread: index, frames: frames)
    }

    static func launchDate(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
        return formatter.date(from: text)
    }

    static func find(for run: DiagnosticRun, in directory: URL) -> (summary: DiagnosticCrashSummary?, status: DiagnosticCrashStatus) {
        guard run.binaryUUID != nil else { return (nil, .notFound) }
        guard FileManager.default.fileExists(atPath: directory.path) else { return (nil, .notFound) }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("HostDock-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            var invalid = false, unreadable = false
            for file in files.prefix(100) {
                do {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= 10 * 1024 * 1024,
                          (values.contentModificationDate ?? .distantPast).timeIntervalSince1970 >= run.launchTime - 5 else { continue }
                    if let result = try parse(Data(contentsOf: file), for: run) { return (result, .matched) }
                } catch let error as CocoaError where error.code == .fileReadCorruptFile || error.code == .propertyListReadCorrupt { invalid = true }
                catch { unreadable = true }
            }
            return (nil, unreadable ? .unreadable : invalid ? .invalid : .notFound)
        } catch { return (nil, .unreadable) }
    }
}
