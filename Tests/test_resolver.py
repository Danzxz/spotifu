import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("resolver", Path(__file__).parents[1] / "server/resolver.py")
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)

class ResolverTests(unittest.TestCase):
    def test_rejects_internal_and_unknown_hosts(self):
        for url in ["http://localhost/audio", "https://127.0.0.1/a", "https://youtube.com.evil.org/a", "file:///etc/passwd", "https://user:pass@youtube.com/a"]:
            with self.assertRaises(ValueError, msg=url):
                resolver.validate_media_url(url)

    def test_accepts_supported_public_sources(self):
        for url in ["https://www.youtube.com/watch?v=abc", "https://soundcloud.com/artist/song", "https://artist.bandcamp.com/track/song", "https://archive.org/details/item", "https://audius.co/artist/song"]:
            self.assertEqual(resolver.validate_media_url(url), url)

    def test_ranking_rejects_wrong_duration_and_live_version(self):
        wanted = {"title": "Song", "artist": "Artist", "duration": 200}
        self.assertGreater(resolver.match_score(wanted, {"title": "Artist - Song", "duration": 201}), .8)
        self.assertLess(resolver.match_score(wanted, {"title": "Artist - Song Live", "duration": 201}), .5)
        self.assertLess(resolver.match_score(wanted, {"title": "Artist - Song", "duration": 400}), .5)

    def test_auto_selection_requires_verified_metadata_and_duration(self):
        wanted = {"title": "Song", "artist": "Artist", "duration": 200}
        wrong = {"title": "Artist - Song live", "duration": 200, "url": "https://soundcloud.com/a/live"}
        right = {"title": "Artist - Song", "duration": 201, "url": "https://soundcloud.com/a/right"}
        self.assertEqual(resolver.select_verified(wanted, [wrong, right])["url"], right["url"])
        self.assertIsNone(resolver.select_verified(wanted, [wrong]))
        self.assertIsNone(resolver.select_verified(wanted, [{"title": "Artist - Song", "duration": 0}]))
        self.assertIsNone(resolver.select_verified({**wanted, "duration": 0}, [right]))

    def test_auto_selection_rejects_unrequested_versions(self):
        wanted = {"title": "Song", "artist": "Artist", "duration": 200}
        for suffix in ["acoustic", "radio edit", "remastered", "clean", "instrumental", "demo"]:
            self.assertIsNone(resolver.select_verified(wanted, [{"title": "Artist Song " + suffix, "duration": 200}]), suffix)

if __name__ == "__main__":
    unittest.main()
