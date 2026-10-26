#!/usr/bin/env python3
"""Copy the resolved dependencies' license/notice files into the application."""
import json
import re
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
pins = json.loads((root / "Package.resolved").read_text())["pins"]
checkouts = {p.name.lower(): p for p in (root / ".build/checkouts").iterdir() if p.is_dir()}
index = ["# HostDock 第三方许可", "", "HostDock 独立实现界面与应用逻辑；以下为依赖及其上游许可原文。", ""]
pattern = re.compile(r"^(licen[sc]e|notice|copying|copyright)([._-].*)?$", re.I)
for pin in pins:
    identity = pin["identity"]
    checkout = checkouts.get(identity.lower())
    if checkout is None:
        raise RuntimeError(f"缺少依赖检出目录：{identity}")
    version = pin["state"].get("version", pin["state"]["revision"])
    index += [f"## {identity} {version}", "", f"来源：{pin['location']}", ""]
    licenses = sorted(p for p in checkout.rglob("*") if p.is_file() and pattern.match(p.name)
                      and not any(part in (".git", ".build") for part in p.relative_to(checkout).parts))
    if not licenses:
        raise RuntimeError(f"依赖缺少许可文件：{identity}")
    for source in licenses:
        relative = Path(identity) / source.relative_to(checkout)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        index.append(f"- [{relative.as_posix()}]({relative.as_posix()})")
    # 部分内嵌 C 组件只在源码头部声明 BSD/OpenSSL 等许可，不能只收集 LICENSE 文件。
    headers = []
    for source in sorted(checkout.rglob('*')):
        if source.is_file() and source.suffix.lower() in ('.c', '.h', '.cc', '.cpp', '.hpp', '.s', '.inc', '.asm'):
            blocks = re.findall(r'/\*[\s\S]*?\*/|(?m:(?://[^\n]*(?:\n|$))+)', source.read_text(errors='replace'))
            notices = [block for block in blocks if re.search(r'copyright|redistribution|permission is hereby|licensed under|spdx-license', block, re.I)]
            if notices:
                headers += [str(source.relative_to(checkout)), *notices, '']
    if headers:
        relative = Path(identity) / 'Embedded-C-Licenses.txt'
        (destination / relative).write_text('\n'.join(headers), encoding='utf8')
        index.append(f'- [{relative.as_posix()}]({relative.as_posix()})')
    index.append("")
patch = root / "packaging/Citadel-LSTAT.patch"
if patch.exists():
    shutil.copyfile(patch, destination / "citadel/HostDock-LSTAT.patch")
    index += ["## HostDock 对 Citadel 的本地修改", "", "为锁定版本补齐 LSTAT 请求及可选的不跟随符号链接属性查询，保留原 STAT 默认行为。", "", "- [补丁](citadel/HostDock-LSTAT.patch)", ""]
(destination / "README.md").write_text("\n".join(index), encoding="utf-8")
print(f"已收集 {len(pins)} 项依赖的许可证与通知文件")

exec_patch = root / "packaging/Citadel-Exec.patch"
if exec_patch.exists():
    shutil.copyfile(exec_patch, destination / "citadel/HostDock-Exec.patch")
    with (destination / "README.md").open("a") as output:
        output.write("\n## HostDock 命令通道修改\n\n标准 Exec 缺少退出状态时报告错误，PTY/Shell 保持原行为。见 [补丁](citadel/HostDock-Exec.patch)。\n")

shutil.copyfile(root / 'packaging/Citadel-macOS14.patch', destination / 'citadel/HostDock-macOS14.patch')
with (destination / 'README.md').open('a') as output:
    output.write('\n## HostDock macOS 14 适配\n\n将仅封装既有 AsyncThrowingStream/NIO 的 TTY 类型与三个通道入口的可用性下限改为 macOS 14，与依赖自身部署目标一致。见 [补丁](citadel/HostDock-macOS14.patch)。\n')
