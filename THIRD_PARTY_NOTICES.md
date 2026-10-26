# 第三方版权与许可声明

HostDock 的界面、业务逻辑和图标独立实现。应用使用 SwiftUI、AppKit、CryptoKit、系统字体和 SF Symbols，以及下列开源依赖。

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| Citadel | SSH、SFTP、PTY | MIT |
| SwiftTerm | 原生终端模拟 | MIT |
| BigInt | RSA 所需大整数运算 | MIT |
| swift-nio、swift-nio-ssh、swift-log、swift-atomics、swift-asn1、swift-crypto、swift-system、swift-collections、swift-argument-parser | 网络、密码学及基础工具 | Apache-2.0；以各上游例外条款为准 |
| swift-png、h | 图像及终端相关基础工具 | Apache-2.0 |

版本、来源和提交以 `Package.resolved` 为准。`scripts/collect-licenses.py` 收集全部锁定依赖及嵌入组件的 LICENSE、NOTICE、COPYING、COPYRIGHT 原文，包括 BoringSSL 等内嵌组件，分发时不得移除。

Citadel 的本地修改分别见 `packaging/Citadel-LSTAT.patch`、`packaging/Citadel-Exec.patch`、`packaging/Citadel-macOS14.patch`，用于不跟随符号链接查询、缺失命令退出状态保护和 macOS 14 TTY 可用性适配。原版权和许可保留，补丁随 App 分发。

App 的 `Contents/Resources/LICENSE.txt` 为 HostDock MIT 许可，`THIRD_PARTY_NOTICES.md` 为本声明，`Licenses/README.md` 提供完整第三方许可索引。部分 Apache 组件含 Swift Runtime Library Exception，实际适用内容以随附原文为准。

[electerm](https://github.com/electerm/electerm) 仅作为 SSH/SFTP/终端技术组合的调研参考，不作为依赖分发，未复制其产品代码或资源。

Citadel 内嵌的 OpenBSD bcrypt／Blowfish 组件包含 BSD／ISC 声明，完整原文随附于 `Licenses/citadel/Embedded-C-Licenses.txt`。

This product includes software developed by Niels Provos.
