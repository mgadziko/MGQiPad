import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    /// Offline rendering holds the decoded source and rendered stereo result in
    /// memory at once.  Keep its estimated peak below a level iPadOS can safely
    /// sustain; larger Music-library items fall back to Apple's player.
    private static let maximumOfflineRenderBytes = 800_000_000.0
    @Published var leftBands = EqualizerBand.frequencies.enumerated().map { EqualizerBand(id: $0.offset, frequency: $0.element, gain: 0) }
    @Published var rightBands = EqualizerBand.frequencies.enumerated().map { EqualizerBand(id: $0.offset, frequency: $0.element, gain: 0) }
    @Published private(set) var leftMasterVolume: Float = 1
    @Published private(set) var rightMasterVolume: Float = 1
    @Published var leftMasterLevel: Float = -72
    @Published var rightMasterLevel: Float = -72
    @Published var tandem = true { didSet { persistCurrentEQ() } }
    @Published var bypassed = false { didSet { persistCurrentEQ() } }
    @Published var isPlaying = false
    @Published var title = "Import a song to begin"
    @Published var albumTitle = ""
    @Published var artistName = ""
    @Published var status = "Ready"
    @Published var spectrum = Array(repeating: Float(-72), count: 31)
    @Published var librarySongs: [MPMediaItem] = []
    @Published var presets: [EQPreset] = []
    @Published var useAlbumArtist = UserDefaults.standard.bool(forKey: "mgq-use-album-artist") {
        didSet { UserDefaults.standard.set(useAlbumArtist, forKey: "mgq-use-album-artist") }
    }
    @Published var isLibraryPlaying = false
    @Published var usingMusicLibrary = false
    @Published var libraryUsesMGQ = false
    @Published var pendingLibrarySelection: LibraryPlaybackSelection?
    @Published var playbackElapsed: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    @Published var isPreparingTrack = false
    @Published var showPreparationProgress = false
    @Published var preparationProgress = 0.0
    @Published var preparationPhase = "Loading track"

    /// Apple-managed playback does not expose audio frames to this app, so its
    /// EQ faders must not imply that they can change the sound.
    var isEQAvailable: Bool { !usingMusicLibrary || libraryUsesMGQ }

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
    private var restoredMGQPlaybackPending = false
    private var nowPlayingObserver: NSObjectProtocol?
    private var scheduledSourceFrame: AVAudioFramePosition = 0
    private var progressTimer: Timer?
    /// Increments whenever scheduled MGQ playback is replaced or stopped.
    /// A completion from an old buffer must never advance the library queue.
    private var scheduledPlaybackID = 0
    private var preparationID = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
            let levels = Self.spectrumLevels(for: buffer)
            let masterLevels = Self.masterLevels(for: buffer)
            DispatchQueue.main.async {
                self?.spectrum = levels
                self?.leftMasterLevel = masterLevels.left
                self?.rightMasterLevel = masterLevels.right
            }
        }
        loadPresets()
        restoreCurrentEQ()
        configureLockScreenControls()
        savedLibraryQueue = loadPersistedLibraryQueue()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPlaybackProgress() }
        }
        if let progressTimer { RunLoop.main.add(progressTimer, forMode: .common) }
    }

    deinit {
        progressTimer?.invalidate()
        if let nowPlayingObserver { NotificationCenter.default.removeObserver(nowPlayingObserver) }
        if nowPlayingObserver != nil { musicPlayer.endGeneratingPlaybackNotifications() }
    }

    func importFile(_ url: URL) {
        usingMusicLibrary = false
        libraryUsesMGQ = false
        restoredMGQPlaybackPending = false
        loadAudioFile(url, title: url.deletingPathExtension().lastPathComponent, album: nil, artist: nil, autoplay: false)
    }

    func togglePlayback() {
        if isPlaying { pauseMGQPlayback() }
        else { playPrepared() }
    }

    func toggleTransport() {
        if usingMusicLibrary {
            if libraryUsesMGQ {
                if isPlaying { pauseMGQPlayback(status: "MGQ library playback paused") }
                else { playPrepared() }
            } else if restoredMGQPlaybackPending {
                restoredMGQPlaybackPending = false
                libraryUsesMGQ = true
                loadCurrentMGQLibraryTrack()
            } else if isLibraryPlaying { refreshPlaybackProgress(); musicPlayer.pause(); isLibraryPlaying = false; status = "Music library paused" }
            else { musicPlayer.play(); isLibraryPlaying = true; status = "Playing through Apple’s player — MGQ EQ and Spectrum Analyzer are unavailable for this track." }
        } else {
            if isPlaying { pauseMGQPlayback(status: "Paused") } else { playPrepared() }
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

    func setGain(channel: EQChannel, id: Int, gain: Float) {
        let value = min(12, max(-12, (gain * 2).rounded() / 2))
        if channel == .left { leftBands[id].gain = value } else { rightBands[id].gain = value }
        if tandem { if channel == .left { rightBands[id].gain = value } else { leftBands[id].gain = value } }
    }

    func setMasterVolume(channel: EQChannel, volume: Float) {
        let clampedVolume = min(1, max(0, volume))
        if channel == .left { leftMasterVolume = clampedVolume }
        else { rightMasterVolume = clampedVolume }
    }

    func commitMasterVolumeChange() {
        persistCurrentEQ()
        rebuildKeepingPlayhead()
    }

    /// Apply the latest slider values while retaining the current song position.
    func commitEQChange() {
        persistCurrentEQ()
        rebuildKeepingPlayhead()
    }

    func update(channel: EQChannel, id: Int, gain: Float) {
        setGain(channel: channel, id: id, gain: gain)
        commitEQChange()
    }

    func reset() { leftBands.indices.forEach { leftBands[$0].gain = 0; rightBands[$0].gain = 0 }; commitEQChange() }

    func refreshEQ() { rebuildKeepingPlayhead() }

    func seek(to time: TimeInterval) {
        let destination = min(max(0, time), playbackDuration)
        if libraryUsesMGQ || !usingMusicLibrary {
            guard let sourceBuffer else { return }
            let frame = AVAudioFramePosition(destination * sourceBuffer.format.sampleRate)
            let shouldResume = isPlaying
            rebuildPlayback(autoplay: shouldResume, startingAt: frame)
        } else {
            musicPlayer.currentPlaybackTime = destination
        }
        playbackElapsed = destination
    }

    func savePreset(named name: String) {
        presets.append(EQPreset(name: name, left: leftBands.map(\.gain), right: rightBands.map(\.gain)))
        persistPresets()
    }

    func deletePresets(ids: Set<UUID>) {
        presets.removeAll { ids.contains($0.id) }
        persistPresets()
    }

    func apply(_ preset: EQPreset) {
        for index in leftBands.indices { leftBands[index].gain = preset.left.indices.contains(index) ? preset.left[index] : 0; rightBands[index].gain = preset.right.indices.contains(index) ? preset.right[index] : 0 }
        commitEQChange()
    }

    func requestMusicLibrary() {
        beginMusicPlayerNotificationsIfNeeded()
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

    private func beginMusicPlayerNotificationsIfNeeded() {
        guard nowPlayingObserver == nil else { return }
        musicPlayer.beginGeneratingPlaybackNotifications()
        nowPlayingObserver = NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: musicPlayer, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncApplePlayerQueuePosition() }
        }
    }

    func albums(for artist: String) -> [LibraryAlbum] {
        Dictionary(grouping: librarySongs.filter { browserArtist(for: $0) == artist }, by: { $0.albumTitle ?? "Unknown Album" })
            .map { LibraryAlbum(artist: artist, title: $0.key, songs: sortedTracks($0.value)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var artists: [String] {
        Array(Set(librarySongs.map(browserArtist))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func browserArtist(for item: MPMediaItem) -> String {
        if useAlbumArtist,
           let albumArtist = item.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
           !albumArtist.isEmpty {
            return albumArtist
        }
        return item.artist ?? "Unknown Artist"
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
        restoredMGQPlaybackPending = false
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        libraryUsesMGQ = false
        restoredMGQPlaybackPending = false
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: selection.tracks))
        descriptor.startItem = selection.startItem
        musicPlayer.setQueue(with: descriptor)
        if autoplay { musicPlayer.play() } else { musicPlayer.pause() }
        usingMusicLibrary = true
        isLibraryPlaying = autoplay
        updateNowPlayingDetails(selection.startItem ?? selection.tracks.first)
        playbackElapsed = musicPlayer.currentPlaybackTime
        status = autoplay ? "Playing \(selection.tracks.count) tracks through Apple’s player — MGQ EQ and Spectrum Analyzer are unavailable for these tracks." : "Restored \(selection.tracks.count)-track Music queue — paused."
    }

    private func startMGQLibraryPlayback(_ selection: LibraryPlaybackSelection, autoplay: Bool) {
        musicPlayer.stop()
        usingMusicLibrary = true
        libraryUsesMGQ = true
        restoredMGQPlaybackPending = false
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
        loadAudioFile(url, title: item.title ?? "Music library track", album: item.albumTitle, artist: item.artist, autoplay: autoplay) { [weak self] success in
            guard let self, !success else { return }
            self.startAppleMusicPlayback(LibraryPlaybackSelection(title: item.title ?? "Music library track", tracks: self.mgqLibraryQueue, startItem: item), autoplay: autoplay)
        }
    }

    private func loadAudioFile(_ url: URL, title: String, album: String?, artist: String?, autoplay: Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        preparationID &+= 1
        let loadID = preparationID
        isPreparingTrack = true
        showPreparationProgress = false
        preparationProgress = 0
        preparationPhase = "Loading \(title)"
        let left = bypassed ? Array(repeating: Float.zero, count: EqualizerBand.frequencies.count) : leftBands.map(\.gain)
        let right = bypassed ? Array(repeating: Float.zero, count: EqualizerBand.frequencies.count) : rightBands.map(\.gain)
        let leftMaster = leftMasterVolume
        let rightMaster = rightMasterVolume
        let maximumOfflineRenderBytes = Self.maximumOfflineRenderBytes
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.preparationID == loadID, self.isPreparingTrack else { return }
            self.showPreparationProgress = true
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
            let file = try AVAudioFile(forReading: url)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: max(1, min(2, file.processingFormat.channelCount)), interleaved: false),
                  file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
            // The source buffer plus the always-stereo rendered buffer, with a
            // small working allowance.  A 112-minute stereo track exceeds this
            // by several gigabytes and can otherwise be terminated by iPadOS.
            let estimatedPeakBytes = Double(file.length) * Double(Int(format.channelCount) + 2) * Double(MemoryLayout<Float>.size) * 1.25
            guard estimatedPeakBytes <= maximumOfflineRenderBytes,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw OfflineRenderError.trackTooLarge }
            buffer.frameLength = AVAudioFrameCount(file.length)
            var framesRead = 0
            while framesRead < Int(file.length) {
                let count = min(65_536, Int(file.length) - framesRead)
                guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw CocoaError(.fileReadCorruptFile) }
                try file.read(into: chunk, frameCount: AVAudioFrameCount(count))
                guard chunk.frameLength > 0, let from = chunk.floatChannelData, let to = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
                for channel in 0..<Int(format.channelCount) { to[channel].advanced(by: framesRead).update(from: from[channel], count: Int(chunk.frameLength)) }
                framesRead += Int(chunk.frameLength)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.preparationID == loadID else { return }
                    self.preparationProgress = Double(framesRead) / Double(file.length) * 0.7
                }
            }
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            DispatchQueue.main.async { [weak self] in guard let self, self.preparationID == loadID else { return }; self.preparationPhase = "Applying MGQ EQ"; self.preparationProgress = 0.72 }
            let rendered = StereoEQRenderer().render(buffer, left: left, right: right, leftVolume: leftMaster, rightVolume: rightMaster, frequencies: EqualizerBand.frequencies)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.preparationID == loadID else { return }
                self.sourceBuffer = buffer; self.preparedBuffer = rendered
                self.playbackDuration = Double(buffer.frameLength) / buffer.format.sampleRate; self.playbackElapsed = 0
                self.title = title; self.albumTitle = album ?? ""; self.artistName = artist ?? ""
                self.status = autoplay ? "Processing Music library track through MGQ EQ and spectrum analyzer" : "Loaded — ready to process through MGQ"
                self.schedulePreparedPlayback(autoplay: autoplay, sourceFrame: 0)
                self.preparationProgress = 1; self.isPreparingTrack = false; self.showPreparationProgress = false
                completion(true)
            }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.preparationID == loadID else { return }
                    self.isPreparingTrack = false; self.showPreparationProgress = false
                    self.status = "Could not open this audio file through MGQ: \(error.localizedDescription)"; completion(false)
                }
            }
        }
    }

    private enum OfflineRenderError: LocalizedError {
        case trackTooLarge

        var errorDescription: String? {
            "This track is too large for MGQ's offline EQ renderer. It will play through Apple's player without MGQ EQ or the spectrum analyzer."
        }
    }

    private func sortedTracks(_ songs: [MPMediaItem]) -> [MPMediaItem] {
        songs.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.albumTrackNumber != $1.albumTrackNumber { return $0.albumTrackNumber < $1.albumTrackNumber }
            return ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
        }
    }

    private func rebuildKeepingPlayhead() {
        let shouldResume = isPlaying
        let frame = shouldResume ? currentPlaybackFrame() : 0
        rebuildPlayback(autoplay: shouldResume, startingAt: frame)
    }

    private func currentPlaybackFrame() -> AVAudioFramePosition {
        guard let sourceBuffer,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return scheduledSourceFrame }
        let renderedFrames = AVAudioFramePosition(
            Double(playerTime.sampleTime) * sourceBuffer.format.sampleRate / playerTime.sampleRate
        )
        let finalFrame = AVAudioFramePosition(sourceBuffer.frameLength) - 1
        return min(max(0, scheduledSourceFrame + renderedFrames), max(0, finalFrame))
    }

    private func refreshPlaybackProgress() {
        if libraryUsesMGQ || (!usingMusicLibrary && sourceBuffer != nil) {
            guard let sourceBuffer else { return }
            playbackDuration = Double(sourceBuffer.frameLength) / sourceBuffer.format.sampleRate
            playbackElapsed = min(playbackDuration, Double(currentPlaybackFrame()) / sourceBuffer.format.sampleRate)
        } else if usingMusicLibrary, let item = musicPlayer.nowPlayingItem {
            playbackDuration = item.playbackDuration
            playbackElapsed = min(playbackDuration, max(0, musicPlayer.currentPlaybackTime))
        }
    }

    private func rebuildPlayback(autoplay: Bool, startingAt sourceFrame: AVAudioFramePosition = 0) {
        guard let sourceBuffer else { return }
        let left = leftBands.map(\.gain), right = rightBands.map(\.gain)
        // The player node feeds a stereo mixer.  It must always receive a
        // stereo buffer, including while EQ is bypassed.  Scheduling a mono
        // library buffer directly causes AVAudioPlayerNode to abort with a
        // channel-format mismatch.
        preparedBuffer = renderer.render(
            sourceBuffer,
            startingAt: sourceFrame,
            left: bypassed ? Array(repeating: 0, count: EqualizerBand.frequencies.count) : left,
            right: bypassed ? Array(repeating: 0, count: EqualizerBand.frequencies.count) : right,
            leftVolume: leftMasterVolume,
            rightVolume: rightMasterVolume,
            frequencies: EqualizerBand.frequencies
        )
        schedulePreparedPlayback(autoplay: autoplay, sourceFrame: sourceFrame)
    }

    private func schedulePreparedPlayback(autoplay: Bool, sourceFrame: AVAudioFramePosition) {
        cancelMGQPlayback()
        let playbackID = scheduledPlaybackID
        scheduledSourceFrame = sourceFrame
        if let preparedBuffer {
            updateSpectrum(preparedBuffer)
            player.scheduleBuffer(preparedBuffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduledPlaybackID == playbackID, self.isPlaying else { return }
                if self.libraryUsesMGQ, self.mgqLibraryQueueIndex + 1 < self.mgqLibraryQueue.count {
                    self.mgqLibraryQueueIndex += 1
                    self.persistLibraryQueue()
                    self.loadCurrentMGQLibraryTrack()
                } else if self.queuedAfterImportedAudio.isEmpty {
                    self.isPlaying = false
                    self.status = self.libraryUsesMGQ ? "MGQ Music library queue finished" : "Imported audio finished"
                    self.updateLockScreenNowPlaying()
                } else {
                    self.startLibraryPlayback(self.queuedAfterImportedAudio.removeFirst())
                }
            }
            }
        }
        if autoplay { playPrepared() }
        else { updateLockScreenNowPlaying() }
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
            updateLockScreenNowPlaying()
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

    private func pauseMGQPlayback(status: String? = nil) {
        refreshPlaybackProgress()
        player.pause()
        isPlaying = false
        if let status { self.status = status }
        updateLockScreenNowPlaying()
    }

    private func configureLockScreenControls() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true

        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrepared() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseMGQPlayback() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggleTransport() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousTrack() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextTrack() }
            return .success
        }
    }

    private func updateLockScreenNowPlaying() {
        let isMGQPlayback = libraryUsesMGQ || (!usingMusicLibrary && preparedBuffer != nil)
        guard isMGQPlayback, playbackDuration > 0 else {
            if !usingMusicLibrary { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: playbackDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if !albumTitle.isEmpty { info[MPMediaItemPropertyAlbumTitle] = albumTitle }
        if !artistName.isEmpty { info[MPMediaItemPropertyArtist] = artistName }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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

    nonisolated private static func masterLevels(for buffer: AVAudioPCMBuffer) -> (left: Float, right: Float) {
        guard let channels = buffer.floatChannelData else { return (-72, -72) }
        let frameCount = min(Int(buffer.frameLength), 4_096)
        guard frameCount > 0 else { return (-72, -72) }

        func level(for channel: Int) -> Float {
            var sumOfSquares: Float = 0
            for index in 0..<frameCount {
                let sample = channels[channel][index]
                sumOfSquares += sample * sample
            }
            let rms = sqrt(sumOfSquares / Float(frameCount))
            return max(-72, min(12, 20 * log10(max(rms, 0.000_001))))
        }

        let left = level(for: 0)
        let right = level(for: min(1, Int(buffer.format.channelCount - 1)))
        return (left, right)
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
        usingMusicLibrary = true
        isLibraryPlaying = false
        isPlaying = false
        libraryUsesMGQ = false
        restoredMGQPlaybackPending = tracks.allSatisfy { canProcessWithMGQ($0) }
        updateNowPlayingDetails(currentTrack)
        if !restoredMGQPlaybackPending {
            let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: tracks))
            descriptor.startItem = currentTrack
            musicPlayer.setQueue(with: descriptor)
            musicPlayer.pause()
        }
        status = "Restored \(tracks.count)-track Music queue — paused."
        return true
    }

    private func syncApplePlayerQueuePosition() {
        guard usingMusicLibrary, !libraryUsesMGQ,
              let item = musicPlayer.nowPlayingItem else { return }
        updateNowPlayingDetails(item)
        if let index = mgqLibraryQueue.firstIndex(where: { $0.persistentID == item.persistentID }) {
            mgqLibraryQueueIndex = index
            persistLibraryQueue()
        }
    }

    private func updateNowPlayingDetails(_ item: MPMediaItem?) {
        guard let item else { return }
        title = item.title ?? "Music library track"
        albumTitle = item.albumTitle ?? ""
        artistName = item.artist ?? ""
    }

    private struct CurrentEQSettings: Codable {
        var left: [Float]
        var right: [Float]
        var tandem: Bool
        var bypassed: Bool
        var leftMaster: Float?
        var rightMaster: Float?
    }

    private var currentEQURL: URL { URL.documentsDirectory.appending(path: "mgq-current-eq.json") }

    private func persistCurrentEQ() {
        let settings = CurrentEQSettings(left: leftBands.map(\.gain), right: rightBands.map(\.gain), tandem: tandem, bypassed: bypassed, leftMaster: leftMasterVolume, rightMaster: rightMasterVolume)
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
        leftMasterVolume = min(1, max(0, settings.leftMaster ?? 1))
        rightMasterVolume = min(1, max(0, settings.rightMaster ?? 1))
    }
}
