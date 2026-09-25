#!/usr/bin/env python3
"""Trim the bundled CPython runtime inside an app copy to what DocKit actually runs.

    slim-runtime.py <App>/Contents/Resources     (called by package.py before signing)

Every removal below is a named rule with its reason, and the build stops instead of shipping a
broken app (fail-closed) when
  * a removal pattern no longer matches anything (e.g. the runtime's Tcl/Tk version changed), or
  * any shipped .py file (runtime, packages or backend) still imports a removed module: every
    import statement and literal importlib.import_module()/__import__() call is read with the
    bundled interpreter's own parser; only `if TYPE_CHECKING:` blocks are skipped. The few imports
    that are known to be safe are listed in ALLOWED_IMPORTS with the reason.
Evidence for the lists: an import trace of every GUI operation on the v1.1.0 package (DocKit's
backend only reaches the modules it imports) plus that static scan of the shipped Python files.

  1. dists     markitdown's content sniffer (magika → onnxruntime and their own dependencies).
               backend/docx_to_md.py registers a small content sniffer as `magika` before
               markitdown loads, so .docx files whose content is HTML, text, pptx … still convert.
  2. tests     package test suites (pandas/tests, numpy/**/tests) and pytest conftest files.
  3. devfiles  type stubs, Cython sources and C headers (*.pyi *.pxd *.pyx *.pxi *.h, include dirs);
               they are only read when compiling extensions or type-checking, never at run time.
  4. stdlib    Tk GUI (tkinter, _tkinter, Tcl/Tk libraries), IDLE, turtle, ensurepip and its bundled
               pip wheel, lib2to3, pydoc topic data, C headers, pkg-config files and man pages.
  5. lxml      lxml.objectify: no shipped module imports it (python-docx/pptx use lxml.etree).
  6. strip     local symbols of every Mach-O file (strip -x); exported symbols such as PyInit_*
               stay, so loading is unchanged. package.py re-signs every Mach-O afterwards.
  7. bytecode  precompile .pyc for the modules listed in runtime-modules.txt, i.e. what the
               operations import. The app runs Python with -B, so without shipped .pyc every
               operation recompiled pandas, python-docx … from source each time. They are
               unchecked-hash .pyc: Python never compares them with the .py again, so a .py edited
               inside a built app keeps running the old bytecode until the app is rebuilt.
"""
from __future__ import annotations

import ast
import json
import re
import shutil
import subprocess
import sys
import warnings
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODULE_LIST = HERE / "runtime-modules.txt"
PY = "lib/python3.12"  # bundle-runtime.py pins CPython 3.12

# 1. Distributions not shipped. Value = why nothing DocKit runs needs it.
DROP_DISTS = {
    "magika": "markitdown content-type sniffer; backend/docx_to_md.py registers a small sniffer in its place",
    "onnxruntime": "model runtime used only by magika",
    "flatbuffers": "required only by onnxruntime",
    "protobuf": "required only by onnxruntime",
    "packaging": "required only by onnxruntime",
    "click": "magika's command line",
    "python-dotenv": "magika's command line configuration",
}
# kept distribution -> dropped requirement, and the backend file that registers a replacement module
ALLOWED_DANGLING = {("markitdown", "magika"): ("backend/docx_to_md.py", 'sys.modules["magika"]')}

# 4. Standard-library and runtime pieces not shipped: glob patterns relative to the runtime root.
#    Versioned names are matched by wildcard, and every pattern must match at least one path, so a
#    runtime upgrade that renames them stops the build instead of silently shipping them again.
STDLIB_DROP = [
    f"{PY}/tkinter", f"{PY}/idlelib", f"{PY}/turtledemo", f"{PY}/turtle.py", f"{PY}/ensurepip",
    f"{PY}/lib2to3", f"{PY}/pydoc_data", f"{PY}/lib-dynload/_tkinter.*.so",
    "lib/tcl[0-9]*", "lib/tk[0-9]*", "lib/itcl[0-9]*", "lib/thread[0-9]*",   # Tcl/Tk script libraries
    "lib/libtcl[0-9]*.dylib", "lib/libtcl[0-9]*tk[0-9]*.dylib",              # Tcl and Tk shared libraries
    "lib/pkgconfig", "include", "share",
]

# 5. Unimported extension modules inside kept packages (site-packages glob -> module).
PKG_DROP = {"lxml/objectify.*.so": "lxml.objectify"}

