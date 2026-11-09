import Foundation

/// Raw-byte document reads and atomic replacement, shared by the app and the
/// Quick Look extension. Snapshots compare by bytes (not canonical String
/// equality), and a replace can verify the disk still matches before writing.
public enum DocumentFileIO {
    public struct Snapshot: Equatable, Sendable {
        public let target: URL
        public let data: Data
        public let text: String

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target && lhs.data == rhs.data
        }
    }

    public static func read(_ url: URL) throws -> Snapshot {
        let target = url.resolvingSymlinksInPath()
        let data = try Data(contentsOf: target)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return Snapshot(target: target, data: data, text: text)
    }

    public static func replace(_ url: URL, text: String, expected: Snapshot? = nil, preserveBOM: Bool = false) throws -> Snapshot {
        let target = url.resolvingSymlinksInPath()
        if let expected, try read(url) != expected {
            throw CocoaError(.fileWriteFileExists)
        }
        let bom = (expected?.data.starts(with: [0xEF, 0xBB, 0xBF]) == true || preserveBOM)
            ? Data([0xEF, 0xBB, 0xBF]) : Data()
        let data = bom + Data(text.utf8)
        if FileManager.default.fileExists(atPath: target.path) {
            let replacementDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? FileManager.default.removeItem(at: replacementDirectory) }
            let temporary = replacementDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try data.write(to: target, options: .atomic)
        }
        return Snapshot(target: target, data: data, text: text)
    }
}
