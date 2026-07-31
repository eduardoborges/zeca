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
        if state == .notDownloaded { state = .downloading(0) }
        let task = Task { [weak self] in
            let container = try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: Self.modelID)
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.state != .ready else { return }
                    self.state = .downloading(progress.fractionCompleted)
                    self.onStatus?("Downloading \(Self.displayName) (\(Int(progress.fractionCompleted * 100))%)...")
                }
            }
            return container
        }
        loadTask = task
        defer { loadTask = nil; onStatus?(nil) }
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
