# 访达集成 / Finder integration

本功能包含在 1.3.0 及更新安装包中，也可从源码构建。
This feature is included in version 1.3.0 and later, and in source builds.

## 启用

1. 安装并打开 Mac SVN 1.3.0 或更新版本；从源码运行时，使用 `bash scripts/build-app.sh` 构建并打开 `dist/Mac SVN.app`。裸 `swift run` 不包含访达扩展。
2. 打开本地 SVN 工作副本，进入“设置 → 访达”。
3. 点击“管理访达扩展”，在系统界面启用 Mac SVN。
4. 点击“添加当前工作副本”。“扩展已接收目录配置”表示已收到扩展的同步回执；未收到时，确认扩展已启用，再点击“检查并同步”。
5. 在该目录的文件、文件夹或空白处右键，使用“Mac SVN”菜单。

每个工作副本单独启用。最近使用列表的变化不会自动添加或移除集成目录。“停用”只移除菜单监控，不删除本地文件。配置会保存，扩展可在主应用关闭时提供菜单，并在操作时唤起主应用。

## 操作范围

- **提交所选项目**：展示所选文件或目录范围内的实际变更。填写说明并检查实际提交范围后，再次确认提交。SVN 必须关联的移动两端或父目录会在确认页列出。未受控、冲突等不可提交状态不会直接提交。
- **更新整个工作副本**：无论右键哪个文件，确认页都明确更新整个所属副本。若只想更新部分目录，请勿使用此入口。
- **查看差异 / 查看历史**：只支持单选；历史可继续加载更早记录。
- **在 Mac SVN 中打开**：在确认表单中打开目标工作副本。

跨工作副本多选会报错，不会默认选取一个副本。后续请求排队，当前表单关闭后再显示。访达表单的说明和勾选与主工作区草稿隔离；写操作结束后刷新同一副本的主界面。

使用与主应用相同的 SVN 可执行文件、忽略配置和仓库认证。可在操作表单中登录仓库，失败后手动重试；不会自动重试写操作。取消提交后应核对仓库历史和工作副本状态，不能仅凭取消认为服务器没有提交。

## 当前边界

本版本提供菜单和操作表单，不提供文件状态角标或后台状态服务。扩展只传递路径和操作意图，不读取文件或执行 SVN；主应用重新验证工作副本和操作范围。目录配置通知不携带账号密码，也不是写操作授权。

目前使用 ad-hoc 签名，本机验收不能代替其他机器和系统版本的安装验证。源码构建支持 arm64/x86_64；正式 Developer ID 签名、公证和跨设备验收属于发布工作。

## English

Build the app with `bash scripts/build-app.sh`, open a working copy, then use **Settings → Finder**. Enable Mac SVN through **Manage Finder Extensions**, then choose **Add Current Working Copy**. If configuration has not been acknowledged, enable the extension and select **Check and Sync**.

Right-click a file, folder, or folder background within a registered working copy:

- **Commit Selected Items** lists changes within the selection, then reviews SVN's full required scope before confirmation.
- **Update Entire Working Copy** always updates the whole owning working copy after confirmation.
- **Show Diff / Show History** accept one selection. History supports loading earlier records.
- **Open in Mac SVN** opens the target working copy from the confirmation form.

Selections spanning multiple working copies are rejected. Requests are queued without replacing the current form. Main-workspace drafts are preserved. Authentication, SVN configuration, cancellation, and error handling use the host application; failed writes are never retried automatically.

Disabling a directory does not delete files. Directory registrations persist independently of recent working copies. The extension can show menus while the host is closed. Status badges and background status services are not included. Current builds use ad-hoc signatures; Developer ID signing, notarization, and cross-device acceptance remain distribution work.
