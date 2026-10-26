import Darwin
import Foundation
import HostDockCore

@main
struct HostDockCLI {
    static let help = """
    HostDock 本机命令入口（默认输出 JSON）
    用法：hostdock <命令> [参数]
      status
      profiles list
      sessions list
      connect --profile <记录ID>
      disconnect --session <会话ID>
      close --session <会话ID>
      exec --session <会话ID> --command 'id -un' [--timeout 30]
      exec --session <会话ID> --stdin < command.txt
      terminal read --session <会话ID> [--tail 200]
      terminal send --session <会话ID> --text 'pwd' [--enter]
      terminal key --session <会话ID> --key ctrl-c|enter|tab|escape|up|down
      files list --session <会话ID> --path <远端绝对路径> [--side remote|local]
      files upload --session <会话ID> --source <本机绝对路径> [--source ...] --destination <远端目录>
      files download --session <会话ID> --source <远端绝对路径> [--source ...] --destination <本机目录>
      cancel --request <本次请求ID>
    
    先启动 HostDock，在“设置 → AI 与自动化”中开启“允许 AI 操作 HostDock”。
    connect 每次新建独立后台连接；sessions list 只列后台会话。
    --session 必须使用后台 ID；人工标签 ID 返回 SESSION_SCOPE_MISMATCH。
    连接仅使用已保存的认证；指纹和冲突需用户主动打开“AI 后台”处理。
    终端输入成功仅表示已发送；请通过 terminal read 读取实际结果。
    Ctrl+C 或终止 CLI 只取消本次请求。不会占用人工终端；关闭 AI 开关会取消任务并断开全部后台连接。
    不提供密码参数；不修改 PATH；无网络监听端口。
    """
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] || args == ["help"] { print(help); return }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let task = Task { () -> Int32 in
            var id = UUID()
            do {
                var input: String?
                if args.contains("--stdin") {
                    var bytes = Data()
                    while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
                        bytes.append(chunk)
                        guard bytes.count < 1_048_576 else { throw ControlFailure("INVALID_ARGUMENT", "标准输入必须小于 1 MiB。") }
                    }
                    guard let text = String(data: bytes, encoding: .utf8) else { throw ControlFailure("INVALID_ARGUMENT", "标准输入必须为 UTF-8 文本。") }
                    input = text
                }
                let request = try ControlRequest.parse(args, input: input); id = request.id
                let response = try await ControlClient.call(request)
                emit(response)
                if request.command == "exec", case .object(let result) = response.result,
                   case .number(let code) = result["exitCode"], code != 0 { return Int32(min(125, max(1, code))) }
                return response.ok ? 0 : 1
            } catch {
                let failure = Task.isCancelled ? ControlFailure("CANCELLED", "本次请求已取消。")
                    : error as? ControlFailure ?? ControlFailure("APP_UNAVAILABLE", "无法访问 HostDock，请启动应用并在设置中开启「允许 AI 操作 HostDock」。")
                emit(ControlResponse(id, error: failure))
                return Task.isCancelled ? 130 : 1
            }
        }
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        for source in [interrupt, terminate] { source.setEventHandler { task.cancel() }; source.resume() }
        let status = await task.value
        interrupt.cancel(); terminate.cancel()
        exit(status)
    }
    static func emit(_ value: ControlResponse) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
