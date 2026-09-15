# DocKit

[中文](README.md) | **English**

Local document tools for Mac: standardize Chinese quotation marks, clean up punctuation and units, convert formats, and split or merge files. Originals are preserved, and results are listed for each file.

**[Product website and installation guide](https://app-mac-doctools.tianli.cyou/)** · [Download the latest release](https://github.com/zengtianli/doc-tools/releases/latest) · [Report an issue](https://github.com/zengtianli/doc-tools/issues)

## Installation

Requires **macOS 15 or later and an Apple Silicon Mac**. Download `DocKit-v1.1.0-arm64.zip`, extract it, and drag `DocKit.app` into Applications. The public bundle ID remains `io.github.zengtianli.DocTools`; the source repository is still named doc-tools.

The release includes Python and document dependencies. Common operations require no uv, Python, or Office installation and no account; file contents are processed locally. The app has no background document process and starts the engine only while running a task.

The current version is ad-hoc signed and has not been notarized by Apple. If macOS blocks the first launch, attempt to open it, then choose “Open Anyway” in System Settings → Privacy & Security. If you have verified the source but macOS still says the app is damaged, run this in Terminal:

```sh
xattr -cr "/Applications/DocKit.app"
```

No sudo is required. This package is not currently available for Intel Macs. For complex legacy DOC/PPT content, convert it to DOCX/PPTX with LibreOffice first. Common DOCX, XLSX, CSV, and Markdown workflows are built in.

## Usage

1. Select an operation on the left, or search with **⌘K**.
2. Drag in files or click “Choose files,” then select the target format and rules as needed.
3. Click “Run” or press **⌘↩**. Inputs cannot be changed and tasks cannot be started again while execution is in progress.
4. Review each file’s result. “Show in Finder” locates the output. A result of 1/2 successful means one file succeeded and one still needs attention.

Each task first copies its inputs and writes to `DocKit 输出/<本次任务>` beside the first input file. Originals are never overwritten, including for font standardization and header/footer removal. Copies of the inputs provide a basis for recovery and comparison.

| Operation | Supported scope |
|---|---|
| Normalization | Text cleanup in DOCX, Markdown, and PPTX; selectable rules and Word scopes |
| Quotation mark standardization | DOCX and Markdown; quotation marks only, with selectable Word body text, tables, revisions, comments, footnotes, and headers/footers |
| Font standardization | PPTX, including masters and layouts |
| English lowercase cleanup | XLSX/XLSM data rows and DOCX body text |
| Header/footer removal | DOCX copies |
| Format conversion | Supported combinations such as Word ↔ Markdown, PPTX → Markdown, CSV → XLSX, and XLSX → CSV/TXT |
| Splitting | Markdown by heading; XLSX/XLSM by worksheet |
| Merging | Multiple Markdown files into one document; multiple TXT files into CSV |
| Preview | Generate local HTML from Markdown and open it in the browser |

The public edition does not include PDF → Word, client templates, final bid-document checks, or private scanning dictionaries. Format conversion cannot guarantee an identical layout; open and inspect the output before formal delivery.

## Building from source

Building requires Xcode, Python 3, and uv. The first build needs network access to download locked dependencies. These development tools are not needed to run the release package.

```sh
git clone https://github.com/zengtianli/doc-tools.git
cd doc-tools
bash build.sh
python3 scripts/verify-package.py
bash scripts/check-ui-state.sh
```

Outputs: `build/DocKit.app`, `dist/DocKit-v1.1.0-arm64.zip`, and `dist/release-manifest.json`. Building does not automatically replace the locally installed version. The document engine and dependencies for supported formats are in `Contents/Resources`, with no runtime dependency on the author’s workspace.

`verify-package.py` copies the entire app into a renamed directory and runs real document tasks with an empty HOME, a system-only PATH, and network access disabled. It checks outputs, original-file hashes, and the app signature. Tests use generated fictional documents and do not read personal files. `check-ui-state.sh` uses the production BackendClient and ViewModel to check option decoding, input isolation during execution, and prevention of reentrant execution.

## Website and releases

`VERSION` is the version source. `scripts/package.py` generates hashes and the release manifest from the actual installation package. `scripts/build-site.py` generates `build/site/` and an explicit public allowlist, `site-manifest.json`. `--preview` is for local preview only; a production build requires real media matching the version.

`python3 scripts/publish.py` builds and verifies a new release and website. After recording and verification, `python3 scripts/publish.py --upload` consumes the prepared dist package directly, checking its hash, embedded signature, actual version/build, and correspondence with the media without recompiling. Uploading requires a clean working tree and pushed commits. The Release points to the binary source commit recorded in the package manifest; an existing Release with the same name will not be overwritten. The website package is consumed by the existing deployment entry point; the publishing script does not change server configuration. Requirements for real recordings are in `docs/demo/plan.md`; original footage stays in the gitignored build/tutorial/raw/.

## License

Original code is licensed under [MIT](LICENSE). Runtime and dependency licenses are retained in the installation package; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The public product has independent releases and takes general upstream fixes only as needed. Client resources and private business features do not enter the public package.

## English

DocKit is a native macOS document toolbox for Chinese typography, conversion, splitting and merging. It works on copies and preserves your original files. The release bundles its Python runtime and document dependencies, so supported local operations need no account, uv or Python installation. Requires Apple Silicon and macOS 15+. The current build is ad-hoc signed and not notarized. See the product website for installation, real demonstrations and supported formats.
