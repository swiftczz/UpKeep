import Foundation

/// Reads selected application files without extracting or executing an ASAR.
struct ElectronApplicationArchive {
  private let bundleRoot: URL
  private let archiveURL: URL
  private let header: [String: Any]
  private let dataOffset: UInt64
  private let archiveSize: UInt64

  init?(bundleURL: URL) {
    let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let archive = root.appendingPathComponent("Contents/Resources/app.asar")
      .resolvingSymlinksInPath().standardizedFileURL
    guard archive.path.hasPrefix(root.path + "/"),
      let size = try? archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      size.isRegularFile == true, let fileSize = size.fileSize, fileSize >= 16,
      let handle = try? FileHandle(forReadingFrom: archive)
    else { return nil }
    defer { try? handle.close() }
    guard let prefix = try? handle.read(upToCount: 16), prefix.count == 16 else { return nil }
    let bytes = Array(prefix)
    func word(_ index: Int) -> UInt64 {
      (0..<4).reduce(UInt64(0)) { $0 | UInt64(bytes[index * 4 + $1]) << ($1 * 8) }
    }
    let pickleSize = word(1)
    let jsonSize = word(3)
    guard word(0) == 4, pickleSize >= 8, pickleSize <= 16 * 1024 * 1024,
      jsonSize > 0, jsonSize <= pickleSize - 8,
      pickleSize - 8 - jsonSize <= 3, word(2) == pickleSize - 4,
      8 + pickleSize <= UInt64(fileSize),
      let data = try? handle.read(upToCount: Int(jsonSize)), data.count == Int(jsonSize),
      let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      header["files"] is [String: Any]
    else { return nil }
    bundleRoot = root
    archiveURL = archive
    self.header = header
    dataOffset = 8 + pickleSize
    archiveSize = UInt64(fileSize)
  }

  func data(for path: String, maximumBytes: Int) -> Data? {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, maximumBytes > 0,
      components.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
      })
    else { return nil }
    var entry = header
    for component in components {
      guard let files = entry["files"] as? [String: Any],
        let child = files[String(component)] as? [String: Any], child["link"] == nil
      else { return nil }
      entry = child
    }
    guard let size = entry["size"] as? Int, size >= 0, size <= maximumBytes else { return nil }
    if entry["unpacked"] as? Bool == true {
      let file = bundleRoot.appendingPathComponent("Contents/Resources/app.asar.unpacked")
        .appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
      guard file.path.hasPrefix(bundleRoot.path + "/"),
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true, values.fileSize == size,
        let handle = try? FileHandle(forReadingFrom: file)
      else { return nil }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: size), data.count == size else { return nil }
      return data
    }
    guard let rawOffset = entry["offset"] as? String, let offset = UInt64(rawOffset),
      offset <= archiveSize - dataOffset, UInt64(size) <= archiveSize - dataOffset - offset,
      let handle = try? FileHandle(forReadingFrom: archiveURL)
    else { return nil }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: dataOffset + offset)
      guard let data = try handle.read(upToCount: size) else { return nil }
      return data.count == size ? data : nil
    } catch { return nil }
  }
}
