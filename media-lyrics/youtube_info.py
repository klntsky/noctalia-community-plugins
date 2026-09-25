#!/usr/bin/env python3
"""Extract compact chapter metadata for a YouTube video without downloading media."""

import json
import subprocess
import sys
from urllib.parse import urlparse


YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}


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
