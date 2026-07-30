import SwiftUI

/// Configuracoes do app (menu Zeca AI > Settings ou Cmd+,).
struct SettingsView: View {
    @AppStorage("asrModel") private var modelId = "parakeet-v3"
    @AppStorage("asrLanguage") private var language = "auto"
    @EnvironmentObject private var summarizer: Summarizer

    private let languages: [(code: String, label: String)] = [
        ("auto", "Detectar automaticamente"),
        ("pt", "Português"),
        ("en", "Inglês"),
        ("es", "Espanhol"),
        ("fr", "Francês"),
        ("de", "Alemão"),
    ]

    var body: some View {
        Form {
            Section("Modelo de transcrição") {
                ForEach(AsrModelInfo.catalog) { model in
                    ModelRow(model: model, selected: model.id == modelId)
                        .contentShape(Rectangle())
                        .onTapGesture { modelId = model.id }
                }
                Text("A transcrição ao vivo usa Parakeet (único com streaming). Se um Whisper estiver selecionado, ele vale para a transcrição final e o \"Refazer transcrição\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Idioma") {
                Picker("Idioma da transcrição", selection: $language) {
                    ForEach(languages, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
            }
            Section("Resumo") {
                SecureField("Chave da API da Anthropic", text: Binding(
                    get: { summarizer.apiKey }, set: { summarizer.apiKey = $0 }))
                Text("Usada só para os resumos. Fica salva no seu Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}

private struct ModelRow: View {
    let model: AsrModelInfo
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.primary : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.name).fontWeight(.medium)
                    Text(model.languages)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                HStack(spacing: 14) {
                    Stars(label: "Precisão", count: model.accuracyStars, tint: .primary)
                    Stars(label: "Velocidade", count: model.speedStars, tint: .secondary)
                    Text(model.storage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct Stars: View {
    let label: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < count ? "star.fill" : "star")
                    .font(.system(size: 8))
                    .foregroundStyle(index < count ? tint : .secondary.opacity(0.4))
            }
        }
    }
}
