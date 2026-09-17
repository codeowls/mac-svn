# Mac SVN App 图标

- `AppIcon-v1.png`：带透明留白的生成原稿。
- `AppIcon.icns`：macOS 图标，包含 16、32、128、256、512 pt 的 1x/2x 尺寸。

设计使用蓝色圆角底板和白色三节点分支图形，表达版本历史与分支；避免小字号文字和复杂细节。参考 [Apple App icons 设计指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。

当前项目使用兼容 macOS 14+ 的传统 `.icns` 资源。这是静态图标，不是 Icon Composer 的分层 Liquid Glass 图标，也未制作深色或着色专用变体。

在项目根目录运行 `bash scripts/build-icon.sh` 可重新生成 `.icns`；`bash scripts/build-app.sh` 会自动生成并打包图标。缩放使用系统 `sips`，封装使用 `iconutil`，保留透明通道。中间尺寸存放在 `.build/AppIcon.iconset`，不纳入 Git。
