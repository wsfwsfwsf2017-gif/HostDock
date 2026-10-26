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

do {
    let manager = FileManager.default
    guard CommandLine.arguments.count <= 2 else { throw InstallError(message: "用法：swift scripts/install-app.swift [候选 HostDock.app 路径]") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let candidate = CommandLine.arguments.count == 2 ? URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL : root.appendingPathComponent("dist/HostDock.app")
    let target = URL(fileURLWithPath: "/Applications/HostDock.app")
    guard candidate != target else { throw InstallError(message: "候选应用不能是当前安装位置。") }
    try verify(candidate)
    let bundle = Bundle(url: candidate)!
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    let stage = target.deletingLastPathComponent().appendingPathComponent(".HostDock-\(UUID()).app")
    let rollback = target.deletingLastPathComponent().appendingPathComponent(".HostDock-\(UUID()).rollback")
    defer { try? manager.removeItem(at: stage) }
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
    var backup: URL?
    if manager.fileExists(atPath: target.path) {
        let path = backups.appendingPathComponent("HostDock-\(Int(Date().timeIntervalSince1970))-\(UUID()).zip")
        try command("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", target.path, path.path])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try command("/usr/bin/unzip", ["-tq", path.path])
        backup = path
        try manager.moveItem(at: target, to: rollback)
    }
    do {
        try manager.moveItem(at: stage, to: target)
        try verify(target)
        guard LSRegisterURL(target as CFURL, true) == noErr else {
            throw InstallError(message: "系统应用注册失败。")
        }
    } catch {
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        if manager.fileExists(atPath: rollback.path) {
            try manager.moveItem(at: rollback, to: target)
            _ = LSRegisterURL(target as CFURL, true)
        }
        throw error
    }
    if manager.fileExists(atPath: rollback.path) { try manager.removeItem(at: rollback) }
    print("已安装 HostDock \(version) (\(build))：\(target.path)")
    if let backup { print("可恢复备份：\(backup.path)") }
    print("用户资料保持原位置，未写入配置或密码库。")
} catch {
    fputs("安装失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
