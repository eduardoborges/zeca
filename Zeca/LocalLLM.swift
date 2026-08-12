import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import SwiftUI
import Tokenizers

/// LLM pequeno rodando dentro do proprio app (MLX, Apple Silicon).
/// Baixa o modelo do Hugging Face na primeira utilizacao, como o Parakeet.
@MainActor
final class LocalLLM: ObservableObject {
    static let shared = LocalLLM()

    /// Modelos recomendados (mlx-community, 4-bit). Tamanhos reais do HF; os rotulos
    /// vem de medicao propria — mesmo prompt de resumo sobre a mesma transcricao de
    /// 2.9k tokens, temperatura 0. Velocidade so em termos relativos: o numero absoluto
    /// depende da maquina, a ordem entre os modelos nao. Os que ignoram o idioma
    /// configurado estao marcados; velocidade sem obedecer o prompt nao serve.
    /// Em ordem de recomendacao.
    static let models: [(id: String, label: String, bytes: Int64)] = [
        ("mlx-community/Qwen3.5-4B-4bit", "Qwen 3.5 4B: recommended, the most faithful on both tasks (3.1 GB)", 3_060_000_000),
        ("mlx-community/Qwen3.5-9B-OptiQ-4bit", "Qwen 3.5 9B: just as faithful, more detail, slower (8.2 GB)", 8_220_000_000),
        ("mlx-community/gemma-4-e4b-it-4bit", "Gemma 4 E4B: excellent point by point, brief summaries (5.2 GB)", 5_180_000_000),
        ("mlx-community/NVIDIA-Nemotron-Nano-9B-v2-4bits", "Nemotron Nano 9B: faithful content, untidy formatting (5.0 GB)", 5_020_000_000),
        ("mlx-community/gemma-4-12B-it-4bit", "Gemma 4 12B: Google's largest, reads images, not yet benchmarked (6.8 GB)", 6_770_000_000),
    ]

    // Catalogo curado por benchmark (BENCHMARK.md). Cortados por conteudo, nao por
    // velocidade: Llama 3.2 3B fabrica estrutura de reuniao; Qwen 3.5 2B e Llama
    // 3.1 8B produzem texto raso e repetitivo; Gemma 4 E2B ignora a maior parte da
    // reuniao no ponto a ponto; Bonsai 27B e dominado pelo Qwen 9B; Bonsai 8B e
    // Nemotron 3 Nano 4B ignoram o limite do prompt e estouram o teto de tokens.
    // Quem ja tinha um deles escolhido continua usando — o picker mantem o id atual.

    @AppStorage("mlxModel") private(set) var modelID = "mlx-community/Qwen3.5-4B-4bit"

