"""Exercise the production service with real JSON and deterministic transports."""
import argparse
import json
import unittest

from replay_lyrics import Replay


class FixtureReplay(Replay):
    def __init__(self, *, not_song=False):
        super().__init__(argparse.Namespace(title="Artist - Song", artist="", album="", url="",
            duration=240, position=0, provider="openrouter", model=None, metadata=None, yt_dlp=False, timeout=10))
        self.settings["openrouter_api_key"] = "fixture-key"
        self.not_song = not_song
        self.model_calls = 0

    def command(self, request):
        argv = request["argv"]
        if argv[-1] == "GetActivePlayer": return self.player()
        if argv[0] == "busctl": return {"exitCode": 0, "stdout": ""}
        body = []
        if self.model_calls:
            body = [{"id": 123, "trackName": "Song", "artistName": "Artist", "albumName": "",
                     "duration": 240, "syncedLyrics": "[00:00.00]Fixture words"}]
        return {"exitCode": 0, "stdout": json.dumps(body)}

    def http(self, item):
        self.model_calls += 1
        body = json.loads(item["request"]["body"])
        assert body["tools"][0]["function"]["name"] == "search_lyrics"
        assert body["tools"][1]["type"] == "openrouter:web_search"
        if self.not_song:
            delta = {"content": '{"not_a_song":true}'}
            reason = "stop"
        elif self.model_calls == 1:
            delta = {"tool_calls": [{"index": 0, "id": "query-1", "type": "function", "function": {
                "name": "search_lyrics", "arguments": '{"title":"Song","artist":"Artist"}'}}]}
            reason = "tool_calls"
        else:
            result = json.loads(body["messages"][-1]["content"])["results"][0]
            assert result["result_id"] == 123
            delta, reason = {"content": '{"result_id":123}'}, "stop"
        event = {"choices": [{"delta": delta, "finish_reason": reason}]}
        for line in ("data: " + json.dumps(event), "", "data: [DONE]", ""):
            self.lua.dispatch("line", item["id"], line)
        self.lua.dispatch("close", item["id"], {"ok": True, "status": 200})


class ReplayTests(unittest.TestCase):
    def test_not_song_is_terminal_without_database_tool(self):
        replay = FixtureReplay(not_song=True)
        result = replay.run()
        self.assertEqual(result["ai_status"], "not_song")
        self.assertEqual(result["lyrics_status"], "empty")
        self.assertIsNone(result["error"])
        self.assertEqual(replay.model_calls, 1)

    def test_real_json_tool_round_trip_uses_selected_lyrics(self):
        replay = FixtureReplay()
        result = replay.run()
        self.assertEqual(result["ai_status"], "done")
        self.assertEqual(result["lyrics_status"], "ready")
        self.assertEqual((result["artist"], result["title"]), ("Artist", "Song"))
        self.assertEqual(result["lyric_lines"], 1)
        self.assertIsNone(result["error"])
        self.assertEqual(replay.model_calls, 2)


if __name__ == "__main__":
    unittest.main()