# Import guard exceptions: (shipped file, removed module it imports) -> why that is safe.
ALLOWED_IMPORTS = {
    ("markitdown/_markitdown.py", "magika"): "backend/docx_to_md.py registers its sniffer as magika first",
    ("PIL/ImageTk.py", "tkinter"): "Tk display helper, only used by Tk GUI programs",
    ("PIL/_tkinter_finder.py", "tkinter"): "loaded only by PIL.ImageTk",
    ("pydoc.py", "pydoc_data"): "optional import inside try/except (help topics)",
}

DEV_SUFFIXES = {".pyi", ".pxd", ".pyx", ".pxi", ".h"}
DEV_DIRS = ["numpy/_core/include", "lxml/includes"]  # C headers / Cython cimport declarations
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"}


def size(path: Path) -> int:
    if path.is_symlink() or path.is_file():
        return path.lstat().st_size
    return sum(p.lstat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


class Removal:
    """Deletes paths, tallies bytes per rule and remembers which importable modules went away."""

    def __init__(self, lib: Path):
        self.lib, self.site, self.dynload = lib, lib / "site-packages", lib / "lib-dynload"
        self.tally: dict[str, int] = {}
        self.modules: dict[str, str] = {}  # dotted module name -> rule that removed it

    def module_name(self, path: Path) -> str | None:
        for root in (self.site, self.dynload, self.lib):
            if path.is_relative_to(root):
                parts = list(path.relative_to(root).parts)
                break
        else:
            return None
        if not parts:
            return None
        last = parts[-1]
        if last.endswith(".py"):
            parts[-1] = last[:-3]
        elif last.endswith(".so"):
            parts[-1] = last.split(".")[0]
        elif "." in last:
            return None  # data files, stubs, headers: not importable
        if parts[-1] == "__init__":
            parts.pop()
        return ".".join(parts) if parts and all(p.isidentifier() for p in parts) else None

    def forget(self, path: Path, rule: str) -> None:
        name = self.module_name(path)
        if name:
            self.modules.setdefault(name, rule)

    def remove(self, path: Path, rule: str) -> None:
        if not (path.exists() or path.is_symlink()):
            return
        self.tally[rule] = self.tally.get(rule, 0) + size(path)
        self.forget(path, rule)
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def expand(root: Path, patterns) -> list[Path]:
    """Every pattern must match: a pattern that matches nothing means the runtime changed."""
    found, stale = [], []
    for pattern in patterns:
        hits = sorted(root.glob(pattern))
        if hits:
            found += hits
        else:
            stale.append(pattern)
    if stale:
        raise SystemExit(f"slim: patterns match nothing in {root} (runtime changed? update the rule): {stale}")
    return list(dict.fromkeys(found))


def prune_empty(root: Path) -> None:
    for d in sorted((p for p in root.rglob("*") if p.is_dir() and not p.is_symlink()), key=lambda p: -len(p.parts)):
        if not any(d.iterdir()):
            d.rmdir()


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def dist_infos(site: Path) -> dict[str, Path]:
    found = {}
    for info in site.glob("*.dist-info"):
        meta = (info / "METADATA").read_text(errors="replace")
        name = re.search(r"^Name:\s*(\S+)", meta, re.M).group(1)
        found[norm(name)] = info
    return found


def requirements(info: Path) -> set[str]:
    reqs = set()
    for line in (info / "METADATA").read_text(errors="replace").splitlines():
        if line.startswith("Requires-Dist:") and "extra ==" not in line:
            reqs.add(norm(re.match(r"Requires-Dist:\s*([A-Za-z0-9._-]+)", line).group(1)))
    return reqs


# ---- import scan: runs inside the bundled interpreter so the parser matches the shipped code ----

def _type_checking(test: ast.expr) -> bool:
    return (isinstance(test, ast.Name) and test.id == "TYPE_CHECKING") or (
        isinstance(test, ast.Attribute) and test.attr == "TYPE_CHECKING")


class _Imports(ast.NodeVisitor):
    def __init__(self, package: list[str]):
        self.package, self.found = package, []

    def visit_If(self, node: ast.If) -> None:
        if _type_checking(node.test):  # typing-only imports never run
            for child in node.orelse:
                self.visit(child)
            return
        self.generic_visit(node)

    def visit_Import(self, node: ast.Import) -> None:
        self.found += [(node.lineno, alias.name) for alias in node.names]

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if node.level:
            if node.level - 1 > len(self.package):
                return
            anchor = self.package[: len(self.package) - (node.level - 1)]
            base = ".".join(anchor + ([node.module] if node.module else []))
        else:
            base = node.module or ""
        if base:
            self.found.append((node.lineno, base))
        # `from pkg import name` may load the submodule pkg.name
        self.found += [(node.lineno, f"{base}.{a.name}" if base else a.name) for a in node.names if a.name != "*"]

    def visit_Call(self, node: ast.Call) -> None:
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        arg = node.args[0] if node.args else None
        if name in ("import_module", "__import__") and isinstance(arg, ast.Constant) \
                and isinstance(arg.value, str) and not arg.value.startswith("."):
            self.found.append((node.lineno, arg.value))
        self.generic_visit(node)


def scan_imports_here(entries: list) -> list:
    """[(label, path, package parts)] -> [(label, line, absolute dotted module)]."""
    out = []
    warnings.simplefilter("ignore")  # invalid escape sequences in third-party code are not our concern
    for label, path, package in entries:
        visitor = _Imports(package)
        visitor.visit(ast.parse(Path(path).read_bytes(), path))
        out += [(label, line, target) for line, target in visitor.found]
    return out


def scan_imports(python: Path, entries: list) -> list:
    result = subprocess.run([str(python), "-I", "-B", str(Path(__file__).resolve()), "--scan-imports"], input=json.dumps(entries),
                            text=True, capture_output=True)
    if result.returncode:
        raise SystemExit("slim: import scan failed (a shipped file does not parse?)\n" + result.stderr[-2000:])
    return json.loads(result.stdout)


def import_guard(resources: Path, lib: Path, removal: Removal) -> tuple[int, list[str]]:
    """Fail if any shipped .py imports a module this script removed.
    Returns (files parsed, the allowed imports that were found)."""
    site = lib / "site-packages"
    entries = []  # (label, path, package parts used to resolve relative imports)
    for path in sorted(lib.rglob("*.py")):
        rel = path.relative_to(site if path.is_relative_to(site) else lib)
        entries.append((str(rel), str(path), list(rel.parts[:-1])))
    for path in sorted((resources / "backend").rglob("*.py")):
        rel = path.relative_to(resources / "backend")  # the backend directory is its own import root
        entries.append(("backend/" + str(rel), str(path), list(rel.parts[:-1])))
    # An import that reaches a removed module names its last component literally; parse only files
    # containing one of those words (the scan is exhaustive over the rest).
    words = {name.rsplit(".", 1)[-1] for name in removal.modules}
    entries = [e for e in entries if any(w in Path(e[1]).read_text(errors="replace") for w in words)]
    problems, allowed = [], set()
    for label, line, target in scan_imports(lib.parents[1] / "bin/python3.12", entries):
        parts = target.split(".")
        hit = next((".".join(parts[:i]) for i in range(1, len(parts) + 1)
                    if ".".join(parts[:i]) in removal.modules), None)
        if hit and (label, hit) in ALLOWED_IMPORTS:
            allowed.add(f"{label} -> {hit}")
        elif hit:
            problems.append(f"{label}:{line} imports {target} (removed by rule '{removal.modules[hit]}')")
    if problems:
        raise SystemExit("slim: shipped code still imports removed modules:\n  " + "\n  ".join(sorted(set(problems))))
    return len(entries), sorted(allowed)


def main() -> int:
    resources = Path(sys.argv[1]).resolve()
    runtime = resources / "python"
    lib = runtime / PY
    site = lib / "site-packages"
    removal = Removal(lib)
    before = size(runtime)
    # Resolve every pattern first: a stale rule stops the build before anything is deleted.
    dev_dirs, stdlib_paths, pkg_paths = expand(site, DEV_DIRS), expand(runtime, STDLIB_DROP), expand(site, PKG_DROP)

    # 1. distributions
    infos = dist_infos(site)
    missing = sorted(set(DROP_DISTS) - set(infos))
    if missing:
        raise SystemExit(f"slim: expected distributions not installed: {missing}; update DROP_DISTS")
    for kept, info in infos.items():
        if kept in DROP_DISTS:
            continue
        for req in requirements(info) & set(DROP_DISTS):
            helper, marker = ALLOWED_DANGLING.get((kept, req), (None, None))
            if not helper or marker not in ((resources / helper).read_text() if (resources / helper).is_file() else ""):
                raise SystemExit(f"slim: {kept} requires {req}, which is not shipped")
    removed_files = []
    for name in DROP_DISTS:
        info = infos[name]
        for row in (info / "RECORD").read_text().splitlines():
            rel = row.split(",")[0]
            if rel and not rel.startswith(".."):
                removed_files.append(site / rel)
                removal.remove(site / rel, "dists")
        removal.remove(info, "dists")
    prune_empty(site)
    for path in removed_files:  # packages (incl. namespace ones such as google/) that are now gone
        for parent in path.parents:
            if parent == site:
                break
            if not parent.exists():
                removal.forget(parent, "dists")
    for leftover in ("magika", "onnxruntime", "google", "flatbuffers", "packaging", "click", "dotenv"):
        if (site / leftover).exists():
            raise SystemExit(f"slim: {leftover} still present after RECORD removal")

    # 2. tests  3. dev files (license texts inside *.dist-info are kept as they are)
    for path in dev_dirs:
        removal.remove(path, "devfiles")
    for path in sorted(site.rglob("*"), key=lambda p: len(p.parts)):
        if any(part.endswith(".dist-info") for part in path.relative_to(site).parts):
            continue
        if not (path.exists() or path.is_symlink()):
            continue
        if path.is_dir() and path.name == "tests":
            removal.remove(path, "tests")
        elif path.is_file() and path.name == "conftest.py":
            removal.remove(path, "tests")
        elif path.is_file() and path.suffix in DEV_SUFFIXES:
            removal.remove(path, "devfiles")

    # 4. standard library / runtime extras
    for path in stdlib_paths:
        removal.remove(path, "stdlib")

    # 5. unimported extension modules
    for path in pkg_paths:
        removal.remove(path, "lxml")

    # Guard for 1-5: nothing shipped may import what was removed.
    scanned, allowed = import_guard(resources, lib, removal)

    # 7. bytecode for the modules the operations import. Compiled by the bundled interpreter
    #    (its magic number), before strip so the interpreter is still validly signed. The
    #    recorded file name is relative; the import system replaces it with the real path.
    python = runtime / "bin/python3.12"
    wanted = []
    if MODULE_LIST.exists():
        for line in MODULE_LIST.read_text().splitlines():
            rel = line.strip()
            if rel and not rel.startswith("#") and (runtime / rel).is_file():
                wanted.append(rel)  # a listed file that no longer exists only loses its speed-up
    compile_code = (
        "import py_compile,sys\n"
        "mode=py_compile.PycInvalidationMode.UNCHECKED_HASH\n"
        "for rel in sys.stdin.read().split():\n"
        "    py_compile.compile(rel, dfile=rel, doraise=True, invalidation_mode=mode)\n")
    subprocess.run([str(python), "-I", "-B", "-c", compile_code], input="\n".join(wanted), text=True,
                   cwd=runtime, check=True)
    pycs = [p for p in runtime.rglob("__pycache__/*.pyc")]
    added = sum(p.stat().st_size for p in pycs)
    compiled = len(pycs)
    if compiled != len(wanted):  # stray timestamp .pyc would carry build-machine paths
        raise SystemExit(f"slim: expected {len(wanted)} .pyc files, found {compiled}")

    # 6. strip local symbols
    stripped = 0
    for path in runtime.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as handle:
            if handle.read(4) not in MACHO:
                continue
        old = path.stat().st_size
        subprocess.run(["strip", "-x", str(path)], check=True, capture_output=True)
        stripped += old - path.stat().st_size
    removal.tally["strip"] = stripped

    after = size(runtime)
    report = {"runtime_bytes_before": before, "runtime_bytes_after": after,
              "removed_bytes_by_rule": removal.tally,
              "removed_modules": len(removal.modules), "import_guard_files_parsed": scanned,
              "import_guard_allowed": allowed,
              "bytecode_files": compiled, "bytecode_bytes_added": added,
              "dropped_distributions": DROP_DISTS}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--scan-imports"]:  # internal: called by scan_imports() under the bundled python
        json.dump(scan_imports_here(json.load(sys.stdin)), sys.stdout)
        sys.exit(0)
    sys.exit(main())
