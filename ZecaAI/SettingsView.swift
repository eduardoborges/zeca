import SwiftUI

/// Configuracoes (menu Zeca AI > Settings ou Cmd+,), tudo num form unico por secoes.
struct SettingsView: View {
    @AppStorage("asrLanguage") private var language = "auto"
    @EnvironmentObject private var summarizer: Summarizer
    @ObservedObject private var google = GoogleCalendar.shared
    @ObservedObject private var llm = LocalLLM.shared

    private let languages: [(code: String, label: String)] = [
        ("auto", "Detect automatically"),
        ("pt", "Portuguese"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
    ]

    var body: some View {
        Form {
            transcriptionSection
            summaryOutputSection
            providerSection
            calendarSection
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 640)
    }

    // MARK: - Transcricao

    @ViewBuilder
    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Language", selection: $language) {
                ForEach(languages, id: \.code) { item in
                    Text(item.label).tag(item.code)
                }
            }
            Text("Applies to live transcription and \"Redo analysis\". \"Detect automatically\" handles mixed-language meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Saida do resumo

    @ViewBuilder
    private var summaryOutputSection: some View {
        Section("Summary output") {
            Picker("Language", selection: Binding(
                get: { summarizer.summaryLanguage }, set: { summarizer.summaryLanguage = $0 })) {
                ForEach(Summarizer.languages, id: \.code) { item in
                    Text(item.label).tag(item.code)
                }
            }
            Text("Applies to the summary, the point by point and automatic titles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Provider do resumo

    @ViewBuilder
    private var providerSection: some View {
        Section("Summary provider") {
            Picker("Provider", selection: Binding(
                get: { summarizer.provider },
                set: {
                    summarizer.provider = $0
                    // Ja dispara o download do modelo ao escolher o on-device.
                    if $0 == "mlx" { llm.prepare() }
                })) {
                Text("Claude (API)").tag("claude")
                Text("On-device (built-in)").tag("mlx")
                Text("On-device (Apple Intelligence)").tag("local")
            }
            .pickerStyle(.radioGroup)

            if summarizer.usesMLX {
                mlxRows
            } else if summarizer.usesLocal {
                Text(Summarizer.localAvailable
                     ? "Runs on Apple's built-in on-device model. Nothing to install, nothing leaves your Mac. Long meetings are summarized in two passes."
                     : "Not available on this Mac. It needs macOS 26 with Apple Intelligence enabled in System Settings.")
                    .font(.caption)
                    .foregroundStyle(Summarizer.localAvailable ? Color.secondary : .orange)
            } else {
                Picker("Model", selection: Binding(
                    get: { summarizer.claudeModel }, set: { summarizer.claudeModel = $0 })) {
                    ForEach(Summarizer.claudeModels, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                SecureField("Anthropic API key", text: Binding(
                    get: { summarizer.apiKey }, set: { summarizer.apiKey = $0 }))
                Text("Used only for summaries. Stored on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Linhas do provider embarcado: escolha de modelo, estado e acoes de download.
    @ViewBuilder
    private var mlxRows: some View {
        Picker("Model", selection: Binding(
            get: { llm.modelID }, set: { llm.selectModel($0) })) {
            ForEach(LocalLLM.models, id: \.id) { item in
                Text(item.label).tag(item.id)
            }
        }
        Text("Runs inside the app (MLX). Nothing to install, nothing leaves your Mac. Requires Apple Silicon.")
            .font(.caption)
            .foregroundStyle(.secondary)

        switch llm.state {
        case .ready:
            HStack {
                Label("Model downloaded and ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Delete model", role: .destructive) { llm.deleteModel() }
                    .help("Removes the weights from disk. You can download them again anytime.")
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                HStack {
                    Text("Downloading model... \(Int(fraction * 100))%. Summaries stay unavailable until it finishes. Keep the app open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart download") { llm.restartDownload() }
                        .help("Clears the partial download and starts over.")
                }
            }
        case .notDownloaded:
            HStack {
                Text("The model needs to be downloaded once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download model") { llm.prepare() }
            }
        }
    }

    // MARK: - Calendario

    @ViewBuilder
    private var calendarSection: some View {
        Section("Google Calendar") {
            if google.isConnected {
                LabeledContent("Status") {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("Disconnect") { google.disconnect() }
            } else {
                TextField("OAuth Client ID", text: $google.clientId)
                SecureField("OAuth Client Secret", text: $google.clientSecret)
                HStack {
                    Button(google.connecting ? "Waiting for browser..." : "Connect Google account") {
                        google.connect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(google.connecting || google.clientId.isEmpty)
                    if google.connecting {
                        Button("Cancel") { google.cancelConnect() }
                    }
                }
                Text("Create a Desktop-app OAuth client at console.cloud.google.com (APIs & Services > Credentials), enable the Google Calendar API, and paste the ID and secret here. Read-only access; tokens stay on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Open Google Cloud Console",
                     destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
            }
            if let error = google.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        Section("macOS Calendar") {
            Text("Events from the system calendar (including Google accounts added in System Settings > Internet Accounts) always appear on the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
