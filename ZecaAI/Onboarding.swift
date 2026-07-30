import SwiftUI

/// Fluxo de boas-vindas: apresentacao, chave da Anthropic e download do modelo local.
struct OnboardingView: View {
    @AppStorage("onboarded") private var onboarded = false
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer

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
                    case 1: keyStep
                    default: modelStep
                    }
                }
                .frame(maxWidth: 460)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
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
            Text("Zeca AI")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("Suas reuniões gravadas, transcritas e resumidas.\nTudo processado no seu Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Começar") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
    }

    // MARK: - Passo 2: chave da API

    private var keyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 52))
                .foregroundStyle(LinearGradient.zeca)
                .symbolEffect(.pulse)
            Text("Resumos com o Claude")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Cole sua chave da API da Anthropic para gerar resumos das reuniões — ao vivo, a cada minuto. A chave fica salva só no seu Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("sk-ant-...", text: keyBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 340)
            HStack(spacing: 12) {
                Button("Agora não") { step = 2 }
                Button("Continuar") { step = 2 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(summarizer.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 8)
            Link("Criar uma chave em console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text(modelReady ? "Tudo pronto!" : "Modelo de transcrição")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(modelReady
                 ? "O Zeca AI está pronto para a sua primeira reunião."
                 : "O Parakeet TDT v3 roda 100% no seu Mac, no Neural Engine.\nNada de áudio sai do computador. Download único de ~600 MB.")
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
                    Text(transcriber.status ?? "Preparando...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            } else if let modelFailed {
                Text(modelFailed).font(.caption).foregroundStyle(.red)
            }

            if modelReady {
                Button("Abrir o Zeca AI") { withAnimation(.easeOut(duration: 0.4)) { onboarded = true } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if !downloading {
                HStack(spacing: 12) {
                    Button("Baixar depois") { onboarded = true }
                    Button("Baixar modelo") { download() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
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
