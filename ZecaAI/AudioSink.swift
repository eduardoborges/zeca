import AVFoundation
import FluidAudio
import ScreenCaptureKit

/// Escreve as duas trilhas do SCStream em arquivos AAC separados.
/// Ambos os outputs sao registrados na mesma fila, entao o estado aqui e serializado por ela.
final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "ai.zeca.audio")

    private let systemURL: URL
    private let micURL: URL
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    // Os arquivos comecam no primeiro buffer de cada trilha, que nao chegam juntos.
    // Guardamos o PTS de inicio (mesmo relogio do SCStream) para alinhar na transcricao.
    private var systemStart: TimeInterval?
    private var micStart: TimeInterval?

    /// Chamado fora da fila de audio. Erro fatal da stream (ex: usuario revogou a permissao).
    var onStop: ((Error) -> Void)?

    /// Chamado na fila de audio com cada chunk ja em 16kHz mono, para a transcricao ao vivo.
    var onSamples: ((Speaker, [Float]) -> Void)?
    private let systemConverter = AudioConverter()
    private let micConverter = AudioConverter()

    init(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    // Lido na fila de audio; escrito via setPaused, que serializa na mesma fila.
    private var isPaused = false

    func setPaused(_ paused: Bool) {
        queue.async { self.isPaused = paused }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, buffer.numSamples > 0, !isPaused else { return }
        let pts = buffer.presentationTimeStamp.seconds
        switch type {
        case .audio:
            if systemStart == nil { systemStart = pts }
            write(buffer, to: &systemFile, at: systemURL)
            if let onSamples, let samples = try? systemConverter.resampleSampleBuffer(buffer) {
                onSamples(.others, samples)
            }
        case .microphone:
            if micStart == nil { micStart = pts }
            write(buffer, to: &micFile, at: micURL)
            if let onSamples, let samples = try? micConverter.resampleSampleBuffer(buffer) {
                onSamples(.me, samples)
            }
        default: break // .screen: configurado no minimo, ignorado
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    /// Fecha os arquivos e grava o offset entre as trilhas.
    /// Sincrono na fila de audio para nao truncar o ultimo buffer.
    func close(metaURL: URL) {
        queue.sync {
            systemFile = nil
            micFile = nil
            let base = min(systemStart ?? 0, micStart ?? 0)
            let meta = TrackOffsets(system: (systemStart ?? base) - base, mic: (micStart ?? base) - base)
            if let data = try? JSONEncoder().encode(meta) { try? data.write(to: metaURL) }
        }
    }

    private func write(_ buffer: CMSampleBuffer, to file: inout AVAudioFile?, at url: URL) {
        guard let description = buffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            try buffer.withAudioBufferList { list, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                if file == nil {
                    // O formato de processamento precisa casar com o buffer de entrada
                    // (mic chega int16 interleaved; o padrao float32 deinterleaved da erro -50).
                    file = try AVAudioFile(forWriting: url, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                    ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                }
                try file?.write(from: pcm)
            }
        } catch {
            NSLog("ZecaAI: falha escrevendo %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }
}
