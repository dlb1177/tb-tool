import Compression
import Foundation

/// One grid of cells as it appears in the source: a spreadsheet tab, or a whole text file.
/// Row and column positions match the source (row 0 is Excel row 1).
public struct RawSheet: Equatable, Sendable {
    public var name: String
    public var rows: [[String]]

    public init(name: String, rows: [[String]]) {
        self.name = name
        self.rows = rows
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

/// Reads trial balance sources into cells: Excel workbooks (.xlsx / .xlsm) directly, and
/// comma-, tab-, semicolon- or pipe-separated text (the separator is detected).
public enum SourceReader {
    public static let fileExtensions = ["xlsx", "xlsm", "csv", "tsv", "tab", "txt"]

    public static func read(url: URL) throws -> [RawSheet] {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "xls":
            throw TBError("\(name) is an older Excel (.xls) file. Open it in Excel and use Save As ▸ Excel Workbook (.xlsx), or copy the cells and use Paste Trial Balance.")
        case "numbers":
            throw TBError("\(name) is a Numbers file. In Numbers use File ▸ Export To ▸ Excel, or copy the cells and use Paste Trial Balance.")
        case "pdf":
            throw TBError("PDF trial balances can't be read. Ask for an Excel or CSV export, or copy the table out of the PDF and use Paste Trial Balance.")
        default:
            break
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TBError("Couldn't read \(name): \(error.localizedDescription)")
        }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return try XLSXReader.read(data, name: name)
        }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
            throw TBError("\(name) is an older Excel (.xls) file. Open it in Excel and Save As .xlsx.")
        }
        guard let text = decode(data) else { throw TBError("\(name) isn't a text or Excel file.") }
        return [RawSheet(name: name, rows: parseDelimited(text))]
    }

    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman)
    }

    /// Text in any common delimited layout, including cells copied out of Excel (tabs).
    public static func parseDelimited(_ text: String) -> [[String]] {
        TBImporter.parseCSV(text, separator: detectSeparator(text))
    }

    /// The separator that splits the most lines, counting only characters outside quotes.
    static func detectSeparator(_ text: String) -> Character {
        let candidates: [Character] = ["\t", ",", ";", "|"]
        var lines = 0
        var linesWith = [Character: Int](), totals = [Character: Int]()
        var inQuotes = false
        var seenThisLine = Set<Character>()
        for ch in text.prefix(40_000) {
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes && (ch == "\n" || ch == "\r" || ch == "\r\n") {
                if !seenThisLine.isEmpty { lines += 1 }
                for c in seenThisLine { linesWith[c, default: 0] += 1 }
                seenThisLine = []
                if lines >= 60 { break }
                continue
            }
            if !inQuotes && candidates.contains(ch) {
                seenThisLine.insert(ch)
                totals[ch, default: 0] += 1
            }
        }
        for c in seenThisLine { linesWith[c, default: 0] += 1 }
        return candidates.max { a, b in
            let la = linesWith[a] ?? 0, lb = linesWith[b] ?? 0
            if la != lb { return la < lb }
            return (totals[a] ?? 0) < (totals[b] ?? 0)
        }.flatMap { (linesWith[$0] ?? 0) > 0 ? $0 : nil } ?? ","
    }
}

// MARK: - Excel

/// What a journal entry's reference to a workbook can point at: one of its tabs, and cells on it.
public enum WorkbookTabs {

    /// The names of a workbook's tabs, in the order Excel shows them. Nil when they can't be
    /// read: the file isn't there, or it is in the older .xls or the binary .xlsb format.
    public static func names(of url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let zip = try? ZipReader(data),
              let workbook = zip.entry("xl/workbook.xml") else { return nil }
        let names = WorkbookParser.parse(workbook).map(\.0)
        return names.isEmpty ? nil : names
    }

