"""Authenticated local resolver. Bind loopback; put HTTPS in front for a phone."""
import argparse
import hmac
import json
import math
import os
import secrets
import shutil
import subprocess
import time
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
LIBRARY = ROOT / "library"
LIBRARY.mkdir(exist_ok=True)

def probe_audio(path, expected_duration):
    if not path.is_file() or not 0 < path.stat().st_size <= 100 * 1024 * 1024:
        raise ValueError("Invalid audio size")
    duration = float(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(path)
    ], timeout=15, stderr=subprocess.DEVNULL).strip())
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Invalid audio duration")
    if expected_duration and abs(duration - expected_duration) > max(2, expected_duration * .015):
        raise ValueError("Downloaded audio duration does not match the requested recording")
    return duration

def download(job_id, request):
    folder = ROOT / job_id
    try:
        from yt_dlp import YoutubeDL
        candidates = [{"url": request["url"]}] if request.get("url") else []
        if not candidates:
            with LOCK:
                JOBS[job_id] = {"status": "working", "phase": "searching"}
            candidates = search(request)["candidates"][:12]
        chosen = None
        for candidate in candidates:
            try:
                if not request.get("url"):
                    candidate = verify_candidate(request, candidate)
                    if candidate is None: continue
                shutil.rmtree(folder, ignore_errors=True)
                folder.mkdir()
                with SLOTS, YoutubeDL({
                    "quiet": True, "no_warnings": True, "noplaylist": True,
                    "format": "bestaudio/best", "outtmpl": str(folder / "audio.%(ext)s"),
                    "socket_timeout": 20, "max_filesize": 100 * 1024 * 1024,
                    "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}],
                }) as ydl:
                    ydl.extract_info(validate_media_url(candidate["url"]), download=True)
                if (folder / "audio.m4a").stat().st_size:
                    candidate["duration"] = probe_audio(folder / "audio.m4a", request.get("duration", 0))
                    chosen = candidate
                    break
            except Exception:
                continue
        if chosen is None:
            raise ValueError("Не удалось найти и скачать подтверждённую запись из доступных источников")
        audio = folder / "audio.m4a"
        if not audio.is_file() or not audio.stat().st_size:
            raise ValueError("No complete audio produced")
        saved_lyrics = lyrics(request["title"], request["artist"], chosen.get("duration") or request.get("duration", 0))
        track_id = request.get("id") or job_id
        if not isinstance(track_id, str) or not track_id.isalnum() or len(track_id) > 128:
            raise ValueError("Invalid track identity")
        # Native Spotify scans this folder; no second audio engine is involved.
        target = LIBRARY / (track_id + ".m4a")
        staged = folder / "tagged.m4a"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(audio), "-c", "copy",
                        "-metadata", "title=" + request["title"], "-metadata", "artist=" + request["artist"],
                        "-metadata", "album=Spotifu", str(staged)], check=True, timeout=30, capture_output=True)
        os.replace(staged, target)
        # Phone imports need the same title/artist tags as the desktop scanner.
        shutil.copyfile(target, audio)
        metadata = {"id": track_id, "title": request["title"], "artist": request["artist"],
                    "duration": chosen.get("duration") or request.get("duration", 0), "lyrics": saved_lyrics,
                    "source": chosen["url"], "file": target.name}
        temp_metadata = folder / "track.json"
        temp_metadata.write_text(json.dumps(metadata))
        os.replace(temp_metadata, LIBRARY / (track_id + ".json"))
        result = {"status": "ready", "audio": f"/audio/{job_id}", "lyrics": saved_lyrics}
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
        self.cors()
        self.end_headers()
        self.wfile.write(body)

    def cors(self):
        origin = self.headers.get("Origin", "")
        if origin in ("https://xpui.app.spotify.com", "https://xpui.app.spotify.com:443"):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Private-Network", "true")

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_POST(self):
        if not self.authorized():
            return self.send_json({"error": "Unauthorized"}, 401)
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 16384:
                raise ValueError("Invalid request size")
            request = json.loads(self.rfile.read(length))
            if self.path == "/remove-download":
                track_id = request.get("id")
                if not isinstance(track_id, str) or not track_id.isascii() or not track_id.isalnum() or len(track_id) > 128:
                    raise ValueError("Invalid track identity")
                (LIBRARY / (track_id + ".m4a")).unlink(missing_ok=True)
                (LIBRARY / (track_id + ".json")).unlink(missing_ok=True)
                return self.send_json({"removed": track_id})
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
        if self.path == "/library":
            tracks = []
            for path in LIBRARY.glob("*.json"):
                try:
                    track = json.loads(path.read_text())
                    if (LIBRARY / track["file"]).is_file(): tracks.append(track)
                except (ValueError, KeyError, OSError): continue
            return self.send_json({"folder": str(LIBRARY.resolve()), "tracks": tracks})
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
        self.cors()
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
