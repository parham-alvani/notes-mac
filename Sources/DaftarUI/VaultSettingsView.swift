import AppKit
import DaftarCore
import SwiftUI

/// Settings › Vault: what this clone is, in its own git config (read-only,
/// its address, its author and its SSH key), and the app's settings the
/// vault carries in its `.daftar.toml`. The rules are
/// `docs/specs/read-only-vault.md` and `vault-config.md` in notes-linux.
struct VaultSettingsTab: View {
    @Environment(VaultStore.self) private var store
    /// The clone's own git config, read when the tab shows and after each change.
    @ViewState private var clone: VaultStore.CloneSettings?
    /// Grows with each read, so the fields take the values git has now.
    @ViewState private var read = 0
    @ViewState private var problem: String?
    /// The public key of the key in use, shown to copy to the remote.
    @ViewState private var publicKey: String?
    @ViewState private var generating = false

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section {
                ForEach(store.listedVaults) { vault in
                    VaultRow(vault: vault)
                }
                Button("Open Vault…") { chooseVault(store) }
                    .help("Opens a folder as the vault in use, and adds it to this list")
            } header: {
                Text("Vaults")
            } footer: {
                Text("One vault is open at a time. Switch changes to another in the running app: the notes you are editing are saved first, and each vault keeps its tabs and reading places. Forget takes a vault out of this list and touches no file.")
            }
            if store.isRepository, let clone {
                git(clone)
            }
            Section {
                TextField("Verify as", text: $settings.okfActor, prompt: Text("The name of your git email"))
                    .help("okf.actor: Mark as Verified signs a concept as human:<this name>")
            } header: {
                Text("Concepts")
            } footer: {
                Text("A note with a type in its properties is a concept, as the Open Knowledge Format has it: the inspector shows who confirmed it and whether it is stale, and Mark as Verified adds your name and the time.")
            }
            Section {
                Toggle("Use the settings the vault carries", isOn: $settings.followsVault)
                    .help("vault_settings in the settings file. Off, no setting of the app is read from any vault.")
                if !settings.declinedKeys.isEmpty {
                    LabeledContent("Declined here") { keys(settings.declinedKeys) }
                }
                if !settings.fromVault.isEmpty {
                    LabeledContent("From the vault") { keys(settings.fromVault.sorted()) }
                }
                if !settings.refusedByVault.isEmpty {
                    LabeledContent("Not taken") { keys(settings.refusedByVault) }
                        .help("A vault never sets a key that names a program, a file outside the vault, or what leaves this Mac.")
                }
            } header: {
                Text("From the vault")
            } footer: {
                Text("A vault may carry settings of the app in the .daftar.toml at its root, and its value wins over this Mac's. Such a setting shows “From the vault” and is changed in that file. To keep this Mac's own value for one, name its key in vault_settings in the settings file.")
            }
        }
        .formStyle(.grouped)
        .task(id: store.root) { await load() }
        .onChange(of: store.readOnly) { Task { await load() } }
        .onChange(of: store.isRepository) { Task { await load() } }
    }

    @ViewBuilder private func git(_ clone: VaultStore.CloneSettings) -> some View {
        Section {
            Toggle("Read-only", isOn: Binding { clone.readOnly } set: { on in
                Task {
                    await store.setReadOnly(on)
                    await load()
                }
            })
            .help("Daftar pulls and never writes: no file of the vault changes and no commit is made. For a computer whose key cannot push.")
            CommitField(title: "Address", prompt: "git@github.com:you/notes.git", value: clone.address) { address in
                problem = await store.setAddress(address)
                await load()
            }
            .help("Where this clone pulls from and pushes to. Nothing is fetched until the next sync.")
            CommitField(title: "Name", prompt: store.settings.vaultAuthor.name ?? "Your git config's", value: clone.name) { name in
                problem = await store.setCloneConfig("user.name", name)
                await load()
            }
            CommitField(title: "Email", prompt: store.settings.vaultAuthor.email ?? "Your git config's", value: clone.email) { email in
                problem = await store.setCloneConfig("user.email", email)
                await load()
            }
            key(clone)
            if let publicKey {
                LabeledContent("Public key") {
                    HStack {
                        Text(publicKey).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicKey, forType: .string)
                        }
                        .help("Copy the public key, to add it to the remote as a deploy key")
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Palette.red)
                    .accessibilityLabel("Not saved. \(problem)")
            }
        } header: {
            Text("Git")
        } footer: {
            Text("These belong to this clone alone, in its git config (.git/config), and are never committed. An empty field takes the key away. With no name or email here, the vault's own (git.name and git.email in its .daftar.toml) sign the commits, then your git config's.")
        }
    }

    @ViewBuilder private func key(_ clone: VaultStore.CloneSettings) -> some View {
        let written = SSHKey.key(in: clone.ssh)
        // A command Daftar did not write is shown as it is, and left alone.
        let foreign = !clone.ssh.isEmpty && written == nil
        LabeledContent("SSH key") {
            HStack {
                if foreign {
                    Text(clone.ssh).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else {
                    Text(written.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "This Mac's own keys")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button("Choose…") { choose() }.disabled(foreign)
                Button(generating ? "Generating…" : "Generate") { generate() }.disabled(foreign || generating)
                    .help("Makes a new key for this vault in ~/.ssh, with no passphrase, never over a file that is there")
                Button("Clear") { setKey(nil) }.disabled(clone.ssh.isEmpty || foreign)
            }
        }
        .help(foreign
            ? "core.sshCommand was not written by Daftar, so it is not changed here: git config --local core.sshCommand"
            : "The key this clone's ssh uses: core.sshCommand, as ssh -i <key> -o IdentitiesOnly=yes")
    }

    private func keys(_ keys: [String]) -> some View {
        Text(keys.joined(separator: ", ")).font(.callout.monospaced()).foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing).textSelection(.enabled)
    }

    private func load() async {
        clone = await store.cloneSettings()
        publicKey = clone.flatMap { SSHKey.key(in: $0.ssh) }.flatMap { SSHKey.publicKey(of: URL(filePath: ($0 as NSString).expandingTildeInPath)) }
        read += 1
    }

    private func setKey(_ path: String?) {
        Task {
            problem = await store.setCloneConfig("core.sshCommand", path.map(SSHKey.command(key:)) ?? "")
            await load()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = SSHKey.directory
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Key"
        panel.message = "The private key this vault's git uses."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The private key is the one `ssh -i` takes.
        setKey(url.pathExtension == "pub" ? url.deletingPathExtension().path : url.path)
    }

    private func generate() {
        let vault = store.name
        generating = true
        Task {
            defer { generating = false }
            do {
                let made = try await Task.detached { try SSHKey.generate(vault: vault) }.value
                problem = await store.setCloneConfig("core.sshCommand", SSHKey.command(key: made.file.path))
            } catch {
                problem = error.localizedDescription
            }
            await load()
        }
    }
}

/// One vault of the list: its name and folder, the one in use marked, a
/// missing one said so, with Switch and Forget.
private struct VaultRow: View {
    let vault: VaultStore.ListedVault
    @Environment(VaultStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: vault.inUse ? "checkmark.circle.fill" : vault.missing ? "questionmark.folder" : "folder")
                .foregroundStyle(vault.inUse ? Palette.green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(vault.name)
                Text(vault.missing ? "\(vault.folder) · missing" : vault.folder)
                    .font(.caption).foregroundStyle(vault.missing ? Palette.red : .secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if vault.inUse {
                Text("In use").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Switch") { store.open(URL(filePath: vault.path)) }
                    .disabled(vault.missing || store.changing)
                    .help(vault.missing ? "The folder is not there now; it may be on a disk that is not connected" : "Change to this vault")
                Button("Forget…") { askToForget(vault, store: store) }
                    .help("Takes this vault out of the list. No file is touched.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(vault.name), \(vault.inUse ? "in use" : vault.missing ? "missing" : vault.folder)")
    }
}

/// Forget Vault, after a question. The vault in use is never offered.
@MainActor
func askToForget(_ vault: VaultStore.ListedVault, store: VaultStore) {
    let alert = NSAlert()
    alert.messageText = "Forget \(vault.name)?"
    alert.informativeText = "Daftar takes \(vault.folder) out of its list of vaults. The folder and its notes are not touched, and Open Vault… adds it again."
    alert.addButton(withTitle: "Forget")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { store.forgetVault(vault.path) }
}

extension PaletteCommands {
    /// Switch Vault and Forget Vault: a command for each vault of the list
    /// that is not in use, a missing one left out of Switch, then Open Vault….
    static func vaults(store: VaultStore) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        let listed = store.listedVaults
        for vault in listed where !vault.inUse && !vault.missing {
            out.append(PaletteCommand(id: "switch-vault-" + vault.path, title: "Switch Vault: \(vault.name)", group: "Vault", symbol: "books.vertical.fill", color: Palette.blue) {
                store.open(URL(filePath: vault.path))
            })
        }
        out.append(PaletteCommand(id: "open-vault", title: "Switch Vault: Open Vault…", group: "Vault", symbol: "folder.badge.plus", color: Palette.yellow, shortcut: "⇧⌘O") {
            chooseVault(store)
        })
        for vault in listed where !vault.inUse {
            out.append(PaletteCommand(id: "forget-vault-" + vault.path, title: "Forget Vault: \(vault.name)", group: "Vault", symbol: "minus.circle.fill", color: Palette.red) {
                askToForget(vault, store: store)
            })
        }
        return out
    }
}

/// A text field of the clone's git config: written when it is submitted or
/// left, never at each key.
private struct CommitField: View {
    let title: String
    let prompt: String
    let value: String
    let save: (String) async -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onSubmit(commit)
            .onAppear { text = value }
            .onChange(of: value) { _, value in text = value }
            .onChange(of: focused) { _, focused in if !focused { commit() } }
    }

    private func commit() {
        guard text != value else { return }
        let written = text
        Task {
            await save(written)
            // What git has now: a refused value goes back to the one before.
            text = value
        }
    }
}

/// A control whose setting the open vault sets in its `.daftar.toml`: off,
/// with its value shown and "From the vault" under it.
private struct FromVault: ViewModifier {
    let key: String
    let settings: AppSettings

    func body(content: Content) -> some View {
        if settings.isFromVault(key) {
            VStack(alignment: .leading, spacing: 3) {
                content.disabled(true)
                Label("From the vault", systemImage: "books.vertical")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .help("The vault sets \(key) in its .daftar.toml. To keep this Mac's own value, add \"\(key)\" to vault_settings in the settings file, or set vault_settings = false.")
            .accessibilityHint("From the vault. Change it in the vault's .daftar.toml.")
        } else {
            content
        }
    }
}

extension View {
    /// Shows this control as set by the vault when the vault sets [key].
    func fromVault(_ key: String, _ settings: AppSettings) -> some View { modifier(FromVault(key: key, settings: settings)) }
}