    /// Cells as typed, tidied to what Excel expects: "b4" → "B4", "$B$4 : d10" → "B4:D10",
    /// "B:D", "4:10", and several areas with commas. Nil when it isn't a cell reference.
    public static func cells(_ typed: String) -> String? {
        let text = typed.uppercased().filter { $0 != "$" && !$0.isWhitespace }
        guard !text.isEmpty else { return "" }
        enum Kind { case cell, column, row }
        func kind(_ s: Substring) -> Kind? {
            let letters = s.prefix { $0 >= "A" && $0 <= "Z" }
            let digits = s.dropFirst(letters.count)
            guard digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), letters.count <= 3, digits.count <= 7 else { return nil }
            if !digits.isEmpty, Int(digits) == 0 { return nil }
            if letters.isEmpty { return digits.isEmpty ? nil : .row }
            return digits.isEmpty ? .column : .cell
        }
        for area in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = area.split(separator: ":", omittingEmptySubsequences: false)
            guard ends.count == 1 || ends.count == 2, let first = kind(ends[0]) else { return nil }
            if ends.count == 1 {
                guard first == .cell else { return nil }
            } else {
                guard kind(ends[1]) == first else { return nil }
            }
        }
        return text
    }
}

enum XLSXReader {
    static func read(_ data: Data, name: String) throws -> [RawSheet] {
        let zip: ZipReader
        do {
            zip = try ZipReader(data)
        } catch {
            throw TBError("\(name) looks like an Excel file but couldn't be opened (\(error.localizedDescription)).")
        }
        guard let workbook = zip.entry("xl/workbook.xml") else {
            throw TBError("\(name) isn't an Excel workbook.")
        }
        let shared = zip.entry("xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        let rels = zip.entry("xl/_rels/workbook.xml.rels").map(RelationshipsParser.parse) ?? [:]
        var sheets: [RawSheet] = []
        for (sheetName, rid) in WorkbookParser.parse(workbook) {
            guard let target = rels[rid] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let xml = zip.entry(path) else { continue }
            sheets.append(RawSheet(name: sheetName, rows: SheetParser.parse(xml, shared: shared)))
        }
        guard !sheets.isEmpty else { throw TBError("\(name) has no worksheets that can be read.") }
        return sheets
    }

    /// Excel stores numbers as doubles ("1234.5600000000001", "1.5E-2"). Bring them back to
    /// what the person saw: at most 6 decimals, no trailing zeros, no exponent.
    static func normalizeNumber(_ v: String) -> String {
        guard let d = Double(v), d.isFinite else { return v }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func columnIndex(_ ref: String) -> (col: Int, row: Int)? {
        var col = 0, row = 0, sawLetter = false
        for ch in ref.uppercased() {
            if let a = ch.asciiValue, a >= 65, a <= 90 {
                col = col * 26 + Int(a - 64)
                sawLetter = true
            } else if let a = ch.asciiValue, a >= 48, a <= 57 {
                row = row * 10 + Int(a - 48)
            }
        }
        guard sawLetter, row > 0 else { return nil }
        return (col - 1, row - 1)
    }
}

private func localName(_ element: String) -> String {
    element.split(separator: ":").last.map(String.init) ?? element
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inT = false, inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch localName(name) {
        case "si": current = ""
        case "t": inT = true
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT && !inPhonetic { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "si": strings.append(current)
        case "t": inT = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(String, String)] = []

    static func parse(_ data: Data) -> [(String, String)] {
        let p = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.sheets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard localName(name) == "sheet", let sheetName = attributes["name"] else { return }
        if let rid = attributes.first(where: { $0.key == "r:id" || $0.key.hasSuffix(":id") })?.value {
            sheets.append((sheetName, rid))
        }
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let p = RelationshipsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.targets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if localName(name) == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    var cells: [Int: [Int: String]] = [:]
    var maxRow = -1
    private var rowIndex = -1
    private var colIndex = -1
    private var cellType = ""
    private var value = ""
    private var inValue = false, inInline = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let p = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        guard p.maxRow >= 0 else { return [] }
        let lastRow = min(p.maxRow, 200_000)
        return (0...lastRow).map { r in
            guard let row = p.cells[r], let maxCol = row.keys.max() else { return [] }
            return (0...maxCol).map { row[$0] ?? "" }
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch localName(name) {
        case "row":
            if let r = attributes["r"], let n = Int(r) { rowIndex = n - 1 } else { rowIndex += 1 }
            colIndex = -1
        case "c":
            if let ref = attributes["r"], let pos = XLSXReader.columnIndex(ref) {
                colIndex = pos.col
                rowIndex = pos.row
            } else {
                colIndex += 1
            }
            cellType = attributes["t"] ?? ""
            value = ""
        case "v": inValue = true
        case "is": inInline = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInline { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "v": inValue = false
        case "is": inInline = false
        case "c":
            var text: String
            switch cellType {
            case "s": text = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "inlineStr", "str", "e": text = value
            case "b": text = value == "1" ? "TRUE" : "FALSE"
            default: text = XLSXReader.normalizeNumber(value.trimmingCharacters(in: .whitespaces))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, rowIndex >= 0, colIndex >= 0, colIndex < 500 {
                cells[rowIndex, default: [:]][colIndex] = text
                maxRow = max(maxRow, rowIndex)
            }
        default: break
        }
    }
}

/// Reads entries out of a zip archive (stored or deflated), which is all an .xlsx needs.
struct ZipReader {
    private struct Entry {
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var offset: Int
    }

    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw TBError("file too short") }
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 65_557)
        while i >= floor {
            if u32(i) == 0x0605_4B50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw TBError("no zip directory") }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { throw TBError("damaged zip directory") }
            let nameLength = Int(u16(p + 28)), extraLength = Int(u16(p + 30)), commentLength = Int(u16(p + 32))
            guard p + 46 + nameLength <= bytes.count else { throw TBError("damaged zip directory") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: u16(p + 10), compressedSize: Int(u32(p + 20)), size: Int(u32(p + 24)), offset: Int(u32(p + 42)))
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    func entry(_ name: String) -> Data? {
        let found = entries[name] ?? entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        guard let e = found, e.offset + 30 <= bytes.count, u32(e.offset) == 0x0403_4B50 else { return nil }
        let start = e.offset + 30 + Int(u16(e.offset + 26)) + Int(u16(e.offset + 28))
        guard start + e.compressedSize <= bytes.count else { return nil }
        let slice = Array(bytes[start..<(start + e.compressedSize)])
        switch e.method {
        case 0: return Data(slice)
        case 8: return ZipReader.inflate(slice, size: e.size)
        default: return nil
        }
    }

    static func inflate(_ src: [UInt8], size: Int) -> Data? {
        if size == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == size ? Data(dst) : nil
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
}

// MARK: - Saved layouts

/// A column layout remembered from an earlier import, recognized again by its header row.
public struct ImportProfile: Codable, Equatable, Sendable {
    public var signature: String
    public var roles: [ColumnRole]
    public var sign: SignConvention
    public var savedAt: String
    /// Nil in layouts saved before this was a choice: numbers are split out.
    public var splitNumbers: Bool?

    public init(signature: String, roles: [ColumnRole], sign: SignConvention, splitNumbers: Bool = true) {
        self.signature = signature
        self.roles = roles
        self.sign = sign
        self.savedAt = Timestamp.now()
        self.splitNumbers = splitNumbers
    }
}

public enum ImportProfiles {
    /// Kept per Mac user, so any trial balance file benefits.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TB Tool", isDirectory: true).appendingPathComponent("import-layouts.json")
    }

    public static func load(_ url: URL = defaultURL) -> [ImportProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ImportProfile].self, from: data)) ?? []
    }

    /// Adds or replaces the layout for this header, keeping the 200 most recent.
    @discardableResult
    public static func remember(_ mapping: ImportMapping, header: [String], to url: URL = defaultURL) -> [ImportProfile] {
        let sig = signature(header)
        var all = load(url)
        guard !sig.isEmpty else { return all }
        all.removeAll { $0.signature == sig }
        all.insert(ImportProfile(signature: sig, roles: mapping.roles, sign: mapping.sign, splitNumbers: mapping.splitNumbers), at: 0)
        all = Array(all.prefix(200))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(all).write(to: url, options: .atomic)
        } catch {}
        return all
    }

    /// The header row reduced to its shape: lowercased, spaces collapsed, digit runs replaced by
    /// "#" so a date in a heading ("Dec 31, 26") still matches next year.
    public static func signature(_ row: [String]) -> String {
        var cells = row.map { cell -> String in
            var out = "", lastDigit = false, lastSpace = false
            for ch in cell.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                if ch.isNumber {
                    if !lastDigit { out.append("#") }
                    lastDigit = true
                    lastSpace = false
                } else if ch.isWhitespace {
                    if !lastSpace { out.append(" ") }
                    lastSpace = true
                    lastDigit = false
                } else {
                    out.append(ch)
                    lastDigit = false
                    lastSpace = false
                }
            }
            return out
        }
        while cells.last?.isEmpty == true { cells.removeLast() }
        guard cells.filter({ !$0.isEmpty && $0.contains(where: \.isLetter) }).count >= 2 else { return "" }
        return cells.joined(separator: "|")
    }
}
