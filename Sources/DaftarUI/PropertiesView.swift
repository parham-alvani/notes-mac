import AppKit
import DaftarCore
import SwiftUI

/// The note's front matter above the editor, as Obsidian's Properties view:
/// a row for each property with a control for its type, and the YAML hidden
/// in the text. YAML the form cannot show without losing something stays
/// in the text, and a line says why. An edit saves the editors, reads the
/// file again, refuses when its front matter changed, and writes with
/// `VaultStore.write`; `PropertySheet` (core) keeps the style of each line
/// it did not change and never touches the body.
struct PropertiesView: View {
    var path: String
    @Environment(VaultStore.self) private var store
    @ViewState private var form: FrontMatterForm?
    @ViewState private var types: [String: String] = [:]
    /// The type picked for a property added without a value, until it has one.
    @ViewState private var chosen: [String: PropertyType] = [:]
    @ViewState private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            if store.settings.vimMode || !Vault.isNote(path) {
                Color.clear.frame(height: 0)
            } else if !store.settings.propertiesForm {
                if case .form = form { sourceBar } else if case .source = form { sourceBar } else { Color.clear.frame(height: 0) }
            } else {
                switch form {
                case .form(let sheet): sheetView(sheet)
                case .source(let reason): reasonBar(reason)
                case .absent(let sheet): sheetView(sheet)
                case nil: Color.clear.frame(height: 0)
                }
            }
        }
        .task(id: "\(path)\u{0}\(store.revision)") { reload() }
    }

    private func reload() {
        form = PropertySheet.read(store.text(of: path) ?? "")
        types = store.root.map { BaseEngine.types(in: $0) } ?? [:]
    }

    private func type(of property: PropertySheet.Property) -> PropertyType {
        if property.value == .empty, let picked = chosen[property.key] { return picked }
        return PropertyType.infer(property.key, property.value, types: types)
    }

    // MARK: The form

    private func sheetView(_ sheet: PropertySheet) -> some View {
        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach(sheet.properties) { property in
                PropertyRow(
                    property: property, type: type(of: property),
                    commit: { value in commit { $0.set(property.key, value) } },
                    rename: { name in
                        commit { try $0.rename(property.key, to: name) }
                        if let picked = chosen.removeValue(forKey: property.key) { chosen[name] = picked }
                    },
                    remove: { commit { $0.remove(property.key) } })
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            if !sheet.properties.isEmpty {
                HStack {
                    Text("Properties").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Show Source") { store.settings.propertiesForm = false }
                        .buttonStyle(.link).font(.caption)
                        .help("Show the front matter as YAML in the text (a setting)")
                }
                if sheet.properties.count > 8 {
                    ScrollView { rows }.frame(height: 8 * 28)
                } else {
                    rows
                }
            }
            if adding {
                AddPropertyRow(sheet: sheet, store: store, types: types, onCancel: { adding = false }) { name, type in
                    let value: PropertyValue = type == .checkbox ? .text("false") : .empty
                    chosen[name] = type
                    commit { try $0.add(name, value) }
                    adding = false
                }
            } else {
                Button { adding = true } label: { Label("Add property", systemImage: "plus").font(.callout) }
                    .buttonStyle(.borderless).foregroundStyle(Palette.muted)
                    .help("Add a property to the note's front matter")
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: CGFloat(store.settings.textSize) * 46, alignment: .leading)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.muted.opacity(0.2)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Properties")
    }

    /// The YAML is in the text; one click shows the form again.
    private var sourceBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "curlybraces").accessibilityHidden(true)
            Text("Properties are shown as YAML.")
            Button("Show as Form") { store.settings.propertiesForm = true }.buttonStyle(.link)
            Spacer()
        }
        .font(.caption).foregroundStyle(Palette.muted)
        .padding(.horizontal, 16).frame(height: 24)
        .background(Palette.background)
    }

    private func reasonBar(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "curlybraces").accessibilityHidden(true)
            Text("The properties are shown as YAML: the form cannot show this front matter without a change. \(reason)")
                .lineLimit(2)
            Spacer()
        }
        .font(.caption).foregroundStyle(Palette.muted)
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(Palette.background)
    }

    // MARK: Writing

    private func commit(_ change: @escaping (inout PropertySheet) throws -> Void) {
        guard let shown = form?.sheet else { return }
        let path = path
        Task {
            if let now = await store.editProperties(path, shown: shown, change) { form = now } else { reload() }
        }
    }
}

