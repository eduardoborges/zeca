import AVFoundation
import FluidAudio
import ScreenCaptureKit

/// Escreve as duas trilhas do SCStream, sistema e microfone, em arquivos AAC separados.
/// Os dois outputs usam a mesma fila, entao o estado aqui e serializado por ela.
/// O mic vem cru: voice processing abaixa o mic e o volume da reuniao.
final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "ai.zeca.audio")

    private let urls: [Speaker: URL]
    private var files: [Speaker: AVAudioFile] = [:]
    /// PTS do primeiro buffer de cada trilha (relogio host), usado para alinhar as duas.
    private(set) var starts: [Speaker: TimeInterval] = [:]
    private var converted: [Speaker: (seconds: Double, samples: Int)] = [:]

    /// Chamado fora da fila de audio. Erro fatal da stream (ex: usuario revogou a permissao).
    var onStop: ((Error) -> Void)?

    /// Chamado na fila de audio com cada chunk ja em 16kHz mono e o PTS dele, para a transcricao ao vivo.
    var onSamples: ((Speaker, [Float], TimeInterval) -> Void)?
    private let converter = AudioConverter()

    init(systemURL: URL, micURL: URL) {
        urls = [.others: systemURL, .me: micURL]
    }

    // Lido na fila de audio; escrito via setPaused, que serializa na mesma fila.
    private var isPaused = false

    func setPaused(_ paused: Bool) {
        queue.async { self.isPaused = paused }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, buffer.numSamples > 0, !isPaused else { return }
        let speaker: Speaker
        switch type {
        case .audio: speaker = .others
        case .microphone: speaker = .me
        default: return // .screen: configurado no minimo, ignorado
        }
        let pts = buffer.presentationTimeStamp.seconds
        if starts[speaker] == nil { starts[speaker] = pts }
        write(buffer, speaker)
        if let onSamples, let samples = resample(buffer, speaker) {
            onSamples(speaker, samples, pts)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    /// Fecha os arquivos. Sincrono na fila de audio para nao truncar o ultimo buffer.
    func close() {
        queue.sync { files = [:] }
    }

    /// Converte pra 16kHz mono sem acumular arredondamento. O AudioConverter trunca cada
    /// buffer (1024 frames a 48kHz viram 341, nao 341,33), e sem essa correcao as trilhas
    /// escorregariam ate 3,5s por hora uma contra a outra na mistura.
    private func resample(_ buffer: CMSampleBuffer, _ speaker: Speaker) -> [Float]? {
        guard let rate = buffer.formatDescription?.audioStreamBasicDescription?.mSampleRate else { return nil }
        var samples = (try? converter.resampleSampleBuffer(buffer)) ?? []
        var total = converted[speaker] ?? (0, 0)
        total.seconds += Double(buffer.numSamples) / rate
        let count = Int((total.seconds * 16_000).rounded()) - total.samples
        if samples.count > count { samples.removeLast(samples.count - count) }
        samples += repeatElement(samples.last ?? 0, count: count - samples.count)
        total.samples += count
        converted[speaker] = total
        return samples
    }

    private func write(_ buffer: CMSampleBuffer, _ speaker: Speaker) {
        guard let description = buffer.formatDescription, let url = urls[speaker] else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            try buffer.withAudioBufferList { list, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                if files[speaker] == nil {
                    // O formato de processamento precisa casar com o buffer de entrada
                    // (mic chega int16 interleaved; o padrao float32 deinterleaved da erro -50).
                    files[speaker] = try AVAudioFile(forWriting: url, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                    ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                }
                try files[speaker]?.write(from: pcm)
            }
        } catch {
            NSLog("Zeca: falha escrevendo %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }
}
