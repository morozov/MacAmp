import Foundation

enum PlaylistOrdering: CaseIterable, Sendable {
    case title
    case filename
    case pathAndFilename
    case reverse
    case randomize

    var menuTitle: String {
        switch self {
        case .title: "Sort list by title"
        case .filename: "Sort list by filename"
        case .pathAndFilename: "Sort list by path and filename"
        case .reverse: "Reverse list"
        case .randomize: "Randomize list"
        }
    }

    func compare(_ lhs: Track, _ rhs: Track) -> ComparisonResult {
        switch self {
        case .title:
            return Self.compareText(lhs.playlistTitle, rhs.playlistTitle, localized: true)
        case .filename, .pathAndFilename:
            if lhs.url.isFileURL != rhs.url.isFileURL {
                return lhs.url.isFileURL ? .orderedAscending : .orderedDescending
            }
            if !lhs.url.isFileURL {
                return Self.compareText(lhs.url.absoluteString, rhs.url.absoluteString, localized: false)
            }
            if self == .pathAndFilename {
                let directories = Self.compareText(
                    lhs.url.deletingLastPathComponent().path, rhs.url.deletingLastPathComponent().path, localized: false
                )
                if directories != .orderedSame { return directories }
            }
            return Self.compareText(lhs.url.lastPathComponent, rhs.url.lastPathComponent, localized: false)
        case .reverse, .randomize:
            return .orderedSame
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .decimalNumber }
    }

    private static func compareText(_ lhs: String, _ rhs: String, localized: Bool) -> ComparisonResult {
        var left = lhs[...]
        var right = rhs[...]
        while let firstLeft = left.first, let firstRight = right.first {
            let leftIsDigit = isDigit(firstLeft)
            let rightIsDigit = isDigit(firstRight)
            if leftIsDigit != rightIsDigit { return leftIsDigit ? .orderedAscending : .orderedDescending }
            let result: ComparisonResult
            if leftIsDigit {
                let leftRun = left.prefix(while: isDigit)
                let rightRun = right.prefix(while: isDigit)
                let leftDigits = leftRun.compactMap(\.wholeNumberValue).drop(while: { $0 == 0 })
                let rightDigits = rightRun.compactMap(\.wholeNumberValue).drop(while: { $0 == 0 })
                if leftDigits.count != rightDigits.count {
                    result = leftDigits.count < rightDigits.count ? .orderedAscending : .orderedDescending
                } else if leftDigits.elementsEqual(rightDigits) {
                    result = .orderedSame
                } else {
                    result = leftDigits.lexicographicallyPrecedes(rightDigits) ? .orderedAscending : .orderedDescending
                }
                left = left.dropFirst(leftRun.count)
                right = right.dropFirst(rightRun.count)
            } else if localized {
                let leftRun = left.prefix { !isDigit($0) }
                let rightRun = right.prefix { !isDigit($0) }
                result = String(leftRun).compare(
                    String(rightRun), options: [.caseInsensitive, .widthInsensitive], locale: .current
                )
                left = left.dropFirst(leftRun.count)
                right = right.dropFirst(rightRun.count)
            } else {
                result = String(firstLeft).uppercased().compare(String(firstRight).uppercased(), options: .literal)
                left = left.dropFirst()
                right = right.dropFirst()
            }
            if result != .orderedSame { return result }
        }
        if left.isEmpty && right.isEmpty { return .orderedSame }
        return left.isEmpty ? .orderedAscending : .orderedDescending
    }
}
