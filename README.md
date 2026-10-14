# DocKit

**中文** | [English](README_EN.md)

App 菜单提供「配置与更新…」和「检查更新…」。记住上次操作与各操作的目标格式，支持导入、导出和可选择开启的 iCloud 配置同步（默认关闭）；勾选规则、文件路径、文档与任务记录不参与同步。检查更新只访问本产品的 GitHub 发行信息，不发送文档内容。

「配置与更新…」可保存刷新快捷键并单独关闭或恢复，默认 ⌘R，只在本 App 内生效；⌘K 搜索、⌘↩ 执行及系统编辑快捷键保留，冲突组合不覆盖原设置。刷新组合与更新选项随可选配置同步迁移；自动检查、下载和安装各有独立选项，默认关闭。

Mac 上的本地文档工具：统一中文引号、整理标点与单位、转换格式、拆分和合并文件。原件保留，结果逐份列出。

**[产品主页与安装教程](https://app-mac-doctools.tianli.cyou/)** · [下载最新版](https://github.com/zengtianli/doc-tools/releases/latest) · [反馈问题](https://github.com/zengtianli/doc-tools/issues)

<!-- lightweight:start -->
## 资源占用

| 安装包 | 空闲内存 | 空闲 CPU | 冷启动到首屏就绪 |
|---|---|---|---|
| **44.8 MB**（装好后 133 MB） | **50.3 MB** | **0%** | **665 ms** |

SwiftUI 界面；文档处理靠包内 Python 3.12，只在启动读操作列表和点「执行」时起子进程、做完即退出，空闲只剩界面进程。运行时只带各项操作实际用到的部分：docx 转 Markdown 用约 140 行的内容识别代替 magika 与 onnxruntime 模型运行时，去掉各库测试目录和用不到的标准库，二进制去掉调试符号；各项操作用到的模块预编译成字节码，不再每次从源码编译。

<sub>v1.1.3 (39) · Mac16,12 / Apple M4 / macOS 27.2 · 静默只读加载包内真实操作目录并离屏绘制初始界面；输入文件为空，不处理文档，不写本人偏好。 · 2026-10-05。数字来自所列版本与设备的测量记录；当前版本与测量范围以本页说明为准。内存口径为 phys_footprint；CPU 为 60 秒采样窗内 CPU 时间 ÷ 墙钟；大小按十进制 MB。原始数据见 [perf/lightweight.json](perf/lightweight.json)。</sub>
<!-- lightweight:end -->

以上是本地验收构建 **1.1.3 (39)** 的实测，公开下载仍为 **1.1.3 (37)**；两份构建分别标注，不把本地样本当作已发布包的性能。

## 安装

需要 **macOS 15 或更高版本、Apple Silicon Mac**。下载 `DocKit-v1.1.3-arm64.zip`，解压后把 `DocKit.app` 拖入「应用程序」。公开版 bundle ID 保持 `io.github.zengtianli.DocTools`，源码仓仍叫 doc-tools。

发布包已经包含 Python 与文档依赖，常用操作不需要安装 uv、Python 或 Office，不需要账号，文件内容在本机处理。应用没有后台文档进程，执行任务时才启动引擎。

目前可下载的 1.1.3 (37) 为 ad-hoc 签名，尚未经过 Apple 公证；之后的发行包一律用 Developer ID 签名并经 Apple 公证、装订票据，下载后直接打开，不需要下面的步骤。对 1.1.3 (37)：若首次打开被系统阻止，先尝试打开，再到「系统设置 → 隐私与安全性」点「仍要打开」。来源确认可信但仍显示损坏时，可在终端执行：

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

产物：`build/DocKit.app`、`dist/DocKit-v1.1.3-arm64.zip` 和 `dist/release-manifest.json`。构建不自动替换本机安装版。

签名分两种，`scripts/package.py` 按本机钥匙串自动选：有 Developer ID Application 证书时，应用和包内运行时的每个可执行文件、动态库都用它签名，带 hardened runtime 和安全时间戳，这是发行构建；没有证书时为 ad-hoc 签名，只供本机试用（别的 Mac 上 Gatekeeper 会拒绝）。多张证书时用 `DOCKIT_SIGN_IDENTITY` 指定，`DOCKIT_SIGN_IDENTITY=-` 强制 ad-hoc。用证书签名要在登录会话里做，纯 SSH 里钥匙串打不开。

装进「应用程序」只接受任何一台 Mac 都能直接运行的包：`bash build.sh --install` 在构建后依次运行 `scripts/notarize.py`（提交 Apple 公证、装订票据、用 `stapler validate` 与 `spctl` 复核，并用装订后的应用重出压缩包和清单）与 `scripts/install.py`（复核后替换已装版本，旧版进废纸篓，再让装好的应用回答一次 `status`）。ad-hoc、Apple Development 签名、未公证或带设备清单描述文件的包，两步都会拒绝。另一台 Mac 装同一份包：`python3 scripts/install.py --archive DocKit-v1.1.3-arm64.zip`。公证凭据从 `DOCKIT_NOTARY_PROFILE`，或 `NOTARY_KEY`、`NOTARY_KEY_ID`、`NOTARY_ISSUER` 读取；公证只是把包提交给 Apple 检查，不等于发布。`DOCKIT_OUT=目录` 让应用、压缩包和清单都落在该目录，不动 `dist/`。文档引擎和受支持格式的依赖在 `Contents/Resources`，没有对作者工作区的运行时依赖。

本人明确授权的本机迭代使用独立入口 `bash build.sh --install-local`：只做编译、稳定 Developer ID 签名和可回滚替换，不公证、不发布；包内代码必须通过共享签名闸，开发者团队和 designated requirement 必须与已装版一致，ad-hoc 和 Apple Development 不能替换正式运行版。产物默认在 `build/local-install/`，原发行目录不动。证书在配对 Mac 时加 `DOCKIT_SIGN_HOST=macbook`，经原登录会话签名入口只签冻结包；不转移私钥，也不在对端重建或安装。分发仍走前述公证入口。

编译默认使用本机核数，可用 `DOCKIT_BUILD_JOBS` 调整。包验证默认按核数并行执行独立用例，每个用例使用自己的输出目录；依赖 LibreOffice 的老格式转换串行执行，可用 `verify-package.py --jobs N` 调整并行数。界面状态、偏好和生命周期测试并行运行。验证独立构建时传 `verify-package.py --app /绝对路径/DocKit.app`，状态与固定验收脚本传 `DOCKIT_APP=/绝对路径/DocKit.app`。

打包时 `scripts/slim-runtime.py` 去掉运行时用不到的部分（magika/onnxruntime、各包测试目录、Tk 等；仍被导入的模块会让构建失败），并为各项操作用到的模块预编译 unchecked-hash 的 `.pyc`。Python 不会拿这些 `.pyc` 与 `.py` 比对，所以直接修改构建好的 `DocKit.app` 里的 `.py` 不会触发重新编译，仍运行旧字节码；改后端请改源码后重新构建。

`verify-package.py` 将整个应用复制到改名目录，在空 HOME、仅系统 PATH 和禁止网络的环境里执行真实文档任务，检查输出、原件哈希和应用签名。测试使用脚本生成的虚构文档，不读取个人文件；装有 LibreOffice 时的老 .ppt 用例只额外放行 /tmp 下的本地 socket，IP 网络仍禁止。每项操作默认 90 秒超时，较慢的机器可设 `DOCKIT_VERIFY_TIMEOUT=秒数` 调高。`check-ui-state.sh` 通过生产 BackendClient 和 ViewModel 检查选项解码、运行中输入隔离和防重入。

## 网站和发布

`VERSION` 是版本源，`scripts/package.py` 从实际安装包生成哈希与发行清单。`scripts/build-site.py` 生成 `build/site/` 与显式公开白名单 `site-manifest.json`；下载按钮从发行清单生成对应版本的 GitHub Release 页，校验链接指向该 Release 的 `release-manifest.json`。网站不复制或提供安装包备用，教程示例文件与视频照常保留；`--preview` 仅供本地预览，正式构建必须有匹配版本的真实媒体。重建后运行 `python3 tests/test_site_downloads.py` 核对下载入口及站点白名单。

`python3 scripts/publish.py` 构建并验证新发行与网站，验证通过后公证并装订；没有 Developer ID 证书或公证未通过就停下。录制验收后，`python3 scripts/publish.py --upload` 直接消费已准备的 dist 安装包，检查哈希、包内签名、真实版本/build 与媒体对应关系，并要求包是已公证装订的 Developer ID 包（ad-hoc 包不上传），不再重新编译。上传要求工作树干净且提交已推送；Release 指向安装包清单中的二进制源提交，已有同名 Release 会拒绝覆盖。网站包交给现有部署入口消费，发布脚本不更改服务器配置。真实录制要求见 `docs/demo/plan.md`，原片留在 gitignored build/tutorial/raw/。

## 许可

原创代码采用 [MIT](LICENSE)。运行时及依赖许可证随安装包保留，说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。公开产品独立发版，只按需同步上游通用修复；客户资源和私有业务能力不进入公开包。

## English

DocKit is a native macOS document toolbox for Chinese typography, conversion, splitting and merging. It works on copies and preserves your original files. The release bundles its Python runtime and document dependencies, so supported local operations need no account, uv or Python installation. Requires Apple Silicon and macOS 15+. The downloadable 1.1.3 (37) is ad-hoc signed and not notarized; later releases are Developer ID signed and notarized. See the product website for installation, real demonstrations and supported formats.
