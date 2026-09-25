import MediaPlayer
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var importing = false
    @State private var presetName = ""
    @State private var showingSavePreset = false
    @State private var showingLibrary = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    EqualizerChannel(title: "Left channel", channel: .left)
                    EqualizerChannel(title: "Right channel", channel: .right)
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
                    Button { player.toggleTransport() } label: { Image(systemName: (player.usingMusicLibrary ? player.isLibraryPlaying : player.isPlaying) ? "pause.fill" : "play.fill") }
                    Button { player.nextTrack() } label: { Label("Next", systemImage: "forward.fill") }
                        .disabled(!player.usingMusicLibrary)
                    Menu {
                        Button("Authorize & Refresh Music Library") { player.requestMusicLibrary(); showingLibrary = true }
                        Button("Show Music Library") { showingLibrary = true }
                    } label: { Label("Music Library", systemImage: "music.note.list") }
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
        .sheet(isPresented: $showingLibrary) {
            NavigationStack { MusicLibraryView() }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text(player.title).font(.title2.weight(.semibold)); Text(player.status).foregroundStyle(.secondary) }
                Spacer()
                Button("Flat") { player.reset() }.buttonStyle(.bordered)
            }
            HStack(spacing: 18) {
                CompactCheckbox("Link L/R", isOn: $player.tandem)
                CompactCheckbox("Bypass EQ", isOn: Binding(get: { player.bypassed }, set: { player.bypassed = $0; player.refreshEQ() }))
                Text("±12 dB · ½ dB steps").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { showingSavePreset = true } label: { Label("Save EQ Preset", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
                Menu {
                    if player.presets.isEmpty { Text("No saved presets") }
                    ForEach(player.presets) { preset in Button(preset.name) { player.apply(preset) } }
                } label: { Label("Load EQ Preset", systemImage: "folder") }
                .buttonStyle(.bordered)
                Text(player.usingMusicLibrary ? "Spectrum analyzer unavailable for Apple Music playback" : "Spectrum analyzer enabled for imported audio")
                    .font(.caption)
                    .foregroundStyle(player.usingMusicLibrary ? Color.orange : Color.green)
            }
            Text("Imported audio is processed by MGQ. Apple Music/iTunes library tracks can be browsed below, but iPadOS does not permit another app to process their protected playback stream.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct EqualizerChannel: View {
    @EnvironmentObject private var player: PlayerViewModel
    let title: String
    let channel: EQChannel

    private var bands: [EqualizerBand] { channel == .left ? player.leftBands : player.rightBands }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text("Spectrum follows the processed file").font(.caption).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                let bandWidth = max(20, (geometry.size.width - 8) / CGFloat(bands.count))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(bands) { band in
                        VStack(spacing: 4) {
                            SpectrumMeter(level: player.spectrum[band.id]).frame(width: max(10, bandWidth - 8), height: 92)
                            VerticalSlider(value: Binding(get: { bands[band.id].gain }, set: { player.update(channel: channel, id: band.id, gain: $0) }))
                                .frame(width: bandWidth, height: 170)
                            Text(band.label).font(.system(size: bandWidth < 24 ? 6 : 8, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5).frame(width: bandWidth)
                        }
                        .frame(width: bandWidth)
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .frame(height: 292)
            .padding(.horizontal, 4)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct VerticalSlider: View {
    @Binding var value: Float
    @State private var dragStartValue: Float?
    var body: some View {
        GeometryReader { geometry in
            let y = CGFloat((12 - value) / 24) * geometry.size.height
            ZStack(alignment: .top) {
                ForEach(Array(stride(from: -12, through: 12, by: 3)), id: \.self) { gain in
                    Rectangle()
                        .fill(gain == 0 ? Color.primary.opacity(0.42) : Color.secondary.opacity(0.28))
                        .frame(width: geometry.size.width, height: gain == 0 ? 1.25 : 0.75)
                        .position(x: geometry.size.width / 2, y: (CGFloat(12 - gain) / 24) * geometry.size.height)
                }
                Capsule().fill(.secondary.opacity(0.25)).frame(width: 3)
                Capsule().fill(.tint).frame(width: 3, height: max(0, geometry.size.height - y)).offset(y: y)
                Circle().fill(.primary)
                    .frame(width: 18, height: 18)
                    .offset(y: min(max(0, y - 9), geometry.size.height - 18))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        if dragStartValue == nil { dragStartValue = value }
                        let start = dragStartValue ?? value
                        value = Float((min(12, max(-12, start - Float(gesture.translation.height / geometry.size.height) * 24)) * 2).rounded() / 2)
                    }.onEnded { _ in dragStartValue = nil })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityAdjustableAction { direction in
            value = min(12, max(-12, value + (direction == .increment ? 0.5 : -0.5)))
        }
        .accessibilityValue("\(value, specifier: "%.1f") decibels")
    }
}

private struct SpectrumMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geometry in
            let height = max(0, min(1, CGFloat((level + 60) / 72))) * geometry.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(.black.opacity(0.12))
                Capsule().fill(level > 0 ? .red : level > -12 ? .yellow : .green).frame(height: height)
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

private struct CompactCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(label)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct MusicLibraryView: View {
    @EnvironmentObject private var player: PlayerViewModel
    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                List(player.artists, id: \.self) { artist in
                    HStack {
                        NavigationLink { ArtistAlbumsView(artist: artist) } label: {
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
                        NavigationLink { AlbumTracksView(album: album) } label: {
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
