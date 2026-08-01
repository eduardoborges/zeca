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

    /// Modelos recomendados (mlx-community, 4-bit). Tamanhos reais do HF.
    static let models: [(id: String, label: String, bytes: Int64)] = [
        ("mlx-community/Qwen3.5-4B-4bit", "Qwen 3.5 4B — newest generation, great balance (3.1 GB)", 3_060_000_000),
        ("mlx-community/Qwen3.5-9B-OptiQ-4bit", "Qwen 3.5 9B — newest generation, high quality (8.2 GB)", 8_220_000_000),
        ("prism-ml/Ternary-Bonsai-27B-mlx-2bit", "Bonsai 27B — big-model quality, ternary 2-bit (8.5 GB)", 8_520_000_000),
        ("mlx-community/gemma-4-12B-it-4bit", "Gemma 4 12B — highest quality, heavy (6.8 GB)", 6_770_000_000),
        ("mlx-community/gemma-4-e4b-it-4bit", "Gemma 4 E4B — Google's efficient 4B (5.2 GB)", 5_180_000_000),
        ("mlx-community/gemma-4-e2b-it-4bit", "Gemma 4 E2B — efficient and light (3.6 GB)", 3_580_000_000),
        ("mlx-community/NVIDIA-Nemotron-Nano-9B-v2-4bits", "Nemotron Nano 9B — NVIDIA, fast long context (5.0 GB)", 5_020_000_000),
        ("mlx-community/Llama-3.1-8B-Instruct-4bit", "Llama 3.1 8B — the classic all-rounder (4.5 GB)", 4_530_000_000),
        ("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B — light and capable (1.8 GB)", 1_820_000_000),
        ("prism-ml/Ternary-Bonsai-8B-mlx-2bit", "Bonsai 8B — ternary 2-bit, tiny for its class (2.3 GB)", 2_320_000_000),
        ("mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit", "Nemotron 3 Nano 4B — NVIDIA compact (2.3 GB)", 2_250_000_000),
        ("mlx-community/Qwen3.5-2B-4bit", "Qwen 3.5 2B — smallest download (1.8 GB)", 1_750_000_000),
    ]

    @AppStorage("mlxModel") private(set) var modelID = "mlx-community/Qwen3.5-4B-4bit"

    /// Nome curto pro UI e rotulos de progresso ("Qwen 3 4B (on-device)").
    var displayName: String {
        let short = Self.models.first { $0.id == modelID }
            .map { $0.label.components(separatedBy: " —")[0] } ?? "Local model"
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

    func generate(system: String, prompt: String) async throws -> String {
        let container = try await loadContainer()
        // enable_thinking=false vai direto pro chat template (Jinja): o Qwen3/3.5
        // fecha o bloco <think> vazio no proprio prompt em vez de raciocinar antes
        // de responder — o que multiplicava o tempo de um resumo por varias vezes.
        // maxTokens segura modelo que ignore a flag.
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: .init(maxTokens: 8192),
            additionalContext: ["enable_thinking": false])

        var out = try await session.respond(to: prompt)

        // Rede de seguranca: modelo cujo template nao tem a flag ainda pode pensar.
        if let closing = out.range(of: "</think>", options: .backwards) {
            out = String(out[closing.upperBound...])
        }
        out = out.replacingOccurrences(of: "<think>", with: "")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else {
            throw NSError(domain: "ZecaAI", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "The model returned an empty answer. Try a larger model in Settings."])
        }
        return out
    }
}
