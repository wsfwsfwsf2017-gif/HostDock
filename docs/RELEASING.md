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

安装器正常请求旧版退出，等待未保存提示处理；60 秒后仍未退出则停止，不强制结束进程。旧版保存为用户资料目录下的 ZIP，应用替换或注册失败时回滚。连接配置、凭据和草稿不由安装器修改。安装后从 `/Applications/HostDock.app` 启动，确认实际路径、版本和签名；当前不声明文件类型关联。

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
ditto -x -k <下载目录>/HostDock-$RELEASE_VERSION-arm64.zip <解包目录>
swift scripts/install-app.swift <解包目录>/HostDock.app
```

6. 检查安装版实际运行路径、一键连接、SFTP 浏览、终端及临时目录往返校验。记录 Actions、下载校验、安装和功能结果，分别列出未验收项。只有这些步骤完成才报告正式发布完成。

同版本本地包输出目录也拒绝覆盖。已推送标签、已发布版本和附件不移动、不覆盖；如需源码修正，增加修订版本和构建号后创建新标签。上传中断留下的草稿不公开，也不通过覆盖操作恢复。

## 检查范围

- 自动测试覆盖递归传输、同名冲突、取消恢复、文件操作、编辑冲突、认证保存、配置迁移、会话隔离、路径预约及 CLI。
- 发布脚本检查版本、构建号、最低系统版本、ARM64、主程序和 CLI 签名、图标、资源清单、14 项依赖许可、DMG 快捷方式、ZIP 路径和 SHA-256，以及两种包中的应用一致性。
- 容错测试覆盖错误标签、未提交源码、错误标签提交、缺失或变更资源、重复或错误的校验清单和损坏附件。
- 实际服务器测试默认关闭；不能将其跳过解释为通过。完整 Xcode 或 CLT 的常规测试由 `scripts/test.sh` 统一启动。`scripts/check-app.sh` 是需要交互输入的可选直连验收工具，不用于 CI。
- macOS 14 为最低部署目标；CI 的 macOS 15 和当前本机运行检查不代表 macOS 14 实机、其他 Mac 或外接屏已通过。

当前仅提供临时签名，未经 Apple 公证。没有 Intel、自动更新、全局 CLI 安装或付费签名步骤。
