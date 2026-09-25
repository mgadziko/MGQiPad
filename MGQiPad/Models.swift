import Foundation
import MediaPlayer

enum EQChannel: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? "Left" : "Right" }
}

struct EqualizerBand: Identifiable, Hashable, Codable {
    let id: Int
    let frequency: Double
    var gain: Float

    static let frequencies: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000]

    var label: String {
        frequency >= 1_000 ? String(format: frequency.truncatingRemainder(dividingBy: 1_000) == 0 ? "%.0fk" : "%.1fk", frequency / 1_000) : String(format: frequency.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", frequency)
    }
}

struct EQPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var left: [Float]
    var right: [Float]
}

struct LibraryAlbum: Identifiable {
    let artist: String
    let title: String
    let songs: [MPMediaItem]
    var id: String { "\(artist)|\(title)" }
}

struct LibraryPlaybackSelection: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [MPMediaItem]
    let startItem: MPMediaItem?
}
