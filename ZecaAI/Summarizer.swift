import Foundation
import FoundationModels
import SwiftUI

/// Gera um resumo da reuniao (Claude API ou o modelo local do Apple Intelligence)
/// e salva em summary.md na pasta da gravacao.
@MainActor
final class Summarizer: ObservableObject {
    @AppStorage("anthropicKey") var apiKey = ""
    @AppStorage("summaryProvider") var provider = "claude" // "claude" | "openai" | "local" | "mlx"
    @AppStorage("summaryLanguage") var summaryLanguage = "auto" // "auto" | codigo ISO
    @AppStorage("claudeModel") var claudeModel = "claude-opus-5"
    // Qualquer servidor compativel com a API da OpenAI (OpenAI, OpenRouter, Groq, Ollama...).
    static let openaiDefaultURL = "https://api.openai.com/v1"
    static let openaiDefaultModel = "gpt-4o-mini"
    @AppStorage("openaiCustomServer") var openaiCustomServer = false
    @AppStorage("openaiBaseURL") var openaiBaseURL = openaiDefaultURL
    @AppStorage("openaiKey") var openaiKey = ""
    @AppStorage("openaiModel") var openaiModel = openaiDefaultModel

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
    /// Modelos listados pelo servidor OpenAI-compativel (GET /models).
    @Published var openaiModels: [String] = []
    @Published var fetchingModels = false
    /// Progresso extra (ex.: download do modelo MLX) mostrado no lugar do rotulo padrao.
    @Published var status: String?
    /// Texto parcial da geracao em andamento, atualizado token a token.
    @Published private(set) var streaming: String?

    var usesLocal: Bool { provider == "local" }
    var usesMLX: Bool { provider == "mlx" }
    var usesOpenAI: Bool { provider == "openai" }

    init() {
        // Retoma um download interrompido do modelo embarcado ao abrir o app.
        if usesMLX, LocalLLM.shared.state != .ready { LocalLLM.shared.prepare() }
    }

    /// Nome exibido nos indicadores de progresso.
    var providerName: String {
        if usesMLX { return LocalLLM.shared.displayName }
        if usesLocal { return "Apple Intelligence (on-device)" }
        if usesOpenAI { return openaiModel.isEmpty ? "OpenAI-compatible API" : openaiModel }
        let short = Self.claudeModels.first { $0.id == claudeModel }
            .map { $0.label.components(separatedBy: " (")[0] }
        return short.map { "Claude \($0)" } ?? "Claude"
    }

    /// Ha um provedor utilizavel configurado?
    var isConfigured: Bool {
        if usesMLX { return LocalLLM.shared.state == .ready }
        if usesOpenAI { return !openaiBaseURL.isEmpty && !openaiModel.isEmpty }
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
        // Sidecar com o modelo que gerou; o card mostra no rodape.
        try? providerName.write(to: recording.url.appendingPathComponent("summary.model.txt"),
                                atomically: true, encoding: .utf8)
        return text
    }