extension VaultStore {
    /// Saves the editors, reads the note again and applies [change] to the
    /// front matter on disk -- only when it is still the one [shown] was
    /// read from. What the note's front matter is now, or nil when it
    /// changed on disk and nothing was written.
    func editProperties(_ path: String, shown: PropertySheet, _ change: (inout PropertySheet) throws -> Void) async -> FrontMatterForm? {
        await flushEditors()
        guard let disk = text(of: path) else {
            notice = "\(Vault.title(of: path)) could not be read."
            return nil
        }
        guard var sheet = PropertySheet.read(disk).sheet, sheet.original == shown.original else {
            notice = "The properties of \(Vault.title(of: path)) changed on disk, so the change was not made. They are shown as they are now."
            return nil
        }
        do {
            try change(&sheet)
        } catch {
            notice = (error as? PropertySheet.Failure)?.description ?? error.localizedDescription
            return PropertySheet.read(disk)
        }
        guard let edited = sheet.applied(to: disk), edited != disk else { return PropertySheet.read(disk) }
        do {
            try write(edited, to: path)
            // The editors take it now, not after the file watcher's wait,
            // so a key typed in between is not saved over it.
            noteChanged(path)
        } catch {
            notice = "\(Vault.title(of: path)) could not be saved: \(error.localizedDescription)"
            return PropertySheet.read(disk)
        }
        return PropertySheet.read(edited)
    }
}

extension PropertyType {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .multitext: "list.bullet"
        case .number: "number"
        case .checkbox: "checkmark.square"
        case .date: "calendar"
        case .datetime: "clock"
        case .aliases: "arrowshape.turn.up.right"
        case .tags: "tag"
        }
    }
}

