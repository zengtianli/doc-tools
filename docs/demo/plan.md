# DocKit v1.1.0 真实演示

仅用 scripts/make-demo.py 创建的虚构文件。实际业务由发布包的同一 BackendClient 和文档引擎运行，不预制成功界面。原片保存在 build/tutorial/raw/，不进公开仓与站点包。

主线程采集约定：docs/demo/screenshot.png；quotes.mp4/quotes.jpg；convert.mp4/convert.jpg；results.mp4/results.jpg。可补同名 VTT。media-manifest.json 记录 version=1.1.0、实际环境、各片段操作/切点/速度处理/未覆盖项；不要在公开清单放本机绝对路径、原片或真实文档。

## 准备

用 build/DocKit.app/Contents/Resources/python/bin/python3.12 -B scripts/make-demo.py 在独立目录生成输入。

可选环境只预置真实输入状态，不执行任务：DOCKIT_DEMO_FILES 为换行分隔的真实文件绝对路径；DOCKIT_DEMO_OP 为 quotes 或 convert；DOCKIT_INPUT_DIR 是文件选择器起始目录。DOCKIT_OUTPUT_DIR 可指定隔离输出根目录；默认实际产品输出是输入旁的「DocKit 输出」。应用没有主动 activate 启动路径，禁止脚本替代 Computer Use 驱动 GUI。

## 片段

1. quotes：起点是「引号统一」与活动说明.docx 已选中；先录再操作，关闭「页眉页脚」，点执行，等待结果绿色勾号。字幕：「只统一引号」「按需选择处理范围」「完成后，原件和结果副本都保留」。独立核验：正文包含中文弯引号，120 平方米与示例 URL 不变，页眉保留直引号，原件 SHA-256 不变。
2. convert：起点是「格式转换」与活动说明.docx；选择 Markdown，点执行，显示成功与 .md 输出。字幕：「选择目标格式」「在本机完成转换」「转换结果单独保存」。独立核验：Markdown 有标题、24 人、120 平方米与表格内容。不要用外部编辑器抢焦点来补画界面。
3. results：起点是「引号统一」，选择活动说明.docx 与不支持的图片.jpg；执行，显示成功 1/2，Word 结果绿色、图片不支持红色。字幕：「批量处理，逐份看结果」「不支持的格式会明确列出」「只重试失败项，原件保持不变」。独立核验：成功结果存在，失败输入没有被修改。

截图使用实际发布候选，确保版本、已批准图标和名称都是 DocKit。列表只显示虚构文件名；用户目录以 ~ 缩写。操作中的等待按真实速度保留，剪掉长等待则在字幕或媒体清单注明。正式 build-site.py 缺真实媒体或录制版本不符会拒绝构建。

## 本次完成的录制与剪辑

2026-09-10 实录 DocKit 1.1.0 / build 16。三个独立副本均使用同一发行候选的真实界面与文档引擎；录制通过非激活面板和独立应用标识隔离。主线程提供截图和原片，未打开 Finder，也未使用真实业务文件。

quotes 完整记录取消「页眉页脚」与成功 1/1；独立检查正文和表格引号更新、页眉 XML 不变。convert 原片录到操作与等待，完成状态来自同一任务的后续补拍，已在画面与清单标明。results 展示成功 1/2，Word 输出存在、JPG 明确不支持；处理详情展开后仅部分日志在窗口内可见，不把完整日志列作画面覆盖。三场景各 7 个输入文件均与准备时的 SHA-256 一致。

`scripts/render-demo.py` 用 ffmpeg 和 Pillow 生成画面外字幕带、标明局部放大，保留操作原速；生成三段 MP4、JPG 封面、VTT 以及 44.2 秒章节合集。原片和逐帧核验图仍在 gitignored 的 build/tutorial/，不进入站点。`media-manifest.json` 是实际切点、补拍、版本、发行包哈希及核验范围的清单。`scripts/build-site.py` 检查截图、成片与发行包哈希，再按白名单输出 `build/site/`。
