"""Authenticated local resolver. Bind loopback; put HTTPS in front for a phone."""
import argparse
import hmac
import json
import os
import secrets
import shutil
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from resolver import lyrics, search, validate_media_url, verify_candidate

ROOT = Path(os.environ.get("SPOTIFU_DATA", Path(__file__).parents[1] / ".local/resolver"))
ROOT.mkdir(parents=True, exist_ok=True)
TOKEN = os.environ.get("SPOTIFU_TOKEN", "")
JOBS = {}
LOCK = threading.Lock()
SLOTS = threading.BoundedSemaphore(2)

def download(job_id, request):
    folder = ROOT / job_id
    try:
        from yt_dlp import YoutubeDL
        if not request.get("url"):
            with LOCK:
                JOBS[job_id] = {"status": "working", "phase": "searching"}
            candidates = search(request)["candidates"]
            chosen = None
            for candidate in candidates[:12]:
                try:
                    chosen = verify_candidate(request, candidate)
                    if chosen:
                        break
                except Exception:
                    continue
            if not chosen:
                raise ValueError("Не найдено надёжного совпадения исполнителя, версии и длительности")
            request = {**request, "url": chosen["url"]}
        folder.mkdir()
        with SLOTS, YoutubeDL({
            "quiet": True, "no_warnings": True, "noplaylist": True,
            "format": "bestaudio/best", "outtmpl": str(folder / "audio.%(ext)s"),
            "socket_timeout": 20, "max_filesize": 100 * 1024 * 1024,
            "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}],
        }) as ydl:
            ydl.extract_info(validate_media_url(request["url"]), download=True)
        audio = folder / "audio.m4a"
        if not audio.is_file() or not audio.stat().st_size:
            raise ValueError("No complete audio produced")
        result = {"status": "ready", "audio": f"/audio/{job_id}", "lyrics": lyrics(request["title"], request["artist"])}
        with LOCK:
            JOBS[job_id] = result
    except Exception as error:
        shutil.rmtree(folder, ignore_errors=True)
        with LOCK:
            JOBS[job_id] = {"status": "failed", "error": str(error)[:300]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log URL queries, tokens or account information.

    def authorized(self):
        value = self.headers.get("Authorization", "")
        return bool(TOKEN) and hmac.compare_digest(value, "Bearer " + TOKEN)

    def send_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.authorized():
            return self.send_json({"error": "Unauthorized"}, 401)
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 16384:
                raise ValueError("Invalid request size")
            request = json.loads(self.rfile.read(length))
            if not all(isinstance(request.get(k), str) and 0 < len(request[k]) <= 500 for k in ["title", "artist"]):
                raise ValueError("Title and artist required")
            if self.path == "/search":
                return self.send_json(search(request))
            if self.path in ("/download", "/auto-download"):
                if self.path == "/download":
                    validate_media_url(request.get("url", ""))
                else:
                    request.pop("url", None)
                    duration = request.get("duration")
                    if not isinstance(duration, (int, float)) or not 0 < duration < 7200:
                        raise ValueError("Для автоматической проверки нужна длительность трека")
                with LOCK:
                    if sum(j["status"] == "working" for j in JOBS.values()) >= 4:
                        return self.send_json({"error": "Download queue full"}, 429)
                    job_id = uuid.uuid4().hex
                    JOBS[job_id] = {"status": "working"}
                threading.Thread(target=download, args=(job_id, request), daemon=True).start()
                return self.send_json({"job": job_id}, 202)
            self.send_json({"error": "Not found"}, 404)
        except (ValueError, TypeError, KeyError) as error:
            self.send_json({"error": str(error)}, 400)
        except Exception:
            self.send_json({"error": "Provider request failed"}, 502)

    def do_GET(self):
        if not self.authorized():
            return self.send_json({"error": "Unauthorized"}, 401)
        parts = urlsplit(self.path).path.strip("/").split("/")
        if len(parts) != 2 or parts[0] not in ("jobs", "audio") or len(parts[1]) != 32 or any(c not in "0123456789abcdef" for c in parts[1]):
            return self.send_json({"error": "Not found"}, 404)
        with LOCK:
            job = JOBS.get(parts[1])
        if not job:
            return self.send_json({"error": "Unknown job"}, 404)
        if parts[0] == "jobs":
            return self.send_json(job)
        path = ROOT / parts[1] / "audio.m4a"
        if job["status"] != "ready" or not path.is_file():
            return self.send_json({"error": "Not ready"}, 409)
        self.send_response(200)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Content-Length", str(path.stat().st_size))
        self.end_headers()
        with path.open("rb") as stream:
            shutil.copyfileobj(stream, self.wfile)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if len(TOKEN) < 24:
        raise SystemExit("Set SPOTIFU_TOKEN to a random secret of at least 24 characters")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
