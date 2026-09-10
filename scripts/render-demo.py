#!/usr/bin/env python3
"""Edit reviewed real DocKit recordings with external caption bands; never launch an app.

Requires ffmpeg/ffprobe and Pillow. Source clips remain in build/tutorial/raw.
The observed source is DocKit 1.1.0 build 16, recorded on 2026-09-10.
"""
from pathlib import Path
import hashlib
import json
import subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
RAW, WORK, OUT = ROOT / "build/tutorial/raw", ROOT / "build/tutorial/edit", ROOT / "docs/demo"
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
FULL = (23, 16, 1060, 844)
WIDTH, VIEW, TOP, BOTTOM = 1280, 792, 64, 168
# filename, start/end in the untouched recording, source crop, title, supporting caption.
SCENES = {
    "quotes": {"title": "01 / 引号统一", "poster": 12.0, "segments": [
        ("quotes", 0.4, 2.4, FULL, "只统一引号，范围由你选", "选中虚构 Word 示例 · 不修改标点和单位"),
        ("quotes", 6.5, 10.0, (298, 78, 770, 322), "取消勾选「页眉页脚」", "这次保留页眉，仅按勾选范围处理"),
        ("quotes", 14.0, 19.0, FULL, "点击「执行」，生成结果副本", "保留操作原速 · 已剪去操作间的等待"),
        ("quotes", 19.0, 21.7, (298, 610, 770, 230), "成功 1/1，原件仍然保留", "已核对：正文引号更新，未选中的页眉保持原样"),
    ]},
    "convert": {"title": "02 / 格式转换", "poster": 9.0, "segments": [
        ("convert", 0.3, 3.5, (298, 78, 770, 150), "选择 Markdown 作为目标格式", "在同一个窗口中切换 Word、Markdown 等格式"),
        ("convert", 4.5, 8.0, FULL, "点击「执行」，在本机完成转换", "保留操作原速 · 转换等待已剪去"),
        ("convert-result", 0.3, 3.6, (298, 446, 770, 194), "Word 已转换为 Markdown", "同一任务结果补拍 · 已核对人数、面积与表格内容保留"),
        ("convert-result", 3.6, 5.8, FULL, "成功 1/1，转换结果单独保存", "同一任务结果补拍 · 原 Word 文件保持不变"),
    ]},
    "results": {"title": "03 / 部分成功", "poster": 10.0, "segments": [
        ("results", 0.5, 2.8, FULL, "批量处理，逐份看结果", "本次选择一个 Word 文件和一个不支持的 JPG"),
        ("results", 5.0, 10.0, FULL, "点击「执行」，等待处理结果", "真实处理同一组虚构文件 · 原速播放"),
        ("results", 10.0, 14.0, (298, 602, 770, 240), "成功 1/2，不支持的文件明确列出", "绿色：Word 副本已生成 · 红色：该操作不支持 JPG"),
        ("results", 14.0, 21.5, (298, 674, 750, 168), "展开「处理详情」", "可以查看处理记录 · 原始文件均保持不变"),
    ]},
}


def run(*args):
    subprocess.run(args, check=True)


def probe(path):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], text=True))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def timestamp(seconds):
    ms = round(seconds * 1000)
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}.{ms % 1000:03}"


def band(path, height, lines):
    image = Image.new("RGB", (WIDTH, height), "#f5f3ed")
    draw = ImageDraw.Draw(image)
    for text, xy, size, color in lines:
        font = ImageFont.truetype(FONT, size)
        assert draw.textbbox(xy, text, font=font)[2] < WIDTH - 22, "Caption overflow"
        draw.text(xy, text, font=font, fill=color)
    image.save(path)


