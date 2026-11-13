import Foundation

/// Writes a report in each export format. Amounts are always plain signed numbers
/// (debits positive, credits negative) so the output can be summed or pivoted as-is.
public enum Exporter {

    /// With `heading`, a report's binder heading (client, title, year end…) sits above the column
    /// titles, one line each, followed by a blank line. Flat data tables never get one.
    public static func csv(_ t: ReportTable, heading: Bool = false) -> String {
        delimited(t, separator: ",", heading: heading) { field in
            if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
    }

    /// Tab-separated, for pasting straight into a spreadsheet.
    public static func tsv(_ t: ReportTable) -> String {
        delimited(t, separator: "\t", heading: false) { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    }

    /// The lines written above a report's columns.
    static func headingLines(_ t: ReportTable) -> [String] {
        if t.flat { return [] }
        return t.heading.isEmpty ? [t.title, t.subtitle].filter { !$0.isEmpty } : t.heading
    }

    private static func delimited(_ t: ReportTable, separator: String, heading: Bool, escape: (String) -> String) -> String {
        var lines: [String] = []
        if heading {
            let head = headingLines(t)
            lines += head.map(escape)
            if !head.isEmpty { lines.append("") }
        }
        lines.append(t.columns.map { escape($0.title) }.joined(separator: separator))
        for row in t.rows {
            lines.append(row.cells.map { cell -> String in
                switch cell {
                case .empty: return ""
                case .text(let s): return escape(s)
                case .money(let m): return m.plain
                }
            }.joined(separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An array of records keyed by column title. Subtotal and total rows are left out so the
    /// records can be aggregated without double counting.
    public static func jsonRecords(_ t: ReportTable) -> String {
        var titles: [String] = []
        for c in t.columns {
            var title = c.title, n = 2
            while titles.contains(title) {
                title = "\(c.title) \(n)"
                n += 1
            }
            titles.append(title)
        }
        let records: [JSONValue] = t.rows.filter { $0.style == .normal }.map { row in
            .object(zip(titles, zip(t.columns, row.cells)).map { title, pair in
                let (column, cell) = pair
                switch cell {
                case .empty: return JSONField(title, column.kind == .money ? .money(.zero) : .string(""))
                case .text(let s): return JSONField(title, .string(s))
                case .money(let m): return JSONField(title, .money(m))
                }
            })
        }
        return JSONValue.object([
            JSONField("report", .string(t.title)),
            JSONField("subtitle", .string(t.subtitle)),
            JSONField("heading", .array(headingLines(t).map { .string($0) })),
            JSONField("rows", .array(records)),
        ]).render()
    }

    public static func xlsx(_ tables: [ReportTable]) -> Data {
        XLSXWriter.workbook(tables)
    }
}

/// A minimal .xlsx writer: real numeric cells, bold headers and totals, frozen header rows,
/// one sheet per report. No dependencies — the zip container is written by hand (stored, no compression).
enum XLSXWriter {

    static func workbook(_ tables: [ReportTable]) -> Data {
        let names = sheetNames(tables)
        var files: [(String, String)] = []

        var types = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
        var sheetsXML = ""
        var rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for (i, name) in names.enumerated() {
            let n = i + 1
            types += #"<Override PartName="/xl/worksheets/sheet\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            sheetsXML += #"<sheet name="\#(esc(name))" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(n).xml"/>"#
        }
        types += "</Types>"
        rels += #"<Relationship Id="rId\#(names.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#

        files.append(("[Content_Types].xml", types))
        files.append(("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#))
        // The heading and column titles repeat at the top of every printed page.
        var printTitles = ""
        for (i, t) in tables.enumerated() {
            let quoted = "'" + names[i].replacingOccurrences(of: "'", with: "''") + "'"
            printTitles += #"<definedName name="_xlnm.Print_Titles" localSheetId="\#(i)">\#(esc(quoted))!$1:$\#(headerRow(t))</definedName>"#
        }
        files.append(("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(sheetsXML)</sheets><definedNames>\#(printTitles)</definedNames></workbook>"#))
        files.append(("xl/_rels/workbook.xml.rels", rels))
        files.append(("xl/styles.xml", styles))
        for (i, t) in tables.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", sheet(t)))
        }
        return Zip.archive(files.map { ($0.0, Data($0.1.utf8)) })
    }

    // Cell style indexes into cellXfs below.
    private static let sText = 0, sBold = 1, sMoney = 2, sMoneyBold = 3, sHeader = 4, sMoneyTotal = 5, sHeaderRight = 6, sBoldTop = 7, sClient = 8

    private static let styles = ##"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00_);\(#,##0.00\)"/></numFmts><fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="3"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color auto="1"/></bottom><diagonal/></border><border><left/><right/><top style="thin"><color auto="1"/></top><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="9"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/><xf numFmtId="164" fontId="1" fillId="0" borderId="2" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="2" xfId="0" applyFont="1" applyBorder="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"##

    /// The row the column titles sit on: row 1 for flat data, otherwise below the heading and a blank row.
    static func headerRow(_ t: ReportTable) -> Int {
        let head = Exporter.headingLines(t)
        return head.isEmpty ? 1 : head.count + 2
    }

    private static func sheet(_ t: ReportTable) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        let head = Exporter.headingLines(t)
        let titleRow = headerRow(t)
        xml += #"<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>"#
        xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="\#(titleRow)" topLeftCell="A\#(titleRow + 1)" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        xml += "<cols>"
        for (i, c) in t.columns.enumerated() {
            let width = max(8, (c.width / 7).rounded())
            xml += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(Int(width))" customWidth="1"/>"#
        }
        xml += "</cols><sheetData>"

        func textCell(_ col: Int, _ row: Int, _ s: String, _ style: Int) -> String {
            #"<c r="\#(ref(col, row))" t="inlineStr" s="\#(style)"><is><t xml:space="preserve">\#(esc(s))</t></is></c>"#
        }
        func moneyCell(_ col: Int, _ row: Int, _ m: Money, _ style: Int) -> String {
            #"<c r="\#(ref(col, row))" s="\#(style)"><v>\#(m.plain)</v></c>"#
        }

        // Client name large, report title bold, the rest plain.
        for (i, line) in head.enumerated() {
            xml += #"<row r="\#(i + 1)">\#(textCell(0, i + 1, line, i == 0 ? sClient : (i == 1 ? sBold : sText)))</row>"#
        }
        var r = titleRow
        xml += #"<row r="\#(r)">"#
        for (i, c) in t.columns.enumerated() {
            xml += textCell(i, r, c.title, c.kind == .money ? sHeaderRight : sHeader)
        }
        xml += "</row>"
        for row in t.rows {
            r += 1
            xml += #"<row r="\#(r)">"#
            for (i, cell) in row.cells.enumerated() {
                switch (cell, row.style) {
                case (.empty, .total), (.empty, .subtotal):
                    xml += #"<c r="\#(ref(i, r))" s="\#(sBoldTop)"/>"#
                case (.empty, _):
                    break
                case (.text(let s), .normal): xml += textCell(i, r, s, sText)
                case (.text(let s), .section): xml += textCell(i, r, s, sBold)
                case (.text(let s), _): xml += textCell(i, r, s, sBoldTop)
                case (.money(let m), .normal): xml += moneyCell(i, r, m, sMoney)
                case (.money(let m), .section): xml += moneyCell(i, r, m, sMoneyBold)
                case (.money(let m), _): xml += moneyCell(i, r, m, sMoneyTotal)
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData>"
        xml += #"<pageMargins left="0.5" right="0.5" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>"#
        xml += #"<pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>"#
        xml += #"<headerFooter><oddFooter>&amp;L&amp;A&amp;RPage &amp;P of &amp;N</oddFooter></headerFooter>"#
        xml += "</worksheet>"
        return xml
    }

    /// Excel sheet names: at most 31 characters, none of []:*?/\, unique without regard to case.
    static func sheetNames(_ tables: [ReportTable]) -> [String] {
        var used = Set<String>()
        return tables.map { t in
            var base = String(t.sheetName.map { "[]:*?/\\".contains($0) ? "-" : $0 }).trimmed
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if base.isEmpty { base = "Sheet" }
            base = String(base.prefix(31))
            var name = base, n = 2
            while used.contains(name.lowercased()) {
                let suffix = " (\(n))"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    private static func ref(_ col: Int, _ row: Int) -> String {
        var n = col + 1, letters = ""
        while n > 0 {
            let rem = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + rem))) + letters
            n = (n - 1) / 26
        }
        return letters + String(row)
    }

    private static func esc(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// Just enough of the zip format for an .xlsx container: stored entries, UTF-8 names.
enum Zip {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ d: inout Data, _ v: UInt32) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        let dosTime = 0, dosDate = (46 << 9) | (1 << 5) | 1  // 2026-01-01 00:00

        for f in files {
            let name = Data(f.name.utf8)
            let crc = crc32(f.data)
            let offset = UInt32(out.count)
            let size = UInt32(f.data.count)

            u32(&out, 0x0403_4B50); u16(&out, 20); u16(&out, 0x0800); u16(&out, 0)
            u16(&out, dosTime); u16(&out, dosDate)
            u32(&out, crc); u32(&out, size); u32(&out, size)
            u16(&out, name.count); u16(&out, 0)
            out.append(name)
            out.append(f.data)

            u32(&central, 0x0201_4B50); u16(&central, 20); u16(&central, 20); u16(&central, 0x0800); u16(&central, 0)
            u16(&central, dosTime); u16(&central, dosDate)
            u32(&central, crc); u32(&central, size); u32(&central, size)
            u16(&central, name.count); u16(&central, 0); u16(&central, 0); u16(&central, 0); u16(&central, 0)
            u32(&central, 0); u32(&central, offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        u32(&out, 0x0605_4B50); u16(&out, 0); u16(&out, 0)
        u16(&out, files.count); u16(&out, files.count)
        u32(&out, UInt32(central.count)); u32(&out, centralOffset); u16(&out, 0)
        return out
    }
}
