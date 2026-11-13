# Spotifu implementation plan

Goal: fork Eevee with durable offline library and lyrics, shared macOS client, resolver and SideStore releases. User explicitly authorized implementation and publication.

1. Preserve upstream GPL notices; vendor iOS source in ios/EeveeSpotify; no proprietary IPA in git.
2. Test and implement Foundation-only durable library, identity validation, lyrics parsing and atomic file import.
3. Build shared SwiftUI downloads/player screen with AVAudioPlayer, lyrics, import and backend fetch; expose it inside Eevee and a Mac app.
4. Backend resolves multiple permitted audio sources, returns candidates for explicit selection, and caches audio/lyrics. Tests cover ambiguity and URL validation.
5. CI builds shared clients and Eevee tweak; source generator only lists real release IPA assets. Publish source and artifacts when built.
6. Verify host suites, CI, release links. Native Spotify audio/state substitution needs device validation; do not claim it works from static checks.

Review focus: wrong recording, corrupt/incomplete downloads, traversal, stale lyrics, offline after restart, duplicate audio engines.

User correction: default download must be ONE TAP with automatic multi-source search, verification, download and identity binding. No candidate picker in normal flow. Ambiguous/unverified candidates fail clearly rather than saving wrong audio. Advanced import is secondary.
