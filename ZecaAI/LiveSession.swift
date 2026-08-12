import FluidAudio
import Foundation

/// Buffer thread-safe entre a fila de audio e a transcricao ao vivo.
/// A fila de audio faz append; o loop da LiveSession drena.
final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Speaker: [Float]] = [.me: [], .others: []]
    private var peaks: [Speaker: Float] = [.me: 0, .others: 0]

    func append(_ speaker: Speaker, _ samples: [Float]) {
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        lock.lock()
        buffers[speaker]?.append(contentsOf: samples)
        peaks[speaker] = max(peaks[speaker] ?? 0, peak)
        lock.unlock()
    }

    /// Devolve e zera o pico acumulado desde a ultima leitura.
    func takePeak(_ speaker: Speaker) -> Float {
        lock.lock()
        defer { peaks[speaker] = 0; lock.unlock() }
        return peaks[speaker] ?? 0
    }

    /// Drena tudo que chegou desde a ultima leitura.
    func takeAll(_ speaker: Speaker) -> [Float] {
        lock.lock()
        defer { buffers[speaker] = []; lock.unlock() }
        return buffers[speaker] ?? []
    }
}

/// Transcricao ao vivo durante a gravacao.
///
/// Segmentacao no estilo do Hex: em vez de blocos de tamanho fixo (que cortam
/// palavras no meio e degradam o Parakeet), acumulamos fala ate uma pausa de
/// silencio e transcrevemos a frase INTEIRA de uma vez, com estado novo do
/// decoder — o mesmo que o Hex faz com o clipe completo do push-to-talk.
@MainActor
final class LiveSession: ObservableObject {
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var status: String?

    let box = SampleBox()

    private static let sampleRate = 16_000
    // ponytail: limiares fixos; viram ajuste fino se errarem em mic muito baixo/alto.
    private static let silenceThreshold: Float = 0.015
    private static let silenceCut = Int(0.7 * 16_000.0)   // pausa que fecha uma frase
    private static let maxUtterance = 15 * 16_000          // fala continua: corta em 15s
    private static let keepTail = Int(0.2 * 16_000.0)      // silencio que fica pro proximo trecho
    private static let minClip = Int(1.5 * 16_000.0)       // aprendizado do Hex: pad minimo de 1.5s

    private var manager: AsrManager?
    private var pending: [Speaker: [Float]] = [.me: [], .others: []]
    private var baseSample: [Speaker: Int] = [.me: 0, .others: 0]
    private var loop: Task<Void, Never>?
    private var levelLoop: Task<Void, Never>?
    private var folder: URL?
    private var isTranscribing = false

    func start(folder: URL, transcriber: Transcriber) {
        self.folder = folder
        turns = []
        pending = [.me: [], .others: []]
        baseSample = [.me: 0, .others: 0]
        status = "Preparing the model..."

        loop = Task { [weak self] in
            guard let self else { return }
            do {
                self.manager = try await transcriber.loadManager()
                self.status = nil
            } catch {
                self.status = "Live transcription unavailable: \(error.localizedDescription)"
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self.transcribeReadyUtterances(flush: false)
            }
        }
        // Nivel de fala em loop proprio: a transcricao bloqueia o loop principal
        // por segundos e congelava a barra; assim ela fica em tempo real.
        levelLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.updateLevels()
            }
        }
    }

    /// Drena o que sobrou, grava transcript.json e para o loop.
    func stop() async {
        loop?.cancel()
        loop = nil
        levelLoop?.cancel()
        levelLoop = nil
        await transcribeReadyUtterances(flush: true)
        micLevel = 0
        systemLevel = 0
        if let folder, !turns.isEmpty,
           let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: folder.appendingPathComponent("transcript.json"))
        }
        manager = nil
    }

    private func updateLevels() {
        micLevel = box.takePeak(.me)
        systemLevel = box.takePeak(.others)
    }

    private func transcribeReadyUtterances(flush: Bool) async {
        guard let manager, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        for speaker in [Speaker.me, .others] {
            pending[speaker]?.append(contentsOf: box.takeAll(speaker))
            while let (samples, startSample) = nextUtterance(for: speaker, flush: flush) {
                await transcribe(samples, from: speaker, startSample: startSample, with: manager)
            }
        }
    }

    /// Corta a proxima frase completa do buffer: fala seguida de pausa de silencio,
    /// fala continua acima de 15s, ou tudo que sobrou no flush final.
    private func nextUtterance(for speaker: Speaker, flush: Bool) -> (samples: [Float], startSample: Int)? {
        guard var samples = pending[speaker], !samples.isEmpty else { return nil }
        let base = baseSample[speaker] ?? 0

        var cut: Int
        if flush || samples.count >= Self.maxUtterance {
            cut = samples.count
        } else {
            var trailing = 0
            while trailing < samples.count, abs(samples[samples.count - 1 - trailing]) < Self.silenceThreshold {
                trailing += 1
            }
            guard trailing >= Self.silenceCut else { return nil } // ainda falando
            let speechEnd = samples.count - trailing
            guard speechEnd > 0 else {
                // So silencio acumulado: descarta, deixando um rabinho de contexto.
                if samples.count > Self.keepTail {
                    baseSample[speaker] = base + samples.count - Self.keepTail
                    pending[speaker] = Array(samples.suffix(Self.keepTail))
                }
                return nil
            }
            cut = speechEnd + min(trailing, Self.keepTail)
        }

        let utterance = Array(samples[0..<cut])
        samples.removeFirst(cut)
        pending[speaker] = samples
        baseSample[speaker] = base + cut

        // Frase inteira de silencio nao vale uma passada no modelo.
        guard utterance.contains(where: { abs($0) >= Self.silenceThreshold }) else { return nil }
        return (utterance, base)
    }

    private func transcribe(_ samples: [Float], from speaker: Speaker, startSample: Int, with manager: AsrManager) async {
        var clip = samples
        if clip.count < Self.minClip { clip.append(contentsOf: [Float](repeating: 0, count: Self.minClip - clip.count)) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language = LanguageSetting.code.flatMap(Language.init(rawValue:))
        guard let result = try? await manager.transcribe(clip, decoderState: &state, language: language) else { return }
        let offset = Double(startSample) / Double(Self.sampleRate)
        let new = Transcriber.turns(from: result, speaker: speaker, offset: offset)
        if !new.isEmpty {
            turns = (turns + new).sorted { $0.start < $1.start }
        }
    }
}