    /// Ponto a ponto da reuniao (bloco separado do resumo). Salva em notes.md.
    func runNotes(_ recording: Recording, turns: [Turn]) async -> String? {
        guard let text = await complete(
            turns: turns,
            system: """
            You write a detailed, faithful account of a meeting. \(languageInstruction) Go through the conversation in order and split it into its natural parts — at most 12 parts. For each part produce:

            **Short topic title**
            One full paragraph describing that part of the discussion: what was raised, the arguments and examples given, the reactions, and how that part ended.

            Describe everything in your own words, as reported speech — never quote lines verbatim from the transcript. The transcript only identifies speakers as "You" and "Others", so name a person only when the transcript itself makes clear who is speaking or being addressed; otherwise write "the speaker", "someone", or no attribution at all. Be thorough and keep the detail; length is not a problem. The topic title goes in bold with ** on its own line, followed by the paragraph. No introduction, no conclusion, no bullets, never use # or Markdown headers. Stay faithful to the transcript, do not invent. Never repeat a sentence or paragraph you have already written.
            """,
            maxTokens: 8192)
        else { return nil }
        try? text.write(to: recording.notesURL, atomically: true, encoding: .utf8)
        try? providerName.write(to: recording.url.appendingPathComponent("notes.model.txt"),
                                atomically: true, encoding: .utf8)
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
            One bullet (-) per action someone committed to or was assigned, at most 8 bullets in total. The transcript only identifies speakers as "You" and "Others", so you usually do not know who is who: start a bullet with a person's name in bold only when the transcript itself makes clear that person took the action on. When the owner is not clear, write the action without a name. Never list a person who has no action. Omit the whole section if there are no real commitments.

            Section titles in bold with **, never use # or Markdown headers. Stay faithful to the transcript, do not invent. Never repeat a bullet you have already written.
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
        // label, nao speaker.label: reuniao importada e renames manuais trazem o nome real.
        let transcript = turns.map { "[\($0.label)] \($0.text)" }.joined(separator: "\n")
        // A instrucao de idioma volta no fim: entre ela no system e a resposta ha uma
        // transcricao inteira, e modelo pequeno segue o idioma do que leu por ultimo.
        // Medido: o Qwen 3.5 9B respondia em ingles numa reuniao de 36min e passou a
        // respeitar o portugues so com essa repeticao.
        let user = "Meeting transcript (\"You\" = microphone, \"Others\" = system audio):"
            + "\n\n\(transcript)\n\n\(languageInstruction)"
        isRunning = true
        defer { isRunning = false }
        return await route(system: system, user: user, maxTokens: maxTokens)
    }

    private func route(system: String, user: String, maxTokens: Int) async -> String? {
        streaming = nil
        defer { streaming = nil }
        if usesMLX { return await completeMLX(system: system, user: user) }
        if usesLocal { return await completeLocal(system: system, user: user) }
        if usesOpenAI { return await completeOpenAI(system: system, user: user, maxTokens: maxTokens) }
        return await completeClaude(system: system, user: user, maxTokens: maxTokens)
    }

