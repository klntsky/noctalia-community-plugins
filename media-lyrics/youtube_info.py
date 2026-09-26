#!/usr/bin/env python3
"""Extract YouTube metadata and timed captions without downloading media."""

import html
import json
import locale
import re
import subprocess
import sys
from urllib.parse import urlparse
from urllib.request import Request, urlopen


YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}
MAX_CAPTION_BYTES = 1_000_000
MAX_CAPTION_LINES = 2000


def caption_track(info: dict):
    preferred = (locale.getlocale()[0] or "").split("_")[0].lower()
    for group_name in ("subtitles", "automatic_captions"):
        group = info.get(group_name) or {}
        if not isinstance(group, dict):
            continue
        languages = [lang for lang in group if lang != "live_chat"]
        if group_name == "automatic_captions":
            # YouTube exposes translations in many languages. Choose the
            # original transcript so the words keep their original language.
            originals = [lang for lang in languages if lang.endswith("-orig")]
            languages = originals or languages
        order = sorted(languages, key=lambda lang: (
            0 if lang == preferred or lang == preferred + "-orig" else
            1 if lang == "en" or lang == "en-orig" else 2, lang))
        for language in order:
            formats = group.get(language) or []
            choices = []
            for fmt in ("json3", "vtt"):
                track = next((item for item in formats
                              if item.get("ext") == fmt and item.get("url", "").startswith("https://")), None)
                if track:
                    choices.append((fmt, track["url"]))
            if choices:
                return language, choices, group_name == "automatic_captions"
    return None


def clean_caption(value: str) -> str:
    value = html.unescape(re.sub(r"<[^>]*>", "", value)).replace("\u200b", "")
    parts = []
    for line in value.splitlines():
        line = " ".join(line.split())
        if not line or re.fullmatch(r"[\[(].*?(music|applause|laughter|silence).*?[\])]", line, re.I):
            continue
        if line not in parts:
            parts.append(line)
    return " / ".join(parts)[:400]


def caption_lines(payload: bytes, fmt: str) -> list[dict]:
    rows = []
    if fmt == "json3":
        events = json.loads(payload).get("events") or []
        for event in events:
            if not isinstance(event.get("tStartMs"), (int, float)):
                continue
            text = clean_caption("".join(seg.get("utf8", "") for seg in event.get("segs") or []))
            if text:
                rows.append({"time": round(event["tStartMs"] / 1000, 3), "text": text})
    else:
        for block in re.split(r"\r?\n\s*\r?\n", payload.decode("utf-8-sig", "replace")):
            lines = block.splitlines()
            timestamp = next((i for i, line in enumerate(lines) if " --> " in line), None)
            if timestamp is None:
                continue
            start = lines[timestamp].split(" --> ", 1)[0]
            match = re.fullmatch(r"(?:(\d+):)?(\d+):(\d+)\.(\d+)", start)
            if not match:
                continue
            hours, minutes, seconds, fraction = match.groups()
            time = int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds) + int(fraction) / 10 ** len(fraction)
            text = clean_caption("\n".join(lines[timestamp + 1:]))
            if text:
                rows.append({"time": round(time, 3), "text": text})
    distinct = []
    for row in rows:
        if distinct and distinct[-1]["text"] == row["text"]:
            continue
        distinct.append(row)
        if len(distinct) >= MAX_CAPTION_LINES:
            break
    return distinct


def fetch_captions(info: dict) -> tuple[dict | None, bool]:
    if "Music" not in (info.get("categories") or []) and not info.get("track") and not info.get("artist"):
        return None, True
    selected = caption_track(info)
    if not selected:
        return None, True
    language, choices, automatic = selected
    fetched = False
    for fmt, url in choices:
        try:
            with urlopen(Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=12) as response:
                payload = response.read(MAX_CAPTION_BYTES + 1)
            if len(payload) > MAX_CAPTION_BYTES:
                continue
            fetched = True
            lines = caption_lines(payload, fmt)
            if lines:
                return {"language": language, "automatic": automatic, "lines": lines}, True
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    return None, fetched


def extract(binary: str, url: str) -> dict:
    if (urlparse(url).hostname or "").lower() not in YOUTUBE_HOSTS:
        raise ValueError("not a YouTube URL")
    result = subprocess.run(
        [binary, "--ignore-config", "--skip-download", "--no-playlist", "--no-warnings", "--dump-single-json", url],
        capture_output=True, text=True, timeout=25, check=True,
    )
    info = json.loads(result.stdout)
    chapters = []
    for chapter in (info.get("chapters") or [])[:200]:
        start, end = chapter.get("start_time"), chapter.get("end_time")
        if isinstance(start, (int, float)) and isinstance(end, (int, float)) and end > start:
            chapters.append({
                "title": str(chapter.get("title") or ""),
                "start": start,
                "end": end,
            })
    captions, subtitles_checked = fetch_captions(info)
    return {
        "title": str(info.get("title") or ""),
        "uploader": str(info.get("uploader") or ""),
        "channel": str(info.get("channel") or ""),
        "description": str(info.get("description") or ""),
        "artist": str(info.get("artist") or ""),
        "artists": info.get("artists") if isinstance(info.get("artists"), list) else [],
        "track": str(info.get("track") or ""),
        "album": str(info.get("album") or ""),
        "release_year": info.get("release_year"),
        "categories": info.get("categories") if isinstance(info.get("categories"), list) else [],
        "tags": info.get("tags") if isinstance(info.get("tags"), list) else [],
        "duration": info.get("duration") or 0,
        "chapters": chapters,
        "subtitles_checked": subtitles_checked,
        "captions": captions,
    }


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    try:
        print(json.dumps(extract(sys.argv[1], sys.argv[2]), ensure_ascii=False))
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"yt-dlp metadata extraction failed: {exc.__class__.__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
