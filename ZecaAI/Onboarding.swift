import SwiftUI

/// Fluxo de boas-vindas: apresentacao, provider do resumo, download do modelo e apoio.
struct OnboardingView: View {
    @AppStorage("onboarded") private var onboarded = false
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @ObservedObject private var llm = LocalLLM.shared

    @State private var step = 0
    @State private var modelReady = false
    @State private var modelFailed: String?
    @State private var downloading = false

    var body: some View {
        ZStack {
            AnimatedBackdrop()
            VStack(spacing: 0) {
                Spacer()
                Group {
                    switch step {
                    case 0: welcome
                    case 1: providerStep
                    case 2: modelStep
                    default: supportStep
                    }
                }
                .frame(maxWidth: 460)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: index == step ? 24 : 8, height: 8)
                    }
                }
                .padding(.bottom, 32)
            }
            .padding(40)
        }
        .animation(.spring(duration: 0.45), value: step)
    }

    // MARK: - Passo 1: boas-vindas

    private var welcome: some View {
        VStack(spacing: 20) {
            Waveform()
            Text("Zeca")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Your meetings recorded, transcribed and summarized.\nAll on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Get started") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
    }

    // MARK: - Passo 2: provider do resumo

    private var providerStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 52))
                .foregroundStyle(LinearGradient.zeca)
                .symbolEffect(.pulse)
            Text("Summaries and notes")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Pick who writes the summary and the point by point when a meeting ends. You can change this later in Settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("", selection: providerBinding) {
                Text("Claude API").tag("claude")
                Text("Claude Code").tag("claudecode")
                Text("Local model").tag("mlx")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            providerDetail
                .frame(minHeight: 88)

            HStack(spacing: 12) {
                Button("Not now") { step = 2 }
                Button("Continue") { step = 2 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!providerUsable)
            }
        }
    }

    private var providerBinding: Binding<String> {
        Binding(get: { summarizer.provider }, set: { choice in
            summarizer.provider = choice
            // O download do modelo local comeca na hora, com progresso aqui no wizard.
            if choice == "mlx" { llm.prepare() }
        })
    }

    @ViewBuilder
    private var providerDetail: some View {
        switch summarizer.provider {
        case "claudecode":
            VStack(spacing: 8) {
                if let path = Summarizer.claudeCLIPath {
                    Label("Claude Code CLI found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Summaries use your Claude Code login, so they count against that plan instead of API billing.\n\(path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Label("Claude Code CLI not found", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Install it first, or pick another provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case "mlx":
            VStack(spacing: 8) {
                switch llm.state {
                case .ready:
                    Label("\(llm.displayName) ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                        .frame(maxWidth: 300)
                    Text("Downloading \(llm.displayName)... \(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .notDownloaded:
                    ProgressView()
                    Text("Starting the \(llm.displayName) download...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Everything stays on your Mac. The download keeps going while you finish the setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        default:
            VStack(spacing: 8) {
                SecureField("sk-ant-...", text: keyBinding)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 340)
                Text("The key is stored only on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Create a key at console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Continue libera quando a escolha atual tem como funcionar.
    private var providerUsable: Bool {
        switch summarizer.provider {
        case "claudecode": return Summarizer.claudeCLIPath != nil
        case "mlx": return true // download segue em background
        default: return !summarizer.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var keyBinding: Binding<String> {
        Binding(get: { summarizer.apiKey }, set: { summarizer.apiKey = $0 })
    }

    // MARK: - Passo 3: modelo local

    private var modelStep: some View {
        VStack(spacing: 20) {
            Image(systemName: modelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 52))
                .foregroundStyle(modelReady ? .green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
            Text(modelReady ? "Model ready" : "Transcription model")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(modelReady
                 ? "Transcription is set up and runs on the Neural Engine."
                 : "Parakeet TDT v3 runs entirely on your Mac, on the Neural Engine.\nNo audio ever leaves the computer. One-time ~600 MB download.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if downloading {
                VStack(spacing: 8) {
                    if let progress = transcriber.progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 300)
                    } else {
                        ProgressView()
                    }
                    Text(transcriber.status ?? "Preparing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            } else if let modelFailed {
                Text(modelFailed).font(.caption).foregroundStyle(.red)
            }

            if modelReady {
                Button("Continue") { step = 3 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if !downloading {
                HStack(spacing: 12) {
                    Button("Download later") { step = 3 }
                    Button("Download model") { download() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Passo 4: apoio ao projeto

    private var supportStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.fill")
                .font(.system(size: 52))
                .foregroundStyle(.pink)
                .symbolEffect(.pulse)
            Text("All set!")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Zeca is free and open source. If it saves you time, a star on GitHub or a donation keeps it going.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/eduardoborges/zeca")!) {
                    Label("Star on GitHub", systemImage: "star.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Link(destination: URL(string: "https://github.com/sponsors/eduardoborges")!) {
                    Label("Donate", systemImage: "heart")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button("Open Zeca") { withAnimation(.easeOut(duration: 0.4)) { onboarded = true } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
    }

    private func download() {
        downloading = true
        modelFailed = nil
        Task {
            do {
                _ = try await transcriber.loadManager()
                withAnimation(.spring) { modelReady = true }
            } catch {
                modelFailed = error.localizedDescription
            }
            downloading = false
        }
    }
}

/// Fundo com gradiente animado, discreto.
private struct AnimatedBackdrop: View {
    @State private var animate = false

    var body: some View {
        LinearGradient(colors: [Color.primary.opacity(0.06), .clear, Color.primary.opacity(0.04)],
                       startPoint: animate ? .topLeading : .bottomLeading,
                       endPoint: animate ? .bottomTrailing : .topTrailing)
            .ignoresSafeArea()
            .onAppear { withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { animate = true } }
            .background()
    }
}

/// Barras de onda pulsando, estilo gravador.
private struct Waveform: View {
    @State private var animate = false
    private let heights: [CGFloat] = [0.35, 0.7, 1.0, 0.55, 0.85, 0.45, 0.75, 0.3]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.linearGradient(colors: [Color.primary, Color.primary.opacity(0.55)],
                                          startPoint: .top, endPoint: .bottom))
                    .frame(width: 8, height: 64 * heights[index])
                    .scaleEffect(y: animate ? 1 : 0.4, anchor: .center)
                    .animation(.easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.09), value: animate)
            }
        }
        .frame(height: 72)
        .onAppear { animate = true }
    }
}
