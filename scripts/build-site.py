#!/usr/bin/env python3
"""Build an explicit public website package; never copy raw recordings or private files."""
from pathlib import Path
import argparse
import hashlib
import html
import json
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlsplit, urlunsplit
sys.path.insert(0, str(Path.home() / "Apps/apps-portal/site"))
import perf_block  # shared lightweight block; numbers come from perf/lightweight.json
import product_facts  # facts.json published with the page for the portal and Chapter
import zipfile

ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument("--preview",action="store_true")
ap.add_argument("--out",type=Path,default=ROOT/"build/site",help="Site package root (default build/site)");a=ap.parse_args()
release=json.loads((ROOT/"dist/release-manifest.json").read_text())
download=urlsplit(release["download_url"])
parts=download.path.split("/")
if (download.scheme!="https" or download.netloc!="github.com" or download.query or download.fragment
    or len(parts)!=7 or not all(parts[1:3]) or parts[3:5]!=["releases","download"]
    or unquote(parts[5])!=release["tag"] or unquote(parts[6])!=release["filename"]
    or release["tag"]!="v"+release["version"]):
    raise SystemExit("Release download URL does not match its GitHub repository, tag and filename")
release_url=urlunsplit((download.scheme,download.netloc,"/".join(parts[:4]+["tag",parts[5]]),"",""))
checksum_url=urlunsplit((download.scheme,download.netloc,"/".join(parts[:-1]+["release-manifest.json"]),"",""))
archive=ROOT/"dist"/release["filename"]
assert hashlib.sha256(archive.read_bytes()).hexdigest()==release["sha256"],"Release archive hash mismatch"
if archive.stat().st_size!=release["bytes"]: raise SystemExit("Release archive size mismatch")
def ui_sources_sha256(source_commit=None):
    """Hash the UI of the published archive, rather than a newer working checkout."""
    h=hashlib.sha256()
    if source_commit:
        if release.get("source_dirty") is not False:
            raise SystemExit("Published media reuse requires a clean release source commit")
        paths=subprocess.check_output(["git","-C",str(ROOT),"ls-tree","-r","--name-only",source_commit,"--","Sources"],text=True).splitlines()
        if not paths: raise SystemExit("Release source commit has no UI sources")
        for name in sorted(paths):
            data=subprocess.check_output(["git","-C",str(ROOT),"show",source_commit+":"+name])
            h.update(name.encode()+b"\0"+data+b"\0")
        return h.hexdigest()
    for f in sorted(p for p in (ROOT/"Sources").rglob("*") if p.is_file()):
        h.update(str(f.relative_to(ROOT)).encode()+b"\0"+f.read_bytes()+b"\0")
    return h.hexdigest()
media=ROOT/"docs/demo"
clips=[("quotes","只统一引号","选中 Word，保留单位和页眉，只处理选定范围。"),
       ("convert","把 Word 变成 Markdown","选择目标格式，转换结果单独保存。"),
       ("results","看懂部分成功","一份成功、一份格式不支持，原件仍完整保留。")]
