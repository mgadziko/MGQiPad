import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var leftBands = EqualizerBand.frequencies.enumerated().map { EqualizerBand(id: $0.offset, frequency: $0.element, gain: 0) }
    @Published var rightBands = EqualizerBand.frequencies.enumerated().map { EqualizerBand(id: $0.offset, frequency: $0.element, gain: 0) }
    @Published var tandem = true
    @Published var bypassed = false
    @Published var isPlaying = false
    @Published var title = "Import a song to begin"
    @Published var status = "Ready"
    @Published var spectrum = Array(repeating: Float(-72), count: 31)
    @Published var librarySongs: [MPMediaItem] = []
    @Published var presets: [EQPreset] = []
    @Published var isLibraryPlaying = false
    @Published var usingMusicLibrary = false
    @Published var pendingLibrarySelection: LibraryPlaybackSelection?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let renderer = StereoEQRenderer()
    private let musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    private var queuedAfterImportedAudio: [LibraryPlaybackSelection] = []
    private var sourceBuffer: AVAudioPCMBuffer?
    private var preparedBuffer: AVAudioPCMBuffer?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
            let levels = Self.spectrumLevels(for: buffer)
            DispatchQueue.main.async { self?.spectrum = levels }
        }
        loadPresets()
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: max(1, min(2, file.processingFormat.channelCount)), interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
            try file.read(into: buffer)
            sourceBuffer = buffer
            title = url.deletingPathExtension().lastPathComponent
            status = "Loaded — ready to process through MGQ"
            rebuildPlayback(autoplay: false)
        } catch { status = "Could not open this audio file: \(error.localizedDescription)" }
    }

    func togglePlayback() { isPlaying ? player.pause() : playPrepared() }

    func toggleTransport() {
        if usingMusicLibrary {
            if isLibraryPlaying { musicPlayer.pause(); isLibraryPlaying = false; status = "Music library paused" }
            else { musicPlayer.play(); isLibraryPlaying = true; status = "Playing Music library through Apple’s player — MGQ EQ is unavailable for this source." }
        } else {
            if isPlaying { player.pause(); isPlaying = false; status = "Paused" } else { playPrepared() }
        }
    }

    func previousTrack() { guard usingMusicLibrary else { return }; musicPlayer.skipToPreviousItem(); status = "Previous track" }
    func nextTrack() { guard usingMusicLibrary else { return }; musicPlayer.skipToNextItem(); status = "Next track" }

    func update(channel: EQChannel, id: Int, gain: Float) {
        let value = min(12, max(-12, (gain * 2).rounded() / 2))
        if channel == .left { leftBands[id].gain = value } else { rightBands[id].gain = value }
        if tandem { if channel == .left { rightBands[id].gain = value } else { leftBands[id].gain = value } }
        rebuildPlayback(autoplay: isPlaying)
    }

    func reset() { leftBands.indices.forEach { leftBands[$0].gain = 0; rightBands[$0].gain = 0 }; rebuildPlayback(autoplay: isPlaying) }

    func refreshEQ() { rebuildPlayback(autoplay: isPlaying) }

    func savePreset(named name: String) {
        presets.append(EQPreset(name: name, left: leftBands.map(\.gain), right: rightBands.map(\.gain)))
        persistPresets()
    }

    func apply(_ preset: EQPreset) {
        for index in leftBands.indices { leftBands[index].gain = preset.left.indices.contains(index) ? preset.left[index] : 0; rightBands[index].gain = preset.right.indices.contains(index) ? preset.right[index] : 0 }
        rebuildPlayback(autoplay: isPlaying)
    }

    func requestMusicLibrary() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized else { Task { @MainActor in self?.status = "Music Library permission was not granted." }; return }
            let songs = MPMediaQuery.songs().items ?? []
            Task { @MainActor in self?.librarySongs = songs; self?.status = "Found \(songs.count) Music library items. Apple Music playback bypasses custom EQ." }
        }
    }

    func albums(for artist: String) -> [LibraryAlbum] {
        Dictionary(grouping: librarySongs.filter { ($0.artist ?? "Unknown Artist") == artist }, by: { $0.albumTitle ?? "Unknown Album" })
            .map { LibraryAlbum(artist: artist, title: $0.key, songs: sortedTracks($0.value)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var artists: [String] {
        Array(Set(librarySongs.map { $0.artist ?? "Unknown Artist" })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func playAlbum(_ album: LibraryAlbum, startingWith song: MPMediaItem? = nil) {
        let tracks = sortedTracks(album.songs)
        guard !tracks.isEmpty else { return }
        requestLibraryPlayback(LibraryPlaybackSelection(title: "\(album.artist) — \(album.title)", tracks: tracks, startItem: song))
    }

    func playAllAlbums(for artist: String) {
        let tracks = albums(for: artist).flatMap(\.songs)
        guard !tracks.isEmpty else { return }
        requestLibraryPlayback(LibraryPlaybackSelection(title: "\(artist) — all albums", tracks: tracks, startItem: nil))
    }

    func playPendingSelectionNow() {
        guard let selection = pendingLibrarySelection else { return }
        pendingLibrarySelection = nil
        startLibraryPlayback(selection)
    }

    func queuePendingSelection() {
        guard let selection = pendingLibrarySelection else { return }
        pendingLibrarySelection = nil
        if usingMusicLibrary {
            musicPlayer.append(MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: selection.tracks)))
            status = "Added \(selection.title) to the end of the Music queue."
        } else {
            queuedAfterImportedAudio.append(selection)
            status = "Queued \(selection.title) after the imported audio finishes."
        }
    }

    func cancelPendingSelection() { pendingLibrarySelection = nil }

    private func requestLibraryPlayback(_ selection: LibraryPlaybackSelection) {
        if isPlaying || isLibraryPlaying { pendingLibrarySelection = selection }
        else { startLibraryPlayback(selection) }
    }

    private func startLibraryPlayback(_ selection: LibraryPlaybackSelection) {
        player.stop(); isPlaying = false
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: selection.tracks))
        descriptor.startItem = selection.startItem
        musicPlayer.setQueue(with: descriptor)
        musicPlayer.play()
        usingMusicLibrary = true
        isLibraryPlaying = true
        title = selection.title
        status = "Playing \(selection.tracks.count) tracks in the Music queue — MGQ EQ is unavailable for this source."
    }

    private func sortedTracks(_ songs: [MPMediaItem]) -> [MPMediaItem] {
        songs.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.albumTrackNumber != $1.albumTrackNumber { return $0.albumTrackNumber < $1.albumTrackNumber }
            return ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
        }
    }

    private func rebuildPlayback(autoplay: Bool) {
        guard let sourceBuffer else { return }
        player.stop()
        let left = leftBands.map(\.gain), right = rightBands.map(\.gain)
        preparedBuffer = bypassed ? sourceBuffer : renderer.render(sourceBuffer, left: left, right: right, frequencies: EqualizerBand.frequencies)
        if let preparedBuffer {
            updateSpectrum(preparedBuffer)
            player.scheduleBuffer(preparedBuffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.queuedAfterImportedAudio.isEmpty {
                        self.isPlaying = false
                        self.status = "Imported audio finished"
                    } else {
                        self.startLibraryPlayback(self.queuedAfterImportedAudio.removeFirst())
                    }
                }
            }
        }
        if autoplay { playPrepared() }
    }

    private func playPrepared() {
        guard preparedBuffer != nil else { status = "Import an audio file first."; return }
        do { if !engine.isRunning { try engine.start() }; player.play(); isPlaying = true; usingMusicLibrary = false; isLibraryPlaying = false; status = bypassed ? "Playing without EQ" : "Playing through dual 31-band MGQ EQ" } catch { status = "Audio engine error: \(error.localizedDescription)" }
    }

    private func updateSpectrum(_ buffer: AVAudioPCMBuffer) {
        spectrum = Self.spectrumLevels(for: buffer)
    }

    nonisolated private static func spectrumLevels(for buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return Array(repeating: -72, count: EqualizerBand.frequencies.count) }
        let count = min(Int(buffer.frameLength), 4_096)
        return EqualizerBand.frequencies.map { frequency in
            guard frequency < buffer.format.sampleRate / 2 else { return -72 }
            let coefficient = Float(2 * cos(2 * Double.pi * frequency / buffer.format.sampleRate))
            var q1: Float = 0, q2: Float = 0
            for index in 0..<count { let sample = (channels[0][index] + channels[min(1, Int(buffer.format.channelCount - 1))][index]) * 0.5; let q0 = coefficient * q1 - q2 + sample; q2 = q1; q1 = q0 }
            let db = 20 * log10(max(sqrt(q1 * q1 + q2 * q2 - coefficient * q1 * q2) / Float(max(count, 1)), 0.000_001))
            return max(-72, min(12, db + 30))
        }
    }

    private var presetURL: URL { URL.documentsDirectory.appending(path: "mgq-presets.json") }
    private func loadPresets() { presets = (try? JSONDecoder().decode([EQPreset].self, from: Data(contentsOf: presetURL))) ?? [] }
    private func persistPresets() { try? JSONEncoder().encode(presets).write(to: presetURL, options: .atomic) }
}
