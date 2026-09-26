#!/usr/bin/env python3
"""Live backend E2E tests: python3 test_e2e.py [--case single_track_album].

Runs the production service through the replay host with fresh source metadata,
real lyric databases and the configured AI provider's browsing tools. Reads credentials
from Noctalia settings; requests may incur provider charges. No recorded responses,
transport overrides or live player/cache changes. This does not test the native UI.
"""
import argparse
import json
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from replay_lyrics import Replay
from youtube_info import extract


CASES = {
    "song": {"video": "Oyct_cZvYiY", "title": "sisters", "lyrics": True, "tracks": 0},
    "youtube_captions": {"video": "MxekyGtqcNE", "title": "ipod touch",
                          "title_full": "Ninajirachi - iPod Touch (Official Video)",
                          "artist": "Ninajirachi", "duration": 228, "live_yt_dlp": True,
                          "lyrics": True, "synced": True,
                          "lyrics_provider": "YouTube captions", "tracks": 0},
    "chapter_captions": {"video": "-4J-f5lkCLo", "title": "rose",
                         "title_full": "Thee Sacred Souls: Tiny Desk Concert",
                         "artist": "NPR Music", "duration": 1233, "position": 1040,
                         "segment_duration": 233, "live_yt_dlp": True,
                         "lyrics": True, "synced": True,
                         "lyrics_provider": "YouTube captions", "tracks": 0},
    "not_song": {"video": "jNQXAC9IVRw", "status": "not_song", "tracks": 0},
    "album": {"video": "GPGemQOs8fY", "tracks": 7, "positions": [300, 520], "indices": [2, 3]},
    "single_track_album": {"video": "FEDu2PRCDpU", "tracks": 1},
    "x_promo": {"url": "https://x.com/XLRECORDINGS/status/2102082051532873765",
                "title": "ballad of st nick", "statuses": ("done", "unavailable"),
                "manual_ai": True, "tracks": 0},
}


def x_post_metadata(url):
    parsed = urlparse(url)
    if parsed.hostname != "x.com" or not parsed.path.startswith("/"):
        raise ValueError("Expected an X post URL")
    request = Request("https://api.fxtwitter.com" + parsed.path,
                      headers={"User-Agent": "media-lyrics-e2e"})
    with urlopen(request, timeout=20) as response:
        post = json.load(response)["tweet"]
    videos = (post.get("media") or {}).get("videos") or []
    return post["text"].splitlines()[0], post["author"]["name"], videos[0]["duration"] if videos else 0


def check(result, case):
    failures = []
    if result.get("error"):
        failures.append("Backend returned an error")
    if result["album_track_count"] != case["tracks"]:
        failures.append(f"Expected {case['tracks']} album tracks; got {result['album_track_count']}")
    if case.get("status") and result["ai_status"] != case["status"]:
        failures.append(f"Expected AI status {case['status']}; got {result['ai_status']}")
    if case.get("statuses") and result["ai_status"] not in case["statuses"]:
        failures.append(f"Expected AI status in {case['statuses']}; got {result['ai_status']}")
    if result["ai_status"] not in ("idle", "pending") and not (result.get("ai_lookup_seconds") or 0) > 0:
        failures.append("Completed AI lookup did not report elapsed time")
    if result["ai_status"] not in ("idle", "pending"):
        messages = [event.get("message", "") for event in result.get("events", [])]
        if not any("media-lyrics AI context" in message for message in messages):
            failures.append("AI lookup did not log its media context")
        if not any("media-lyrics AI [" in message and " finish " in message for message in messages):
            failures.append("AI lookup did not log its final outcome")
        if case.get("manual_ai") and not any("/web-lyrics] finish " in message for message in messages):
            failures.append("AI lookup did not reach the web lyrics fallback")
    if case.get("lyrics") and (result["lyrics_status"] != "ready" or result["lyric_lines"] == 0):
        failures.append("Expected available lyrics")
    if case.get("synced") and not result["synced"]:
        failures.append("Expected timed lyric lines")
    if case.get("lyrics_provider") and result.get("lyrics_provider") != case["lyrics_provider"]:
        failures.append(f"Expected {case['lyrics_provider']} lyrics; got {result.get('lyrics_provider')}")
    if case.get("segment_duration"):
        first, last = result.get("first_lyric_time"), result.get("last_lyric_time")
        if not (isinstance(first, (int, float)) and isinstance(last, (int, float))
                and 0 <= first <= last < case["segment_duration"]):
            failures.append("Caption times were not rebased within the current chapter")
    if case.get("live_yt_dlp"):
        helpers = [event for event in result.get("events", []) if event.get("command") == "python3"]
        if len(helpers) != 1:
            failures.append(f"Expected one yt-dlp metadata and caption extraction; got {len(helpers)}")
        if result["ai_status"] != "idle":
            failures.append("YouTube captions should load before AI lookup")
    if case.get("title") and case["title"] not in (result["title"] or "").casefold():
        failures.append(f"Expected title containing {case['title']}")
    if case.get("manual_ai") and (result["pre_ai_status"] != "idle"
                                  or result["pre_ai_lookup_state"] != "confirm"
                                  or not result["ai_click_sent"]):
        failures.append("AI lookup did not wait for the panel confirmation request")
    if case.get("indices"):
        indices = [item["album_track_index"] for item in result.get("positions", [])]
        if indices != case["indices"]:
            failures.append(f"Unexpected tracks after seeking: {indices}")
    if case["tracks"]:
        tracklist = result.get("album_tracklist") or {}
        elapsed = 0
        for track in tracklist.get("tracks", []):
            if track["start"] != elapsed or track["duration_seconds"] <= 0:
                failures.append("Invalid cumulative track timing")
                break
            elapsed += track["duration_seconds"]
        if not tracklist.get("tracks"):
            failures.append("Missing extracted tracklist")
    return failures


