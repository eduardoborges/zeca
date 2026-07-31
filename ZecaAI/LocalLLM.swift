import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// LLM pequeno rodando dentro do proprio app (MLX, Apple Silicon).
/// Baixa o modelo do Hugging Face na primeira utilizacao, como o Parakeet.
@MainActor
final class LocalLLM: ObservableObject {
    static let shared = LocalLLM()

    /// Qwen3 4B instruct 4-bit: melhor multilingue da classe, 32k de contexto, ~2.3GB.
    static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    static let displayName = "Qwen 3 (on-device)"

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double) // fracao 0-1
        case ready
    }

    @Published private(set) var state: DownloadState

    /// Progresso de download pro rotulo de progresso fora das Settings.
    var onStatus: ((String?) -> Void)?

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    // O hub so reporta progresso por arquivo completado (o peso e um unico arquivo
    // de 2.3GB), entao a fracao fiel vem de medir bytes no disco: blobs ja movidos
    // pro cache + o .tmp do URLSession crescendo.
    private var progressTimer: Timer?
    private var totalBytes: Int64 = 2_400_000_000 // estimativa; refinada pela API do HF

    private func startProgressPolling() {
        Task { [weak self] in
            guard let url = URL(string: "https://huggingface.co/api/models/\(Self.modelID)?blobs=true"),
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
                let fraction = min(0.99, Double(Self.bytesOnDisk()) / Double(self.totalBytes))
                self.state = .downloading(fraction)
                self.onStatus?("Downloading \(Self.displayName) (\(Int(fraction * 100))%)...")
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private static func bytesOnDisk() -> Int64 {
        var total: Int64 = 0
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(modelID.replacingOccurrences(of: "/", with: "--"))/blobs")
        if let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey]) {
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

    private init() {
        state = Self.isCached ? .ready : .notDownloaded
    }

    /// O cache do Hugging Face ja tem os pesos completos?
    /// (safetensors resolvido no snapshot e nenhum blob .incomplete)
    private static var isCached: Bool {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(modelID.replacingOccurrences(of: "/", with: "--"))")
        guard let files = FileManager.default.enumerator(at: hub, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }) else { return false }
        let hasWeights = files.contains {
            $0.pathExtension == "safetensors" && (try? Data(contentsOf: $0, options: .alwaysMapped)) != nil
        }
        let hasPartial = files.contains { $0.lastPathComponent.hasSuffix(".incomplete") }
        return hasWeights && !hasPartial
    }

    /// Comeca (ou retoma) o download em background. Chamado ao escolher o provider.
    func prepare() {
        guard state != .ready else { return }
        Task { _ = try? await loadContainer() }
    }

    /// Download travou: cancela, apaga o cache parcial e recomeca do zero.
    func restartDownload() {
        loadTask?.cancel()
        loadTask = nil
        container = nil
        stopProgressPolling()
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let name = "models--\(Self.modelID.replacingOccurrences(of: "/", with: "--"))"
        try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: base.appendingPathComponent(".locks/\(name)"))
        state = .notDownloaded
        // Pequena folga pra task antiga morrer antes de recomecar.
        Task {
            try? await Task.sleep(for: .seconds(1))
            prepare()
        }
    }

    /// Carrega (ou baixa) o modelo uma unica vez; chamadas concorrentes compartilham a task.
    private func loadContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        if state == .notDownloaded {
            state = .downloading(0)
            startProgressPolling()
        }
        let task = Task {
            try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: Self.modelID)
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
            state = Self.isCached ? .ready : .notDownloaded
            throw error
        }
    }

    func generate(system: String, prompt: String) async throws -> String {
        let container = try await loadContainer()
        let session = ChatSession(container, instructions: system)
        return try await session.respond(to: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
