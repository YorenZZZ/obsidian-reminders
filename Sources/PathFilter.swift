import Foundation

/// Decides which vault files are synced, from a whitelist and a blacklist of
/// vault-relative folders or files.
///
/// - A non-empty whitelist wins: only files under its entries are synced and
///   the blacklist is otherwise ignored.
/// - An entry present in both lists counts as blacklisted.
/// - With an empty whitelist, everything except the blacklist is synced.
struct PathFilter {
    let include: [String]
    let exclude: [String]
    private let whitelistActive: Bool

    init(include: [String], exclude: [String]) {
        let blocked = Set(exclude.map(Self.normalize))
        let whitelist = include.map(Self.normalize).filter { !$0.isEmpty }
        self.include = whitelist.filter { !blocked.contains($0) }
        self.exclude = Array(blocked.filter { !$0.isEmpty })
        self.whitelistActive = !whitelist.isEmpty
    }

    init(includeText: String, excludeText: String) {
        self.init(include: Self.split(includeText), exclude: Self.split(excludeText))
    }

    /// Everything passes when both lists are empty.
    var isEmpty: Bool { !whitelistActive && exclude.isEmpty }

    func allows(_ relativePath: String) -> Bool {
        if whitelistActive { return include.contains { Self.matches(relativePath, $0) } }
        return !exclude.contains { Self.matches(relativePath, $0) }
    }

    /// Entries are separated by the Chinese enumeration comma 、; commas,
    /// semicolons and line breaks are accepted too.
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,，;；\n\r"))
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    static func join(_ entries: [String]) -> String { entries.joined(separator: "、") }

    static func normalize(_ entry: String) -> String {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("./") { s.removeFirst(2) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s
    }

    /// A folder entry covers everything below it; a file entry matches with or
    /// without its `.md` extension. Comparison ignores case, like APFS.
    private static func matches(_ path: String, _ entry: String) -> Bool {
        let p = path.lowercased(), e = entry.lowercased()
        return p == e || p == e + ".md" || p.hasPrefix(e + "/")
    }
}
