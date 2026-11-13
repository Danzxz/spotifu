# Spotifu

Personal offline music project for iPhone and Mac. GPL-3.0, based on EeveeSpotifyReincarnated (not affiliated with Spotify).

## Current implementation

- Shared persistent audio/lyrics library, local playback, seek and line-synced lyrics.
- Automatic multi-source resolver: searches YouTube, SoundCloud, Internet Archive and Bandcamp, checks full candidate metadata and duration before downloading. Refuses unverified matches. Direct Audius URLs supported by yt-dlp; automatic Audius search not yet available.
- One-tap download button inside the modified Spotify player, plus Eevee settings → Spotifu → Downloads. iOS hook compatibility requires device testing; this is not a claim of verified native offline Spotify playback.
- Standalone iPhone and Mac clients use the same offline code. The standalone app is an offline library, not a replacement implementation of Spotify streaming.

## Build

`swift build` builds the Mac executable. `swift test` needs full Xcode. With Command Line Tools, run `bash scripts/test.sh` for the portable core and Python tests.

For Xcode app bundles: install XcodeGen, run `xcodegen generate`, then build the Spotifu (iOS) or SpotifuMac schemes. CI uploads unsigned IPA and Mac ZIP artifacts. SideStore signs IPA files for your device.

Eevee integration: `python3 scripts/sync-ios.py`, then build `ios/EeveeSpotify` using Theos/Orion and an iPhone SDK. The dedicated GitHub workflow rebuilds the tweak and replaces existing Eevee components in a pinned, account-free base IPA. Proprietary Spotify binaries are not stored in git.

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

An app enters this source only after its actual release asset exists. An empty source means no release is ready. See GitHub Actions for build status. A successful build is not an on-device acceptance test.

Upstream source and original license are retained under `ios/EeveeSpotify`. See `docs/RESEARCH.md` for the initial integration analysis.
