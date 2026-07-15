---
name: project-oss-verify-traps
description: doc-tools 公开仓核验陷阱：release zip 内 __pycache__ pyc 嵌构建机绝对路径；Swift UI 字典/超时分支是已裁操作(typeset/scan)字面量残留高发点
metadata:
  type: project
---

2026-07-15 核验 zengtianli/doc-tools v1.0.0 发现的两类漏网面：

1. **release 资产 ≠ git 仓**：仓 grep 干净不等于公开面干净。zip 内 `DocTools.app/Contents/Resources/backend/__pycache__/doc_dispatch.cpython-312.pyc` 用 `strings` 一查即见构建机绝对路径 `/Users/tianli/Dev/apps/desktop/doc-tools-oss/dist/...`。根因 = build.sh 打包 backend/ 时未排除 `__pycache__`。
2. **死代码字面量残留**：已裁操作(typeset/scan)的字面量藏在 Swift 侧 `ContentView.swift` palette 同义词字典和 `BackendClient.swift` 超时分支——backend OPS 裁掉后前端引用不会报编译错，grep 必扫 Sources/。

**Why:** 本次按题设判据 typeset 命中即 FAIL；pyc 泄露是题设 grep 面之外自主 strings 扫出的。
**How to apply:** 下次核验任何公开 release：① 必 unzip 后 `find -name '*.pyc'` + `strings | grep /Users`；② 敏感词 grep 范围必含 Swift/前端源，不止 backend；③ 修复点 = build.sh 加 `--exclude __pycache__`、删两处死代码字面量后重发 release。
