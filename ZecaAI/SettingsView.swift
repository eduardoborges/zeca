import SwiftUI

/// Configuracoes (menu Zeca AI > Settings ou Cmd+,), tudo num form unico por secoes.
struct SettingsView: View {
    @EnvironmentObject private var summarizer: Summarizer
    @ObservedObject private var google = GoogleCalendar.shared
    @ObservedObject private var llm = LocalLLM.shared

    var body: some View {
        Form {
            summaryOutputSection
            providerSection
            calendarSection
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 640)
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
            groupHeader("On-device (nothing leaves your Mac)")
            providerChoice("mlx", "Built-in model (MLX)")
            providerChoice("local", "Apple Intelligence")
            groupHeader("Cloud API")
            providerChoice("claude", "Claude")
            providerChoice("openai", "OpenAI-compatible")
        }
        Section(providerTitle) {
            providerDetails
        }
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    /// Radio desenhado a mao: um Picker .radioGroup nao pode ser quebrado em grupos.
    private func providerChoice(_ id: String, _ title: String) -> some View {
        Button {
            summarizer.provider = id
            // Ja dispara o download do modelo ao escolher o on-device.
            if id == "mlx" { llm.prepare() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: summarizer.provider == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(summarizer.provider == id ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var providerTitle: String {
        switch summarizer.provider {
        case "mlx": return "Built-in model"
        case "local": return "Apple Intelligence"
        case "openai": return "OpenAI-compatible API"
        default: return "Claude"
        }
    }

    @ViewBuilder
    private var providerDetails: some View {
        if summarizer.usesOpenAI {
            Toggle("Custom server", isOn: Binding(
                get: { summarizer.openaiCustomServer },
                set: {
                    summarizer.openaiCustomServer = $0
                    // Desligou: volta pros padroes da OpenAI pra nao sobrar
                    // URL/modelo de outro servidor apontando pro lugar errado.
                    summarizer.openaiModels = []
                    if !$0 {
                        summarizer.openaiBaseURL = Summarizer.openaiDefaultURL
                        summarizer.openaiModel = Summarizer.openaiDefaultModel
                    }
                }))
            if summarizer.openaiCustomServer {
                TextField("Base URL", text: Binding(
                    get: { summarizer.openaiBaseURL }, set: { summarizer.openaiBaseURL = $0 }))
                SecureField("API key (optional for local servers)", text: Binding(
                    get: { summarizer.openaiKey }, set: { summarizer.openaiKey = $0 }))
                openaiModelRow
                Text("Works with OpenRouter, Groq, Ollama, LM Studio or any /chat/completions endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("OpenAI API key", text: Binding(
                    get: { summarizer.openaiKey }, set: { summarizer.openaiKey = $0 }))
                openaiModelRow
                Text("Turn on Custom server for other providers (OpenRouter, Groq, Ollama...).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if summarizer.usesMLX {
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

    /// Campo de modelo do provider OpenAI: texto livre, ou picker apos buscar
    /// a lista do servidor (GET /models) pelo botao ao lado.
    @ViewBuilder
    private var openaiModelRow: some View {
        HStack {
            if summarizer.openaiModels.isEmpty {
                TextField("Model", text: Binding(
                    get: { summarizer.openaiModel }, set: { summarizer.openaiModel = $0 }))
            } else {
                Picker("Model", selection: Binding(
                    get: { summarizer.openaiModel }, set: { summarizer.openaiModel = $0 })) {
                    // Mantem o valor atual selecionavel mesmo se o servidor nao listar.
                    if !summarizer.openaiModels.contains(summarizer.openaiModel) {
                        Text(summarizer.openaiModel).tag(summarizer.openaiModel)
                    }
                    ForEach(summarizer.openaiModels, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
            }
            if summarizer.fetchingModels {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await summarizer.fetchOpenAIModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Fetch the model list from the server")
            }
        }
    }

    /// Linhas do provider embarcado: escolha de modelo, estado e acoes de download.
    @ViewBuilder
    private var mlxRows: some View {
        Picker("Model", selection: Binding(
            get: { llm.modelID }, set: { llm.selectModel($0) })) {
            // Modelo que saiu do catalogo mas segue selecionado/baixado.
            if !LocalLLM.models.contains(where: { $0.id == llm.modelID }) {
                Text(llm.modelID).tag(llm.modelID)
            }
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
                    Text("Downloading... \(Int(fraction * 100))%. Keep the app open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { llm.pauseDownload() }
                        .help("Stops the download. Finished files stay cached.")
                    Button("Cancel", role: .destructive) { llm.cancelDownload() }
                        .help("Stops the download and discards everything downloaded so far.")
                }
            }
        case .notDownloaded:
            HStack {
                if llm.pausedFraction > 0.01 {
                    Text("Download paused at \(Int(llm.pausedFraction * 100))%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume download") { llm.prepare() }
                    Button("Discard", role: .destructive) { llm.cancelDownload() }
                        .help("Deletes the partial download.")
                } else {
                    Text("The model needs to be downloaded once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download model") { llm.prepare() }
                }
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
