import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var leftBands = EqualizerBand.frequencies.enumerated().map { EqualizerBand(id: $0.offset, frequency: $0.element, gain: 0) }
    @Published var rightBands = EqualizerBand.frequencies.enumerated().map { EqualizerBand(id: $0.offset, frequency: $0.element, gain: 0) }
    @Published var tandem = true { didSet { persistCurrentEQ() } }
    @Published var bypassed = false { didSet { persistCurrentEQ() } }
    @Published var isPlaying = false
    @Published var title = "Import a song to begin"
    @Published var status = "Ready"
    @Published var spectrum = Array(repeating: Float(-72), count: 31)
    @Published var librarySongs: [MPMediaItem] = []
    @Published var presets: [EQPreset] = []
    @Published var isLibraryPlaying = false
    @Published var usingMusicLibrary = false
    @Published var libraryUsesMGQ = false
    @Published var pendingLibrarySelection: LibraryPlaybackSelection?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let renderer = StereoEQRenderer()
    private let musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    private var queuedAfterImportedAudio: [LibraryPlaybackSelection] = []
    private var mgqLibraryQueue: [MPMediaItem] = []
    private var mgqLibraryQueueIndex = 0
    private var sourceBuffer: AVAudioPCMBuffer?
    private var preparedBuffer: AVAudioPCMBuffer?
    private var savedLibraryQueue: PersistedLibraryQueue?
    private var nowPlayingObserver: NSObjectProtocol?
    /// Increments whenever scheduled MGQ playback is replaced or stopped.
    /// A completion from an old buffer must never advance the library queue.
    private var scheduledPlaybackID = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
            let levels = Self.spectrumLevels(for: buffer)
            DispatchQueue.main.async { self?.spectrum = levels }
        }
        loadPresets()
        restoreCurrentEQ()
        savedLibraryQueue = loadPersistedLibraryQueue()
        musicPlayer.beginGeneratingPlaybackNotifications()
        nowPlayingObserver = NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: musicPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncApplePlayerQueuePosition() }
        }
        if MPMediaLibrary.authorizationStatus() == .authorized {
            requestMusicLibrary()
        }
    }

    deinit {
        if let nowPlayingObserver { NotificationCenter.default.removeObserver(nowPlayingObserver) }
        musicPlayer.endGeneratingPlaybackNotifications()
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        usingMusicLibrary = false
        libraryUsesMGQ = false
        _ = loadAudioFile(url, title: url.deletingPathExtension().lastPathComponent, autoplay: false)
    }

    func togglePlayback() { isPlaying ? player.pause() : playPrepared() }

    func toggleTransport() {
        if usingMusicLibrary {
            if libraryUsesMGQ {
                if isPlaying { player.pause(); isPlaying = false; status = "MGQ library playback paused" }
                else { playPrepared() }
            } else if isLibraryPlaying { musicPlayer.pause(); isLibraryPlaying = false; status = "Music library paused" }
            else { musicPlayer.play(); isLibraryPlaying = true; status = "Playing through Apple’s player — MGQ EQ and Spectrum Analyzer are unavailable for this track." }
        } else {
            if isPlaying { player.pause(); isPlaying = false; status = "Paused" } else { playPrepared() }
        }
    }

    func previousTrack() {
        guard usingMusicLibrary else { return }
        guard mgqLibraryQueueIndex > 0 else { return }
        mgqLibraryQueueIndex -= 1
        persistLibraryQueue()
        if libraryUsesMGQ { loadCurrentMGQLibraryTrack() }
        else { musicPlayer.skipToPreviousItem(); status = "Previous track" }
    }

    func nextTrack() {
        guard usingMusicLibrary else { return }
        guard mgqLibraryQueueIndex + 1 < mgqLibraryQueue.count else { return }
        mgqLibraryQueueIndex += 1
        persistLibraryQueue()
        if libraryUsesMGQ { loadCurrentMGQLibraryTrack() }
        else { musicPlayer.skipToNextItem(); status = "Next track" }
    }

    func update(channel: EQChannel, id: Int, gain: Float) {
        let value = min(12, max(-12, (gain * 2).rounded() / 2))
        if channel == .left { leftBands[id].gain = value } else { rightBands[id].gain = value }
        if tandem { if channel == .left { rightBands[id].gain = value } else { leftBands[id].gain = value } }
        persistCurrentEQ()
        rebuildPlayback(autoplay: isPlaying)
    }

    func reset() { leftBands.indices.forEach { leftBands[$0].gain = 0; rightBands[$0].gain = 0 }; persistCurrentEQ(); rebuildPlayback(autoplay: isPlaying) }

    func refreshEQ() { rebuildPlayback(autoplay: isPlaying) }

    func savePreset(named name: String) {
        presets.append(EQPreset(name: name, left: leftBands.map(\.gain), right: rightBands.map(\.gain)))
        persistPresets()
    }

    func apply(_ preset: EQPreset) {
        for index in leftBands.indices { leftBands[index].gain = preset.left.indices.contains(index) ? preset.left[index] : 0; rightBands[index].gain = preset.right.indices.contains(index) ? preset.right[index] : 0 }
        persistCurrentEQ()
        rebuildPlayback(autoplay: isPlaying)
    }

    func requestMusicLibrary() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            guard status == .authorized else { Task { @MainActor in self?.status = "Music Library permission was not granted." }; return }
            let songs = MPMediaQuery.songs().items ?? []
            Task { @MainActor in
                guard let self else { return }
                self.librarySongs = songs
                if !self.restoreSavedLibraryQueue() {
                    self.status = "Found \(songs.count) Music library items. MGQ will process local, non-protected tracks."
                }
            }
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
            if libraryUsesMGQ {
                mgqLibraryQueue.append(contentsOf: selection.tracks)
                persistLibraryQueue()
                status = "Added \(selection.title) to the end of the MGQ queue."
            } else {
                musicPlayer.append(MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: selection.tracks)))
                mgqLibraryQueue.append(contentsOf: selection.tracks)
                persistLibraryQueue()
                status = "Added \(selection.title) to the end of the Music queue."
            }
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

    private func startLibraryPlayback(_ selection: LibraryPlaybackSelection, autoplay: Bool = true, restoringQueue: Bool = false) {
        if !restoringQueue {
            mgqLibraryQueue = selection.tracks
            mgqLibraryQueueIndex = selection.startItem.flatMap { item in selection.tracks.firstIndex(where: { $0.persistentID == item.persistentID }) } ?? 0
            persistLibraryQueue()
        }
        if selection.tracks.allSatisfy({ canProcessWithMGQ($0) }) {
            startMGQLibraryPlayback(selection, autoplay: autoplay)
        } else {
            startAppleMusicPlayback(selection, autoplay: autoplay)
        }
    }

    private func startAppleMusicPlayback(_ selection: LibraryPlaybackSelection, autoplay: Bool = true) {
        cancelMGQPlayback(); isPlaying = false
        libraryUsesMGQ = false
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: selection.tracks))
        descriptor.startItem = selection.startItem
        musicPlayer.setQueue(with: descriptor)
        if autoplay { musicPlayer.play() } else { musicPlayer.pause() }
        usingMusicLibrary = true
        isLibraryPlaying = autoplay
        title = selection.title
        status = autoplay ? "Playing \(selection.tracks.count) tracks through Apple’s player — MGQ EQ and Spectrum Analyzer are unavailable for these tracks." : "Restored \(selection.tracks.count)-track Music queue — paused."
    }

    private func startMGQLibraryPlayback(_ selection: LibraryPlaybackSelection, autoplay: Bool) {
        musicPlayer.stop()
        usingMusicLibrary = true
        libraryUsesMGQ = true
        isLibraryPlaying = false
        loadCurrentMGQLibraryTrack(autoplay: autoplay)
    }

    private func canProcessWithMGQ(_ item: MPMediaItem) -> Bool {
        !item.hasProtectedAsset && item.assetURL != nil && item.playbackDuration > 0
    }

    private func loadCurrentMGQLibraryTrack(autoplay: Bool = true) {
        guard mgqLibraryQueue.indices.contains(mgqLibraryQueueIndex) else { return }
        let item = mgqLibraryQueue[mgqLibraryQueueIndex]
        guard let url = item.assetURL else { return }
        cancelMGQPlayback()
        if !loadAudioFile(url, title: item.title ?? "Music library track", autoplay: autoplay) {
            startAppleMusicPlayback(LibraryPlaybackSelection(title: item.title ?? "Music library track", tracks: mgqLibraryQueue, startItem: item), autoplay: autoplay)
        }
    }

    @discardableResult
    private func loadAudioFile(_ url: URL, title: String, autoplay: Bool) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: max(1, min(2, file.processingFormat.channelCount)), interleaved: false),
                  file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            sourceBuffer = buffer
            self.title = title
            status = autoplay ? "Processing Music library track through MGQ EQ and spectrum analyzer" : "Loaded — ready to process through MGQ"
            rebuildPlayback(autoplay: autoplay)
            return true
        } catch {
            status = "Could not open this audio file through MGQ: \(error.localizedDescription)"
            return false
        }
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
        cancelMGQPlayback()
        let playbackID = scheduledPlaybackID
        let left = leftBands.map(\.gain), right = rightBands.map(\.gain)
        preparedBuffer = bypassed ? sourceBuffer : renderer.render(sourceBuffer, left: left, right: right, frequencies: EqualizerBand.frequencies)
        if let preparedBuffer {
            updateSpectrum(preparedBuffer)
            player.scheduleBuffer(preparedBuffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.scheduledPlaybackID == playbackID, self.isPlaying else { return }
                    if self.libraryUsesMGQ, self.mgqLibraryQueueIndex + 1 < self.mgqLibraryQueue.count {
                        self.mgqLibraryQueueIndex += 1
                        self.persistLibraryQueue()
                        self.loadCurrentMGQLibraryTrack()
                    } else if self.queuedAfterImportedAudio.isEmpty {
                        self.isPlaying = false
                        self.status = self.libraryUsesMGQ ? "MGQ Music library queue finished" : "Imported audio finished"
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
        do {
            try configurePlaybackAudioSession()
            if !engine.isRunning { try engine.start() }
            player.play()
            isPlaying = true
            isLibraryPlaying = false
            if libraryUsesMGQ {
                status = bypassed ? "Playing Music library track through MGQ without EQ" : "Playing Music library track through dual 31-band MGQ EQ"
            } else {
                usingMusicLibrary = false
                status = bypassed ? "Playing without EQ" : "Playing through dual 31-band MGQ EQ"
            }
        } catch {
            if libraryUsesMGQ, mgqLibraryQueue.indices.contains(mgqLibraryQueueIndex) {
                let item = mgqLibraryQueue[mgqLibraryQueueIndex]
                startAppleMusicPlayback(LibraryPlaybackSelection(title: item.title ?? "Music library track", tracks: mgqLibraryQueue, startItem: item))
            } else {
                status = "Audio engine error: \(error.localizedDescription)"
            }
        }
    }

    private func configurePlaybackAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private func cancelMGQPlayback() {
        scheduledPlaybackID &+= 1
        player.stop()
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

    private struct PersistedLibraryQueue: Codable {
        var itemIDs: [UInt64]
        var currentIndex: Int
    }

    private var libraryQueueURL: URL { URL.documentsDirectory.appending(path: "mgq-library-queue.json") }

    private func persistLibraryQueue() {
        guard !mgqLibraryQueue.isEmpty else { return }
        let queue = PersistedLibraryQueue(itemIDs: mgqLibraryQueue.map { UInt64($0.persistentID) }, currentIndex: mgqLibraryQueueIndex)
        try? JSONEncoder().encode(queue).write(to: libraryQueueURL, options: .atomic)
    }

    private func loadPersistedLibraryQueue() -> PersistedLibraryQueue? {
        try? JSONDecoder().decode(PersistedLibraryQueue.self, from: Data(contentsOf: libraryQueueURL))
    }

    @discardableResult
    private func restoreSavedLibraryQueue() -> Bool {
        guard let savedLibraryQueue else { return false }
        let itemsByID = Dictionary(uniqueKeysWithValues: librarySongs.map { (UInt64($0.persistentID), $0) })
        let tracks = savedLibraryQueue.itemIDs.compactMap { itemsByID[$0] }
        guard !tracks.isEmpty else {
            self.savedLibraryQueue = nil
            return false
        }
        let requestedIndex = min(max(0, savedLibraryQueue.currentIndex), savedLibraryQueue.itemIDs.count - 1)
        let requestedID = savedLibraryQueue.itemIDs[requestedIndex]
        let currentIndex = tracks.firstIndex { UInt64($0.persistentID) == requestedID } ?? 0
        let currentTrack = tracks[currentIndex]
        self.savedLibraryQueue = nil
        mgqLibraryQueue = tracks
        mgqLibraryQueueIndex = currentIndex
        persistLibraryQueue()
        startLibraryPlayback(LibraryPlaybackSelection(title: currentTrack.title ?? "Restored Music queue", tracks: tracks, startItem: currentTrack), autoplay: false, restoringQueue: true)
        status = "Restored \(tracks.count)-track Music queue — paused."
        return true
    }

    private func syncApplePlayerQueuePosition() {
        guard usingMusicLibrary, !libraryUsesMGQ,
              let item = musicPlayer.nowPlayingItem,
              let index = mgqLibraryQueue.firstIndex(where: { $0.persistentID == item.persistentID }) else { return }
        mgqLibraryQueueIndex = index
        persistLibraryQueue()
    }

    private struct CurrentEQSettings: Codable {
        var left: [Float]
        var right: [Float]
        var tandem: Bool
        var bypassed: Bool
    }

    private var currentEQURL: URL { URL.documentsDirectory.appending(path: "mgq-current-eq.json") }

    private func persistCurrentEQ() {
        let settings = CurrentEQSettings(left: leftBands.map(\.gain), right: rightBands.map(\.gain), tandem: tandem, bypassed: bypassed)
        try? JSONEncoder().encode(settings).write(to: currentEQURL, options: .atomic)
    }

    private func restoreCurrentEQ() {
        guard let settings = try? JSONDecoder().decode(CurrentEQSettings.self, from: Data(contentsOf: currentEQURL)) else { return }
        for index in leftBands.indices {
            leftBands[index].gain = settings.left.indices.contains(index) ? min(12, max(-12, settings.left[index])) : 0
            rightBands[index].gain = settings.right.indices.contains(index) ? min(12, max(-12, settings.right[index])) : 0
        }
        tandem = settings.tandem
        bypassed = settings.bypassed
    }
}