def run_case(name, timeout):
    case = CASES[name]
    args = argparse.Namespace(title="", artist="", album="", duration=0,
        position=case.get("position", 0),
        url=case.get("url") or "https://www.youtube.com/watch?v=" + case["video"],
        positions=case.get("positions"),
        provider=None, model=None, metadata=None, yt_dlp=case.get("live_yt_dlp", False),
        confirm_ai=True, timeout=timeout)
    replay = Replay(args)
    # Exercise the default confirmation path without changing local settings or credentials.
    replay.settings["automatic_ai_fallback"] = False
    if case.get("live_yt_dlp"):
        replay.settings["llm_backend"] = "none"
    provider = replay.settings.get("llm_backend")
    started = False
    try:
        if (not provider or provider == "none") and not case.get("live_yt_dlp"):
            raise RuntimeError("Select an AI backend in the plugin settings before running E2E tests")
        if provider != "none" and not replay.settings.get(provider + "_api_key"):
            raise RuntimeError("The selected backend has no API key in the plugin settings")
        if case.get("live_yt_dlp"):
            args.title, args.artist, args.duration = case["title_full"], case["artist"], case["duration"]
        elif case.get("video"):
            binary = str(Path(replay.settings.get("yt_dlp_path") or "yt-dlp").expanduser())
            metadata = extract(binary, args.url)
            args.title, args.artist = metadata["title"], metadata["uploader"]
            args.duration = metadata["duration"]
            # This is fresh output from the real metadata helper, not a fixture.
            replay.metadata = metadata
        else:
            args.title, args.artist, args.duration = x_post_metadata(args.url)
        print(f"Running {name}: {args.title} ({provider})", flush=True)
        started = True
        result = replay.run()
        failures = check(result, case)
        report = {"case": name, "passed": not failures, "failures": failures,
            **{key: value for key, value in result.items() if key != "events"}}
    except Exception as error:
        report = {"case": name, "passed": False, "failure": str(error), **replay.summary()}
    finally:
        if not started:
            replay.lua.close()
    output = json.dumps(report, ensure_ascii=False)
    for key, value in replay.settings.items():
        if key.endswith("_api_key") and value:
            output = output.replace(str(value), "[redacted]")
    print(output, flush=True)
    return report["passed"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", choices=CASES, help="Run selected cases; default: all")
    parser.add_argument("--timeout", type=float, default=300, help="Deadline per case in seconds")
    args = parser.parse_args()
    results = [run_case(name, args.timeout) for name in (args.case or CASES)]
    print(f"{sum(results)}/{len(results)} live E2E cases passed", flush=True)
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
