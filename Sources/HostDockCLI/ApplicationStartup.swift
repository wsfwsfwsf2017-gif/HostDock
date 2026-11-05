import AppKit
import Foundation
import HostDockCore

@MainActor
enum ApplicationStartup {
    static let bundleIdentifier = "app.hostdock.mac"

    static func prepare(timeout: Duration = .seconds(15),
                        probe: () async throws -> Void = probe,
                        launch: () async throws -> Void = launch) async throws {
        try Task.checkCancellation()
        do { try await probe(); return }
        catch let error as ControlFailure { throw error }
        catch let error as CancellationError { throw error }
        catch { }

        try Task.checkCancellation()
        try await launch()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do { try await probe(); return }
            catch let error as ControlFailure { throw error }
            catch let error as CancellationError { throw error }
            catch { }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlFailure("APP_UNAVAILABLE", "HostDock 自动化接口未在 15 秒内就绪，请检查应用是否正常运行及「允许 AI 操作 HostDock」是否开启。")
    }

    private static func probe() async throws {
        let response = try await ControlClient.call(ControlRequest(command: "status"))
        if let error = response.error { throw error }
    }

    static func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        return configuration
    }

    private static func launch() async throws {
        guard UserDefaults(suiteName: bundleIdentifier)?.bool(forKey: "HostDock.AutomationEnabled") == true else {
            throw ControlFailure("DISABLED", "请先在 HostDock 设置中手动开启「允许 AI 操作 HostDock」，之后调用会自动后台启动应用。")
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains(where: { !$0.isTerminated }) else { return }
        let url = URL(fileURLWithPath: "/Applications/HostDock.app")
        guard Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
            throw ControlFailure("APP_UNAVAILABLE", "未找到 /Applications/HostDock.app，请先安装 HostDock。")
        }
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration()) }
        catch { throw ControlFailure("APP_UNAVAILABLE", "无法在后台启动 HostDock，请检查应用安装与系统权限。") }
    }
}
