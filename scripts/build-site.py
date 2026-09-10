#!/usr/bin/env python3
"""Build an explicit public website package; never copy raw recordings or private files."""
from pathlib import Path
import argparse
import hashlib
import html
import json
import shutil
import subprocess
import zipfile

ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument("--preview",action="store_true");a=ap.parse_args()
release=json.loads((ROOT/"dist/release-manifest.json").read_text())
archive=ROOT/"dist"/release["filename"]
assert hashlib.sha256(archive.read_bytes()).hexdigest()==release["sha256"],"Release archive hash mismatch"
media=ROOT/"docs/demo"
clips=[("quotes","只统一引号","选中 Word，保留单位和页眉，只处理选定范围。"),
       ("convert","把 Word 变成 Markdown","选择目标格式，完成后直接定位转换结果。"),
       ("results","看懂部分成功","一份成功、一份格式不支持，原件仍完整保留。")]
needed=["screenshot.png"]+[name+suffix for name,_,_ in clips for suffix in (".mp4",".jpg")]
missing=[n for n in needed if not (media/n).is_file()]
if not a.preview:
    if missing: raise SystemExit("Missing real product media: "+", ".join(missing))
    evidence=json.loads((media/"media-manifest.json").read_text())
    if evidence.get("version")!=release["version"]: raise SystemExit("Recorded product version does not match release")
    for name,_,_ in clips:
        duration=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","default=noprint_wrappers=1:nokey=1",str(media/(name+".mp4"))],text=True))
        if duration<1: raise SystemExit("Invalid video: "+name)
out=ROOT/"build/site"
if out.exists(): shutil.rmtree(out)
(out/"images").mkdir(parents=True);(out/"downloads").mkdir();(out/"media").mkdir()
shutil.copy2(ROOT/"icon/AppIcon.png",out/"images/icon.png")
shutil.copy2(ROOT/"site/style.css",out/"style.css")
shutil.copy2(archive,out/"downloads"/archive.name)
shutil.copy2(ROOT/"dist/release-manifest.json",out/"downloads/release-manifest.json")
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
replacements={"VERSION":release["version"],"FILENAME":archive.name,"DOWNLOAD":"downloads/"+archive.name,
              "SIZE":f'{release["bytes"]/1024/1024:.1f} MB',"SCREENSHOT":shot,"VIDEOS":"".join(videos)}
page=(ROOT/"site/index.html").read_text()
for key,value in replacements.items(): page=page.replace("{{"+key+"}}",value)
if "{{" in page: raise SystemExit("Unresolved website placeholders")
(out/"index.html").write_text(page)
files=[{"path":str(p.relative_to(out)),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(out.rglob("*")) if p.is_file()]
(out/"site-manifest.json").write_text(json.dumps({"product":"DocKit","version":release["version"],"preview":a.preview,"files":files},ensure_ascii=False,indent=2)+"\n")
print(out)
