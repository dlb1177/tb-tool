import AppKit
import TBCore

/// Writes reports as a PDF: the binder heading on the first page of each report, the column
/// titles repeated on every page, numbered pages, and rows that belong together (a journal entry)
/// never split across a page unless one is longer than a page.
enum PDFReport {

    /// Paper and type sizes tried in turn until the report's columns fit across the page.
    private static let choices: [(size: CGSize, font: CGFloat)] = [
        (CGSize(width: 612, height: 792), 9), (CGSize(width: 792, height: 612), 9), (CGSize(width: 792, height: 612), 8),
        (CGSize(width: 792, height: 612), 7), (CGSize(width: 1008, height: 612), 8), (CGSize(width: 1008, height: 612), 7),
        (CGSize(width: 1224, height: 792), 8), (CGSize(width: 1224, height: 792), 7), (CGSize(width: 1224, height: 792), 6),
    ]
    private static let margin: CGFloat = 40

    static func data(_ tables: [ReportTable]) -> Data {
        let layouts = tables.map(Layout.init)
        let total = layouts.reduce(0) { $0 + $1.pages.count }
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: layouts.first?.paper ?? CGSize(width: 792, height: 612))
        guard let consumer = CGDataConsumer(data: out as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        var number = 0
        for layout in layouts {
            for page in layout.pages.indices {
                number += 1
                var media = CGRect(origin: .zero, size: layout.paper)
                let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
                ctx.beginPDFPage(info)
                // Work downwards from the top of the page, as everything else here does.
                ctx.translateBy(x: 0, y: layout.paper.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                layout.draw(page: page, number: number, of: total)
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return out as Data
    }

    /// A colour from the six hex digits the report bands are given in.
    private static func color(_ hex: String) -> NSColor {
        let v = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private static func text(_ cell: ReportCell) -> String {
        switch cell {
        case .empty: return ""
        case .text(let s): return s
        case .money(let m): return m.isZero ? "–" : m.formatted
        }
    }

    /// One report, measured and cut into pages.
    private struct Layout {
        let table: ReportTable
        let paper: CGSize
        let size: CGFloat
        let widths: [CGFloat]
        let lefts: [CGFloat]
        let heights: [CGFloat]
        /// Row indexes on each page.
        let pages: [[Int]]
        let head: [String]

        private static let pad: CGFloat = 4

        private static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            let name = bold ? "HelveticaNeue-Bold" : (italic ? "HelveticaNeue-Italic" : "HelveticaNeue")
            return NSFont(name: name, size: size) ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }

        private static func font(for style: ReportRow.Style, _ size: CGFloat) -> NSFont {
            switch style {
            case .normal, .blank: return font(size)
            case .note: return font(size, italic: true)
            case .section: return font(size + 1, bold: true)
            case .subtotal, .total, .heading: return font(size, bold: true)
            }
        }

        /// The cell that runs on across the empty cells to its right: the title of a section,
        /// an entry's description, a reference.
        private static func spanning(_ row: ReportRow) -> Int? {
            guard row.style == .section || row.style == .heading || row.style == .note else { return nil }
            return row.cells.lastIndex { if case .text(let s) = $0 { return !s.isEmpty }; return false }
        }

        private var lineHeight: CGFloat { ceil(size * 1.32) }
        private var tableWidth: CGFloat { widths.reduce(0, +) }
        private var bottom: CGFloat { paper.height - PDFReport.margin - 16 }

        init(_ table: ReportTable) {
            self.table = table
            head = table.flat ? [table.title] : (table.heading.isEmpty ? [table.title, table.subtitle].filter { !$0.isEmpty } : table.heading)
            let columns = table.columns
            func measure(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

            // The width each column would like at a type size, and the least it can be given.
            func natural(_ size: CGFloat) -> (want: [CGFloat], least: [CGFloat]) {
                var want = columns.map { measure($0.title, Layout.font(size, bold: true)) + 2 * Layout.pad }
                for row in table.rows {
                    let span = Layout.spanning(row)
                    let f = Layout.font(for: row.style, size)
                    for (i, cell) in row.cells.enumerated() where i < columns.count && i != span {
                        let s = PDFReport.text(cell)
                        if !s.isEmpty { want[i] = max(want[i], measure(s, f) + 2 * Layout.pad) }
                    }
                }
                // Figures are never cut or wrapped; words can be, down to a point.
                let least = zip(columns, want).map { c, w in c.kind == .money ? w : min(w, max(size * 11, measure(c.title, Layout.font(size, bold: true)) + 2 * Layout.pad)) }
                return (want.map { min($0, size * 44) }, least)
            }

            // The first paper and type size on which every column gets the width it wants; failing
            // that, the first on which they fit once the columns of words are narrowed and wrapped.
            var chosen = PDFReport.choices[PDFReport.choices.count - 1]
            var want: [CGFloat] = [], least: [CGFloat] = []
            var settled = false
            for wanting in [true, false] where !settled {
                for choice in PDFReport.choices {
                    let n = natural(choice.font)
                    chosen = choice
                    (want, least) = n
                    if (wanting ? n.want : n.least).reduce(0, +) <= choice.size.width - 2 * PDFReport.margin {
                        settled = true
                        break
                    }
                }
            }
            paper = chosen.size
            size = chosen.font
            let room = paper.width - 2 * PDFReport.margin
            var w = want
            let over = w.reduce(0, +) - room
            if over > 0 {
                // Take the excess from the columns of words, in proportion to what each can give.
                let give = zip(w, least).map { max(0, $0 - $1) }
                let can = give.reduce(0, +)
                let share = can > 0 ? min(1, over / can) : 0
                w = zip(w, give).map { $0 - $1 * share }
                let still = w.reduce(0, +) - room
                if still > 0.5 { w = w.map { $0 * room / (room + still) } }
            }
            widths = w
            var x = PDFReport.margin
            var l: [CGFloat] = []
            for width in w {
                l.append(x)
                x += width
            }
            lefts = l
            let right = x

            // Row heights: one line, or as many as a wrapped cell needs.
            let line = ceil(chosen.font * 1.32)
            var h: [CGFloat] = []
            for row in table.rows {
                if row.style == .blank {
                    h.append(ceil(line * 0.6))
                    continue
                }
                let span = Layout.spanning(row)
                let f = Layout.font(for: row.style, chosen.font)
                var tallest = line
                for (i, cell) in row.cells.enumerated() where i < columns.count {
                    guard case .text(let s) = cell, !s.isEmpty else { continue }
                    let width = (i == span ? right - l[i] : w[i]) - 2 * Layout.pad
                    if measure(s, f) > width {
                        let box = (s as NSString).boundingRect(with: CGSize(width: max(width, 20), height: 10_000),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: f])
                        tallest = max(tallest, ceil(box.height))
                    }
                }
                h.append(tallest + (row.style == .heading || row.style == .section ? 7 : 4))
            }
            heights = h

            // Pages. Rows of one block stay together; a section title stays with what follows it.
            var units: [[Int]] = []
            var i = 0
            while i < table.rows.count {
                var unit = [i]
                if let block = table.rows[i].block {
                    while i + 1 < table.rows.count, table.rows[i + 1].block == block {
                        i += 1
                        unit.append(i)
                    }
                }
                units.append(unit)
                i += 1
            }
            let headFirst = Layout.headHeight(head, first: true, size: chosen.font) + line + 8
            let headNext = Layout.headHeight(head, first: false, size: chosen.font) + line + 8
            let floor = chosen.size.height - PDFReport.margin - 16
            var out: [[Int]] = [[]]
            var y = PDFReport.margin + headFirst
            func newPage() {
                out.append([])
                y = PDFReport.margin + headNext
            }
            for (n, unit) in units.enumerated() {
                let own = unit.reduce(0) { $0 + h[$1] }
                var need = own
                let style = table.rows[unit[0]].style
                // A title, or the line that totals what came before, isn't left alone at a page's edge.
                if style == .section, n + 1 < units.count { need += units[n + 1].reduce(0) { $0 + h[$1] } }
                var ahead = n + 1
                while ahead < units.count, ahead <= n + 4 {
                    let next = table.rows[units[ahead][0]]
                    guard next.block == nil, next.style == .blank || next.style == .total || (next.style == .subtotal && next.groupingID == nil) else { break }
                    if next.style != .blank || ahead + 1 < units.count { need += units[ahead].reduce(0) { $0 + h[$1] } }
                    ahead += 1
                }
                if style == .blank {
                    if out[out.count - 1].isEmpty { continue }  // no gap at the top of a page
                    if y + own > floor { continue }
                }
                let capacity = floor - (PDFReport.margin + headNext)
                if y + need > floor, !out[out.count - 1].isEmpty, own <= capacity { newPage() }
                for r in unit {
                    if y + h[r] > floor, !out[out.count - 1].isEmpty { newPage() }
                    out[out.count - 1].append(r)
                    y += h[r]
                }
            }
            pages = out
        }

        private static func headHeight(_ head: [String], first: Bool, size: CGFloat) -> CGFloat {
            guard first else { return ceil((size + 1) * 1.4) + 6 }
            var total: CGFloat = 0
            for i in head.indices { total += ceil((i == 0 ? size + 6 : (i == 1 ? size + 2 : size)) * 1.4) }
            return total + 10
        }

        private func draw(_ s: String, _ f: NSFont, in rect: CGRect, right: Bool = false, color: NSColor = .black, wrap: Bool = false) {
            guard !s.isEmpty else { return }
            let style = NSMutableParagraphStyle()
            style.alignment = right ? .right : .left
            style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
            (s as NSString).draw(with: rect, options: wrap ? [.usesLineFragmentOrigin, .usesFontLeading] : [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: f, .foregroundColor: color, .paragraphStyle: style])
        }

        private func rule(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat, _ gray: CGFloat, _ weight: CGFloat = 0.6) {
            NSColor(white: gray, alpha: 1).setFill()
            CGRect(x: x0, y: y, width: x1 - x0, height: weight).fill()
        }

        func draw(page: Int, number: Int, of total: Int) {
            let left = PDFReport.margin, right = left + tableWidth
            var y = PDFReport.margin
            // The heading: in full on the first page, one line after that.
            if page == 0 {
                for (i, line) in head.enumerated() {
                    let s = i == 0 ? size + 6 : (i == 1 ? size + 2 : size)
                    draw(line, Layout.font(s, bold: i < 2), in: CGRect(x: left, y: y, width: paper.width - 2 * left, height: ceil(s * 1.4)),
                         color: i < 2 ? .black : NSColor(white: 0.25, alpha: 1))
                    y += ceil(s * 1.4)
                }
                y += 10
            } else {
                let line = (head.count > 1 ? "\(head[0]) — \(head[1])" : (head.first ?? table.title)) + " (continued)"
                draw(line, Layout.font(size + 1, bold: true), in: CGRect(x: left, y: y, width: paper.width - 2 * left, height: ceil((size + 1) * 1.4)))
                y += ceil((size + 1) * 1.4) + 6
            }
            // Column titles, on every page, on a dark band.
            let bold = Layout.font(size, bold: true)
            PDFReport.color(ReportBand.columns.hex).setFill()
            CGRect(x: left, y: y - 2, width: right - left, height: lineHeight + 6).fill()
            for (i, c) in table.columns.enumerated() {
                draw(c.title, bold, in: CGRect(x: lefts[i] + Layout.pad, y: y + 0.5, width: widths[i] - 2 * Layout.pad, height: lineHeight), right: c.kind == .money, color: .white)
            }
            y += lineHeight + 8

            // A long list of plain rows is easier to read across with every other one tinted.
            let striped = !table.rows.contains { $0.block != nil }
            var stripe = false

            for r in pages[page] {
                let row = table.rows[r]
                let h = heights[r]
                defer { y += h }
                if row.style == .blank { continue }
                let f = Layout.font(for: row.style, size)
                let span = Layout.spanning(row)
                var top = y + 2
                // The band the row sits on: a section, a grouping, an entry's heading, a total.
                let band = ReportBand(row)
                if band != .none {
                    PDFReport.color(band.hex).setFill()
                    CGRect(x: left, y: y, width: right - left, height: h - (row.style == .heading || row.style == .section ? 1 : 0)).fill()
                    stripe = false
                } else if row.style == .normal, striped {
                    if stripe {
                        NSColor(white: 0.965, alpha: 1).setFill()
                        CGRect(x: left, y: y, width: right - left, height: h).fill()
                    }
                    stripe.toggle()
                }
                switch row.style {
                case .heading:
                    rule(y, from: left, to: right, 0.55)
                    top = y + 3.5
                case .section:
                    top = y + 4
                case .total:
                    rule(y, from: left, to: right, 0.1, 0.9)
                    rule(y + h - 1.6, from: left, to: right, 0.1, 0.5)
                case .subtotal where band == .none:
                    // A line over the figures being totalled.
                    for (i, cell) in row.cells.enumerated() where i < table.columns.count {
                        if case .money = cell { rule(y, from: lefts[i] + 2, to: lefts[i] + widths[i] - 2, 0.45) }
                    }
                default: break
                }
                for (i, cell) in row.cells.enumerated() where i < table.columns.count {
                    let s = PDFReport.text(cell)
                    if s.isEmpty { continue }
                    let money: Bool = { if case .money = cell { return true }; return false }()
                    let width = (i == span ? right - lefts[i] : widths[i]) - 2 * Layout.pad
                    draw(s, f, in: CGRect(x: lefts[i] + Layout.pad, y: top, width: width, height: h - 2), right: money,
                         color: row.style == .note ? NSColor(white: 0.3, alpha: 1) : (row.style == .section ? PDFReport.color(ReportBand.ink) : .black), wrap: !money)
                }
            }

            // The foot of the page.
            let foot = Layout.font(max(size - 1, 6))
            let fy = paper.height - PDFReport.margin - 8
            rule(fy - 4, from: left, to: paper.width - left, 0.7, 0.4)
            let name = head.count > 1 ? "\(head[0]) — \(head[1])" : (head.first ?? table.title)
            draw(name, foot, in: CGRect(x: left, y: fy, width: paper.width - 2 * left - 90, height: 12), color: NSColor(white: 0.35, alpha: 1))
            draw("Page \(number) of \(total)", foot, in: CGRect(x: paper.width - left - 90, y: fy, width: 90, height: 12), right: true, color: NSColor(white: 0.35, alpha: 1))
        }
    }
}
