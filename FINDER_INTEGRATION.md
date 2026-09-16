# 访达集成可行性调研

调研日期：2026-09-16。范围：Apple 官方资料、已安装 SnailSVN Lite 的扩展元数据、当前 Mac SVN 源码与本机开发环境。本文记录方案，尚未实现或加载 Mac SVN 的访达扩展。

## 结论

可以实现类似 SnailSVN 的访达右键 SVN 菜单，并进一步提供文件状态角标。建议采用 Apple 的 Finder Sync 扩展，将菜单与状态展示接入访达，继续由 Mac SVN 主程序执行 SVN 操作。

建议分阶段推进：先验证扩展加载和主程序唤起，再接入现有操作，最后增加角标缓存及后台状态服务。右键入口可独立于内置 SVN 引擎、Finder 角标和正式分发开发；完整集成不能仅靠给当前 SwiftUI 窗口增加菜单完成。

## 已核实的依据

- Apple 的 Finder Sync API 提供右键菜单、状态角标、访达工具栏按钮和目录观察回调。菜单可区分文件多选、目录空白处和侧栏等上下文，并读取当前目标与选择。参见 [Finder Sync](https://developer.apple.com/documentation/findersync) 与 [FIFinderSyncProtocol](https://developer.apple.com/documentation/findersync/fifindersyncprotocol?changes=_3_5)。
- SnailSVN 的官方介绍明确说明其使用 Finder 扩展提供 SVN 操作和图标覆盖，需要启用扩展并添加工作副本。参见 [SnailSVN 官方 App Store 介绍](https://apps.apple.com/us/app/snailsvn-svn-for-finder/id847259925?mt=12)。
- 本机 `/Applications/SnailSVNLite.app` 为 1.15.17，包含 `Contents/PlugIns/SnailSVNFreeExtension.appex`；其 `NSExtensionPointIdentifier` 为 `com.apple.FinderSync`，入口类为 `FinderSync`。这直接确认了已安装产品采用的扩展机制，未推断其内部通信或 SVN 执行实现。
- 对该扩展使用 `codesign -d --entitlements -` 只读检查，确认它声明了 App Sandbox、App Groups、应用范围书签及用户选择文件的只读权限。这是该产品的配置证据，不表示我们的扩展应照搬全部权限。
- 本机 SDK 的 `FinderSync.h` 存在上述 API，所检查声明未标记废弃。SDK 可用不等于 Mac SVN 的扩展已通过实际加载验收。

## 可实现的体验

| 能力 | 可行性与建议 |
| --- | --- |
| 右键菜单中的 SVN 操作 | 高；可提供“在 Mac SVN 中打开”“查看差异”“SVN 提交…”“更新工作副本”“工作副本历史”等入口。 |
| 单选、多选、目录空白处菜单 | API 支持；需分别定义作用范围，同一操作不能在不同上下文中悄悄扩大目标。 |
| 提交确认窗口 | 高；将访达选择映射为提交候选，复用现有说明、清单和提交前状态校验。 |
| 文件与目录角标 | API 支持；需额外建设本地状态查询、缓存和失效机制。 |
| 工具栏按钮 | API 支持；适合作为全局打开应用或管理工作副本入口，可后置。 |
| 主窗口关闭后持续刷新角标 | 可实现，但当前程序关闭最后窗口就退出，需增加独立后台状态服务或明确调整应用生命周期。 |
| 完全复制截图的菜单位置和样式 | 能添加菜单项及子菜单，但系统负责最终呈现；不承诺与其他扩展共存时的位置、顺序和外观完全相同。 |

首版建议在已注册工作副本中显示一个“Mac SVN”子菜单，常用操作是否提升到一级菜单可在实际使用后决定。菜单命名中的“工作副本”和“所选项目”应准确表达作用范围。

## 推荐架构

```text
访达选中的文件／当前目录
        ↓
Mac SVN Finder Sync 扩展
  菜单、选择上下文、角标展示
        ↓ 操作请求；不传递账号密码
Mac SVN 主程序
  请求校验、工作副本定位、确认窗口、忙碌状态处理
        ↓
现有 SVNCore → 本机 svn

第二阶段：后台状态服务 → 状态缓存 → 扩展更新角标
```

扩展保持轻量，不在构建右键菜单或请求角标时同步运行 SVN。Apple 指出系统可能为打开／保存面板创建额外扩展实例，并建议将同步、状态维护及远端通信放在独立服务中。参见 [Finder Sync 扩展开发指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)。

### 主程序与扩展的通信

- 主程序维护明确的“启用访达集成的工作副本”列表，扩展据此设置 `FIFinderSyncController.directoryURLs`。不扫描整块磁盘。
- 使用 App Groups 共享工作副本配置、非敏感操作请求及状态快照；它支持沙盒应用与非沙盒应用之间的通信，因此无需仅为接入菜单就把整个主程序迁入沙盒。参见 [配置 App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups?changes=_5)。
- 原型阶段验证“请求写入共享容器 → 唤起指定主程序 → 主程序接收请求”的链路。请求按类型携带工作副本、选中路径和请求标识；具体唤起 API、冷启动与已运行时的接收方式在原型中确认。
- 若采用自定义 URL 作为唤起信号，仅传递请求标识；不能把来自任意 URL 的动作视为可信写操作。主程序仍核实请求来源、操作类型及目标范围。
- 共享数据不保存密码。认证和提交继续由主程序处理，保持当前按仓库隔离的会话语义。
- 后台服务阶段再引入明确的 IPC 接口和统一调度。多个扩展实例、主窗口及后台服务不能同时写同一个工作副本。

## 当前项目需要补齐的部分

| 当前实现 | 接入影响 |
| --- | --- |
| [Package.swift](Package.swift) 只有可执行程序、SVNCore 库及测试目标 | 增加 App 与 Finder Sync 扩展的构建配置；推荐用 Xcode 工程管理宿主和 `.appex`，保留 SVNCore 的 Swift Package 与现有测试。 |
| [build-app.sh](scripts/build-app.sh) 手工组装 `.app` 并进行 ad-hoc 签名 | 增加扩展嵌入、独立 Info.plist、entitlements 和完整签名流程；仅复制 `.appex` 不能作为加载成功的证明。 |
| [MacSVNApp.swift](Sources/MacSVN/MacSVNApp.swift) 没有外部操作请求入口 | 增加唤起与请求分发，覆盖冷启动、已运行、正在操作及当前窗口属于另一副本的情况。 |
| [AppModel.swift](Sources/MacSVN/AppModel.swift) 打开副本时清空选择、聚焦和提交说明 | 需在成功定位副本后应用访达选择，并处理原工作区草稿，避免丢失已有内容。 |
| `AppModel.perform` 忙碌时直接返回 | 外部请求必须收到明确的忙碌反馈或进入可见队列，不能静默丢失。 |
| `AppModel` 的更新流程在副本根目录执行更新 | 首版可明确命名“更新整个工作副本”；若提供“更新所选项目”，必须增加接收目标路径的核心接口。 |
| `SVNClient.history(at:)` 当前查询整个工作副本最近 50 条历史 | 首版命名“工作副本历史”；单文件历史需要新增目标查询能力。 |
| 选择性提交使用 `--depth empty`，并限制部分目录操作 | 访达选择目录时先列出候选变更并确认，不能绕过现有约束或自动递归提交。 |
| 最近工作副本列表最多保留 12 项 | 集成目录注册表应与最近列表分离，避免最近记录被挤出后角标和菜单突然消失。 |
| 本地状态基于 `svn status --xml --ignore-externals` | 适用于变更列表，但需要为角标补充可靠的受控文件识别、状态覆盖范围与缓存新鲜度。 |

## 角标的关键设计

角标建议分为本地无修改、已修改、新增、冲突、未受控及未知状态。绿色状态只表示本地无修改，不能据此声称与服务器 HEAD 一致。

本机 `svn help status` 确认，默认查询侧重本地变更，`--verbose` 才提供每个项目的信息，`--show-updates` 会查询服务器的新版本。因此不能把“默认状态结果里没有这个路径”直接解释成“正常且已同步”；忽略目录、未受控目录的子项以及未覆盖范围需另行识别。

建议实现：

1. 先在已注册副本内建立可靠的状态快照，扫描成功后才发布结果；扫描失败或缓存过期时显示未知或暂不显示角标。
2. 扩展从缓存回应可见项目的角标请求，避免每个文件启动一次 SVN，也避免每次右键全量扫描仓库。
3. 主程序操作完成后触发刷新；通过文件系统事件识别编辑器或终端产生的变化，合并高频事件后扫描。Apple 的 [FSEvents 指南](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html) 说明该 API 用于目录层级内容变化通知；Finder Sync 的目录观察回调本身表示用户浏览行为，不能替代文件变化监听。
4. 目录角标需要聚合后代状态，并明确冲突优先等规则；忽略 `.svn` 的逐文件展示，但工作副本元数据变化仍应使相关状态失效。
5. 对 externals 和嵌套工作副本明确归属，保持当前 externals 单独管理的约定。

## 环境、签名与系统兼容性

- 本机只读检查结果为 macOS 27.0，构建号 `26A428`；当前开发目录为 `/Library/Developer/CommandLineTools`，`xcrun --find xcodebuild` 失败，`/Applications` 下未找到 Xcode 应用。推荐的 Xcode 扩展工程路线需要先准备适配的完整 Xcode；本次没有安装或切换开发环境。
- 主程序当前使用 ad-hoc 签名。不能由此推断扩展及 App Groups 在本机或其他机器上一定可用，也不能断言制作所有本地菜单原型都必须先购买开发者会员。第一步应验证所选签名方案下的加载和通信。
- 正式采用 App Groups 时需要正确配置标识、权限和签名。Apple 文档说明：macOS 的 `TeamID.groupName` 形式会核对签名中的 Team ID；`group.` 形式需按对应注册及描述文件要求配置。macOS 15 以后还有容器访问保护。参见 [访问 macOS App Group 容器](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)。
- Finder Sync 扩展按沙盒扩展配置，主程序保持当前部署方式；只申请实际功能需要的访问权限。系统隐私权限与主程序可访问路径仍需实测，App Groups 不自动授予任意工作副本的磁盘访问权。
- 应提供扩展启用状态检测和打开管理界面的入口。具体系统设置位置以目标系统为准；不能照搬旧版 SnailSVN 文档的菜单路径。
- Apple DTS 曾明确说明 Finder Sync 在 macOS 15.0 未被废弃，并记录了当时设置入口缺失及后续修复。这是历史兼容性证据，不是 macOS 27 的运行保证。参见 [Apple 关于 Finder Sync 设置入口的说明](https://developer.apple.com/forums/thread/756711)。
- 本次只读 `pluginkit` 查询返回 `Connection invalid`，未能据此确定 SnailSVN 扩展的注册或启用状态。未启停扩展、重启 Finder 或改动系统设置。
- 同一目录可能同时由 SnailSVN 或其他扩展管理，需要验证菜单共存与角标竞争；不能保证多个产品的角标同时显示。SnailSVN 的 [官方说明](https://langui.net/snailsvn/) 也将多个扩展监控同一工作副本列为排查项。

## 为什么当前选择 Finder Sync

Finder Sync 与“管理已有 SVN 工作副本并提供菜单和状态提示”的需求直接对应。File Provider 更侧重由系统管理本地副本、占位文件及远端存储同步；若采用它，会引入远超当前右键菜单需求的文件管理模型。基于当前产品范围，不建议为此迁移工作副本或重做 SVN 存储层。参见 [Apple File Provider 说明](https://developer.apple.com/documentation/fileprovider)。

系统服务或快速操作可单独提供“在 Mac SVN 中打开”一类入口，但不能把这类入口当作已经完成截图中的完整 Finder Sync 集成。无需为当前研究引入私有 Finder 注入机制。

## 分阶段建议与验收

### 阶段一：最小原型，先验证环境可行性

- [ ] 添加最小 Finder Sync 扩展及宿主构建配置，验证签名、嵌入、注册、启用和共享配置。
- [ ] 仅注册隔离测试目录，显示“在 Mac SVN 中打开”，传递当前目录、单选和多选路径。
- [ ] 验证主程序未启动及已经运行时均能收到请求，中文、空格、`@` 路径不丢失。
- [ ] 在本机 macOS 27 完成实际菜单点击、退出重开和扩展启用状态回读。

本阶段不执行 SVN 写操作。完成标准是端到端菜单请求被主程序正确接收，而非仅编译通过。

### 阶段二：复用现有 SVN 功能

- [ ] 接入单文件差异、工作副本历史及提交确认窗口。
- [ ] 接入明确作用范围的更新入口，若支持所选项目则先补齐核心接口。
- [ ] 完成工作副本识别、忙碌反馈、提交草稿保护、仓库认证与错误展示。
- [ ] 在隔离 SVN 仓库验收操作、取消、冲突与独立状态／历史读回。

本阶段完成后，即可获得主要的右键 SVN 操作体验，不依赖后台角标服务。

### 阶段三：状态角标与长期运行

- [ ] 增加状态缓存、目录聚合、文件事件合并和局部刷新。
- [ ] 明确应用关闭后的服务生命周期；若需持续刷新，增加独立状态服务及用户可控的启停设置。
- [ ] 验证大量文件、多个访达窗口、打开／保存面板及长时间空闲时的资源消耗。
- [ ] 验证重启、升级应用、移除监控目录、卷卸载，以及与 SnailSVN 同目录监控的表现。

### 跨阶段必须验证的范围

- 单文件、多个文件、目录空白处及跨工作副本选择；不支持的混合选择给出明确提示。
- 文件在菜单打开后被移动或修改时，执行前重新确认目标及状态。
- 嵌套副本、externals、受保护目录、失效路径及无权限目录。
- 当前支持的 macOS 14 与后续目标系统分别验收；本机验证不能替代其他系统的兼容性证明。

## 本次交付边界

已完成资料与代码调研，新增本文档并关联项目待办。未创建扩展实现，未运行新的 SVN 写操作，未修改 SnailSVN、访达设置、签名或开发环境；未将 API 和产品元数据证据记为 Mac SVN 运行验收。
