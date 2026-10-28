import Darwin
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let reports = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : root.appendingPathComponent("reports")
let log = DiagnosticLog(directory: root, reportsDirectory: reports)
log.record(.viewRecordClicked, id: UUID(), critical: true)
switch CommandLine.arguments[2] {
case "kill": Darwin.kill(getpid(), SIGKILL)
case "abort": abort()
case "inspect":
    log.flush()
    print("DIAGNOSTIC_CRASH_STATUS=\(log.status().crashStatus.rawValue)")
    try log.export(to: root.deletingLastPathComponent().appendingPathComponent("diagnostics.zip"))
    log.markNormalExit()
default: log.markNormalExit()
}
