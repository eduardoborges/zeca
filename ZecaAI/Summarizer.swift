import Foundation
import SwiftUI

/// Gera um resumo da reuniao via API do Claude e salva em summary.md na pasta da gravacao.
@MainActor
final class Summarizer: ObservableObject {
    @AppStorage("anthropicKey") var apiKey = ""
    @Published private(set) var isRunning = false
    @Published var error: String?

    func run(_ recording: Recording, turns: [Turn]) async -> String? {
        guard let text = await summarize(turns) else { return nil }
        try? text.write(to: recording.summaryURL, atomically: true, encoding: .utf8)
        return text
    }

    /// Gera o resumo sem tocar no disco. Usado pelo fluxo normal e pelo resumo ao vivo.
    func summarize(_ turns: [Turn]) async -> String? {
        await complete(
            turns: turns,
            system: "Voce resume reunioes em portugues. Produza as secoes: **Resumo** (2-3 frases), **Pontos principais** (bullets com -) e **Proximos passos** (bullets; omita a secao se nao houver). Titulos de secao em negrito com **, nunca use # nem cabecalhos Markdown. Seja fiel a transcricao, sem inventar.",
            maxTokens: 2048)
    }

    /// Titulo curto pra reuniao sem nome, no idioma predominante da conversa.
    func title(for turns: [Turn]) async -> String? {
        guard let raw = await complete(
            turns: turns,
            system: "Gere um titulo curto (3 a 6 palavras) para esta reuniao, no idioma predominante da conversa. Responda SOMENTE o titulo, sem aspas, sem ponto final.",
            maxTokens: 50)
        else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”."))
        return title.isEmpty ? nil : String(title.prefix(60))
    }

    private func complete(turns: [Turn], system: String, maxTokens: Int) async -> String? {
        guard !apiKey.isEmpty else { error = "Cole sua chave da API da Anthropic."; return nil }
        isRunning = true
        defer { isRunning = false }

        let transcript = turns.map { "[\($0.speaker.label)] \($0.text)" }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": "Transcricao da reuniao (\"Voce\" = microfone, \"Outros\" = audio do sistema):\n\n\(transcript)"]],
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
                error = message ?? "Erro na API."
                return nil
            }
            if json?["stop_reason"] as? String == "refusal" {
                error = "A API recusou o pedido."
                return nil
            }
            guard let content = json?["content"] as? [[String: Any]],
                  let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
            else {
                error = "Resposta inesperada da API."
                return nil
            }
            return text
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