    /// Nome curto pro UI e rotulos de progresso ("Qwen 3 4B (on-device)").
    var displayName: String {
        let short = Self.models.first { $0.id == modelID }
            .map { $0.label.components(separatedBy: ":")[0] } ?? "Local model"
        return "\(short) (on-device)"
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double) // fracao 0-1
        case ready
    }

    @Published private(set) var state: DownloadState = .notDownloaded

    /// Progresso de download pro rotulo de progresso fora das Settings.
    var onStatus: ((String?) -> Void)?

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var progressTimer: Timer?
    private var totalBytes: Int64 = 2_400_000_000

    private init() {
        state = isCached ? .ready : .notDownloaded
        totalBytes = Self.models.first { $0.id == modelID }?.bytes ?? totalBytes
    }

    private var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(modelID.replacingOccurrences(of: "/", with: "--"))")
    }

    /// O cache do Hugging Face ja tem os pesos completos?
    /// (safetensors resolvido no snapshot e nenhum blob .incomplete)
    private var isCached: Bool {
        guard let files = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }) else { return false }
        let hasWeights = files.contains {
            $0.pathExtension == "safetensors" && (try? Data(contentsOf: $0, options: .alwaysMapped)) != nil
        }
        let hasPartial = files.contains { $0.lastPathComponent.hasSuffix(".incomplete") }
        return hasWeights && !hasPartial
    }

    /// Troca o modelo selecionado; baixa na hora se ainda nao estiver em cache.
    func selectModel(_ id: String) {
        guard id != modelID, Self.models.contains(where: { $0.id == id }) else { return }
        cancelLoad()
        modelID = id
        totalBytes = Self.models.first { $0.id == id }?.bytes ?? 2_400_000_000
        state = isCached ? .ready : .notDownloaded
        if state != .ready { prepare() }
    }

    /// Comeca (ou retoma) o download em background. Chamado ao escolher o provider.
    func prepare() {
        guard state != .ready else { return }
        Task { _ = try? await loadContainer() }
    }

    /// Apaga os pesos do disco (completos ou parciais). Pode baixar de novo depois.
    func deleteModel() {
        cancelLoad()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.removeItem(at: cacheDir.deletingLastPathComponent()
            .appendingPathComponent(".locks/\(cacheDir.lastPathComponent)"))
        state = .notDownloaded
    }

    /// Pausa o download mantendo os arquivos ja completos no cache.
    /// (O peso grande em andamento recomeca: o hub nao retoma arquivo pela metade.)
    func pauseDownload() {
        cancelLoad()
        state = .notDownloaded
    }

    /// Cancela e descarta tudo que foi baixado.
    func cancelDownload() {
        deleteModel()
    }

    /// Fracao ja em cache de um download pausado (0 se nao ha nada).
    var pausedFraction: Double {
        guard state == .notDownloaded else { return 0 }
        return min(0.99, Double(bytesOnDisk()) / Double(totalBytes))
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        container = nil
        stopProgressPolling()
    }

    // O hub so reporta progresso por arquivo completado (o peso e um unico arquivo
    // grande), entao a fracao fiel vem de medir bytes no disco: blobs ja movidos
    // pro cache + o .tmp do URLSession crescendo.
    private func startProgressPolling() {
        let id = modelID
        Task { [weak self] in
            guard let url = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let siblings = json["siblings"] as? [[String: Any]] else { return }
            let sum = siblings.reduce(Int64(0)) { $0 + Int64($1["size"] as? Int ?? 0) }
            if sum > 0 { await MainActor.run { self?.totalBytes = sum } }
        }
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                let fraction = min(0.99, Double(self.bytesOnDisk()) / Double(self.totalBytes))
                self.state = .downloading(fraction)
                self.onStatus?("Downloading \(self.displayName) (\(Int(fraction * 100))%)...")
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func bytesOnDisk() -> Int64 {
        var total: Int64 = 0
        let blobs = cacheDir.appendingPathComponent("blobs")
        if let files = try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey]) {
            total += files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        // Download em andamento: tmp do URLSession, so arquivos mexidos ha pouco.
        let tmp = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for file in files where file.lastPathComponent.hasPrefix("CFNetworkDownload") {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      Date().timeIntervalSince(modified) < 120 else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Carrega (ou baixa) o modelo uma unica vez; chamadas concorrentes compartilham a task.
    private func loadContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        if state == .notDownloaded {
            state = .downloading(0)
            startProgressPolling()
        }
        let id = modelID
        let task = Task {
            try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: id)
            ) { _ in }
        }
        loadTask = task
        defer { loadTask = nil; stopProgressPolling(); onStatus?(nil) }
        do {
            let loaded = try await task.value
            container = loaded
            state = .ready
            return loaded
        } catch {
            state = isCached ? .ready : .notDownloaded
            throw error
        }
    }

    /// O Nemotron Nano v2 ignora a variavel do template e decide se pensa procurando
    /// "/no_think" no proprio system prompt (o template remove o marcador antes de
    /// renderizar). Os outros nao entendem o marcador, entao ele so vai pra quem precisa.
    /// ponytail: casa pelo id; se aparecer outro modelo assim, vira campo do catalogo.
    private static func noThinkMarker(for id: String) -> String {
        id.contains("Nemotron-Nano") ? "\n/no_think" : ""
    }

    func generate(
        system: String, prompt: String, onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        let container = try await loadContainer()
        // enable_thinking=false vai direto pro chat template (Jinja): Qwen 3.5,
        // Bonsai e Nemotron 3 fecham o bloco <think> vazio no proprio prompt em vez
        // de raciocinar antes de responder. Gemma 4 e Llama ja nao pensam por padrao.
        // maxTokens segura modelo que ignore tudo isso.
        let session = ChatSession(
            container,
            instructions: system + Self.noThinkMarker(for: modelID),
            generateParameters: .init(maxTokens: 8192),
            additionalContext: ["enable_thinking": false])

        var out = ""
        for try await piece in session.streamResponse(to: prompt) {
            out += piece
            onPartial?(out)
        }

        // Rede de seguranca: modelo cujo template nao tem a flag ainda pode pensar.
        if let closing = out.range(of: "</think>", options: .backwards) {
            out = String(out[closing.upperBound...])
        }
        out = out.replacingOccurrences(of: "<think>", with: "")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else {
            throw NSError(domain: "Zeca", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The model returned an empty answer. Try a larger model in Settings."])
        }
        return out
    }
}
