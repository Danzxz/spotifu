import Foundation

struct LyricsSearchQuery: Hashable {
    var title: String
    var primaryArtist: String
    var spotifyTrackId: String
    var requestGeneration: UInt64? = nil
}

