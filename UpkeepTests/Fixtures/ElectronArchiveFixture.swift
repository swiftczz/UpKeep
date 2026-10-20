import Foundation

enum ElectronArchiveFixture {
    static func write(
        files: [String: Data], additionalEntries: [String: [String: Any]] = [:], to url: URL
    ) throws {
        var tree: [String: Any] = ["files": [String: Any]()]
        var payload = Data()
        for name in files.keys.sorted() {
            let data = files[name]!
            insert(["size": data.count, "offset": String(payload.count)], at: name, into: &tree)
            payload.append(data)
        }
        for (name, entry) in additionalEntries {
            insert(entry, at: name, into: &tree)
        }
        let header = try JSONSerialization.data(withJSONObject: tree)
        let padding = (4 - header.count % 4) % 4
        let pickleSize = header.count + padding + 8
        var archive = Data()
        for value in [4, pickleSize, pickleSize - 4, header.count] {
            var word = UInt32(value).littleEndian
            withUnsafeBytes(of: &word) { archive.append(contentsOf: $0) }
        }
        archive.append(header)
        archive.append(Data(repeating: 0, count: padding))
        archive.append(payload)
        try archive.write(to: url)
    }

    private static func insert(
        _ entry: [String: Any], at path: String, into tree: inout [String: Any]
    ) {
        insert(entry, path.split(separator: "/").map(String.init)[...], into: &tree)
    }

    private static func insert(
        _ entry: [String: Any], _ path: ArraySlice<String>, into node: inout [String: Any]
    ) {
        let name = path.first!
        var children = node["files"] as? [String: Any] ?? [:]
        if path.count == 1 {
            children[name] = entry
        } else {
            var child = children[name] as? [String: Any] ?? [:]
            insert(entry, path.dropFirst(), into: &child)
            children[name] = child
        }
        node["files"] = children
    }
}
