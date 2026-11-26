import Foundation

struct PlaylistFileInfoSession {
    enum Advance {
        case waiting
        case show(Track)
        case close
    }

    enum Completion {
        case superseded
        case skip
        case reload(Track)
        case present(Track?)
    }

    private(set) var request = 0
    private(set) var isLoading = false
    private var selectedIDs: [UUID]?

    var isSelecting: Bool { selectedIDs != nil }
    var canFinish: Bool { !isSelecting || !isLoading }

    mutating func start(_ tracks: [Track]) {
        cancel()
        selectedIDs = tracks.map(\.id)
    }

    mutating func advance(in playlist: [Track]) -> Advance {
        guard !isLoading else { return .waiting }
        while let id = selectedIDs?.first {
            selectedIDs?.removeFirst()
            if let track = playlist.first(where: { $0.id == id }) { return .show(track) }
        }
        return .close
    }

    mutating func beginRequest() -> Int {
        request += 1
        isLoading = true
        return request
    }

    mutating func completeRequest(_ generation: Int, track: Track?, in playlist: [Track]) -> Completion {
        guard generation == request else { return .superseded }
        isLoading = false
        guard isSelecting, let track else { return .present(track) }
        guard let latest = playlist.first(where: { $0.id == track.id }) else { return .skip }
        if latest.url != track.url { return .reload(latest) }
        return .present(latest)
    }

    mutating func cancel() {
        request += 1
        isLoading = false
        selectedIDs = nil
    }
}
