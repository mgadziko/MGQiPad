# MGQ Player for iPad

MGQ Player is an iPad music player with a dual, 31-band graphic equalizer. It is designed for hands-on stereo adjustment: left and right channels may be linked for conventional EQ work or adjusted independently for channel matching, balance correction, and creative listening.

The app plays imported audio through its own AVAudioEngine signal path, so MGQ can apply EQ and show a live spectrum display. It can also browse an on-device Music library, with clear feedback when iPadOS does not permit audio processing for the chosen track.

## Highlights

- Two independent 31-band graphic EQs, spanning 20 Hz to 20 kHz.
- **Link L/R** for mirrored left/right adjustments, or unlink for separate channel control.
- Individual left and right **Out** controls, with post-processing level meters.
- **Bypass EQ** and **Reset** controls for quick A/B comparison.
- Per-band spectrum meters with an easy-to-read dB scale.
- Save named stereo EQ presets, load them later, and select several presets for deletion.
- Import local audio files for MGQ processing and playback.
- Browse the iPad Music library by Artist and Album; play an album, every album by an artist, or an individual track.
- Optional Album Artist browsing for libraries where that metadata is more useful.
- Persistent EQ state and Music-library queue. A restored queue is paused at launch.
- Playback timeline, previous/play-pause/next controls, background audio, and lock-screen transport controls.

## Audio sources and processing

### Imported audio

Imported audio is decoded and rendered through MGQ's stereo DSP path. The independent 31-band EQs, Out controls, and spectrum analyzer are available for these tracks.

### Music library and Apple Music

MGQ can request access to the on-device Music library and presents its Artist → Album → Track browser. Where a local, non-protected library track supplies an asset URL that MGQ can decode, it can be played through the MGQ path.

Protected Apple Music playback is different: iPadOS does not provide third-party apps with the underlying audio stream. Those tracks play through Apple's media player rather than MGQ, and custom EQ, output meters, and the spectrum analyzer are unavailable. The app makes this state explicit and disables its EQ controls instead of suggesting that processing is active.

## Using MGQ

1. Open **Music Library** to authorize access and browse Artists, Albums, and Tracks, or use the import control to choose a local audio file.
2. Use **Link L/R** when both channels should receive the same adjustment. Turn it off to tune them individually.
3. Move a frequency fader to adjust that band from −12 dB to +12 dB. Use **Out** to trim each channel's final level.
4. Use **Save EQ Preset** to name the current stereo setup. **Load EQ Preset** loads a preset when you tap its name; its checkboxes select presets for **Delete Checked Items**.
5. Lock the iPad while a supported MGQ track is playing to continue playback and use standard previous, play/pause, and next controls from the lock screen.

## Requirements

- Xcode 16 or newer
- iPadOS 17 or newer
- A provisioned physical iPad for Music-library testing; the Simulator has no access to a real device Music library

## Build and run

1. Open `MGQiPad.xcodeproj` in Xcode.
2. Select the **MGQiPad** scheme and a connected iPad.
3. Choose your Apple development team under **Signing & Capabilities** if Xcode requests one.
4. Build and run.
5. On the iPad, authorize Music-library access when prompted before opening **Music Library**.

## Project structure

- `MGQiPad/ContentView.swift` — SwiftUI interface and Music-library browser.
- `MGQiPad/PlayerViewModel.swift` — playback, queues, persistence, presets, and Music-library integration.
- `MGQiPad/StereoEQRenderer.swift` — offline stereo 31-band DSP renderer.
- `MGQiPad/Models.swift` — EQ bands, presets, and Music-library models.
- `MGQiPad/Info.plist` — Music-library usage description and background-audio declaration.

## Notes for contributors

This is an iPad-first project. Please test Music-library behavior on a physical provisioned iPad, keep protected-playback fallback states clear, and do not represent Apple's protected streams as processed audio.

There is currently no license file in this repository. Do not assume reuse rights until a license is added.
