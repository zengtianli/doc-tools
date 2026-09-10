# Third-party notices

DocKit's original application and document adapters are provided under the MIT license in LICENSE.

The binary distribution contains CPython 3.12.13 (standalone build 20260414) from Astral's uv-managed python-build-standalone distribution, plus dependencies locked in backend/requirements.lock. CPython's license is retained in Contents/Resources/python/lib/python3.12/LICENSE.txt. The upstream standalone release's license collection is additionally retained in Contents/Resources/licenses/python-build-standalone/; sources.json records each upstream URL and hash. The collection covers multiple standalone configurations, not a claim that every listed component is linked by this macOS build.

Python package licenses, copyright notices and metadata are retained under Contents/Resources/python/lib/python3.12/site-packages/*.dist-info/ and their licenses/ directories. These include python-docx, python-pptx, openpyxl, pandas, NumPy, xlrd, MarkItDown and its document-conversion dependencies. Dependency versions and hashes are recorded in the shipped backend/requirements.lock.

LibreOffice is an optional separately installed application and is not redistributed. The product website is an original MIT implementation; it does not contain code copied from WeChatUnrevoke's AGPL website.
