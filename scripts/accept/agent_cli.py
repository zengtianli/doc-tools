#!/usr/bin/env python3
"""Keep Chapter's feature/help checks and require a successful public status readback."""
import json
import os
from pathlib import Path
import subprocess
import sys

shared = Path.home() / "Apps/chapter/engine/acceptors/agent_cli.py"
detail = Path(os.environ["SOP_OUT_DIR"]) / "agent_cli.detail.json"
try:
    result = subprocess.run([sys.executable, str(shared)], timeout=90, check=False)
    if result.returncode:
        sys.exit(result.returncode)
    data = json.loads(detail.read_text(encoding="utf-8"))
    code = (data.get("readback_run") or {}).get("exit_code")
    if type(code) is not int or code != 0:
        data.update(passed=False, summary=f"公开版状态读回未成功（退出码 {code}）；不能把可解析的错误 JSON 当作可用入口")
        detail.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(data["summary"])
        sys.exit(1)
except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
    print(f"公开版 CLI 验收未完成：{exc}", file=sys.stderr)
    sys.exit(1)