    /// Le uma resposta SSE linha a linha, publicando o texto conforme chega.
    /// `chunk` extrai o pedaco de texto de cada evento (o formato muda por provider).
    private func streamSSE(
        _ request: URLRequest, chunk: ([String: Any]) -> String?
    ) async throws -> String? {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // O corpo do erro tambem chega como stream; junta tudo e le a mensagem.
            var body = ""
            for try await line in bytes.lines { body += line }
            let json = try? JSONSerialization.jsonObject(
                with: Data(body.utf8)) as? [String: Any]
            error = (json?["error"] as? [String: Any])?["message"] as? String ?? "API error."
            return nil
        }
        var out = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let json = try? JSONSerialization.jsonObject(
                    with: Data(payload.utf8)) as? [String: Any]
            else { continue }
            if let message = (json["error"] as? [String: Any])?["message"] as? String {
                error = message
                return nil
            }
            guard let piece = chunk(json), !piece.isEmpty else { continue }
            out += piece
            streaming = out
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            error = "The model returned an empty answer."
            return nil
        }
        return text
    }

    /// Lista os modelos do servidor configurado (GET /models).
    func fetchOpenAIModels() async {
        let base = openaiBaseURL.hasSuffix("/") ? String(openaiBaseURL.dropLast()) : openaiBaseURL
        guard let url = URL(string: "\(base)/models") else {
            error = "Invalid base URL."
            return
        }
        fetchingModels = true
        defer { fetchingModels = false }
        var request = URLRequest(url: url)
        if !openaiKey.isEmpty {
            request.setValue("Bearer \(openaiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = json?["data"] as? [[String: Any]] else {
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                error = message ?? "Could not list models."
                return
            }
            openaiModels = list.compactMap { $0["id"] as? String }.sorted()
            error = openaiModels.isEmpty ? "The server returned no models." : nil
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    /// Qualquer endpoint compativel com /chat/completions da OpenAI.
    /// A chave e opcional (servidores locais como Ollama/LM Studio nao exigem).
    private func completeOpenAI(system: String, user: String, maxTokens: Int) async -> String? {
        let base = openaiBaseURL.hasSuffix("/") ? String(openaiBaseURL.dropLast()) : openaiBaseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            error = "Invalid base URL."
            return nil
        }
        let body: [String: Any] = [
            "model": openaiModel,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !openaiKey.isEmpty {
            request.setValue("Bearer \(openaiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        do {
            return try await streamSSE(request) { json in
                let choices = json["choices"] as? [[String: Any]]
                let delta = choices?.first?["delta"] as? [String: Any]
                return delta?["content"] as? String
            }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return nil
        }
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
            let live: (String) -> Void = { [weak self] text in self?.streaming = text }
            let chunkLimit = 60_000 // ~15k tokens por parte, folga pros 32k do Qwen3
            if user.count <= chunkLimit {
                return try await LocalLLM.shared.generate(
                    system: system, prompt: user, onPartial: live)
            }
            var partials: [String] = []
            var start = user.startIndex
            while start < user.endIndex {
                let end = user.index(start, offsetBy: chunkLimit, limitedBy: user.endIndex) ?? user.endIndex
                partials.append(try await LocalLLM.shared.generate(
                    system: "Rewrite this part of a meeting transcript as detailed notes in reported speech. \(languageInstruction) Keep every point, decision, example and speaker attribution, but describe it in your own words — never copy lines verbatim.",
                    prompt: String(user[start..<end]),
                    onPartial: live))
                start = end
            }
            return try await LocalLLM.shared.generate(
                system: system,
                prompt: "These are partial summaries of consecutive parts of one meeting:\n\n" +
                    partials.joined(separator: "\n\n---\n\n"),
                onPartial: live)
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
            let live: (String) -> Void = { [weak self] text in self?.streaming = text }
            let chunkLimit = 10_000
            if user.count <= chunkLimit {
                return try await Self.respond(
                    instructions: system, prompt: user, onPartial: live)
            }
            var partials: [String] = []
            var start = user.startIndex
            while start < user.endIndex {
                let end = user.index(start, offsetBy: chunkLimit, limitedBy: user.endIndex) ?? user.endIndex
                let chunk = String(user[start..<end])
                partials.append(try await Self.respond(
                    instructions: "Rewrite this part of a meeting transcript as detailed notes in reported speech. \(languageInstruction) Keep every point, decision, example and speaker attribution, but describe it in your own words — never copy lines verbatim.",
                    prompt: chunk,
                    onPartial: live))
                start = end
            }
            return try await Self.respond(
                instructions: system,
                prompt: "These are partial summaries of consecutive parts of one meeting:\n\n" +
                    partials.joined(separator: "\n\n---\n\n"),
                onPartial: live)
        } catch {
            if !(error is CancellationError) { self.error = "Local model error: \(error.localizedDescription)" }
            return nil
        }
    }

    @available(macOS 26.0, *)
    private static func respond(
        instructions: String, prompt: String, onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        // O stream do FoundationModels entrega snapshots do texto inteiro, nao deltas.
        var out = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            out = snapshot.content
            onPartial?(out)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeClaude(system: String, user: String, maxTokens: Int) async -> String? {
        guard !apiKey.isEmpty else { error = "Paste your Anthropic API key."; return nil }
        let body: [String: Any] = [
            "model": claudeModel,
            "max_tokens": maxTokens,
            "stream": true,
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
            var refused = false
            let text = try await streamSSE(request) { json in
                switch json["type"] as? String {
                case "content_block_delta":
                    let delta = json["delta"] as? [String: Any]
                    // So o texto: um bloco de thinking traz "thinking" e e ignorado.
                    return delta?["text"] as? String
                case "message_delta":
                    let delta = json["delta"] as? [String: Any]
                    if delta?["stop_reason"] as? String == "refusal" { refused = true }
                    return nil
                default:
                    return nil
                }
            }
            if refused {
                error = "The API refused the request."
                return nil
            }
            return text
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return nil
        }
    }
}
