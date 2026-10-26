import AppKit
import CoreServices
import Foundation

struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func command(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw InstallError(message: "检查失败：\(executable)") }
}

func verify(_ app: URL) throws {
    guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "app.hostdock.mac",
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") is String,
          bundle.object(forInfoDictionaryKey: "CFBundleVersion") is String else {
        throw InstallError(message: "候选应用不完整或标识不正确。")
    }
    try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
}

func unregister(_ app: URL) throws {
    let urls = LSCopyApplicationURLsForBundleIdentifier("app.hostdock.mac" as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
    guard urls.contains(where: { $0.standardizedFileURL == app.standardizedFileURL }) else { return }
    try command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", app.path])
}

do {
    let manager = FileManager.default
    guard CommandLine.arguments.count <= 2 else { throw InstallError(message: "用法：swift scripts/install-app.swift [候选 HostDock ZIP 或 App 路径]") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = (CommandLine.arguments.count == 2 ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent("dist/HostDock-build.zip")).resolvingSymlinksInPath().standardizedFileURL
    let target = URL(fileURLWithPath: "/Applications/HostDock.app")
    guard source != target else { throw InstallError(message: "候选应用不能是当前安装位置。") }
    let isArchive = source.pathExtension.lowercased() == "zip"
    guard isArchive || source.pathExtension == "app" else { throw InstallError(message: "请提供 HostDock ZIP 或 App。") }
    if !isArchive && !manager.isWritableFile(atPath: source.deletingLastPathComponent().path) {
        throw InstallError(message: "候选 App 来源只读，无法归档清理；请改用 ZIP 安装。")
    }
    let workspace = target.deletingLastPathComponent().appendingPathComponent(".HostDock-\(UUID()).noindex")
    try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let stage = workspace.appendingPathComponent("HostDock.app")
    let unpacked = workspace.appendingPathComponent("unpacked")
    defer {
        for app in [stage, unpacked.appendingPathComponent("HostDock.app")] where manager.fileExists(atPath: app.path) { try? unregister(app) }
        try? manager.removeItem(at: workspace)
    }
    let releaseScript = root.appendingPathComponent("scripts/release.py").path
    if isArchive { try command("/usr/bin/env", ["python3", releaseScript, "extract-app", source.path, unpacked.path]) }
    let candidate = isArchive ? unpacked.appendingPathComponent("HostDock.app") : source
    try verify(candidate)
    let bundle = Bundle(url: candidate)!
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    let rollback = target.deletingLastPathComponent().appendingPathComponent(".HostDock-\(UUID()).rollback")
    try manager.copyItem(at: candidate, to: stage)
    try verify(stage)
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "app.hostdock.mac")
    for app in running {
        guard app.terminate() else { throw InstallError(message: "旧版未能正常退出，未替换应用。") }
    }
    let deadline = Date().addingTimeInterval(60)
    while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard running.allSatisfy(\.isTerminated) else {
        throw InstallError(message: "旧版尚未退出；请处理未保存提示后重试，未替换应用。")
    }
    let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HostDock")
    let backups = support.appendingPathComponent("App Backups")
    try manager.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var copies = isArchive ? [] : [source]
    for directory in [root.appendingPathComponent("dist"), root.appendingPathComponent("dist/Backups"), backups] where manager.fileExists(atPath: directory.path) {
        copies += try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter {
            $0.lastPathComponent.hasPrefix("HostDock") && ["app", "app-backup"].contains($0.pathExtension)
        }
    }
    for path in Set(copies.map(\.path)) {
        let copy = URL(fileURLWithPath: path)
        let archive = backups.appendingPathComponent("HostDock-source-\(UUID()).zip")
        try command("/usr/bin/env", ["python3", releaseScript, "archive-app", copy.path, archive.path, "--remove-source"])
        print("已归档并清理候选或旧构建副本：\(archive.path)")
    }
    var backup: URL?
    if manager.fileExists(atPath: target.path) {
        let path = backups.appendingPathComponent("HostDock-\(Int(Date().timeIntervalSince1970))-\(UUID()).zip")
        try command("/usr/bin/env", ["python3", releaseScript, "archive-app", target.path, path.path])
        backup = path
        try unregister(target)
        try manager.moveItem(at: target, to: rollback)
    }
    do {
        try manager.moveItem(at: stage, to: target)
        try verify(target)
        guard LSRegisterURL(target as CFURL, true) == noErr else {
            throw InstallError(message: "系统应用注册失败。")
        }
    } catch {
        if manager.fileExists(atPath: target.path) { try? unregister(target); try manager.removeItem(at: target) }
        if manager.fileExists(atPath: rollback.path) {
            try manager.moveItem(at: rollback, to: target)
            _ = LSRegisterURL(target as CFURL, true)
        }
        throw error
    }
    if manager.fileExists(atPath: rollback.path) { try? unregister(rollback); try manager.removeItem(at: rollback) }
    print("已安装 HostDock \(version) (\(build))：\(target.path)")
    if let backup { print("可恢复备份：\(backup.path)") }
    print("用户资料保持原位置，未写入配置或密码库。")
} catch {
    fputs("安装失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
