import MediaPlayer
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var importing = false
    @State private var presetName = ""
    @State private var showingSavePreset = false
    @State private var showingLoadPreset = false
    @State private var showingLibrary = false
    @State private var libraryPath: [MusicLibraryRoute] = []
    @State private var controlsReady = false

    var body: some View {
        Group {
            if controlsReady {
                mainContent
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("MGQ Player")
                        .font(.title.bold())
                    Text("Preparing dual 31-band EQ…")
                        .foregroundStyle(.secondary)
                    Text("Build \(buildStamp)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Contact: mgqipad@quantumpenguin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard !controlsReady else { return }
            try? await Task.sleep(for: .seconds(2))
            controlsReady = true
        }
        .overlay {
            preparationOverlay
        }
    }

    private var mainContent: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    EqualizerChannel(title: "Left Channel", channel: .left)
                    EqualizerChannel(title: "Right Channel", channel: .right)
                    Color.clear.frame(height: 80)
                }
                .padding()
            }
            .navigationTitle("Dual 31-band EQ")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import audio", systemImage: "folder.badge.plus") }
                    Button { player.previousTrack() } label: { Label("Previous", systemImage: "backward.fill") }
                        .disabled(!player.usingMusicLibrary)
                    Button { player.toggleTransport() } label: { Image(systemName: transportIsPlaying ? "pause.fill" : "play.fill") }
                    Button { player.nextTrack() } label: { Label("Next", systemImage: "forward.fill") }
                        .disabled(!player.usingMusicLibrary)
                    Button { player.requestMusicLibrary(); showingLibrary = true } label: { Label("Music Library", systemImage: "music.note.list") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result { player.importFile(url) }
        }
        .alert("Save preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { player.savePreset(named: name) }; presetName = "" }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Save the left and right 31-band settings together.") }
        .sheet(isPresented: $showingLoadPreset) {
            PresetPickerSheet()
                .environmentObject(player)
        }
        .sheet(isPresented: $showingLibrary) {
            NavigationStack(path: $libraryPath) {
                MusicLibraryView()
                    .navigationDestination(for: MusicLibraryRoute.self) { route in
                        switch route {
                        case let .artist(artist):
                            ArtistAlbumsView(artist: artist)
                        case let .album(artist, title):
                            if let album = player.albums(for: artist).first(where: { $0.title == title }) {
                                AlbumTracksView(album: album)
                            } else {
                                ContentUnavailableView("Album unavailable", systemImage: "music.note")
                            }
                        }
                    }
            }
                .environmentObject(player)
        }
        .alert("Playback is already in progress", isPresented: Binding(get: { player.pendingLibrarySelection != nil }, set: { if !$0 { player.cancelPendingSelection() } })) {
            Button("Play Now", role: .destructive) { player.playPendingSelectionNow() }
            Button("Add to Queue") { player.queuePendingSelection() }
            Button("Cancel", role: .cancel) { player.cancelPendingSelection() }
        } message: {
            Text("What would you like to do with \(player.pendingLibrarySelection?.title ?? "this selection")?")
        }
    }

    @ViewBuilder
    private var preparationOverlay: some View {
        if player.showPreparationProgress {
            VStack(spacing: 12) {
                Text("Preparing track")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(player.preparationPhase)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                if player.preparationPhase == "Applying MGQ EQ" {
                    ProgressView()
                        .tint(.white)
                    Text("Processing audio…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    ProgressView(value: player.preparationProgress)
                        .tint(.white)
                    Text("\(Int((player.preparationProgress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 16)
            .accessibilityAddTraits(.isModal)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title).font(.title2.weight(.semibold))
                    if !player.albumTitle.isEmpty { Text(player.albumTitle).font(.subheadline).foregroundStyle(.secondary) }
                    if !player.artistName.isEmpty { Text(player.artistName).font(.subheadline).foregroundStyle(.secondary) }
                    Text(player.status).font(.caption).foregroundStyle(.secondary)
                    PlaybackProgressBar()
                }
                Spacer()
                Button { player.requestMusicLibrary(); showingLibrary = true } label: {
                    Label("Music Library", systemImage: "music.note.list")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color(white: 0.22))
                .foregroundStyle(.white)
            }
            HStack(spacing: 18) {
                CompactCheckbox("Link L/R", isOn: $player.tandem, labelColor: .blue)
                CompactCheckbox("Bypass EQ", isOn: Binding(get: { player.bypassed }, set: { player.bypassed = $0; player.refreshEQ() }), labelColor: .blue)
                Button("Reset") { player.reset() }.buttonStyle(.bordered)
                Button { showingSavePreset = true } label: { Label("Save EQ Preset", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
                Button { showingLoadPreset = true } label: { Label("Load EQ Preset", systemImage: "folder") }
                    .buttonStyle(.bordered)
                Text(player.libraryUsesMGQ ? "Spectrum analyzer enabled for this Music library track" : player.usingMusicLibrary ? "Audio processing unavailable for protected Apple Music playback" : "Spectrum analyzer enabled for imported audio")
                    .font(.caption)
                    .foregroundStyle(player.usingMusicLibrary && !player.libraryUsesMGQ ? Color.orange : Color.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
        }
    }

    private var transportIsPlaying: Bool {
        player.libraryUsesMGQ ? player.isPlaying : (player.usingMusicLibrary ? player.isLibraryPlaying : player.isPlaying)
    }

    private var buildStamp: String {
        guard let url = Bundle.main.url(forResource: "BuildStamp", withExtension: "txt"),
              let stamp = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !stamp.isEmpty else { return "development" }
        return stamp
    }
}

private struct PlaybackProgressBar: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var isSeeking = false
    @State private var proposedTime: TimeInterval = 0

    private var duration: TimeInterval { max(0.01, player.playbackDuration) }
    private var displayedTime: TimeInterval { isSeeking ? proposedTime : player.playbackElapsed }

    var body: some View {
        VStack(spacing: 3) {
            Slider(
                value: Binding(
                    get: { min(duration, max(0, displayedTime)) },
                    set: { proposedTime = $0 }
                ),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        isSeeking = true
                        proposedTime = player.playbackElapsed
                    } else {
                        isSeeking = false
                        player.seek(to: proposedTime)
                    }
                }
            )
            .tint(.white)
            .disabled(player.playbackDuration <= 0)

            HStack {
                Text("−\(formatted(max(0, player.playbackDuration - displayedTime)))")
                Spacer()
                Text(formatted(player.playbackDuration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Track progress")
    }

    private func formatted(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct EqualizerChannel: View {
    @EnvironmentObject private var player: PlayerViewModel
    let title: String
    let channel: EQChannel

    private var bands: [EqualizerBand] { channel == .left ? player.leftBands : player.rightBands }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.blue)
            GeometryReader { geometry in
                let scaleWidth: CGFloat = 46
                let masterWidth: CGFloat = 42
                let gridWidth = geometry.size.width - scaleWidth - masterWidth
                let bandWidth = max(20, gridWidth / CGFloat(bands.count))
                HStack(alignment: .bottom, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(bands) { band in
                            VStack(spacing: 4) {
                                SpectrumMeter(level: player.spectrum[band.id]).frame(width: max(10, bandWidth - 8), height: 92)
                                VerticalSlider(
                                    value: Binding(get: { bands[band.id].gain }, set: { player.setGain(channel: channel, id: band.id, gain: $0) }),
                                    onEditingEnded: { player.commitEQChange() },
                                    isAvailable: player.isEQAvailable
                                )
                                    .frame(width: bandWidth, height: 170)
                                Text(band.label).font(.system(size: bandWidth < 24 ? 6 : 8, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5).frame(width: bandWidth)
                            }
                            .frame(width: bandWidth)
                        }
                    }
                    .frame(width: gridWidth, alignment: .leading)
                    VStack(spacing: 4) {
                        SpectrumScaleLabels()
                            .frame(height: 92)
                        EQScaleLabels()
                            .frame(height: 170)
                        Color.clear.frame(height: 10)
                    }
                    .frame(width: scaleWidth)
                    VStack(spacing: 4) {
                        SpectrumMeter(level: channel == .left ? player.leftMasterLevel : player.rightMasterLevel)
                            .frame(width: max(10, masterWidth - 8), height: 92)
                        MasterVolumeSlider(
                            value: Binding(
                                get: { channel == .left ? player.leftMasterVolume : player.rightMasterVolume },
                                set: { player.setMasterVolume(channel: channel, volume: $0) }
                            ),
                            isAvailable: player.isEQAvailable,
                            onEditingEnded: { player.commitMasterVolumeChange() }
                        )
                        .frame(width: masterWidth, height: 170)
                        Text("Out")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(player.isEQAvailable ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: masterWidth)
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .frame(height: 292)
            .padding(.horizontal, 4)
            .padding(.top, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct MasterVolumeSlider: View {
    @Binding var value: Float
    let isAvailable: Bool
    let onEditingEnded: () -> Void
    @State private var dragStartValue: Float?

    var body: some View {
        GeometryReader { geometry in
            let y = CGFloat(1 - value) * geometry.size.height
            let controlColor: Color = isAvailable ? .accentColor : .gray
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 6)
                Capsule()
                    .fill(controlColor)
                    .frame(width: 7, height: max(0, geometry.size.height - y))
                    .offset(y: y)
                Circle()
                    .fill(controlColor)
                    .frame(width: 20, height: 20)
                    .offset(y: min(max(0, y - 10), geometry.size.height - 20))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        if dragStartValue == nil { dragStartValue = value }
                        let start = dragStartValue ?? value
                        let heightFraction = Float(gesture.translation.height / max(geometry.size.height, 1))
                        value = min(1, max(0, start - heightFraction))
                    }.onEnded { _ in
                        dragStartValue = nil
                        onEditingEnded()
                    })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(isAvailable)
        }
        .accessibilityLabel("Master volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityHint(isAvailable ? "Adjust master output volume" : "Audio processing is unavailable for this track")
        .accessibilityAdjustableAction { direction in
            guard isAvailable else { return }
            value = min(1, max(0, value + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}

private struct SpectrumScaleLabels: View {
    private let values = [12, 0, -12, -24, -36, -48]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(values, id: \.self) { value in
                    let y = (CGFloat(12 - value) / 72) * geometry.size.height
                    Text(label(for: value))
                        .foregroundStyle(color(for: value))
                        .position(x: geometry.size.width / 2, y: y)
                }
            }
            .font(.system(size: 8, design: .monospaced).weight(.semibold))
        }
    }

    private func label(for value: Int) -> String {
        value > 0 ? "+\(value) dB" : "\(value) dB"
    }

    private func color(for value: Int) -> Color {
        if value >= 0 { return .red }
        return .green
    }
}

private struct EQScaleLabels: View {
    private let values = [12, 9, 6, 3, 0, -3, -6, -9, -12]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(values, id: \.self) { value in
                    let y = min(max(6, (CGFloat(12 - value) / 24) * geometry.size.height), geometry.size.height - 6)
                    Text(value == 0 ? "0 dB" : "\(value > 0 ? "+" : "−")\(abs(value)) dB")
                        .position(x: geometry.size.width / 2, y: y)
                }
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.blue)
        }
    }
}

private struct VerticalSlider: View {
    @Binding var value: Float
    let onEditingEnded: () -> Void
    let isAvailable: Bool
    @State private var dragStartValue: Float?
    var body: some View {
        GeometryReader { geometry in
            let y = CGFloat((12 - value) / 24) * geometry.size.height
            let controlColor: Color = isAvailable ? .accentColor : .gray
            ZStack(alignment: .top) {
                ForEach(Array(stride(from: -12, through: 12, by: 3)), id: \.self) { gain in
                    Rectangle()
                        .fill(gain == 0 ? Color.primary.opacity(0.42) : Color.secondary.opacity(0.28))
                        .frame(width: geometry.size.width, height: gain == 0 ? 1.25 : 0.75)
                        .position(x: geometry.size.width / 2, y: (CGFloat(12 - gain) / 24) * geometry.size.height)
                }
                Capsule().fill(.secondary.opacity(0.25)).frame(width: 3)
                Capsule().fill(controlColor).frame(width: 3, height: max(0, geometry.size.height - y)).offset(y: y)
                Circle().fill(isAvailable ? Color.primary : Color.gray)
                    .frame(width: 18, height: 18)
                    .offset(y: min(max(0, y - 9), geometry.size.height - 18))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        if dragStartValue == nil { dragStartValue = value }
                        let start = dragStartValue ?? value
                        let heightFraction = Float(gesture.translation.height / max(geometry.size.height, 1))
                        let proposedValue = start - heightFraction * 24
                        let clampedValue = min(Float(12), max(Float(-12), proposedValue))
                        value = (clampedValue * 2).rounded() / 2
                    }.onEnded { _ in dragStartValue = nil; onEditingEnded() })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(isAvailable)
        }
        .accessibilityAdjustableAction { direction in
            guard isAvailable else { return }
            value = min(12, max(-12, value + (direction == .increment ? 0.5 : -0.5)))
        }
        .accessibilityValue("\(value, specifier: "%.1f") decibels")
        .accessibilityHint(isAvailable ? "Adjust EQ gain" : "EQ is unavailable for this track")
    }
}

private struct SpectrumMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geometry in
            let height = max(0, min(1, CGFloat((level + 60) / 72))) * geometry.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(.black.opacity(0.12))
                Capsule().fill(level >= 0 ? .red : .green).frame(height: height)
                ForEach(Array(stride(from: -60, through: 12, by: 3)), id: \.self) { db in
                    Rectangle()
                        .fill(db == 0 ? Color.primary.opacity(0.5) : Color.secondary.opacity(0.34))
                        .frame(width: geometry.size.width, height: db == 0 ? 1 : 0.5)
                        .position(x: geometry.size.width / 2, y: (CGFloat(12 - db) / 72) * geometry.size.height)
                }
            }
        }
    }
}

private struct PresetPickerSheet: View {
    @EnvironmentObject private var player: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var checkedPresetIDs = Set<UUID>()

    var body: some View {
        NavigationStack {
            Group {
                if player.presets.isEmpty {
                    ContentUnavailableView("No Saved Presets", systemImage: "slider.horizontal.3", description: Text("Save an EQ setting from the main screen, then return here to load it."))
                } else {
                    List {
                        ForEach(player.presets) { preset in
                            HStack(spacing: 10) {
                                Button {
                                    toggle(preset.id)
                                } label: {
                                    Image(systemName: checkedPresetIDs.contains(preset.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(checkedPresetIDs.contains(preset.id) ? Color.blue : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Select \(preset.name)")
                                .accessibilityValue(checkedPresetIDs.contains(preset.id) ? "Selected" : "Not selected")

                                Button(preset.name) {
                                    player.apply(preset)
                                    dismiss()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Load EQ Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Delete Checked Items", role: .destructive) {
                    player.deletePresets(ids: checkedPresetIDs)
                    checkedPresetIDs.removeAll()
                }
                .buttonStyle(.bordered)
                .disabled(checkedPresetIDs.isEmpty)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }

    private func toggle(_ id: UUID) {
        if checkedPresetIDs.contains(id) {
            checkedPresetIDs.remove(id)
        } else {
            checkedPresetIDs.insert(id)
        }
    }
}

private struct CompactCheckbox: View {
    let label: String
    @Binding var isOn: Bool
    let labelColor: Color

    init(_ label: String, isOn: Binding<Bool>, labelColor: Color = .primary) {
        self.label = label
        _isOn = isOn
        self.labelColor = labelColor
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(label)
                    .foregroundStyle(labelColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private enum MusicLibraryRoute: Hashable {
    case artist(String)
    case album(artist: String, title: String)
}

private struct MusicLibraryView: View {
    @EnvironmentObject private var player: PlayerViewModel
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    CompactCheckbox("Use Album Artist", isOn: $player.useAlbumArtist)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.thinMaterial)

                HStack(spacing: 0) {
                    List(player.artists, id: \.self) { artist in
                        HStack {
                            NavigationLink(value: MusicLibraryRoute.artist(artist)) {
                                Label(artist, systemImage: "person.crop.circle")
                            }
                            Spacer()
                            Button { player.playAllAlbums(for: artist) } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play all albums by \(artist)")
                        }
                        .id(artist)
                    }
                    ArtistAlphabetIndex(artists: player.artists) { letter in
                        if let artist = player.artists.first(where: { indexLetter(for: $0) == letter }) {
                            withAnimation { proxy.scrollTo(artist, anchor: .top) }
                        }
                    }
                    .frame(width: 29)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .overlay { if player.librarySongs.isEmpty { ContentUnavailableView("No library artists", systemImage: "music.note.list", description: Text("Choose Read Music library and allow access.")) } }
        .navigationTitle("Artists")
    }

    private func indexLetter(for artist: String) -> String {
        let letter = String(artist.prefix(1)).uppercased()
        return letter.rangeOfCharacter(from: .letters) == nil ? "#" : letter
    }
}

private struct ArtistAlphabetIndex: View {
    let artists: [String]
    let select: (String) -> Void
    private let letters = ["#"] + (65...90).compactMap { UnicodeScalar($0).map(String.init) }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                let available = artists.contains { indexLetter(for: $0) == letter }
                Button(letter) { select(letter) }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(available ? Color.accentColor : Color.secondary.opacity(0.45))
                    .frame(width: 20, height: 16)
                    .disabled(!available)
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func indexLetter(for artist: String) -> String {
        let letter = String(artist.prefix(1)).uppercased()
        return letter.rangeOfCharacter(from: .letters) == nil ? "#" : letter
    }
}

private struct ArtistAlbumsView: View {
    @EnvironmentObject private var player: PlayerViewModel
    let artist: String

    var body: some View {
        List {
            Section {
                Button { player.playAllAlbums(for: artist) } label: {
                    Label("Play All Albums in Order", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Albums") {
                ForEach(player.albums(for: artist)) { album in
                    HStack {
                        NavigationLink(value: MusicLibraryRoute.album(artist: artist, title: album.title)) {
                            VStack(alignment: .leading) {
                                Text(album.title)
                                Text("\(album.songs.count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { player.playAlbum(album) } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Play album \(album.title)")
                    }
                }
            }
        }
        .navigationTitle(artist)
    }
}

private struct AlbumTracksView: View {
    @EnvironmentObject private var player: PlayerViewModel
    let album: LibraryAlbum

    var body: some View {
        List {
            Section {
                Button { player.playAlbum(album) } label: { Label("Play Album", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            }
            Section("Tracks") {
                ForEach(album.songs, id: \.persistentID) { song in
                    Button { player.playAlbum(album, startingWith: song) } label: {
                        HStack {
                            Text("\(song.discNumber > 1 ? "\(song.discNumber)-" : "")\(song.albumTrackNumber)").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                            Text(song.title ?? "Untitled")
                        }
                    }
                }
            }
        }
        .navigationTitle(album.title)
    }
}
