import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.request
import urllib.error

sys.path.insert(0, str(Path(__file__).parents[1] / "server"))
temporary = tempfile.TemporaryDirectory()
os.environ["SPOTIFU_DATA"] = temporary.name
import app

class ServerTests(unittest.TestCase):
    def test_audio_probe_rejects_preview_even_with_matching_provider_metadata(self):
        path = Path(temporary.name) / "probe.m4a"
        path.write_bytes(b"audio")
        with patch.object(app.subprocess, "check_output", return_value=b"30.0\n"):
            with self.assertRaises(ValueError): app.probe_audio(path, 205)
        with patch.object(app.subprocess, "check_output", return_value=b"205.3\n"):
            self.assertEqual(app.probe_audio(path, 205), 205.3)

    @classmethod
    def setUpClass(cls):
        app.TOKEN = "test-secret-only-not-a-production-token"
        cls.server = app.ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        cls.url = "http://127.0.0.1:" + str(cls.server.server_port)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        temporary.cleanup()

    def request(self, path, payload=None, authorized=True):
        request = urllib.request.Request(self.url + path, data=json.dumps(payload).encode() if payload is not None else None)
        if authorized: request.add_header("Authorization", "Bearer " + app.TOKEN)
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def test_requires_authentication(self):
        self.assertEqual(self.request("/jobs/" + "a"*32, authorized=False)[0], 401)

    def test_auto_download_rejects_missing_duration(self):
        self.assertEqual(self.request("/auto-download", {"title": "Song", "artist": "Artist"})[0], 400)

    def test_audio_does_not_serve_arbitrary_files(self):
        self.assertEqual(self.request("/audio/../../etc/passwd")[0], 404)

    def test_ready_audio_is_exact_downloaded_file(self):
        job = "b" * 32
        folder = Path(temporary.name) / job
        folder.mkdir(exist_ok=True)
        (folder / "audio.m4a").write_bytes(b"test-audio")
        app.JOBS[job] = {"status": "ready"}
        status, data = self.request("/audio/" + job)
        self.assertEqual(status, 200)
        self.assertEqual(data, b"test-audio")
