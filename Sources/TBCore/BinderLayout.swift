import Foundation

// The folders a brand-new binder starts with. One layout serves every entity type unless a
// type is given its own. The layouts are kept on this Mac and edited in the app's settings;
// a trial balance that is rolled forward takes last year's folders instead.

public struct BinderFolder: Equatable, Sendable {
    public var name: String
    public var children: [BinderFolder]

    public init(_ name: String, _ children: [BinderFolder] = []) {
        self.name = name
        self.children = children
    }
}

public struct BinderLayout: Equatable, Sendable {
    public var folders: [BinderFolder]

    public init(folders: [BinderFolder] = []) {
        self.folders = folders
    }

    /// The layout the app ships with.
    public static let standard = BinderLayout(folders: [
        BinderFolder("0000 Binder Notes"),
        BinderFolder("2000 Client Financials"),
        BinderFolder("3000 Standard Workpapers"),
        BinderFolder("3050 Additional Workpapers"),
        BinderFolder("4000 Support"),
        BinderFolder("5000 Permanent Files", [
            BinderFolder("5010 PY Tax Returns"),
            BinderFolder("5020 Entity Formation Documents"),
            BinderFolder("5030 Tax Resolution & Notices"),
        ]),
    ])

    // MARK: As an outline

    /// Reads a layout typed as an outline: one folder per line, a folder inside another indented
    /// under it (a tab, or four spaces, per level). Blank lines are ignored.
    public init(outline: String) {
        struct Line { var depth: Int; var name: String }
        var lines: [Line] = []
        for raw in outline.components(separatedBy: .newlines) {
            let name = raw.trimmed
            guard !name.isEmpty else { continue }
            var columns = 0
            for ch in raw {
                if ch == "\t" { columns += 4 } else if ch == " " { columns += 1 } else { break }
            }
            lines.append(Line(depth: (columns + 1) / 4, name: name))
        }
        // A line can sit at most one level deeper than the line before it.
        var previous = -1
        for i in lines.indices {
            lines[i].depth = min(lines[i].depth, previous + 1)
            previous = lines[i].depth
        }
        func build(_ start: Int, _ depth: Int) -> (folders: [BinderFolder], next: Int) {
            var out: [BinderFolder] = []
            var i = start
            while i < lines.count, lines[i].depth >= depth {
                let inner = build(i + 1, depth + 1)
                out.append(BinderFolder(lines[i].name, inner.folders))
                i = inner.next
            }
            return (out, i)
        }
        self.folders = build(0, 0).folders
    }

    public var outline: String {
        var out: [String] = []
        func walk(_ list: [BinderFolder], _ depth: Int) {
            for f in list {
                out.append(String(repeating: "    ", count: depth) + f.name)
                walk(f.children, depth + 1)
            }
        }
        walk(folders, 0)
        return out.joined(separator: "\n")
    }

    /// Every folder's path, parents before children.
    public var paths: [String] {
        var out: [String] = []
        func walk(_ list: [BinderFolder], _ parent: String) {
            for f in list {
                let path = parent.isEmpty ? f.name : parent + "/" + f.name
                out.append(path)
                walk(f.children, path)
            }
        }
        walk(folders, "")
        return out
    }

    /// What would go wrong if this layout were used, in plain lines. Empty when it is fine.
    public func problems() -> [String] {
        var out: [String] = []
        var numbers: [String: String] = [:]
        func walk(_ list: [BinderFolder]) {
            var seen = Set<String>()
            for f in list {
                if f.name.contains("/") || f.name.contains(":") { out.append("“\(f.name)” has a “/” or “:” in it, which a folder name can't.") }
                if f.name.hasPrefix(".") { out.append("“\(f.name)” starts with a full stop, which would hide the folder.") }
                if !seen.insert(f.name.lowercased()).inserted { out.append("“\(f.name)” is there twice in the same place.") }
                if let index = BinderIndex.parse(f.name, isFolder: true).index {
                    if let other = numbers[index.text] { out.append("\(index.text) is the number of both “\(other)” and “\(f.name)”.") }
                    numbers[index.text] = f.name
                }
                walk(f.children)
            }
        }
        walk(folders)
        return out
    }

    /// Makes the folders inside `root`. Folders that are already there are left as they are.
    /// Returns how many were made.
    @discardableResult
    public func create(in root: URL) throws -> Int {
        let fm = FileManager.default
        var made = 0
        for path in paths {
            let url = root.appendingPathComponent(path, isDirectory: true)
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                made += 1
            } catch {
                throw TBError("Couldn't make the folder “\(path)”: \(error.localizedDescription)")
            }
        }
        return made
    }

    // MARK: JSON

    static func json(_ folders: [BinderFolder]) -> JSONValue {
        .array(folders.map { f in
            var fields = [JSONField("name", .string(f.name))]
            if !f.children.isEmpty { fields.append(JSONField("folders", json(f.children))) }
            return .object(fields)
        })
    }

    static func folders(_ any: Any?) -> [BinderFolder] {
        ((any as? [Any]) ?? []).compactMap { item in
            guard let o = item as? [String: Any], let name = (o["name"] as? String)?.trimmed, !name.isEmpty else { return nil }
            return BinderFolder(name, folders(o["folders"]))
        }
    }
}

/// The binder layouts kept on this Mac: one for every entity type, and any a type has of its own.
public struct BinderLayouts: Equatable, Sendable {
    /// Used for every entity type that has no layout of its own.
    public var general: BinderLayout = .standard
    /// Layouts for particular entity types, by the type's name.
    public var byEntityType: [String: BinderLayout] = [:]

    public init() {}

    public func layout(forEntityType type: String) -> BinderLayout {
        let wanted = type.trimmed.lowercased()
        return byEntityType.first { $0.key.lowercased() == wanted }?.value ?? general
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TB Tool/Binder Layouts.json")
    }

    /// The layouts saved on this Mac, or the built-in one if none have been saved.
    public static func load(from url: URL = defaultURL) -> BinderLayouts {
        var out = BinderLayouts()
        guard let data = try? Data(contentsOf: url), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return out }
        if root["folders"] != nil { out.general = BinderLayout(folders: BinderLayout.folders(root["folders"])) }
        for (type, value) in (root["byEntityType"] as? [String: Any]) ?? [:] {
            out.byEntityType[type] = BinderLayout(folders: BinderLayout.folders((value as? [String: Any])?["folders"]))
        }
        return out
    }

    public func save(to url: URL = defaultURL) throws {
        var fields = [
            JSONField("fileType", .string("tb-tool-binder-layouts")),
            JSONField("schemaVersion", .int(1)),
            JSONField("folders", BinderLayout.json(general.folders)),
        ]
        if !byEntityType.isEmpty {
            fields.append(JSONField("byEntityType", .object(byEntityType.keys.sorted().map { type in
                JSONField(type, .object([JSONField("folders", BinderLayout.json(byEntityType[type]!.folders))]))
            })))
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(JSONValue.object(fields).render().utf8).write(to: url, options: .atomic)
        } catch {
            throw TBError("Couldn't save the binder layouts: \(error.localizedDescription)")
        }
    }
}