/// One property: its type's icon, its name (a menu to rename or remove it)
/// and the control for its value.
private struct PropertyRow: View {
    var property: PropertySheet.Property
    var type: PropertyType
    var commit: (PropertyValue) -> Void
    var rename: (String) -> Void
    var remove: () -> Void
    @ViewState private var renaming = false
    @ViewState private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: type.symbol).foregroundStyle(Palette.muted).frame(width: 16).accessibilityHidden(true)
            Group {
                if renaming {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(finishRename)
                        .onExitCommand { renaming = false }
                        .onChange(of: nameFocused) { if !nameFocused { finishRename() } }
                        .onAppear { nameFocused = true }
                } else {
                    Menu {
                        Button("Rename…") {
                            name = property.key
                            renaming = true
                        }
                        Button("Remove", role: .destructive, action: remove)
                    } label: {
                        Text(property.key).lineLimit(1).truncationMode(.tail)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .foregroundStyle(Palette.muted)
                    .help("\(type.title): rename or remove “\(property.key)”")
                    .accessibilityLabel("\(property.key), \(type.title) property")
                }
            }
            .frame(width: 140, alignment: .leading)
            PropertyControl(value: property.value, type: type, name: property.key, commit: commit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    private func finishRename() {
        guard renaming else { return }
        renaming = false
        let new = name.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty, new != property.key { rename(new) }
    }
}

/// The control for a value of [type]: a text or number field, a checkbox,
/// a date picker, or chips for a list.
private struct PropertyControl: View {
    var value: PropertyValue
    var type: PropertyType
    var name: String
    var commit: (PropertyValue) -> Void

    var body: some View {
        let text = value.items.first ?? ""
        if type.isList || { if case .list = value { true } else { false } }() {
            ChipsField(items: value.items, type: type, name: name) { commit(.list($0)) }
        } else {
            switch type {
            case .checkbox:
                Toggle(name, isOn: Binding(get: { text.lowercased() == "true" }, set: { commit(.text($0 ? "true" : "false")) }))
                    .toggleStyle(.checkbox).labelsHidden()
            case .date, .datetime:
                PropertyDateField(value: text, time: type == .datetime, name: name) { commit(.text($0)) }
            case .number:
                CommitField(value: text, prompt: "Number", name: name, valid: { $0.isEmpty || Double($0) != nil }) { commit(.text($0)) }
            default:
                CommitField(value: text, prompt: "Empty", name: name) { commit(.text($0)) }
            }
        }
    }
}

/// A text field that writes when Return is pressed or it loses the focus,
/// not at every key.
private struct CommitField: View {
    var value: String
    var prompt: String
    var name: String
    var valid: (String) -> Bool = { _ in true }
    var commit: (String) -> Void
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(name, text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .focused($focused)
            .foregroundStyle(valid(draft) ? Color.primary : Palette.red)
            .onAppear { draft = value }
            .onChange(of: value) { draft = value }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onExitCommand { draft = value }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard text != value else { return }
        guard valid(text) else {
            draft = value
            return
        }
        commit(text)
    }
}

/// A date, or a date and time, written as Obsidian writes it a moment after
/// the picker stops changing; text that is no date stays a text field.
private struct PropertyDateField: View {
    var value: String
    var time: Bool
    var name: String
    var commit: (String) -> Void
    @ViewState private var date = Date()
    @ViewState private var pending: Task<Void, Never>?

    var body: some View {
        if value.isEmpty {
            Button(time ? "Add date and time" : "Add date") { commit(PropertyType.format(Date(), time: time)) }
                .buttonStyle(.link)
        } else if let parsed = PropertyType.date(from: value) {
            DatePicker(
                name,
                selection: Binding(get: { date }, set: { new in
                    date = new
                    pending?.cancel()
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        let text = PropertyType.format(new, time: time)
                        if text != value { commit(text) }
                    }
                }),
                displayedComponents: time ? [.date, .hourAndMinute] : [.date]
            )
            .labelsHidden().datePickerStyle(.field).fixedSize()
            .onAppear { date = parsed }
            .onChange(of: value) { if let again = PropertyType.date(from: value) { date = again } }
        } else {
            CommitField(value: value, prompt: time ? "YYYY-MM-DDTHH:mm" : "YYYY-MM-DD", name: name,
                        valid: { $0.isEmpty || PropertyType.date(from: $0) != nil }, commit: commit)
        }
    }
}

/// The items of a list as chips -- tags in their colours -- with a field
/// to add one.
private struct ChipsField: View {
    var items: [String]
    var type: PropertyType
    var name: String
    var commit: ([String]) -> Void
    @ViewState private var draft = ""

    var body: some View {
        ChipLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                chip(item, at: index)
            }
            TextField("Add to \(name)", text: $draft, prompt: Text(type == .tags ? "Add tag" : "Add"))
                .labelsHidden().textFieldStyle(.plain).frame(width: 90)
                .onSubmit(add)
        }
    }

    private func chip(_ item: String, at index: Int) -> some View {
        let color = type == .tags ? Palette.named(NSPalette.tagColor(item.hasPrefix("#") ? String(item.dropFirst()) : item))
            : type == .aliases ? Palette.link : Palette.accent
        return HStack(spacing: 3) {
            Text(type == .tags && !item.hasPrefix("#") ? "#" + item : item).lineLimit(1)
            Button {
                var rest = items
                rest.remove(at: index)
                commit(rest)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item)")
            .help("Remove \(item)")
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
    }

    private func add() {
        var item = draft.trimmingCharacters(in: .whitespaces)
        if type == .tags, item.hasPrefix("#") { item.removeFirst() }
        draft = ""
        guard !item.isEmpty, !items.contains(item) else { return }
        commit(items + [item])
    }
}

