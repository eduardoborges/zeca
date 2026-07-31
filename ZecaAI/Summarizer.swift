import Foundation
import FoundationModels
import SwiftUI

/// Gera um resumo da reuniao (Claude API ou o modelo local do Apple Intelligence)
/// e salva em summary.md na pasta da gravacao.
@MainActor
final class Summarizer: ObservableObject {
    @AppStorage("anthropicKey") var apiKey = ""
    @AppStorage("summaryProvider") var provider = "claude" // "claude" | "local" | "mlx"
    @AppStorage("summaryLanguage") var summaryLanguage = "auto" // "auto" | codigo ISO
    @AppStorage("claudeModel") var claudeModel = "claude-opus-5"

    static let claudeModels: [(id: String, label: String)] = [
        ("claude-opus-5", "Opus 5 (most capable)"),
        ("claude-sonnet-5", "Sonnet 5 (balanced)"),
        ("claude-haiku-4-5", "Haiku 4.5 (fastest)"),
    ]

    static let languages: [(code: String, label: String)] = [
        ("auto", "Same as the meeting"),
        ("pt", "Portuguese"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
    ]

    /// Instrucao de idioma injetada em todos os prompts.
    private var languageInstruction: String {
        guard summaryLanguage != "auto",
              let name = Self.languages.first(where: { $0.code == summaryLanguage })?.label
        else { return "Write in the predominant language of the transcript." }
        return "Write in \(name), regardless of the language spoken in the meeting."
    }
    @Published private(set) var isRunning = false
    @Published var error: String?
    /// Progresso extra (ex.: download do modelo MLX) mostrado no lugar do rotulo padrao.
    @Published var status: String?

    var usesLocal: Bool { provider == "local" }
    var usesMLX: Bool { provider == "mlx" }

    init() {
        // Retoma um download interrompido do modelo embarcado ao abrir o app.
        if usesMLX, LocalLLM.shared.state != .ready { LocalLLM.shared.prepare() }
    }

    /// Nome exibido nos indicadores de progresso.
    var providerName: String {
        if usesMLX { return LocalLLM.shared.displayName }
        if usesLocal { return "Apple Intelligence (on-device)" }
        let short = Self.claudeModels.first { $0.id == claudeModel }
            .map { $0.label.components(separatedBy: " (")[0] }
        return short.map { "Claude \($0)" } ?? "Claude"
    }

    /// Ha um provedor utilizavel configurado?
    var isConfigured: Bool {
        if usesMLX { return LocalLLM.shared.state == .ready }
        return usesLocal || !apiKey.isEmpty
    }

    /// O modelo on-device existe e esta pronto? (macOS 26+ com Apple Intelligence)
    static var localAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    func run(_ recording: Recording, turns: [Turn]) async -> String? {
        guard let text = await summarize(turns) else { return nil }
        try? text.write(to: recording.summaryURL, atomically: true, encoding: .utf8)
        return text
    }

    /// Ponto a ponto da reuniao (bloco separado do resumo). Salva em notes.md.
    func runNotes(_ recording: Recording, turns: [Turn]) async -> String? {
        guard let text = await complete(
            turns: turns,
            system: """
            You write a detailed, faithful account of a meeting. \(languageInstruction) Go through the conversation in order and split it into its natural parts. For each part produce:

            **Short topic title**
            One full paragraph describing that part of the discussion: what was raised, by whom, the arguments and examples given, the reactions, and how that part ended.

            Describe everything in your own words, as reported speech (e.g. "Maria suggested that...") — NEVER quote lines verbatim from the transcript. Be thorough and keep the detail; length is not a problem. The topic title goes in bold with ** on its own line, followed by the paragraph. No introduction, no conclusion, no bullets, never use # or Markdown headers. Stay faithful to the transcript, do not invent.
            """,
            maxTokens: 8192)
        else { return nil }
        try? text.write(to: recording.notesURL, atomically: true, encoding: .utf8)
        return text
    }

    /// Gera o resumo sem tocar no disco. Usado pelo fluxo normal e pelo resumo ao vivo.
    func summarize(_ turns: [Turn]) async -> String? {
        await complete(
            turns: turns,
            system: """
            You summarize meetings. \(languageInstruction) Produce exactly these sections:

            **Quick recap**
            One paragraph (3-5 sentences) with the essence of the meeting: what it was about, the key facts and how it ended.

            **Next steps**
            Grouped by person: the person's name in bold (**Name**) on its own line, then one bullet (-) per action that person committed to or was assigned. Only include real commitments from the conversation. Omit the whole section if there are none.

            Section titles in bold with **, never use # or Markdown headers. Stay faithful to the transcript, do not invent.
            """,
            maxTokens: 2048)
    }

    /// Short title for an unnamed meeting, in the language of the conversation.
    func title(for turns: [Turn]) async -> String? {
        guard let raw = await complete(
            turns: turns,
            system: "Generate a short title (3 to 6 words) for this meeting. \(languageInstruction) Reply with ONLY the title, no quotes, no trailing period.",
            maxTokens: 50)
        else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”."))
        return title.isEmpty ? nil : String(title.prefix(60))
    }

    /// Traduz a conversa inteira, preservando falante e tempos. Lotes de linhas numeradas.
    func translate(_ turns: [Turn], to code: String) async -> [Turn]? {
        guard let name = Self.languages.first(where: { $0.code == code })?.label else { return nil }
        isRunning = true
        defer { isRunning = false }
        var result = turns
        let batchSize = 40
        var index = 0
        while index < turns.count {
            let upper = min(index + batchSize, turns.count)
            let numbered = (index..<upper)
                .map { "\($0 - index): \(turns[$0].text)" }
                .joined(separator: "\n")
            guard let out = await route(
                system: "Translate each numbered line into \(name). Return ONLY the same numbered lines, one per line, in the format \"N: translation\". Keep the meaning and tone; do not merge, drop or add lines.",
                user: numbered,
                maxTokens: 8192)
            else { return nil }
            for line in out.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":"),
                      let n = Int(line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)),
                      index + n < upper else { continue }
                let translated = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard !translated.isEmpty else { continue }
                let old = turns[index + n]
                result[index + n] = Turn(speaker: old.speaker, start: old.start, end: old.end,
                                         text: translated, who: old.who)
            }
            index = upper
        }
        return result
    }

    /// Traduz um texto ja gerado (resumo ou ponto a ponto), preservando o Markdown.
    func translateText(_ text: String, to code: String) async -> String? {
        guard let name = Self.languages.first(where: { $0.code == code })?.label else { return nil }
        isRunning = true
        defer { isRunning = false }
        return await route(
            system: "Translate the following meeting notes into \(name). Keep the Markdown formatting exactly as is (bold with **, bullets with -). Return ONLY the translation, nothing else.",
            user: text,
            maxTokens: 8192)
    }

    private func complete(turns: [Turn], system: String, maxTokens: Int) async -> String? {
        let transcript = turns.map { "[\($0.speaker.label)] \($0.text)" }.joined(separator: "\n")
        let user = "Meeting transcript (\"You\" = microphone, \"Others\" = system audio):\n\n\(transcript)"
        isRunning = true
        defer { isRunning = false }
        return await route(system: system, user: user, maxTokens: maxTokens)
    }

    private func route(system: String, user: String, maxTokens: Int) async -> String? {
        if usesMLX { return await completeMLX(system: system, user: user) }
        if usesLocal { return await completeLocal(system: system, user: user) }
        return await completeClaude(system: system, user: user, maxTokens: maxTokens)
    }

    /// LLM embarcado (MLX). Contexto de 32k tokens: transcricoes muito longas
    /// passam pelas mesmas duas etapas do provider local.
    private func completeMLX(system: String, user: String) async -> String? {
        guard LocalLLM.shared.state == .ready else {
            error = "The on-device model is still downloading. Follow the progress in Settings."
            return nil
        }
        LocalLLM.shared.onStatus = { [weak self] in self?.status = $0 }
        defer { status = nil }
        do {
            let chunkLimit = 60_000 // ~15k tokens por parte, folga pros 32k do Qwen3
            if user.count <= chunkLimit {
                return try await LocalLLM.shared.generate(system: system, prompt: user)
            }
            var partials: [String] = []
            var start = user.startIndex
            while start < user.endIndex {
                let end = user.index(start, offsetBy: chunkLimit, limitedBy: user.endIndex) ?? user.endIndex
                partials.append(try await LocalLLM.shared.generate(
                    system: "Rewrite this part of a meeting transcript as detailed notes in reported speech. \(languageInstruction) Keep every point, decision, example and speaker attribution, but describe it in your own words — never copy lines verbatim.",
                    prompt: String(user[start..<end])))
                start = end
            }
            return try await LocalLLM.shared.generate(
                system: system,
                prompt: "These are partial summaries of consecutive parts of one meeting:\n\n" +
                    partials.joined(separator: "\n\n---\n\n"))
        } catch {
            if !(error is CancellationError) {
                self.error = "On-device model error: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Modelo on-device do Apple Intelligence (FoundationModels). Nada sai da maquina,
    /// nada precisa ser instalado. Janela de contexto curta: transcricoes longas
    /// passam por duas etapas (resumo das partes -> resumo final).
    private func completeLocal(system: String, user: String) async -> String? {
        guard #available(macOS 26.0, *) else {
            error = "The local model needs macOS 26 or later. Use Claude (API) instead."
            return nil
        }
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            error = "Apple Intelligence is not available. Enable it in System Settings > Apple Intelligence & Siri."
            return nil
        }
        do {
            // ponytail: corte por caracteres (~4 chars/token); refinar se estourar na pratica.
            let chunkLimit = 10_000
            if user.count <= chunkLimit {
                return try await Self.respond(instructions: system, prompt: user)
            }
            var partials: [String] = []
            var start = user.startIndex
            while start < user.endIndex {
                let end = user.index(start, offsetBy: chunkLimit, limitedBy: user.endIndex) ?? user.endIndex
                let chunk = String(user[start..<end])
                partials.append(try await Self.respond(
                    instructions: "Rewrite this part of a meeting transcript as detailed notes in reported speech. \(languageInstruction) Keep every point, decision, example and speaker attribution, but describe it in your own words — never copy lines verbatim.",
                    prompt: chunk))
                start = end
            }
            return try await Self.respond(
                instructions: system,
                prompt: "These are partial summaries of consecutive parts of one meeting:\n\n" +
                    partials.joined(separator: "\n\n---\n\n"))
        } catch {
            if !(error is CancellationError) { self.error = "Local model error: \(error.localizedDescription)" }
            return nil
        }
    }

    @available(macOS 26.0, *)
    private static func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeClaude(system: String, user: String, maxTokens: Int) async -> String? {
        guard !apiKey.isEmpty else { error = "Paste your Anthropic API key."; return nil }
        let body: [String: Any] = [
            "model": claudeModel,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                error = message ?? "API error."
                return nil
            }
            if json?["stop_reason"] as? String == "refusal" {
                error = "The API refused the request."
                return nil
            }
            guard let content = json?["content"] as? [[String: Any]],
                  let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
            else {
                error = "Unexpected API response."
                return nil
            }
            return text
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return nil
        }
    }
}
