#!/usr/bin/env python3
"""Rerun the production lyric service with explicit media metadata.

Uses liblua5.4 and real provider/database requests. It does not read the active
player, modify Noctalia, or use/write its lyric caches. Provider settings are
read locally; API keys never enter subprocess arguments or printed output.
"""
import argparse
from collections import deque
import ctypes as C
import ctypes.util
import json
from pathlib import Path
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent


class Lua:
    """Small Lua host bridge; all algorithm code is loaded from production files."""

    def __init__(self, bridge):
        name = ctypes.util.find_library("lua5.4")
        if not name:
            raise RuntimeError("Install liblua5.4 to run the replay host")
        self.lib = C.CDLL(name)
        signatures = {
            "luaL_newstate": (C.c_void_p, []),
            "luaL_openlibs": (None, [C.c_void_p]),
            "lua_close": (None, [C.c_void_p]),
            "lua_gettop": (C.c_int, [C.c_void_p]),
            "lua_settop": (None, [C.c_void_p, C.c_int]),
            "lua_type": (C.c_int, [C.c_void_p, C.c_int]),
            "lua_toboolean": (C.c_int, [C.c_void_p, C.c_int]),
            "lua_tonumberx": (C.c_double, [C.c_void_p, C.c_int, C.c_void_p]),
            "lua_tolstring": (C.c_void_p, [C.c_void_p, C.c_int, C.POINTER(C.c_size_t)]),
            "lua_pushnil": (None, [C.c_void_p]),
            "lua_pushboolean": (None, [C.c_void_p, C.c_int]),
            "lua_pushnumber": (None, [C.c_void_p, C.c_double]),
            "lua_pushinteger": (None, [C.c_void_p, C.c_longlong]),
            "lua_pushlstring": (None, [C.c_void_p, C.c_char_p, C.c_size_t]),
            "lua_createtable": (None, [C.c_void_p, C.c_int, C.c_int]),
            "lua_settable": (None, [C.c_void_p, C.c_int]),
            "lua_next": (C.c_int, [C.c_void_p, C.c_int]),
            "lua_setglobal": (None, [C.c_void_p, C.c_char_p]),
            "lua_getglobal": (C.c_int, [C.c_void_p, C.c_char_p]),
            "luaL_loadstring": (C.c_int, [C.c_void_p, C.c_char_p]),
            "lua_pcallk": (C.c_int, [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ssize_t, C.c_void_p]),
        }
        for name, (restype, argtypes) in signatures.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = restype, argtypes
        self.state = self.lib.luaL_newstate()
        self.lib.luaL_openlibs(self.state)
        self.bridge_error = None

        @C.CFUNCTYPE(C.c_int, C.c_void_p)
        def callback(_):
            try:
                self.push(bridge(self.value(1), self.value(2)))
            except Exception as exc:
                # Never unwind a Python exception through Lua's C stack.
                self.bridge_error = exc
                self.lib.lua_pushnil(self.state)
            return 1

        self.callback = callback
        self.lib.lua_pushcclosure.argtypes = [C.c_void_p, type(callback), C.c_int]
        self.lib.lua_pushcclosure(self.state, callback, 0)
        self.lib.lua_setglobal(self.state, b"replay_bridge")

    def value(self, index):
        lib, state = self.lib, self.state
        kind = lib.lua_type(state, index)
        if kind in (-1, 0):
            return None
        if kind == 1:
            return bool(lib.lua_toboolean(state, index))
        if kind == 3:
            value = lib.lua_tonumberx(state, index, None)
            return int(value) if value.is_integer() else value
        if kind == 4:
            size = C.c_size_t()
            pointer = lib.lua_tolstring(state, index, C.byref(size))
            return C.string_at(pointer, size.value).decode("utf-8", errors="replace")
        if kind == 5:
            absolute = index if index > 0 else lib.lua_gettop(state) + index + 1
            result = {}
            lib.lua_pushnil(state)
            while lib.lua_next(state, absolute):
                result[self.value(-2)] = self.value(-1)
                lib.lua_settop(state, -2)
            if result and set(result) == set(range(1, len(result) + 1)):
                return [result[i] for i in range(1, len(result) + 1)]
            return result
        raise TypeError(f"Unsupported Lua value type {kind}")

    def push(self, value):
        lib, state = self.lib, self.state
        if value is None:
            lib.lua_pushnil(state)
        elif isinstance(value, bool):
            lib.lua_pushboolean(state, value)
        elif isinstance(value, int):
            lib.lua_pushinteger(state, value)
        elif isinstance(value, float):
            lib.lua_pushnumber(state, value)
        elif isinstance(value, str):
            encoded = value.encode()
            lib.lua_pushlstring(state, encoded, len(encoded))
        elif isinstance(value, (dict, list)):
            lib.lua_createtable(state, 0, len(value))
            items = value.items() if isinstance(value, dict) else enumerate(value, 1)
            for key, item in items:
                self.push(key)
                self.push(item)
                lib.lua_settable(state, -3)
        else:
            raise TypeError(f"Unsupported Python value type {type(value).__name__}")

    def check(self, status):
        if self.bridge_error:
            raise RuntimeError(f"Replay host: {self.bridge_error}")
        if status:
            error = self.value(-1)
            self.lib.lua_settop(self.state, -2)
            raise RuntimeError(error)

    def execute(self, source):
        self.check(self.lib.luaL_loadstring(self.state, source.encode()))
        self.check(self.lib.lua_pcallk(self.state, 0, 0, 0, 0, None))

    def dispatch(self, kind, id_, value):
        self.lib.lua_getglobal(self.state, b"replay_dispatch")
        for argument in (kind, id_, value):
            self.push(argument)
        self.check(self.lib.lua_pcallk(self.state, 3, 0, 0, 0, None))

    def close(self):
        self.lib.lua_close(self.state)


