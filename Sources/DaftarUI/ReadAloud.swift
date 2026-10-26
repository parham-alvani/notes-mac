import AVFoundation
import AppKit
import DaftarCore
import NaturalLanguage
import Observation
import WebKit

/// A note read aloud by the system voice, a block at a time, from the
/// reading cursor on. Each block is said in its own language: a Persian
/// paragraph by a Persian voice when the Mac has one. The page marks the
/// block being read and its cursor follows, so the editor opens there.
@MainActor @Observable
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    /// The note being read, nil when the voice is quiet.
    private(set) var path: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private(set) weak var view: WKWebView?
    /// The page's block number of each utterance.
    @ObservationIgnored private var blocks: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { path != nil }

    /// Starts reading [path] in [view], or stops when it is already reading.
    func toggle(_ path: String, in view: WKWebView) {
        if isSpeaking { return stop() }
        self.view = view
        self.path = path
        Task {
            let result = try? await view.callAsyncJavaScript("return daftar.speechBlocks()", arguments: [:], in: nil, in: .page)
            let items = (result as? [[String: Any]] ?? []).compactMap { item -> (Int, String)? in
                guard let index = item["index"] as? Int, let text = item["text"] as? String else { return nil }
                return (index, text)
            }
            guard self.path == path, !items.isEmpty else { return stop() }
            for (index, text) in items {
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = Self.voice(for: text)
                utterance.postUtteranceDelay = 0.15
                blocks[ObjectIdentifier(utterance)] = index
                synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        blocks = [:]
        if path != nil { mark(-1) }
        path = nil
    }

    /// The voice of the text's own language, or the system's when the Mac has none for it.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage?.rawValue else { return nil }
        let system = AVSpeechSynthesisVoice(language: nil)
        if let system, system.language.hasPrefix(language) { return system }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? system
    }

    private func mark(_ index: Int) {
        view?.callAsyncJavaScript("daftar.speaking(index)", arguments: ["index": index], in: nil, in: .page)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let index = blocks[id] { mark(index) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            blocks[id] = nil
            if blocks.isEmpty, path != nil { stop() }
        }
    }
}

extension Detected {
    /// An address in Maps, a number in the app that makes calls (FaceTime, or the iPhone through it).
    @MainActor static func open(kind: String, value: String) {
        let url: URL?
        switch kind {
        case Kind.phone.rawValue: url = URL(string: "tel:" + value.filter { $0.isNumber || $0 == "+" })
        case Kind.address.rawValue:
            var parts = URLComponents(string: "https://maps.apple.com/")!
            parts.queryItems = [URLQueryItem(name: "q", value: value)]
            url = parts.url
        default: url = nil
        }
        if let url { NSWorkspace.shared.open(url) }
    }
}
