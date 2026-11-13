# Spotifu

Personal offline music project for iPhone and Mac. GPL-3.0, based on EeveeSpotifyReincarnated (not affiliated with Spotify).

## Native integration

The deliverable extends existing Spotify on macOS and EeveeSpotify on iPhone, preserving their player and library UI. The SwiftUI app targets are earlier prototypes, not the requested clients; CI no longer distributes them.

- macOS: `desktop/spotifu.js` adds one Download button, registers the resolver library with Spotify's native LocalFilesAPI and stores verified remote-to-local track mappings. Installed Spotify 1.2.70.409 has loaded the extension; authenticated server access and indexing a tagged two-second test tone were observed at runtime. Playback redirection, queue preservation and native offline lyrics are not yet acceptance-tested.
- iOS: the cover button invokes the automatic resolver and exports tagged audio to Spotify Documents for its native local-file scanner. Settings opens the native local-files route instead of the prototype player. The route, scanner and hooks still require device testing. Native lyrics now use generation-checked asynchronous loading on track changes, mandatory plain Genius fallback, and a persistent text cache. Automatic remote-to-local audio routing and lyric display for native local-file tracks still require device validation.
- Resolver: automatic metadata/duration matching and source fallback across YouTube, SoundCloud, Internet Archive and Bandcamp. Audius direct links supported; no automatic Audius search. Availability and matching are not guaranteed.

## Build and test

Run `bash scripts/test.sh` and `node Tests/desktop.test.cjs`. `swift test` requires full Xcode.

Desktop installation: keep the official Spicetify binary in `.local/spicetify`, then run `python3 scripts/install-desktop.py`. It backs up the existing application, disables theme changes and installs only the extension. Start the resolver with `.local/venv/bin/python scripts/run-server.py`. Private configuration and keys stay under ignored `.local`.

Eevee integration: `python3 scripts/sync-ios.py`, then build `ios/EeveeSpotify` with Theos/Orion and an iPhone SDK. The minimum is iOS 15, matching the pinned Spotify 9.1.88 base. The dedicated workflow rebuilds Eevee components in a pinned base IPA; Spotify binaries are not stored in git. A successful build does not prove native playback compatibility.

## Resolver

Use Python 3.11+, yt-dlp and ffmpeg. Keep dependencies and data local:

```sh
python3 -m venv .local/venv
.local/venv/bin/pip install -r server/requirements.txt
export SPOTIFU_TOKEN='your-random-secret-at-least-24-characters'
.local/venv/bin/python server/app.py
```

Configure its URL and token once in Spotifu. Use HTTPS for an iPhone connection; loopback HTTP is allowed for Mac. Audio and lyrics stay on the device after downloading. Provider availability and lyric timing vary; no promise of every Spotify recording. Only download content you are entitled to save.

## Distribution

Release source: `https://raw.githubusercontent.com/Danzxz/spotifu/main/source/spotifu.json`

The source points to the published beta IPA. Add it in SideStore → Sources → +. Release assets also include the macOS integration source archive. See the release notes for tested behavior and remaining device checks; a successful build is not an on-device acceptance test.

Upstream source and original license are retained under `ios/EeveeSpotify`. See `docs/RESEARCH.md` for the initial integration analysis.
