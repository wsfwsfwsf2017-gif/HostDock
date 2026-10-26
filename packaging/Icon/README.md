# HostDock 应用图标

采用已确认的 A2「负形」：蓝色圆角底与两块白色错位形体。

- `HostDock.photon`：Photon 可编辑母版，三个形状图层，分别包含 8、12、12 个平滑锚点。
- `HostDock.png`：从母版渲染的 1024 × 1024 sRGB 透明 PNG，作为构建输入。

修改图形后应同步导出 PNG，并检查透明边缘及 128、64、32 像素效果。构建通过 `scripts/create-icon.swift` 校验并读取 PNG，再生成完整 `.icns`；不需要安装 Photon。