class Replay:
    def __init__(self, args):
        self.args = args
        self.queue, self.files, self.snapshot, self.events = deque(), {}, {}, []
        self.started = time.monotonic()
        manifest = tomllib.loads((ROOT / "plugin.toml").read_text())
        self.settings = {s["key"]: s.get("default") for s in manifest["setting"]}
        for path in (Path.home() / ".config/noctalia/config.toml", Path.home() / ".local/state/noctalia/settings.toml"):
            if path.exists():
                config = tomllib.loads(path.read_text())
                self.settings.update(config.get("plugin_settings", {}).get("tranzem/media-lyrics", {}))
        if args.provider:
            self.settings["llm_backend"] = args.provider
        provider = self.settings["llm_backend"]
        if args.model:
            self.settings[provider + "_model"] = args.model
        self.settings.update(use_cache=False, local_lyrics_dir="", player_allowlist="", player_blocklist="")
        self.metadata = json.loads(args.metadata.read_text()) if args.metadata else {
            "title": args.title, "uploader": args.artist, "duration": args.duration, "chapters": []}
        self.lua = Lua(self.bridge)

    def bridge(self, operation, value):
        if operation == "root": return str(ROOT)
        if operation == "setting": return self.settings.get(value)
        if operation == "encode": return json.dumps(value, ensure_ascii=False)
        if operation == "decode":
            try: return json.loads(value)
            except (TypeError, ValueError): return None
        if operation == "urlEncode": return urllib.parse.quote(value, safe="")
        if operation == "nowMs": return time.monotonic() * 1000
        if operation == "readFile":
            if value in self.files: return self.files[value]
            if "/youtube/chapters-" in value and not self.args.yt_dlp:
                return json.dumps(self.metadata, ensure_ascii=False)
            return self.files.get(value)
        if operation == "writeFile": self.files[value[0]] = value[1]
        elif operation == "state":
            if value[0] == "media": self.snapshot = value[1]
        elif operation == "log": self.events.append({"seconds": round(time.monotonic() - self.started, 3), "message": value})
        elif operation in ("command", "http"): self.queue.append((operation, value))
        return None

    def player(self):
        values = {"title": self.args.title, "artists": self.args.artist, "album": self.args.album,
            "identity": "Replay", "bus_name": "replay.player", "source_url": self.args.url,
            "playback_status": "Playing"}
        fields = {k: {"type": "s", "data": v} for k, v in values.items()}
        fields.update(length_us={"type": "x", "data": self.args.duration * 1e6},
                      position_us={"type": "x", "data": self.args.position * 1e6})
        return {"exitCode": 0, "stdout": json.dumps({"data": [True, fields]})}

    def command(self, request):
        argv = request["argv"]
        if argv[-1] == "GetActivePlayer": return self.player()
        if argv[0] == "busctl": return {"exitCode": 0, "stdout": ""}
        if argv[0] not in ("curl", "python3"):
            raise RuntimeError(f"Unexpected replay command: {argv[0]}")
        started = time.monotonic()
        try:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=request["timeout"] / 1000)
            value = {"exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        except subprocess.TimeoutExpired:
            value = {"exitCode": -1, "stdout": "", "stderr": "Command timed out", "timedOut": True}
        self.events.append({"seconds": round(time.monotonic() - self.started, 3),
            "command": argv[0], "url": argv[-1], "duration": round(time.monotonic() - started, 3),
            "exitCode": value["exitCode"]})
        return value

    def http(self, item):
        request, id_ = item["request"], item["id"]
        headers = dict(header.split(": ", 1) for header in request["headers"])
        req = urllib.request.Request(request["url"], data=request["body"].encode(),
                                     headers=headers, method=request["method"])
        ok, status = True, 0
        try:
            try: response = urllib.request.urlopen(req, timeout=self.args.timeout)
            except urllib.error.HTTPError as error: response = error
            with response:
                status = response.status
                for raw in response:
                    self.lua.dispatch("line", id_, raw.decode("utf-8").rstrip("\r\n"))
        except (OSError, urllib.error.URLError) as error:
            ok = False
            self.events.append({"network_error": type(error).__name__})
        self.lua.dispatch("close", id_, {"ok": ok, "status": status})

    def drain(self):
        while self.queue:
            if time.monotonic() - self.started > self.args.timeout:
                raise TimeoutError("Replay deadline exceeded")
            kind, value = self.queue.popleft()
            if kind == "command": self.lua.dispatch("command", value["id"], self.command(value))
            else: self.http(value)
        if self.snapshot.get("llmStatus") == "pending" or self.snapshot.get("lyricsStatus") == "loading":
            raise RuntimeError("Pipeline stalled: pending state with no queued work")

    def summary(self):
        return {"title": self.snapshot.get("title"), "artist": self.snapshot.get("artist"),
            "lyrics_status": self.snapshot.get("lyricsStatus"), "ai_status": self.snapshot.get("llmStatus"),
            "lyrics_provider": self.snapshot.get("lyricsProvider"),
            "first_lyric_time": (self.snapshot.get("lyrics") or [{}])[0].get("time"),
            "last_lyric_time": (self.snapshot.get("lyrics") or [{}])[-1].get("time"),
            "ai_lookup_seconds": self.snapshot.get("aiLookupSeconds"),
            "ai_lookup_cost": self.snapshot.get("aiLookupCost"),
            "error": self.snapshot.get("llmError"), "lyric_lines": len(self.snapshot.get("lyrics", [])),
            "synced": self.snapshot.get("synced"), "position_seconds": self.snapshot.get("posSec"),
            "track_duration_seconds": self.snapshot.get("lengthSec"),
            "album_track_index": self.snapshot.get("albumTrackIndex", 0),
            "album_track_count": self.snapshot.get("albumTrackCount", 0),
            "timing_estimated": self.snapshot.get("timingEstimated", False)}

    def run(self):
        try:
            self.lua.execute((ROOT / "replay_host.luau").read_text())
            self.drain()
            pre_ai_status = self.snapshot.get("llmStatus")
            pre_lyrics_status = self.snapshot.get("lyricsStatus")
            pre_ai_lookup_state = self.snapshot.get("aiLookupState")
            ai_click_sent = False
            if getattr(self.args, "confirm_ai", False) and pre_lyrics_status in ("empty", "error"):
                if pre_ai_lookup_state != "confirm":
                    raise RuntimeError("AI lookup was not waiting for confirmation")
                self.lua.dispatch("state", "panel_req", {"action": "lookUpWithAi"})
                ai_click_sent = True
                self.drain()
            positions = []
            for position in getattr(self.args, "positions", None) or []:
                self.args.position = position
                self.lua.execute("update()")
                self.drain()
                positions.append({"video_position_seconds": position, **self.summary()})
            tracklist = next((json.loads(value).get("tracklist") for key, value in self.files.items()
                              if "/youtube/chapters-" in key and json.loads(value).get("tracklist")), None)
            return {"seconds": round(time.monotonic() - self.started, 3), **self.summary(),
                "pre_ai_status": pre_ai_status, "pre_lyrics_status": pre_lyrics_status,
                "pre_ai_lookup_state": pre_ai_lookup_state,
                "ai_click_sent": ai_click_sent,
                **({"album_tracklist": tracklist} if tracklist else {}),
                **({"positions": positions} if positions else {}), "events": self.events}
        finally:
            self.lua.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--title", required=True)
    parser.add_argument("--artist", default="")
    parser.add_argument("--album", default="")
    parser.add_argument("--url", default="")
    parser.add_argument("--duration", type=float, default=0)
    parser.add_argument("--position", type=float, default=0)
    parser.add_argument("--positions", type=float, nargs="+", help="Then seek through these positions using the same in-memory cache")
    parser.add_argument("--provider", help="Override the selected backend; 'none' skips AI")
    parser.add_argument("--model", help="Override the selected provider's model")
    parser.add_argument("--metadata", type=Path, help="Explicit yt-dlp helper JSON, including chapters")
    parser.add_argument("--yt-dlp", action="store_true", help="Fetch fresh YouTube metadata instead of using explicit input")
    parser.add_argument("--confirm-ai", action="store_true", help="Send the panel's AI lookup request after direct lyrics fail")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    replay = Replay(args)
    try:
        result = replay.run()
    except Exception as error:
        result = {"error": str(error), "events": replay.events}
    output = json.dumps(result, ensure_ascii=False, indent=2)
    for key, value in replay.settings.items():
        if key.endswith("_api_key") and value: output = output.replace(str(value), "[redacted]")
    print(output)
    return 1 if result.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
