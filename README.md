# DocKit

Mac 上的本地文档工具：统一中文引号、整理标点与单位、转换格式、拆分和合并文件。原件保留，结果逐份列出。

**[产品主页与安装教程](https://app-mac-doctools.tianli.cyou/)** · [下载最新版](https://github.com/zengtianli/doc-tools/releases/latest) · [反馈问题](https://github.com/zengtianli/doc-tools/issues)

## 安装

需要 **macOS 15 或更高版本、Apple Silicon Mac**。下载 `DocKit-v1.1.0-arm64.zip`，解压后把 `DocKit.app` 拖入「应用程序」。公开版 bundle ID 保持 `io.github.zengtianli.DocTools`，源码仓仍叫 doc-tools。

发布包已经包含 Python 与文档依赖，常用操作不需要安装 uv、Python 或 Office，不需要账号，文件内容在本机处理。应用没有后台文档进程，执行任务时才启动引擎。

当前版本为 ad-hoc 签名，尚未经过 Apple 公证。若首次打开被系统阻止，先尝试打开，再到「系统设置 → 隐私与安全性」点「仍要打开」。来源确认可信但仍显示损坏时，可在终端执行：

```sh
xattr -cr "/Applications/DocKit.app"
```

不需要 sudo。Intel Mac 暂未提供此安装包。老式 DOC/PPT 的复杂内容建议先用 LibreOffice 转成 DOCX/PPTX；DOCX、XLSX、CSV、Markdown 的常用路径已内置。

## 使用

1. 从左侧选择操作，也可以按 **⌘K** 搜索。
2. 拖入文件或点「选择文件」，按需要选择目标格式和规则。
3. 点「执行」，或按 **⌘↩**。执行中禁止修改输入或重复启动。
4. 逐份查看结果；「在 Finder 显示」定位产出。成功 1/2 表示一份成功，一份仍需处理。

每次任务先复制输入，写到第一份输入旁的 `DocKit 输出/<本次任务>`。原件不覆盖，包括字体统一、清除页眉页脚等操作。保留输入的副本是恢复和核对的依据。

| 操作 | 支持范围 |
|---|---|
| 规范化 | DOCX、Markdown、PPTX 的文本整理；规则和 Word 范围可勾选 |
| 引号统一 | DOCX、Markdown；仅修引号，可选择 Word 正文、表格、修订、批注、脚注及页眉页脚 |
| 字体统一 | PPTX，含母版与版式 |
| 英文小写整理 | XLSX/XLSM 数据行、DOCX 正文 |
| 清页眉页脚 | DOCX 副本 |
| 格式转换 | Word ↔ Markdown、PPTX → Markdown、CSV → XLSX、XLSX → CSV/TXT 等受支持组合 |
| 拆分 | Markdown 按标题、XLSX/XLSM 按工作表 |
| 合并 | 多份 Markdown 合一篇，多份 TXT 转 CSV |
| 预览 | Markdown 生成本地 HTML，并在浏览器打开 |

公开版不包含 PDF → Word、客户模板、标书终稿检查或私密扫描词库。格式转换不能保证原版面完全一致，正式交付前请打开输出检查。

## 从源码构建

构建需要 Xcode、Python 3、uv，首次构建需要网络下载锁定依赖。运行发布包不需要这些开发工具。

```sh
git clone https://github.com/zengtianli/doc-tools.git
cd doc-tools
bash build.sh
python3 scripts/verify-package.py
bash scripts/check-ui-state.sh
```

产物：`build/DocKit.app`、`dist/DocKit-v1.1.0-arm64.zip` 和 `dist/release-manifest.json`。构建不自动替换本机安装版。文档引擎和受支持格式的依赖在 `Contents/Resources`，没有对作者工作区的运行时依赖。

`verify-package.py` 将整个应用复制到改名目录，在空 HOME、仅系统 PATH 和禁止网络的环境里执行真实文档任务，检查输出、原件哈希和应用签名。测试使用脚本生成的虚构文档，不读取个人文件。`check-ui-state.sh` 通过生产 BackendClient 和 ViewModel 检查选项解码、运行中输入隔离和防重入。

## 网站和发布

`VERSION` 是版本源，`scripts/package.py` 从实际安装包生成哈希与发行清单。`scripts/build-site.py` 生成 `build/site/` 与显式公开白名单 `site-manifest.json`；`--preview` 仅供本地预览，正式构建必须有匹配版本的真实媒体。

`python3 scripts/publish.py` 构建并验证新发行与网站。录制验收后，`python3 scripts/publish.py --upload` 直接消费已准备的 dist 安装包，检查哈希、包内签名、真实版本/build 与媒体对应关系，不再重新编译。上传要求工作树干净且提交已推送；Release 指向安装包清单中的二进制源提交，已有同名 Release 会拒绝覆盖。网站包交给现有部署入口消费，发布脚本不更改服务器配置。真实录制要求见 `docs/demo/plan.md`，原片留在 gitignored build/tutorial/raw/。

## 许可

原创代码采用 [MIT](LICENSE)。运行时及依赖许可证随安装包保留，说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。公开产品独立发版，只按需同步上游通用修复；客户资源和私有业务能力不进入公开包。

## English

DocKit is a native macOS document toolbox for Chinese typography, conversion, splitting and merging. It works on copies and preserves your original files. The release bundles its Python runtime and document dependencies, so supported local operations need no account, uv or Python installation. Requires Apple Silicon and macOS 15+. The current build is ad-hoc signed and not notarized. See the product website for installation, real demonstrations and supported formats.
