import Foundation

/// Bounded URL extraction shared by binary updater detectors. Each protocol
/// decides whether a candidate is valid or can be reconstructed.
enum ExecutableUpdateURL {
    static let httpsNeedle = Data("https://".utf8)
    static let allowedCharacters = CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    static func find(
        endingAt needle: Range<Data.Index>, in data: Data,
        accepting candidate: (Data) -> URL?
    ) -> URL? {
        var search = needle.lowerBound
        var steps = 0
        while search > data.startIndex && steps < 400 {
            search = data.index(before: search)
            steps += 1
            guard data.distance(from: search, to: needle.lowerBound) >= httpsNeedle.count else {
                continue
            }
            let end = data.index(search, offsetBy: httpsNeedle.count)
            guard data[search..<end].elementsEqual(httpsNeedle) else { continue }
            if let url = candidate(Data(data[search..<needle.upperBound])) { return url }
        }
        return nil
    }
}
