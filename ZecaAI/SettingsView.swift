import SwiftUI

/// Configuracoes (menu Zeca AI > Settings ou Cmd+,), com abas laterais no estilo do Hex.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transcription
        case summary
        case calendar

        var id: String { rawValue }

        var label: (String, systemImage: String) {
            switch self {
            case .transcription: return ("Transcription", "waveform")
            case .summary: return ("Summary", "sparkles")
            case .calendar: return ("Calendar", "calendar")
            }
        }
    }

    @State private var tab: Tab? = .transcription
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
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { item in
                Label(item.label.0, systemImage: item.label.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 170)
        } detail: {
            Form {
                switch tab ?? .transcription {
                case .transcription: transcriptionTab
                case .summary: summaryTab
                case .calendar: calendarTab
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 680, height: 480)
    }

    // MARK: - Abas

    @ViewBuilder
    private var transcriptionTab: some View {
        Section("Language") {
            Picker("Transcription language", selection: $language) {
                ForEach(languages, id: \.code) { item in
                    Text(item.label).tag(item.code)
                }
            }
            Text("Applies to live transcription and \"Redo analysis\". \"Detect automatically\" handles mixed-language meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summaryTab: some View {
        Section("Output") {
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
        Section("Provider") {
            Picker("Provider", selection: Binding(
                get: { summarizer.provider },
                set: {
                    summarizer.provider = $0
                    // Ja dispara o download do modelo ao escolher o Qwen.
                    if $0 == "mlx" { llm.prepare() }
                })) {
                Text("Claude (API)").tag("claude")
                Text("On-device (Qwen 3, built-in)").tag("mlx")
                Text("On-device (Apple Intelligence)").tag("local")
            }
            .pickerStyle(.radioGroup)
            if summarizer.usesMLX {
                Text("Qwen 3 4B running inside the app (MLX). Nothing to install, nothing leaves your Mac. Requires Apple Silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch llm.state {
                case .ready:
                    Label("Model downloaded and ready.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .downloading(let fraction):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                        Text("Downloading model... \(Int(fraction * 100))% of ~2.4 GB. Summaries stay unavailable until it finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .notDownloaded:
                    HStack {
                        Text("The model (~2.4 GB) needs to be downloaded once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download model") { llm.prepare() }
                    }
                }
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

    @ViewBuilder
    private var calendarTab: some View {
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
