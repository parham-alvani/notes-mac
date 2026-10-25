import AppKit
import DaftarCore
import FoundationModels
import SwiftUI

/// Apple Intelligence on the open note: a summary, its key points, the
/// tasks it implies, or an answer to a question about it. Only the model on
/// this Mac is asked, never Private Cloud Compute: a vault can hold other
/// people's notes, and they stay on the machine.
@MainActor @Observable
final class NoteAssistant {
    enum Ask: Equatable {
        case summary, points, tasks
        case question(String)
    }

    private(set) var output = ""
    private(set) var working = false
    private(set) var failure: String?
    private var job: Task<Void, Never>?

    /// Why the model cannot answer, or nil when it can.
    static var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac cannot run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting its model ready. Try again in a few minutes."
        case .unavailable: "Apple Intelligence is not available now."
        }
    }

    /// The model reads a few thousand words at most: a longer note is cut,
    /// and the answer says so.
    static let limit = 12_000

    static func prompt(_ ask: Ask, title: String, text: String) -> String {
        let cut = text.count > limit
        let body = cut ? String(text.prefix(limit)) : text
        let what = switch ask {
        case .summary: "Summarize this note in a short paragraph, then at most five bullet points."
        case .points: "List the key points of this note as short bullet points."
        case .tasks:
            """
            List every task in this note, one per line, each as `- [ ] ` and then the task: who does what,             in the note's words. A date goes only on the task it belongs to, as ` 📅 YYYY-MM-DD` at the end.             Do not move a date to another task, and write no other text.
            """
        case .question(let question): "Answer this question about the note, from the note only: \(question)"
        }
        return "\(what)\(cut ? " Only the first part of the note is given." : "")\n\nThe note is called “\(title)”.\n\n\(body)"
    }

    func run(_ ask: Ask, title: String, text: String) {
        job?.cancel()
        output = ""
        failure = nil
        if let reason = Self.unavailable {
            failure = reason
            return
        }
        working = true
        let prompt = Self.prompt(ask, title: title, text: text)
        job = Task {
            defer { working = false }
            let session = LanguageModelSession(instructions: """
                You help a person with their own notes, which are Markdown files in an Obsidian vault. \
                Answer in the language the note is written in. Be brief and exact, and use Markdown.
                """)
            do {
                // Low temperature: the notes are facts, not a story.
                for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.2)) {
                    guard !Task.isCancelled else { return }
                    output = snapshot.content
                }
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                failure = "The note is too long for the model on this Mac."
            } catch LanguageModelSession.GenerationError.guardrailViolation {
                failure = "Apple Intelligence declined to answer about this note."
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    func stop() {
        job?.cancel()
        working = false
    }
}

/// ⌥⌘A: the assistant's sheet, in glass.
struct AssistantSheet: View {
    var model: WindowModel
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var assistant = NoteAssistant()
    @ViewState private var question = ""
    @ViewState private var last: NoteAssistant.Ask?
    @FocusState private var asking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    choice("Summary", "text.alignleft", .summary)
                    choice("Key Points", "list.bullet", .points)
                    choice("Tasks", "checklist", .tasks)
                }
            }
            HStack {
                TextField("Ask about this note", text: $question)
                    .textFieldStyle(.plain)
                    .focused($asking)
                    .onSubmit { ask(.question(question)) }
                Button { ask(.question(question)) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.glassProminent)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 12).padding(4)
            .glassEffect(.regular, in: .capsule)
            answer
            HStack {
                if assistant.working {
                    ProgressView().controlSize(.small)
                    Button("Stop") { assistant.stop() }.buttonStyle(.glass)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(assistant.output, forType: .string)
                }
                .buttonStyle(.glass)
                .disabled(assistant.output.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
        .onAppear {
            if NoteAssistant.unavailable == nil { ask(.summary) } else { asking = true }
        }
        .onDisappear { assistant.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: assistant.working)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(colors: [Palette.blue, Palette.purple, Palette.pink, Palette.accent], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence").font(.title3.weight(.semibold))
                Text(model.path.map(Vault.title(of:)) ?? "No note").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Label("On this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                .help("The note is read by the model on this Mac only; nothing is sent to a server.")
        }
    }

    private func choice(_ title: String, _ symbol: String, _ ask: NoteAssistant.Ask) -> some View {
        Button { self.ask(ask) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.glass)
            .tint(last == ask ? Palette.accent : nil)
    }

    @ViewBuilder private var answer: some View {
        ScrollView {
            Group {
                if let failure = assistant.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.red)
                } else if assistant.output.isEmpty {
                    Text(assistant.working ? "Reading the note…" : "Choose what to make of the note, or ask about it.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.markdown(assistant.output)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular.tint(Palette.purple.opacity(0.08)), in: .rect(cornerRadius: 14))
    }

    /// The answer's bold, italics and code, with its lines kept.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func ask(_ ask: NoteAssistant.Ask) {
        guard let path = model.path else { return }
        last = ask
        Task {
            // What is typed in the editor is part of the note.
            await store.flushEditors()
            assistant.run(ask, title: Vault.title(of: path), text: store.text(of: path) ?? "")
        }
    }
}
