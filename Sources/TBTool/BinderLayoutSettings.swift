import AppKit
import SwiftUI
import TBCore

/// TB Tool ▸ Settings ▸ Binder Layout: the folders a brand-new binder starts with. One layout
/// serves every entity type; a type can be given its own. A file made by rolling forward
/// takes last year's folders, not these.
struct BinderLayoutSettings: View {
    @State private var layouts = BinderLayouts.load()
    /// "" is the layout for every entity type; otherwise an entity type's name.
    @State private var which: String? = ""
    @State private var text = BinderLayouts.load().general.outline
    @State private var note = ""

    private var type: String { which ?? "" }
    private var own: BinderLayout? { type.isEmpty ? layouts.general : layouts.byEntityType[type] }
    private var typed: BinderLayout { BinderLayout(outline: text) }
    private var dirty: Bool { own.map { $0 != typed } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Binder layout").font(.headline)
                    Text("The folders made beside a brand-new trial balance file. A file made by rolling forward takes last year's folders instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                Divider()
                List(selection: $which) {
                    row("Every entity type", "The layout used unless a type has its own").tag(Optional(""))
                    Section("By entity type") {
                        ForEach(Binder.entityTypes, id: \.self) { t in
                            row(t, layouts.byEntityType[t] == nil ? "Uses the layout for every type" : "Has its own layout").tag(Optional(t))
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(type.isEmpty ? "Layout for every entity type" : type).font(.headline)
                if own == nil {
                    Text("This entity type uses the layout for every entity type, shown below.")
                        .foregroundStyle(.secondary)
                    preview(layouts.general)
                    HStack {
                        Spacer()
                        Button("Give It Its Own Layout") {
                            layouts.byEntityType[type] = layouts.general
                            save("\(type) now has its own layout, starting from the one for every type.")
                            text = layouts.general.outline
                        }
                    }
                } else {
                    Text("One folder per line. To put a folder inside another, indent its line under it with Tab or four spaces. Start a name with its number, like “4000 Support”, so the files inside can be indexed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 12) {
                        TextEditor(text: $text)
                            .font(.system(size: 12.5, design: .monospaced))
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                        preview(typed)
                    }
                    let problems = typed.problems()
                    ForEach(problems, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                    HStack {
                        if type.isEmpty {
                            Button("Put Back the Built-in Layout") { text = BinderLayout.standard.outline }
                                .disabled(typed == .standard)
                        } else {
                            Button("Use the Layout for Every Type Instead") {
                                layouts.byEntityType[type] = nil
                                save("\(type) uses the layout for every entity type again.")
                                text = layouts.general.outline
                            }
                        }
                        Spacer()
                        Text(dirty ? "Not saved yet" : note).font(.callout).foregroundStyle(.secondary)
                        Button("Revert") { text = own?.outline ?? "" }
                            .disabled(!dirty)
                        Button("Save") {
                            if type.isEmpty { layouts.general = typed } else { layouts.byEntityType[type] = typed }
                            save("Saved. New files\(type.isEmpty ? "" : " of this type") start with these folders.")
                        }
                        .keyboardShortcut("s")
                        .disabled(!dirty || !problems.isEmpty || typed.folders.isEmpty)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 500, idealHeight: 640)
        .onChange(of: which) { _, _ in
            text = (own ?? layouts.general).outline
            note = ""
        }
    }

    private func row(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The layout as it will look in the binder.
    private func preview(_ layout: BinderLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(layout.paths, id: \.self) { path in
                    let depth = path.split(separator: "/").count - 1
                    Label((path as NSString).lastPathComponent, systemImage: "folder.fill")
                        .padding(.leading, CGFloat(depth) * 18)
                        .lineLimit(1)
                }
                if layout.folders.isEmpty { Text("No folders").foregroundStyle(.secondary) }
            }
            .font(.system(size: 12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
    }

    private func save(_ message: String) {
        do {
            try layouts.save()
            note = message
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't save the binder layouts"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
}
