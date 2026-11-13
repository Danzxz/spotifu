# Native integration validation — 2026-11-13

## Observed on this Mac

- Spotify 1.2.70.409 loaded Spicetify with theme modifications disabled.
- Download control exists in the native playbar; LocalFilesAPI available.
- The injected extension can access authenticated loopback `/library` (HTTP 200).
- Native Spotify indexed a synthesized tagged 2-second AAC/M4A file as a `spotify:local:` track with the expected album and duration. Probe removed afterwards.
- Automatic resolver downloaded Kevin MacLeod — Carefree from YouTube without a manual source picker. Actual audio duration 205.353 s for requested 205.2 s, file 3,355,487 bytes; authenticated `/audio` response byte-for-byte matches the tagged native-library file. Test library record removed afterwards.
- Portable Swift persistence/lyrics checks, 10 Python tests and desktop local-track matching checks pass. Shared Swift code builds with local Command Line Tools.

## Not established

- Native playback redirection preserving playlist queue, position and metadata.
- Offline lyrics rendered by the native desktop or iOS lyric interface.
- iOS cover button, Documents scanning and `spotify:local-files` route on the user's device.
- Updated Eevee IPA installation, signature validity after SideStore signing and coexistence with the existing installation.

The previous SwiftUI clients are prototypes and are not the requested deliverable. No SideStore release is published while these acceptance checks remain incomplete.
