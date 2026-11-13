# Eevee offline playback investigation

Source revision: `c5bea1fca37585d291aa326a03afc650c102dcd2` (local clone).
This is source analysis and a proposed experiment, not verified iPhone playback.

## Findings

- `Sources/EeveeSpotify/Premium/Helpers/OfflineHelper.swift` resets PersistentCache, remote-config and caches. It does not download tracks.
- `Player/PlayerGestures.x.swift:8` declares pause, relative seek and next/previous selectors; lines 80–94 invoke the playback controller or visible buttons. These are possible control interception points, not proof of replaceable audio transport.
- `Karaoke/KaraokeHooks.x.swift` observes player state through legacy and Esperanto paths. `KaraokePlaybackTracker.swift:28` explicitly documents unconfirmed state-property names and version sensitivity. Its local/non-track handling clears the Spotify track identity: offline replacement must retain an explicit mapping.
- `Lyrics/CustomLyrics.x.swift:433` derives identity from the color-lyrics request path and creates serialized Spotify lyric payloads. An offline-first persistent lookup can precede provider requests, but an offline Spotify UI may not initiate the network request at all. The screen needs testing in airplane mode.
- `Lyrics/Models/KaraokeLyricsStore.swift` is an in-memory eight-track cache, not durable offline storage. Persist both flattened line lyrics and richer syllable timing, when available.
- No local audio replacement engine was established by the inspected paths. Existing seek/observer hooks do not themselves synchronize queue, lock screen, duration and playback state with an independent player.

## Proposed implementation experiment

Keep the existing Spotify player screen as the goal. First implement a feature-gated local playback adapter for one user-provided audio file, associated with a Spotify track ID. Route play/pause/seek and progress through this adapter while suppressing the remote audio path. Restore remote playback on exit. Verify that UI and audio agree before adding download providers.

Store audio, artwork, metadata, plain/line/syllable lyrics and timing offset in Application Support, not purgeable caches. Mark a track downloaded only after validating and atomically committing its assets. Handle audio-ready/lyrics-missing separately. Test after process termination and in airplane mode, including the Spotify library being unavailable offline.

Source matching must distinguish album/live/remix/clean/explicit versions; artist/title similarity alone is insufficient. Use ISRC where supplied, duration and version labels; ambiguous matches need selection. Synced lyrics must match the actual chosen recording.

## Sources to evaluate

| Source/tool | Purpose | Constraint / current evidence |
|---|---|---|
| spotDL | Spotify metadata to matching audio | Project describes YouTube matching; not a universal Spotify audio downloader. |
| yt-dlp | Extractor infrastructure for YouTube, SoundCloud, Bandcamp, Audius, Internet Archive and others | Supported-site listing does not guarantee current extraction or search. Download availability and permissions vary per item. Requires per-provider tests. |
| Jamendo API | Search and explicit downloadable audio | `audiodownload_allowed` and `audiodownload` support permitted downloads. Requires client ID; catalogue differs from Spotify. |
| SoundCloud API | Search and playback/source metadata | Registered application and OAuth required; streaming access does not establish permission for durable offline downloads. |
| Audius API | Additional catalogue candidate | API identified; download eligibility and matching remain unverified. |
| User library / direct authorized URLs | Reliable initial local-file test | No automatic coverage of Spotify catalogue. |
| LRCLIB and existing Eevee lyric providers | Text and timing | Availability varies. Existing repository adapters can be reused behind durable storage; provider and caching conditions require review. |

A resolver on a Mac/server can run extractor tools and return a chosen audio asset; the phone must retain downloaded assets so playback never depends on that server. A phone-only resolver avoids an always-on server but increases packaging and maintenance complexity. Neither approach guarantees every Spotify recording.

## Build and verification boundary

`xcrun --sdk iphoneos --show-sdk-path` fails: no iPhone SDK. No Xcode installation found during setup. The tweak requires Theos/Orion, iPhone SDK, EeveeSwiftProtobuf and IPA injection; its Makefile additionally compiles a Metal shader. Docker does not provide Apple's iOS simulator.

Run the upstream host-only HookSourceAudit separately. Passing it checks source invariants, not runtime selector compatibility or local playback. Full validation needs an iPhone build and installation through the already-working SideStore workflow. Do not replace the user's working IPA until a separately identifiable experiment is ready.

## References

- https://github.com/SideloadLabs/EeveeSpotifyReincarnated
- https://github.com/spotDL/spotify-downloader
- https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md
- https://developer.jamendo.com/v3.0/tracks
- https://developers.soundcloud.com/docs/api/guide
- https://docs.audius.co/api/
- https://lrclib.net/docs

Verification result: upstream `Tests/HookSourceAudit/main.swift` executed on the Mac and reported `Hook source audit regression tests passed` (exit 0). No iOS runtime test performed.
