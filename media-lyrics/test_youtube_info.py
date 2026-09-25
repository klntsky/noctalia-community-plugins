import json
import subprocess
import unittest
from unittest.mock import patch

from youtube_info import extract


class YoutubeInfoTests(unittest.TestCase):
    def test_extracts_only_compact_chapters(self):
        payload = {
            "title": "Artist - Album (FULL ALBUM)",
            "uploader": "Upload channel",
            "channel": "Different from performer",
            "artist": "Actual artist",
            "artists": ["Actual artist", "Guest"],
            "album": "Album",
            "track": "Track",
            "description": "Album context and tracklist. " * 400,
            "categories": ["Music"],
            "duration": 620,
            "chapters": [
                {"title": "First", "start_time": 0, "end_time": 240},
                {"title": "Second", "start_time": 240, "end_time": 620},
                {"title": "invalid", "start_time": 620, "end_time": 620},
            ],
            "formats": [{"url": "must not be returned"}],
        }
        with patch("youtube_info.subprocess.run", return_value=subprocess.CompletedProcess([], 0, json.dumps(payload), "")) as run:
            result = extract("/usr/bin/yt-dlp", "https://www.youtube.com/watch?v=example")
        self.assertEqual(2, len(result["chapters"]))
        self.assertEqual(240, result["chapters"][1]["start"])
        for key in ("channel", "artist", "artists", "album", "track", "description", "categories"):
            self.assertEqual(payload[key], result[key])
        self.assertNotIn("formats", result)
        self.assertEqual("/usr/bin/yt-dlp", run.call_args.args[0][0])
        self.assertIn("--skip-download", run.call_args.args[0])

    def test_rejects_non_youtube_url_before_spawning(self):
        with patch("youtube_info.subprocess.run") as run:
            with self.assertRaises(ValueError):
                extract("yt-dlp", "https://example.com/watch?v=example")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
