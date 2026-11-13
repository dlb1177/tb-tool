import Foundation

/// A workpaper link on a journal entry whose file is no longer where the link says.
public struct BrokenLink: Equatable, Identifiable, Sendable {
    public var entryID: String
    public var entryNumber: String
    public var entryDescription: String
    public var reference: FileReference
    /// Files with the same name found under the trial balance's folder (paths relative to it).
    public var candidates: [String] = []

    public var id: String { entryID + "\u{1F}" + reference.path }
    /// Offered as a one-click fix only when exactly one file by that name was found.
    public var suggestion: String? { candidates.count == 1 ? candidates[0] : nil }
}

extension Engagement {

    /// Every linked file that can't be found on disk. Relative links resolve against `folder`.
    public func brokenLinks(folder: URL?) -> [BrokenLink] {
        var out: [BrokenLink] = []
        var known: [String: Bool] = [:]
        for je in journalEntries {
            for ref in je.references {
                let path = ref.url(engagementFolder: folder).path
                let exists = known[path] ?? FileManager.default.fileExists(atPath: path)
                known[path] = exists
                if !exists {
                    out.append(BrokenLink(entryID: je.id, entryNumber: je.number, entryDescription: je.description, reference: ref))
                }
            }
        }
        return out
    }

    /// Points every link at `oldPath` to `newPath` instead (in all entries). Returns how many changed.
    @discardableResult
    public mutating func relink(_ oldPath: String, to newPath: String) -> Int {
        var n = 0
        for i in journalEntries.indices {
            for j in journalEntries[i].references.indices where journalEntries[i].references[j].path == oldPath {
                // Don't leave the same file linked twice on one entry.
                if journalEntries[i].references.contains(where: { $0.path == newPath }) {
                    journalEntries[i].references[j].path = ""
                } else {
                    journalEntries[i].references[j].path = newPath
                }
                n += 1
            }
            journalEntries[i].references.removeAll { $0.path.isEmpty }
        }
        return n
    }

    /// Removes a link from one entry, or from every entry when `entryID` is nil. The file itself is never touched.
    @discardableResult
    public mutating func removeLink(_ path: String, entryID: String? = nil) -> Int {
        var n = 0
        for i in journalEntries.indices where entryID == nil || journalEntries[i].id == entryID {
            let before = journalEntries[i].references.count
            journalEntries[i].references.removeAll { $0.path == path }
            n += before - journalEntries[i].references.count
        }
        return n
    }
}

public enum LinkFinder {

    /// Where to start looking for a file that has gone missing: the folder the link last pointed
    /// into, or — if that folder is gone too — the nearest folder above it that still exists.
    public static func lastKnownFolder(for reference: FileReference, folder: URL?) -> URL? {
        var dir = reference.url(engagementFolder: folder).standardizedFileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return folder
    }

    /// File names (lowercased) under a folder mapped to their paths relative to it. Hidden files,
    /// app bundles and the backups folder are skipped; the walk stops after `limit` files.
    public static func index(folder: URL, limit: Int = 50_000) -> [String: [String]] {
        var out: [String: [String]] = [:]
        let base = folder.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        var seen = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == "TB Backups" || name == ".build" {
                walker.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            out[name.lowercased(), default: []].append(String(path.dropFirst(prefix.count)))
            seen += 1
            if seen >= limit { break }
        }
        return out
    }

    /// Fills in where each broken link's file might have gone: same file name, anywhere under the folder.
    public static func withCandidates(_ links: [BrokenLink], folder: URL?) -> [BrokenLink] {
        guard let folder, !links.isEmpty else { return links }
        let names = index(folder: folder)
        return links.map { link in
            var l = link
            l.candidates = (names[link.reference.fileName.lowercased()] ?? []).sorted()
            return l
        }
    }

    /// When one file has been found again, the other broken links that sat in the same old folder
    /// and exist under the same name in the new folder: old path → new path.
    public static func siblings(of oldPath: String, movedTo newPath: String, among links: [BrokenLink], folder: URL?) -> [String: String] {
        let oldDir = (oldPath as NSString).deletingLastPathComponent
        let newDir = (newPath as NSString).deletingLastPathComponent
        guard oldDir != newDir else { return [:] }
        var out: [String: String] = [:]
        for link in links where link.reference.path != oldPath {
            let p = link.reference.path
            guard (p as NSString).deletingLastPathComponent == oldDir else { continue }
            let moved = newDir.isEmpty ? link.reference.fileName : (newDir as NSString).appendingPathComponent(link.reference.fileName)
            if FileManager.default.fileExists(atPath: FileReference(path: moved).url(engagementFolder: folder).path) {
                out[p] = moved
            }
        }
        return out
    }
}