/// A new property: its name, completed from the names the vault uses, and
/// its type, which a name the vault knows brings with it.
private struct AddPropertyRow: View {
    var sheet: PropertySheet
    var store: VaultStore
    var types: [String: String]
    var onCancel: () -> Void
    var onAdd: (String, PropertyType) -> Void
    @ViewState private var name = ""
    @ViewState private var type = PropertyType.text
    @ViewState private var names: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let suggestions = PropertyNames.complete(name, from: names).filter { sheet.value($0) == nil }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: type.symbol).foregroundStyle(Palette.muted).frame(width: 16).accessibilityHidden(true)
                TextField("Property name", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder).frame(width: 160)
                    .focused($focused)
                    .onSubmit { if !trimmed.isEmpty { onAdd(trimmed, type) } }
                    .onExitCommand(perform: onCancel)
                Picker("Type", selection: $type) {
                    ForEach(PropertyType.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden().fixedSize()
                Button("Add") { onAdd(trimmed, type) }.disabled(trimmed.isEmpty || sheet.value(trimmed) != nil)
                Button("Cancel", action: onCancel)
            }
            if !suggestions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            name = suggestion
                            focused = true
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .onAppear {
            names = PropertyNames.ranked(store.index.notes.values.lazy.flatMap { $0.parsed.properties.map(\.key) })
            focused = true
        }
        .onChange(of: name) {
            if names.contains(trimmed) { type = vaultType(trimmed) }
        }
    }

    /// The type the vault gives [name]: its line in `types.json`, or the
    /// shape of its value in the first note that has it.
    private func vaultType(_ name: String) -> PropertyType {
        if let named = types[name], let type = PropertyType(rawValue: named) { return type }
        let values = store.index.notes.values.lazy.compactMap { $0.parsed.properties.first { $0.key == name }?.values }.first ?? []
        let value: PropertyValue = values.count > 1 ? .list(values) : values.first.map { .text($0) } ?? .empty
        return PropertyType.infer(name, value, types: types)
    }
}

/// Chips in rows, as wide as there is room for.
private struct ChipLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: The editor

extension EditorController {
    /// How much of the text the form stands for: the front matter when the
    /// form shows it, else nothing. A block with nothing after its closing
    /// fence stays, so typed text never joins the fence.
    func frontMatterToHide() -> Int {
        guard store.settings.propertiesForm, !store.settings.vimMode, let path, Vault.isNote(path),
            let text = view?.string, text.hasPrefix("---"), case .form(let sheet) = PropertySheet.read(text), sheet.original.hasSuffix("\n")
        else { return 0 }
        return sheet.original.utf16.count
    }

    private static let collapsed: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 0.01
        paragraph.maximumLineHeight = 0.01
        return [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear, .paragraphStyle: paragraph]
    }()

    /// The front matter's lines take no room: the form above shows them.
    func collapseFrontMatter(_ storage: NSTextStorage, range: NSRange) {
        guard hiddenFront > 0, hiddenFront <= storage.length else { return }
        let hidden = NSIntersectionRange(range, NSRange(location: 0, length: hiddenFront))
        if hidden.length > 0 { storage.addAttributes(Self.collapsed, range: hidden) }
    }

    /// The cursor and the selection stay out of the hidden front matter.
    /// The method for several ranges: with the one for a single range,
    /// AppKit keeps only the first of a block selection.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue], toCharacterRanges new: [NSValue]) -> [NSValue] {
        guard hiddenFront > 0, hiddenFront <= (textView.string as NSString).length else { return new }
        let kept = new.map(\.rangeValue).compactMap { range -> NSValue? in
            guard range.location < hiddenFront else { return NSValue(range: range) }
            guard NSMaxRange(range) > hiddenFront || range.length == 0 else { return nil }
            return NSValue(range: NSRange(location: hiddenFront, length: max(0, NSMaxRange(range) - hiddenFront)))
        }
        return kept.isEmpty ? [NSValue(range: NSRange(location: hiddenFront, length: 0))] : kept
    }

    /// Typing never reaches the hidden front matter; replacing the whole
    /// note (Sort Tasks, a restore) still may.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard hiddenFront > 0, range.location < hiddenFront else { return true }
        return range.location == 0 && NSMaxRange(range) == (textView.string as NSString).length
    }
}
