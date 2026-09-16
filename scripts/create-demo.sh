#!/bin/bash
set -euo pipefail

# All changes stay in a new local file:// repository; no existing repository is touched.
DEMO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-svn-demo.XXXXXX")"
svnadmin create "$DEMO_ROOT/repository"
svn checkout "file://$DEMO_ROOT/repository" "$DEMO_ROOT/working-copy"
cd "$DEMO_ROOT/working-copy"
printf '# Mac SVN 演示\n\n这是本地测试工作副本。\n' > README.md
svn add README.md
svn commit --message '初始化本地演示仓库'
printf '\n通过 App 查看这一行差异，然后勾选提交。\n' >> README.md
printf '先添加到 SVN，再选择提交。\n' > '中文 @ 文件.txt'
printf '\n请在 Mac SVN 中打开：\n%s\n' "$DEMO_ROOT/working-copy"
