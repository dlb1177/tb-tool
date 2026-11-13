import SwiftUI
import TBCore

/// Every workpaper link that no longer finds its file, with the quickest way to repair each:
/// relink to a file of the same name found in the client folder, point at where it went, or remove it.
struct FixLinksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @State private var links: [BrokenLink] = []
    @State private var searching = false

    var body: some View {
        let found = Dictionary(links.compactMap { l in l.suggestion.map { (l.reference.path, $0) } }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(links.isEmpty ? "Every linked file was found" : "\(links.count) linked file\(links.count == 1 ? "" : "s") can't be found")
                    .font(.title3.bold())
                Text("A link breaks when its file is moved or renamed. The client folder is searched for a file with the same name; where exactly one is found you can relink in a click. Locating one file also repairs the others that moved to the same folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            if links.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(.green)
                    Text(searching ? "Checking…" : "Nothing to fix.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(links) {
                    TableColumn("Entry") { l in
                        Button(l.entryNumber) { model.editEntry(l.entryID) }
                            .buttonStyle(.link)
                            .help(l.entryDescription)
                    }
                    .width(min: 60, ideal: 70, max: 100)
                    TableColumn("Linked file") { l in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(l.reference.fileName).fontWeight(.medium)
                            Text(l.reference.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .help(model.url(for: l.reference).path)
                    }
                    .width(min: 200, ideal: 300)
                    TableColumn("Found in the client folder") { l in
                        if let s = l.suggestion {
                            Label(s, systemImage: "checkmark.circle").foregroundStyle(.green).lineLimit(1).truncationMode(.middle).help(s)
                        } else if l.candidates.count > 1 {
                            Menu("\(l.candidates.count) files with this name") {
                                ForEach(l.candidates, id: \.self) { path in
                                    Button(path) { model.relink(l.reference.path, to: path) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        } else {
                            Text(searching ? "Searching…" : "No file with this name").foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 200, ideal: 300)
                    TableColumn("") { l in
                        HStack(spacing: 6) {
                            if let s = l.suggestion {
                                Button("Relink") { model.relink(l.reference.path, to: s) }
                            }
                            Button("Locate…") {
                                if let path = model.locateFile(for: l.reference) { model.relink(l.reference.path, to: path) }
                            }
                            Button("Remove Link") { model.removeLink(l) }
                                .help("Removes the link from \(l.entryNumber). No file is deleted.")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .width(min: 230, ideal: 250, max: 280)
                }
            }
            Divider()
            HStack {
                if !found.isEmpty {
                    Button("Relink All \(found.count) Found") { model.relink(all: found) }
                }
                Text("Relinking and removing can be undone.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 320)
        .task(id: model.brokenLinks) {
            // Show the list straight away; fill in where the files went once the folder has been searched.
            let broken = model.brokenLinks
            let folder = model.folder
            let known = Dictionary(links.map { ($0.id, $0.candidates) }, uniquingKeysWith: { a, _ in a })
            links = broken.map { l in
                var x = l
                x.candidates = known[l.id] ?? []
                return x
            }
            guard !broken.isEmpty else { return }
            searching = true
            let result = await Task.detached(priority: .userInitiated) { LinkFinder.withCandidates(broken, folder: folder) }.value
            if !Task.isCancelled { links = result }
            searching = false
        }
    }
}
