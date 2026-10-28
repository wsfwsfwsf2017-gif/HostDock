import AppKit
import HostDockCore
import SwiftUI
import UniformTypeIdentifiers

extension DiagnosticOperation {
    static func automation(_ command: String) -> Self? {
        switch command {
        case "connect": return .automationConnect
        case "exec": return .automationExec
        case "terminal.send", "terminal.key": return .automationTerminal
        case "files.list", "files.upload", "files.download": return .automationFiles
        case "close", "disconnect": return .automationClose
        case "cancel": return .automationCancel
        default: return nil
        }
    }
}

extension DiagnosticFailure {
    static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let ssh = error as? SSHConnectionFailure {
            switch ssh {
            case .network: return .network
            case .authentication: return .authentication
            case .keyFile: return .keyFile
            case .keyFormat: return .keyFormat
            case .keyPassphrase: return .keyPassphrase
            case .hostKey: return .hostTrust
            case .sftp: return .sftp
            }
        }
        if let failure = error as? ControlFailure {
            switch failure.code {
            case "SERVER_PROTECTED", "PROTECTION_STATE_UNAVAILABLE": return .protectedServer
            case "CANCELLED": return .cancelled
            case "SESSION_OFFLINE": return .network
            default: return .other
            }
        }
        if error is FileChangedError { return .conflict }
        if error is POSIXError || error is CocoaError { return .io }
        return .other
    }
}

@MainActor
extension DiagnosticLog {
    func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "HostDock-Diagnostics-\(formatter.string(from: Date())).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await Task.detached { try self.export(to: url) }.value }
                catch {
                    let alert = NSAlert()
                    alert.messageText = "诊断包导出失败"
                    alert.informativeText = "已有日志保留，请检查保存位置的权限和剩余空间。"
                    alert.runModal()
                }
            }
        }
    }
}

struct DiagnosticsSettingsView: View {
    let diagnostics: DiagnosticLog
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("诊断", systemImage: "stethoscope").font(.title2.bold())
            Text("自动记录故障线索，仅保存在本机，不包含命令正文或终端内容。")
                .font(.system(size: 12)).foregroundStyle(DockTheme.secondary).fixedSize(horizontal: false, vertical: true)
            Button("导出诊断包…", action: diagnostics.chooseExport).buttonStyle(DockButtonStyle())
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let status = diagnostics.status()
                if status.previousRun != nil {
                    Text("上次未正常结束 · " + status.crashStatus.title).font(.caption).foregroundStyle(DockTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status.writeError { Text("诊断日志写入失败，请检查本机目录权限和剩余空间。已有记录仍可导出。")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if status.damagedFiles { Text("部分诊断文件损坏，原文件已保留；导出包含可读取的部分。")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
    }
}
