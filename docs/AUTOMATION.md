# HostDock 命令行与 AI 接入

CLI 命令协议版本为 1。CLI 控制正在运行的原生应用，共用保存记录、主机指纹、SSH/SFTP 会话和传输队列。

## 开启与调用

1. 打开 HostDock，在「HostDock → 设置… → AI 与自动化」手动开启「允许 AI 操作 HostDock」。首次安装默认关闭，开启偏好会保留；关闭应用后不再监听。
2. 使用应用包内的 CLI，无须修改 PATH 或安装全局工具：

```sh
HOSTDOCK_CLI='/Applications/HostDock.app/Contents/Helpers/hostdock'
"$HOSTDOCK_CLI" --help
"$HOSTDOCK_CLI" profiles list
"$HOSTDOCK_CLI" sessions list
```

以下 `<记录ID>`、`<会话ID>` 替换为上面 JSON 返回的完整 ID，不按名称猜测目标，不隐式使用当前选中的服务器。

```sh
"$HOSTDOCK_CLI" connect --profile '<记录ID>'
"$HOSTDOCK_CLI" exec --session '<会话ID>' --command 'id -un; pwd' --timeout 30
"$HOSTDOCK_CLI" disconnect --session '<会话ID>'
"$HOSTDOCK_CLI" close --session '<会话ID>'
```

`connect` 仅使用已有认证，复用同一身份的会话。缺少认证返回 `AUTH_REQUIRED`；指纹需要核对时返回 `NEEDS_USER_ACTION`，由用户在应用中处理。不要把这些状态当作已连接，也不要自动接受指纹。

`disconnect` 断开但保留会话，`close` 断开并从运行列表移除；保存记录继续保留。

JumpServer 记录和 GUI 共用堡垒机配置解析。配置更新后，在线记录仍返回原会话；断开再连接才使用更新后的网关、账号和私钥。记录 ID 保持不变。CLI 不提供修改堡垒机认证的入口，认证更新由应用验证并保存。

## 命令和交互终端

`exec` 创建同一 SSH 连接上的独立命令通道，不向用户正在操作的交互 Shell 混入命令。返回 `stdout`、`stderr`、`exitCode` 和两路输出编码。正常 UTF-8 输出为字符串；非 UTF-8 输出使用 base64 并标注编码。远端非零退出码仍返回实际结果，CLI 以非零状态退出。

默认超时 30 秒，允许 0.1–3600 秒；输出上限 512 KiB。超时、取消或超过上限只清理本次命令通道，保留 SSH、SFTP 和交互终端。远端已脱离会话的后台程序可能继续运行。

```sh
"$HOSTDOCK_CLI" exec --session '<会话ID>' --stdin < commands.txt
"$HOSTDOCK_CLI" terminal send --session '<会话ID>' --text 'pwd' --enter
"$HOSTDOCK_CLI" terminal read --session '<会话ID>' --tail 100
"$HOSTDOCK_CLI" terminal key --session '<会话ID>' --key ctrl-c
```

`terminal send` 的 `sent: true` 仅表示输入已写入 PTY，不能据此认定命令成功。使用 `terminal read` 读取实际终端文本；它是屏幕／滚动缓冲的文本快照，不提供命令退出码。`terminal key` 支持 `ctrl-c`、`enter`、`tab`、`escape`、`up`、`down`，不发送全局桌面按键。

每条连接首次执行前会用不写文件的固定探测命令核对退出码与输出流。若网关拒绝标准 SSH exec，或改写退出码／合并标准错误流，返回 `EXEC_UNAVAILABLE`，不执行本次用户命令，可明确改用交互终端。终端和 exec 是两种不同工作方式，不会静默切换后伪造结果。

## 浏览与传输

```sh
"$HOSTDOCK_CLI" files list --session '<会话ID>' --path '/远端实际路径'
"$HOSTDOCK_CLI" files list --session '<会话ID>' --side local --path '/本机绝对路径'
"$HOSTDOCK_CLI" files upload --session '<会话ID>' --source '/本机文件或目录' --destination '/远端目录'
"$HOSTDOCK_CLI" files download --session '<会话ID>' --source '/远端文件或目录' --destination '/本机目录'
```

可重复 `--source` 选择多个来源。目标目录必须已经存在，传输复用临时文件提交、备份、路径预约和取消清理。符号链接、特殊文件及同名跳过会在结果的 `skipped` 中体现。同名冲突由所属会话显示确认，默认跳过；不会自动覆盖。

JumpServer 的 SFTP 路径可能经过资产映射。先列出实际路径，不要假定 `/` 是资产的系统根。

## 状态、取消和 JSON

```sh
"$HOSTDOCK_CLI" status
"$HOSTDOCK_CLI" cancel --request '<请求ID>'
```

`status` 列出进行中的请求 ID、操作类型和目标会话，不返回命令文本或认证资料。Ctrl+C 或终止 CLI 会关闭它的请求通道，应用只取消对应请求；已建立会话保留，传输会清理临时文件。

所有结果默认是一个 JSON 对象：

```json
{"version":1,"requestID":"...","ok":true,"result":{"stdout":"ssta\n","stderr":"","exitCode":0,"stdoutEncoding":"utf8","stderrEncoding":"utf8"}}
```

失败时 `ok: false`，并提供 `error.code` 和可读的 `error.message`。常用错误包括 `DISABLED`、`APP_UNAVAILABLE`、`AUTH_REQUIRED`、`NEEDS_USER_ACTION`、`INVALID_ARGUMENT`、`SESSION_NOT_FOUND`、`SESSION_OFFLINE`、`BUSY`、`TIMEOUT`、`CANCELLED`、`OUTPUT_LIMIT`、`EXEC_UNAVAILABLE`、`EXIT_STATUS_UNAVAILABLE`。当退出状态未知时，命令可能已执行，不要自动重试。`result` 和 `error` 为空时会省略。

## 访问边界

自动化只监听当前用户的 Unix socket：`~/Library/Application Support/HostDock/automation.sock`，目录 700、socket 600，并校验对端用户。不开放 TCP/HTTP 端口。

开启后，同一 Mac 账户下的程序能够通过该接口使用现有服务器认证；请在不需要时关闭。关闭会拒绝新请求并取消 AI 未完成的操作，保留已建立的会话和人工操作。CLI 不接收密码参数、不导出密码或口令，不上传私钥；命令文本支持标准输入，应用不持久化自动化命令及输出日志。
