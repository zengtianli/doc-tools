# DocTools

A native macOS batch document toolbox — **clean / convert / split / merge / preview** for docx · pptx · xlsx · md · csv, tuned for Chinese typography.

Drop files in, pick an operation, get per-file results with one-click "Reveal in Finder". The SwiftUI shell delegates all real work to a local Python backend (JSON over stdout) — nothing ever leaves your machine.

![DocTools](docs/screenshot.png)

## Why

- **Native SwiftUI, not Electron.** One small binary, real macOS sidebar/toolbar/dark mode, a ⌘K command palette — no web view, no daemon.
- **Batch by drag-and-drop.** Drop any mix of files; every file gets its own success/failure line and output links.
- **Chinese typography fixes built in.** Straight→curly quotes, full-width punctuation, spacing around units — the cleanup passes are tuned for Chinese documents.
- **Fully local, zero cloud.** The backend is a Python script running on your Mac; no accounts, no telemetry, no uploads.

## Features

| Operation | What it does | Formats |
|---|---|---|
| **Clean** | Normalize documents in place: docx text repair (quotes/punctuation/units), markdown formatting, pptx style normalization, xlsx lowercase tidy-up | docx · md · pptx · xlsx |
| **Convert** | docx/pptx → markdown; markdown → Word with a template; csv/xlsx/txt interconversion; legacy `.doc` upgraded via LibreOffice/textutil | docx · pptx · md · csv · xlsx · txt · doc |
| **Merge** | Merge md/txt files into a single csv/xlsx | md · txt |
| **Split** | Split markdown by heading; split xlsx by sheet | md · xlsx |
| **View** | Markdown → styled HTML preview in your browser | md |

## Requirements

- macOS 15+ (Apple Silicon)
- [uv](https://docs.astral.sh/uv/) — `brew install uv`. The backend declares its dependencies inline (PEP 723); on first run uv resolves and installs python-docx / openpyxl / python-pptx automatically, so **the very first operation can take a minute or two**. After that it's instant.
- Optional: [LibreOffice](https://www.libreoffice.org/) for legacy `.doc` / `.xls` files.

## Install

**From a release:** download `DocTools-<version>-arm64.zip` from [Releases](../../releases), unzip, move `DocTools.app` to `/Applications`.

The app is ad-hoc signed (no paid Apple Developer certificate), so macOS will quarantine the download. Clear it once:

```bash
xattr -cr "/Applications/DocTools.app"
```

or right-click the app → Open, then allow it under **System Settings → Privacy & Security**.

**From source:**

```bash
git clone https://github.com/zengtianli/doc-tools.git
cd doc-tools
./build.sh --install   # requires Xcode
```

`build.sh` bundles the `backend/` directory into the app at `Contents/Resources/backend/`, so the built app is fully self-contained.

## FAQ

**Where do my files go?**
Nowhere. Everything runs locally; outputs are written next to your input files and listed in the results panel.

**"找不到 uv" on launch?**
Install uv (`brew install uv`) and reopen the app. GUI apps don't see your shell `PATH`, so DocTools looks for uv at the standard install locations (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`).

**Why is the first run slow?**
uv is creating the backend's Python environment (PEP 723 inline dependencies). It's a one-time cost.

## 简体中文

DocTools 是一个原生 macOS 批量文档工具箱：清洗 / 转换 / 拆分 / 合并 / 预览，
支持 docx · pptx · xlsx · md · csv，针对中文排版优化（弯引号、标点、单位间距）。

- 原生 SwiftUI，非 Electron；拖放批量处理，逐文件显示结果
- 全本地运行，零云端、零上传
- 依赖 [uv](https://docs.astral.sh/uv/)（`brew install uv`）；首次运行会自动安装
  python-docx / openpyxl / python-pptx，需 1–2 分钟，之后秒开
- 老 `.doc` / `.xls` 需要安装 LibreOffice（可选）
- 安装：从 Releases 下载 zip 解压到 `/Applications`，首次运行前执行
  `xattr -cr "/Applications/DocTools.app"`；或 `./build.sh --install` 从源码构建

## License

[MIT](LICENSE)

## 与私有版的关系

`backend/` 是私有版 `~/Dev/tools/doctools` 的**单向快照**，随其修复同步（本次同步了
「规范化」的选项声明：修哪些内容 × 改哪些范围）。

`Sources/`（SwiftUI 壳）**已刻意分叉**，不跟私有版同步 —— 所以后端声明的 `options`
在本公开版里暂不渲染成勾选框，改用命令行 `--opt K=V`：

```bash
python3 backend/doc_gui_backend.py gui-ops          # 看某个 op 有哪些可选项
python3 backend/doc_gui_backend.py gui-run --op clean \
        --opt scope.comments=0 --opt rule.units=0 --files a.docx
```