def concatenate(parts, output, stem):
    listing = WORK / f"{stem}-concat.txt"
    listing.write_text("".join(f"file '{part.as_posix()}'\n" for part in parts))
    run("ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
        "-c", "copy", "-map_metadata", "-1", "-movflags", "+faststart", str(output))


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    screenshot_hash = sha(OUT / "screenshot.png")
    release = json.loads((ROOT / "dist/release-manifest.json").read_text())
    assert release["version"] == "1.1.0"
    assert release["sha256"] == "2afd9cd036b974550c99c89e1d53aa82a03ce3fccada4060a53a67c1ab28ef6d", "These recordings belong to the reviewed build 16 package"
    assert sha(ROOT / "dist" / release["filename"]) == release["sha256"]
    entries, chapters, all_cues, offset = {}, [], [], 0.0
    for name, scene in SCENES.items():
        pieces, cuts, cues, elapsed = [], [], [], 0.0
        sources = {}
        for index, (raw_name, start, end, rect, title, subtitle) in enumerate(scene["segments"]):
            raw = RAW / f"{raw_name}.mov"
            info = probe(raw)
            stream = next(s for s in info["streams"] if s["codec_type"] == "video")
            duration = float(info["format"]["duration"])
            assert (stream["width"], stream["height"]) == (1106, 890)
            assert not any(s["codec_type"] == "audio" for s in info["streams"])
            assert 0 <= start < end <= duration
            x, y, w, h = rect
            assert min(x, y) >= 0 and x + w <= 1106 and y + h <= 890
            sources[raw.name] = {"sha256": sha(raw), "duration": duration}
            prefix = WORK / f"{name}-{index}"
            header, footer, part = prefix.with_suffix(".top.png"), prefix.with_suffix(".bottom.png"), prefix.with_suffix(".mp4")
            mode = "真实窗口" if rect == FULL else "局部放大"
            band(header, TOP, [(f"DocKit  {scene['title']}", (30, 18), 25, "#174f45"),
                               (f"{mode} · 原速 · 已剪去等待", (876, 23), 18, "#62776c")])
            band(footer, BOTTOM, [(title, (32, 28), 34, "#174f45"), (subtitle, (32, 98), 23, "#62776c")])
            filters = (f"[0:v]crop={w}:{h}:{x}:{y},setpts=PTS-STARTPTS,"
                       f"scale={WIDTH}:{VIEW}:force_original_aspect_ratio=decrease:force_divisible_by=2,"
                       f"pad={WIDTH}:{VIEW}:(ow-iw)/2:(oh-ih)/2:white,setsar=1,fps=30[v];"
                       "[1:v][v][2:v]vstack=inputs=3[out]")
            run("ffmpeg", "-y", "-v", "error", "-ss", str(start), "-i", str(raw),
                "-loop", "1", "-framerate", "30", "-i", str(header), "-loop", "1", "-framerate", "30", "-i", str(footer),
                "-filter_complex", filters, "-map", "[out]", "-an", "-t", str(end - start),
                "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
                "-map_metadata", "-1", "-movflags", "+faststart", str(part))
            length = float(probe(part)["format"]["duration"])
            text = title + "\n" + subtitle
            cues.append(f"{timestamp(elapsed)} --> {timestamp(elapsed + length)}\n{text}")
            all_cues.append(f"{timestamp(offset + elapsed)} --> {timestamp(offset + elapsed + length)}\n{scene['title']}\n{text}")
            cuts.append({"source": raw.name, "source_start": start, "source_end": end,
                         "output_start": round(elapsed, 3), "output_end": round(elapsed + length, 3),
                         "crop_xywh": list(rect), "view": mode, "speed": 1, "title": title, "subtitle": subtitle})
            pieces.append(part)
            elapsed += length
        target = OUT / f"{name}.mp4"
        concatenate(pieces, target, name)
        run("ffmpeg", "-y", "-v", "error", "-ss", str(scene["poster"]), "-i", str(target),
            "-frames:v", "1", "-q:v", "2", str(OUT / f"{name}.jpg"))
        (OUT / f"{name}.vtt").write_text("WEBVTT\n\n" + "\n\n".join(cues) + "\n")
        entries[name] = {"sources": sources, "cuts": cuts, "duration": elapsed, "poster_time": scene["poster"]}
        chapters.append(target)
        offset += elapsed
    concatenate(chapters, OUT / "tutorial.mp4", "tutorial")
    (OUT / "tutorial.vtt").write_text("WEBVTT\n\n" + "\n\n".join(all_cues) + "\n")
    checks = {}
    for name in [*SCENES, "tutorial"]:
        path = OUT / f"{name}.mp4"
        check = subprocess.run(["ffmpeg", "-hide_banner", "-v", "info", "-i", str(path),
                                "-vf", f"crop={WIDTH}:{VIEW}:0:{TOP},blackdetect=d=0.2:pic_th=0.30:pix_th=0.10",
                                "-an", "-f", "null", "-"], capture_output=True, text=True)
        assert check.returncode == 0 and "black_start:" not in check.stderr, "Decode or black-area check failed"
        (WORK / f"{name}-decode.log").write_text(check.stderr)
        info = probe(path)
        video = next(s for s in info["streams"] if s["codec_type"] == "video")
        assert video["codec_name"] == "h264" and video["pix_fmt"] == "yuv420p" and (video["width"], video["height"]) == (1280, 1024)
        checks[name] = {"duration": float(info["format"]["duration"]), "sha256": sha(path), "bytes": path.stat().st_size,
                        "decode": "passed", "black_area_check": "no 30%-black product-area runs lasting 0.2s"}
    evidence = json.loads((ROOT / "build/tutorial/content-verification.json").read_text())
    assert all(evidence[name]["inputs_unchanged"] for name in SCENES)
    metadata = {
        "product": "DocKit", "version": "1.1.0", "build": "16", "recorded_at": "2026-09-10",
        "source": "real-app-window", "release_sha256": release["sha256"],
        "environment": {"macos": "27.0", "architecture": "arm64", "window_pixels": [1106, 890]},
        "isolation": {"synthetic_inputs": True, "separate_bundle_and_preferences": True,
                      "non_key_background_panel": True, "separate_outputs": True, "finder_not_opened": True},
        "editing": {"caption_bands_outside_product_image": True, "labelled_local_crops": True,
                    "retained_speed": 1, "removed_waits_labelled": True, "audio": "原片无音轨，成片静音",
                    "conversion_result": "同一任务完成状态另行补拍，已在画面标注；没有声称原片连续覆盖完成。"},
        "independent_verification": {
            "all_synthetic_inputs": "三场景各7个输入均与准备时SHA-256一致",
            "quotes": "正文和表格直引号转为中文弯引号；页眉XML不变，面积与URL保留",
            "convert": "Markdown保留24人、120平方米及表格各行内容",
            "results": "成功1/2；Word副本存在，正文6个和页眉2个引号更新；JPG原件未变"},
        "scenes": entries, "checks": checks,
        "screenshot_sha256": screenshot_hash,
        "not_covered": ["新用户安装与系统权限授权", "打开Finder", "完整处理日志的逐行展示", "LibreOffice依赖格式"],
        "privacy_review": "源片仅包含DocKit窗口与虚构文件；未见其他应用、真实用户目录名或业务材料。",
        "final_visual_review": "pending-editor-review",
    }
    (OUT / "media-manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    assert sha(OUT / "screenshot.png") == screenshot_hash, "Keep the captured screenshot untouched"
    print(json.dumps(checks, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
