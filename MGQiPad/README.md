# MGQ Player for iPad

An iPad music player for user-imported audio, with independent left/right 31-band graphic EQ, linked-channel mode, presets, and a processed-audio spectrum display.

## Audio sources

- **Imported audio files:** MGQ reads and renders these through its dual 31-band DSP before playback.
- **Music/iTunes library:** the app can request permission and list/play library items through Apple's media player. iPadOS does not give a third-party app the underlying Apple Music stream, so these tracks bypass MGQ's custom EQ. This is an explicit platform limitation, not a silent fallback.

For a production release, the next audio milestone is an AUv3 target so the same EQ can be loaded inside iPad DAW hosts.
