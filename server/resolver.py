"""Multi-source matching. A match is a candidate, never proof of recording identity."""
import difflib
import json
import re
import urllib.parse
import urllib.request

DOMAINS = ("youtube.com", "youtu.be", "soundcloud.com", "bandcamp.com", "archive.org", "audius.co")

def validate_media_url(url):
    parsed = urllib.parse.urlsplit(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError("Use a public HTTPS media URL")
    if not any(host == domain or host.endswith("." + domain) for domain in DOMAINS):
        raise ValueError("Unsupported media source")
    return url

def match_score(wanted, candidate):
    def words(text):
        return set(re.findall(r"\w+", text.lower()))
    expected = words(wanted["artist"] + " " + wanted["title"])
    actual = words(candidate.get("title", ""))
    score = len(expected & actual) / max(1, len(expected))
    versions = {"live", "remix", "cover", "karaoke", "instrumental", "sped", "slowed"}
    if (actual & versions) != (expected & versions):
        score *= .3
    duration = wanted.get("duration", 0)
    found_duration = candidate.get("duration") or 0
    if duration and found_duration and abs(duration - found_duration) > max(5, duration * .04):
        score *= .3
    return round(score, 3)

def select_verified(wanted, candidates):
    duration = wanted.get("duration") or 0
    if duration <= 0:
        return None
    eligible = [c for c in candidates if c.get("duration", 0) > 0
                and abs(c["duration"] - duration) <= max(2, duration * .015)
                and match_score(wanted, c) >= .95]
    return max(eligible, key=lambda c: match_score(wanted, c), default=None)

def verify_candidate(wanted, candidate):
    from yt_dlp import YoutubeDL
    with YoutubeDL({"quiet": True, "no_warnings": True, "noplaylist": True, "socket_timeout": 15}) as ydl:
        info = ydl.extract_info(validate_media_url(candidate["url"]), download=False)
    if not info or info.get("is_live") or info.get("_type") == "playlist":
        return None
    candidate = dict(candidate)
    candidate["title"] = " ".join(filter(None, [info.get("artist") or info.get("uploader"), info.get("track") or info.get("title")]))
    candidate["duration"] = info.get("duration") or 0
    return select_verified(wanted, [candidate])

def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Spotifu/0.1 (https://github.com/Danzxz/spotifu)"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)

def search(wanted):
    from yt_dlp import YoutubeDL
    query = wanted["artist"] + " " + wanted["title"]
    results, errors = [], []
    # Independent provider queries: failure on YouTube must not drop SoundCloud.
    for provider, prefix in [("YouTube", "ytsearch5:"), ("SoundCloud", "scsearch5:")]:
        try:
            with YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": True, "socket_timeout": 15}) as ydl:
                response = ydl.extract_info(prefix + query, download=False)
            for entry in (response or {}).get("entries", []):
                url = entry.get("webpage_url") or entry.get("url", "")
                if provider == "YouTube" and not url.startswith("https://"):
                    url = "https://www.youtube.com/watch?v=" + entry["id"]
                try:
                    validate_media_url(url)
                except ValueError:
                    continue
                item = {"title": entry.get("title", ""), "duration": entry.get("duration") or 0, "url": url, "provider": provider}
                item["score"] = match_score(wanted, item)
                results.append(item)
        except Exception as error:
            errors.append({"provider": provider, "error": type(error).__name__})
    # Internet Archive exposes a searchable public catalogue in addition to
    # the site-specific search extractors above. Only audio items are queried.
    try:
        parameters = urllib.parse.urlencode({"q": f'title:({wanted["title"]}) AND creator:({wanted["artist"]}) AND mediatype:audio',
                                             "output": "json", "rows": 5, "fl[]": "identifier,title,creator"})
        response = fetch_json("https://archive.org/advancedsearch.php?" + parameters)
        for item in response.get("response", {}).get("docs", []):
            candidate = {"title": str(item.get("creator", "")) + " " + item.get("title", ""), "duration": 0,
                         "url": "https://archive.org/details/" + urllib.parse.quote(item["identifier"], safe=""), "provider": "Internet Archive"}
            candidate["score"] = match_score(wanted, candidate)
            results.append(candidate)
    except Exception as error:
        errors.append({"provider": "Internet Archive", "error": type(error).__name__})
    # Bandcamp's public search provides track URLs; extraction and duration
    # checks still happen through yt-dlp before an automatic choice is made.
    try:
        url = "https://bandcamp.com/search?" + urllib.parse.urlencode({"q": query, "item_type": "t"})
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Spotifu/0.1"}), timeout=15) as response:
            html = response.read(2_000_000).decode("utf-8", errors="replace")
        urls = list(dict.fromkeys(re.findall(r'https://[\w-]+\.bandcamp\.com/track/[\w-]+', html)))[:5]
        for url in urls:
            results.append({"title": query, "duration": 0, "url": url, "provider": "Bandcamp", "score": 0})
    except Exception as error:
        errors.append({"provider": "Bandcamp", "error": type(error).__name__})
    return {"candidates": sorted(results, key=lambda x: x["score"], reverse=True), "errors": errors}

def lyrics(title, artist):
    query = urllib.parse.urlencode({"track_name": title, "artist_name": artist})
    try:
        response = fetch_json("https://lrclib.net/api/get?" + query)
        return response.get("syncedLyrics") or response.get("plainLyrics")
    except Exception:
        return None
