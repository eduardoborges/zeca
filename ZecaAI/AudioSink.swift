import AVFoundation
import FluidAudio
import ScreenCaptureKit

/// Escreve a trilha do sistema (SCStream) em AAC.
/// O microfone e capturado a parte pelo MicCapture (com echo cancellation).
final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "ai.zeca.audio")

    private let systemURL: URL
    private var systemFile: AVAudioFile?
    // PTS do primeiro buffer (relogio host, o mesmo do MicCapture) para alinhar as trilhas.
    private(set) var systemStart: TimeInterval?

    /// Chamado fora da fila de audio. Erro fatal da stream (ex: usuario revogou a permissao).
    var onStop: ((Error) -> Void)?

    /// Chamado na fila de audio com cada chunk ja em 16kHz mono, para a transcricao ao vivo.
    var onSamples: (([Float]) -> Void)?
    private let systemConverter = AudioConverter()

    init(systemURL: URL) {
        self.systemURL = systemURL
    }

    // Lido na fila de audio; escrito via setPaused, que serializa na mesma fila.
    private var isPaused = false

    func setPaused(_ paused: Bool) {
        queue.async { self.isPaused = paused }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid, buffer.numSamples > 0, !isPaused else { return }
        if systemStart == nil { systemStart = buffer.presentationTimeStamp.seconds }
        write(buffer)
        if let onSamples, let samples = try? systemConverter.resampleSampleBuffer(buffer) {
            onSamples(samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    /// Fecha o arquivo. Sincrono na fila de audio para nao truncar o ultimo buffer.
    func close() {
        queue.sync { systemFile = nil }
    }

    private func write(_ buffer: CMSampleBuffer) {
        guard let description = buffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            try buffer.withAudioBufferList { list, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                if systemFile == nil {
                    // O formato de processamento precisa casar com o buffer de entrada.
                    systemFile = try AVAudioFile(forWriting: systemURL, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                    ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                }
                try systemFile?.write(from: pcm)
            }
        } catch {
            NSLog("ZecaAI: falha escrevendo %@: %@", systemURL.lastPathComponent, error.localizedDescription)
        }
    }
}

/// Captura o microfone via AVAudioEngine com voice processing ligado.
/// O AEC do sistema subtrai do mic o que esta saindo pelos alto-falantes,
/// entao a fala dos outros participantes nao vaza para a trilha "You".
final class MicCapture {
    private let engine = AVAudioEngine()
    private let url: URL
    private var file: AVAudioFile?
    private let converter = AudioConverter()
    private var observer: NSObjectProtocol?

    /// Host time (segundos) do primeiro buffer, mesmo relogio do PTS do SCStream.
    private(set) var start: TimeInterval?
    // Lidos na thread de audio do tap; race benigna (no maximo um buffer a mais).
    private var isPaused = false

    /// Chamado na thread do tap com cada chunk ja em 16kHz mono.
    var onSamples: (([Float]) -> Void)?

    init(url: URL) {
        self.url = url
    }

    func run() throws {
        let input = engine.inputNode
        // Precisa vir antes de consultar o formato: voice processing muda o formato do no.
        try input.setVoiceProcessingEnabled(true)
        // Sem ducking: o AEC nao deve abaixar o volume da reuniao que esta tocando.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: false, duckingLevel: .min)

        // Com voice processing o no entrega varios canais: o 0 e a voz processada
        // (AEC aplicado), os demais sao mics crus e referencias de eco. O canal 0
        // e copiado a mao — AVAudioConverter fazia esse downmix, mas com a topologia
        // de 9 canais (iPhone via Continuity presente) ele passou a devolver zero
        // digital sem erro nenhum. Tudo (arquivo e transcricao) passa por esse mono.
        let format = input.outputFormat(forBus: 0)
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false) else {
            throw NSError(domain: "ZecaAI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format."])
        }
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: mono.sampleRate,
            AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, when in
            guard let self, !self.isPaused else { return }
            if self.start == nil { self.start = AVAudioTime.seconds(forHostTime: when.hostTime) }
            guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
                  let src = buffer.floatChannelData, let dst = out.floatChannelData else { return }
            out.frameLength = buffer.frameLength
            if buffer.format.isInterleaved {
                let stride = Int(buffer.format.channelCount)
                for i in 0..<Int(buffer.frameLength) { dst[0][i] = src[0][i * stride] }
            } else {
                memcpy(dst[0], src[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
            do {
                try self.file?.write(from: out)
            } catch {
                NSLog("ZecaAI: falha escrevendo mic.m4a: %@", error.localizedDescription)
            }
            if let onSamples = self.onSamples, let samples = try? self.converter.resampleBuffer(out) {
                onSamples(samples)
            }
        }
        try engine.start()

        // ponytail: se o dispositivo de entrada trocar no meio (ex: AirPods), so religa a engine;
        // se o formato mudar, os writes falham logados. Upgrade: reconverter pro formato do arquivo.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self, self.file != nil else { return }
            try? self.engine.start()
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}