needed=["screenshot.png","tutorial.mp4"]+[name+suffix for name,_,_ in clips for suffix in (".mp4",".jpg")]
missing=[n for n in needed if not (media/n).is_file()]
if not a.preview:
    if missing: raise SystemExit("Missing real product media: "+", ".join(missing))
    evidence=json.loads((media/"media-manifest.json").read_text())
    if evidence.get("version")==release["version"]:
        if str(evidence.get("build"))!=str(release.get("build")): raise SystemExit("Recorded product build does not match release")
        if evidence.get("release_sha256")!=release["sha256"]: raise SystemExit("Recorded release archive does not match download")
    else:
        # A later release may reuse the recording only when its UI sources are byte-identical to the
        # recorded build and the manifest names that exact release (build and archive hash). A reuse
        # entry may instead pin its own ui_sources_sha256 with a ui_changes note when Sources/ changed
        # without changing what is drawn (e.g. a self-test entry point). Bind this to the exact
        # clean source commit of the archive; unrelated newer checkout edits are not that release.
        reuse=(evidence.get("reused_for") or {}).get(release["version"]) or {}
        pinned=reuse.get("ui_sources_sha256") if reuse.get("ui_changes") else None
        accepted={pinned or evidence.get("ui_sources_sha256")}
        if release.get("source_commit") and reuse.get("ui_changes"):
            accepted.update(item["ui_sources_sha256"] for item in reuse.get("ui_source_history", [])
                            if item.get("checked") and item.get("ui_sources_sha256"))
        if ui_sources_sha256(release.get("source_commit")) not in accepted: raise SystemExit("Recorded product version does not match release, and the released UI sources changed since the recording")
        if str(reuse.get("build"))!=str(release.get("build")) or reuse.get("release_sha256")!=release["sha256"]: raise SystemExit("Recorded product version does not match release, and the manifest does not name this release for reuse")
    if evidence.get("screenshot_sha256")!=hashlib.sha256((media/"screenshot.png").read_bytes()).hexdigest(): raise SystemExit("Screenshot does not match reviewed media")
    for name in [item[0] for item in clips]+["tutorial"]:
        if evidence["checks"][name]["sha256"]!=hashlib.sha256((media/(name+".mp4")).read_bytes()).hexdigest(): raise SystemExit("Video does not match media manifest: "+name)
        duration=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","default=noprint_wrappers=1:nokey=1",str(media/(name+".mp4"))],text=True))
        if duration<1: raise SystemExit("Invalid video: "+name)
out=a.out
if out.exists(): shutil.rmtree(out)
(out/"images").mkdir(parents=True);(out/"downloads").mkdir();(out/"media").mkdir()
shutil.copy2(ROOT/"icon/AppIcon.png",out/"images/icon.png")
shutil.copy2(ROOT/"site/style.css",out/"style.css")
# Installers and their release record stay on GitHub; downloads/ only holds tutorial samples.
fixtures=ROOT/"build/demo-inputs"
python=ROOT/"build/DocKit.app/Contents/Resources/python/bin/python3.12"
subprocess.run([str(python),"-B",str(ROOT/"scripts/make-demo.py"),str(fixtures)],check=True,capture_output=True)
allowed_samples=["活动说明.docx","读书会流程.md","补充说明.md","报名统计.csv","活动统计.xlsx"]
with zipfile.ZipFile(out/"downloads/DocKit-demo-files.zip","w",zipfile.ZIP_DEFLATED) as z:
    for name in allowed_samples: z.write(fixtures/name,"DocKit 示例/"+name)
if "screenshot.png" not in missing:
    shutil.copy2(media/"screenshot.png",out/"images/screenshot.png")
    shot='<img src="images/screenshot.png" alt="DocKit 真实窗口：可选修复规则、文件列表与逐份处理结果">'
else: shot='<div class="preview-missing">本地预览：等待采集当前版本的真实截图</div>'
videos=[]
for name,title,description in clips:
    if (media/(name+".mp4")).is_file() and (media/(name+".jpg")).is_file():
        for suffix in (".mp4",".jpg"): shutil.copy2(media/(name+suffix),out/"media"/(name+suffix))
        track=""
        if (media/(name+".vtt")).is_file():
            shutil.copy2(media/(name+".vtt"),out/"media"/(name+".vtt"))
            track=f'<track kind="captions" srclang="zh" label="中文" src="media/{name}.vtt">'
        player=f'<video controls playsinline preload="metadata" poster="media/{name}.jpg"><source src="media/{name}.mp4" type="video/mp4">{track}</video>'
        link=f'<a href="media/{name}.mp4" download>下载这段演示 ↓</a>'
    else: player='<div class="preview-missing">本地预览：等待真实录屏</div>';link=""
    videos.append(f'<article>{player}<div class="demo-copy"><h3>{title}</h3><p>{description}</p>{link}</div></article>')
tutorial=""
if (media/"tutorial.mp4").is_file():
    for name in ("tutorial.mp4","tutorial.vtt","media-manifest.json"):
        if (media/name).is_file(): shutil.copy2(media/name,out/"media"/name)
    tutorial='<div class="demo-actions"><a class="text-link" href="media/tutorial.mp4" download>下载三段完整演示 ↓</a></div>'
