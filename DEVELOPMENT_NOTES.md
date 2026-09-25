# MGQiPad development context — 2026-09-25

## Music library playback

- The Music Library UI presents Artist, Album, and track selections, including ordered artist/album playback and queueing.
- MGQ playback is used only when every selected item is non-protected, has an asset URL and a duration, and decodes to a non-empty PCM buffer.
- When MGQ cannot decode or start a library item, playback falls back to Apple's Music player. In that route, neither custom EQ nor the spectrum analyzer can receive the audio stream.
- Before MGQ playback, the app activates an `AVAudioSession` using the playback category. This is required for AVAudioEngine output to reach the iPad speakers.
- Replaced audio buffers are guarded by a playback generation ID. Never allow an old buffer-completion callback to advance the queue.

## Persistent state

- Current 31-band left/right settings, Link L/R, and Bypass EQ are stored in `mgq-current-eq.json` in the app Documents directory.
- Named presets are stored in `mgq-presets.json`.
- The Music-library queue is stored as persistent Media Library IDs plus the current position in `mgq-library-queue.json`.
- On launch, a saved Music-library queue is restored after Music Library authorization. It is deliberately paused; it must never begin playback automatically.

## Verification

- Build command: `xcodebuild -project MGQiPad.xcodeproj -scheme MGQiPad -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- Test library and audio behavior on a physical iPad. The Simulator does not provide a meaningful device Music-library test environment.
