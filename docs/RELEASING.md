# 构建、更新与正式发布

## 版本与日常更新

`packaging/Info.plist` 是唯一版本来源。`CFBundleShortVersionString` 为 `X.Y.Z`，`CFBundleVersion` 为递增正整数；关于窗口直接使用应用元数据。

日常功能修改仅增加构建号，不调整公开版本，不创建标签或 Release：

```sh
./scripts/test.sh
./scripts/build-app.sh
git add <本次源码和构建号改动>
git commit -m '中文说明本次修改'
git push origin main
swift scripts/install-app.swift
```

构建只输出 `dist/HostDock-build.zip`，上次构建移入 `dist/Backups/*.zip`。构建、安装与包体验证在隐藏的 `.noindex` 临时目录中处理 App，完成或失败后清理，不保留可被系统识别的构建副本。

安装器正常请求旧版退出，等待未保存提示处理；60 秒后仍未退出则停止，不强制结束进程。旧版保存为用户资料目录下的 ZIP，校验完整内容及权限后替换，应用替换或注册失败时回滚。成功后只有 `/Applications/HostDock.app` 保留为应用；连接配置、凭据和草稿不由安装器修改。安装后从此路径启动，确认实际路径、版本、签名和系统注册；当前不声明文件类型关联。

安装器也会将项目 `dist`、`dist/Backups` 和用户 `App Backups` 中遗留的 HostDock `.app`／`.app-backup` 逐一压缩校验、注销后清理。兼容传入可写的候选 App，安装时同样归档清理；只读安装盘请改用 ZIP，避免留下一份解包应用。备份必须是 ZIP，不能仅将 `.app` 改名为 `.app-backup`。

## 正式发布

只有用户明确要求“发布新版本”或授权首次发布，才执行下列流程：

1. 更新 Info.plist 的公开版本和构建号，增加 CHANGELOG 对应条目；检查源码、文档和截图不含个人资料或真实认证。
2. 运行功能测试、Release 构建和实际 SSH/SFTP 验收。真实服务器参数仅从本机受保护资料或显式环境变量读取，不传入 CI、不写入源码和日志。
3. 中文提交并推送 `main`，创建指向该提交的注释标签；标签必须与 Info.plist 一致：

```sh
./scripts/test.sh
./scripts/build-app.sh
git add <本次发布文件>
git commit -m '发布新版本及更新记录'
git push origin main
RELEASE_VERSION=$(python3 scripts/release.py version)
git tag -a "v$RELEASE_VERSION" -m "发布 HostDock $RELEASE_VERSION"
./scripts/package-release.sh "v$RELEASE_VERSION"
git push origin "v$RELEASE_VERSION"
```

4. 等待 GitHub Actions 结束且成功。工作流仅响应 `v*` 标签，检查实际 ARM64 架构、标签提交和版本，运行功能测试、构建及包体检查，然后用 `GITHUB_TOKEN` 创建草稿、上传三项附件、重新下载核对后公开。同名 Release（含草稿）拒绝覆盖。
5. 从公开 Release **重新下载** DMG、ZIP 和 `SHA256SUMS.txt`，放到新的空目录：

```sh
python3 scripts/release.py verify-packages <下载目录> --tag "v$RELEASE_VERSION"
swift scripts/install-app.swift <下载目录>/HostDock-$RELEASE_VERSION-arm64.zip
```

6. 检查安装版实际运行路径、一键连接、SFTP 浏览、终端及临时目录往返校验。记录 Actions、下载校验、安装和功能结果，分别列出未验收项。只有这些步骤完成才报告正式发布完成。

同版本本地包输出目录也拒绝覆盖。已推送标签、已发布版本和附件不移动、不覆盖；如需源码修正，增加修订版本和构建号后创建新标签。上传中断留下的草稿不公开，也不通过覆盖操作恢复。

## 检查范围

- 自动测试覆盖递归传输、同名冲突、取消恢复、文件操作、编辑冲突、认证保存、配置迁移、会话隔离、路径预约及 CLI。
- 发布脚本检查版本、构建号、最低系统版本、ARM64、主程序和 CLI 签名、图标、资源清单、14 项依赖许可、DMG 快捷方式、ZIP 路径和 SHA-256，以及两种包中的应用一致性。
- 容错测试覆盖错误标签、未提交源码、错误标签提交、缺失或变更资源、重复或错误的校验清单和损坏附件，以及归档内容／权限／空目录、归档失败保留来源、解包失败清理和非法 ZIP。
- 实际服务器测试默认关闭；不能将其跳过解释为通过。完整 Xcode 或 CLT 的常规测试由 `scripts/test.sh` 统一启动。`scripts/check-app.sh` 是需要交互输入的可选直连验收工具，不用于 CI。
- macOS 14 为最低部署目标；CI 的 macOS 15 和当前本机运行检查不代表 macOS 14 实机、其他 Mac 或外接屏已通过。

当前仅提供临时签名，未经 Apple 公证。没有 Intel、自动更新、全局 CLI 安装或付费签名步骤。

## 诊断与调试符号

诊断默认开启，只在本机 `~/Library/Logs/HostDock/Diagnostics` 保存固定事件、匿名对象编号、耗时和错误类别，不保存命令正文、终端内容、服务器地址、账号、真实路径或认证。目录为 700、文件为 600，保留 14 天、单文件不超过 2 MiB、总量不超过 20 MiB。设置「诊断」或帮助菜单可导出 ZIP，不自动上传，也不包含 AI 操作记录、连接资料和草稿。

诊断包包含当前运行与最近一次未正常结束运行的可读取事件，并尝试匹配 macOS 系统崩溃报告。未正常退出不等于确认崩溃；强制退出、断电和系统报告缺失等情况可能只有操作线索。原始系统报告保留在 macOS 的 DiagnosticReports 目录，导出只采用白名单提取堆栈和异常摘要。关键动作前完成小型文件写入，不承诺断电时最后一条必定落盘。

Release 构建保留函数与行号所需的调试信息，将工程根目录映射为 `/HostDock`、用户主目录映射为 `/BuildUser`。`scripts/archive-symbols.py` 从实际构建程序生成 dSYM，校验 ARM64、UUID 和 DWARF 后压缩到 `dist/Symbols/HostDock-X.Y.Z-buildN-UUID.zip`；App 仅包含 UUID 构建信息，不包含 dSYM。相同名称的不同内容拒绝覆盖。符号 ZIP 被 Git 排除；正式构建的 Actions 将其单独保留 90 天，不增加 Release 附件数量。公共仓库的 Actions 产物可能被他人下载，不在符号包中加入日志、业务数据或认证。

分析崩溃时必须使用报告中程序 UUID 对应的符号 ZIP，不可拿最新构建的符号代替旧版。诊断会改变极少量执行时间，不应把未复现崩溃或添加日志本身当作修复证据。