measured_version=json.loads((ROOT/"perf/lightweight.json").read_text())["version"].split(" ")[0]
historical=measured_version!=release["version"]
block=perf_block.standalone_section(ROOT/"perf/lightweight.json",measured_version,"#167e6d")
measured_build=json.loads((ROOT/"perf/lightweight.json").read_text())["version"]
released_build=f"{release['version']} ({release['build']})"
if measured_build!=released_build and not historical:
    block=block.replace("<div class='perf-grid'>",
                        "<p class='fine'>本地验收构建 "+html.escape(measured_build)+
                        " 的实测；公开下载仍为 "+html.escape(released_build)+
                        "，下列数据不代表已发布包。</p><div class='perf-grid'>",1)
if historical:
    block=block.replace("资源占用与响应速度。",f"历史实测 · v{measured_version}。").replace("数字来自所列设备实测，版本更新后重新测量。",f"以下为 v{measured_version} 的历史实测，不代表当前 v{release['version']}；本轮未重复采样。")
replacements={"VERSION":release["version"],"FILENAME":archive.name,"DOWNLOAD":html.escape(release_url,quote=True),
              "CHECKSUM":html.escape(checksum_url,quote=True),
              "SIZE":perf_block.size_mb(release["bytes"]),"LIGHT":block,"SCREENSHOT":shot,"VIDEOS":"".join(videos),"TUTORIAL":tutorial}
page=(ROOT/"site/index.html").read_text()
if "notarized by Apple; ticket stapled" in release.get("signing", ""):
    page=page.replace("第一次打开时，允许运行", "双击打开 DocKit")
    page=page.replace("此版本尚未经过 Apple 公证。如果 macOS 阻止打开，先尝试打开一次，再到「系统设置 → 隐私与安全性」找到 DocKit，点「仍要打开」。系统要求认证时，使用你自己的 Mac 登录密码或 Touch ID。",
                      "当前发行包使用 Developer ID 签名，已经 Apple 公证并装订票据。解压后直接打开；首次运行时 macOS 可能询问是否打开从互联网下载的应用。")
    page=page.replace("如果仍无法放行，可展开下方“提示应用已损坏或无法打开”查看处理办法。", "如提示文件损坏，请核对下方的来源与校验说明。")
    page=page.replace('请先确认下载来源为本页，重新下载完整 zip 并移入「应用程序」。如果你确认来源可信，可以打开「终端」，执行这一行后再打开 DocKit：</p><pre><code>xattr -cr "/Applications/DocKit.app"</code></pre><p>这条命令只移除 DocKit 的下载隔离标记，不需要 sudo 或管理员密码。不要对不明来源应用执行此操作。',
                      '请从本页指向的 GitHub Release 重新下载完整 ZIP，并与同一发行记录的 SHA-256 核对。当前包已经 Apple 公证；校验不符或系统仍拒绝时请保留错误信息并反馈，勿移除系统下载隔离标记。')
for key,value in replacements.items(): page=page.replace("{{"+key+"}}",value)
if "{{" in page: raise SystemExit("Unresolved website placeholders")
(out/"index.html").write_text(page)
# The public component has its own portal identity, separate from the private product family.
facts=product_facts.from_repo(ROOT,product_id="doc-tools-oss",icon="images/icon.png")
facts["measurement_version"]=measured_build
if measured_build!=released_build:
    facts["measurement_scope"]="historical measurement" if historical else "local acceptance build"
    facts["release_download_bytes"]=release["bytes"]
    facts["card_line"]=facts["card_line"].replace(">",
                        ">"+("历史构建 " if historical else "本地验收构建 ")+html.escape(measured_build)+" 实测 · ",1)
    facts["card_text"]=product_facts.card_text(facts["card_line"])
product_facts.write(out,facts)
files=[{"path":str(p.relative_to(out)),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(out.rglob("*")) if p.is_file()]
(out/"site-manifest.json").write_text(json.dumps({"product":"DocKit","version":release["version"],"preview":a.preview,"files":files},ensure_ascii=False,indent=2)+"\n")
print(out)
