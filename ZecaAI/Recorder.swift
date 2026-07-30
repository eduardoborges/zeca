import AVFoundation
import Foundation
import ScreenCaptureKit

/// Deslocamento de cada trilha em relacao ao inicio da gravacao, em segundos.
struct TrackOffsets: Codable {
    let system: TimeInterval
    let mic: TimeInterval
}

/// Uma reuniao gravada: uma pasta com system.m4a + mic.m4a.
struct Recording: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var system: URL { url.appendingPathComponent("system.m4a") }
    var mic: URL { url.appendingPathComponent("mic.m4a") }
    var offsetsURL: URL { url.appendingPathComponent("offsets.json") }
    var transcriptURL: URL { url.appendingPathComponent("transcript.json") }
    var summaryURL: URL { url.appendingPathComponent("summary.md") }
    var notesURL: URL { url.appendingPathComponent("notes.md") }
    var notes: String? { try? String(contentsOf: notesURL, encoding: .utf8) }

    var summary: String? { try? String(contentsOf: summaryURL, encoding: .utf8) }

    /// Titulo dado pelo usuario na criacao; a pasta continua sendo a identidade.
    var customTitle: String? {
        guard let text = try? String(contentsOf: url.appendingPathComponent("title.txt"), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var offsets: TrackOffsets {
        guard let data = try? Data(contentsOf: offsetsURL),
              let value = try? JSONDecoder().decode(TrackOffsets.self, from: data)
        else { return TrackOffsets(system: 0, mic: 0) }
        return value
    }

    var transcript: [Turn]? {
        guard let data = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode([Turn].self, from: data)
    }

    /// O nome da pasta e a identidade no disco (ordenavel, sem caractere problematico).
    /// Data e hora vem dele; o que aparece na tela e formatado pelo locale do usuario.
    var date: Date? { Recording.folderFormatter.date(from: name) }

    /// Titulo do usuario, ou "29 de jul. às 13:25"
    var title: String {
        if let customTitle { return customTitle }
        guard let date else { return name }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Titulo do usuario, ou "quarta-feira, 29 de julho de 2026 às 13:25"
    var longTitle: String {
        if let customTitle { return customTitle }
        guard let date else { return name }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
    }

    static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var currentTitle: String?
    /// Tempo formatado pro item da barra de status (TimelineView nao roda em MenuBarExtra label).
    @Published private(set) var elapsedDisplay = "0:00"
    private var displayTimer: Timer?
    @Published private(set) var recordings: [Recording] = []
    @Published var error: String?

    // Cronometro que desconta as pausas.
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    var elapsed: TimeInterval {
        accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    let live = LiveSession()

    private var stream: SCStream?
    private var sink: AudioSink?
    private var currentFolder: URL?
    private var sessionSummarizer: Summarizer?

    static let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ZecaAI/Recordings", isDirectory: true)

    init() {
        refresh()
    }

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        recordings = contents
            .filter(\.hasDirectoryPath)
            .map(Recording.init)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func start(title: String, transcriber: Transcriber, summarizer: Summarizer) async {
        guard !isRecording else { return }
        do {
            let folder = Self.root.appendingPathComponent(Self.folderName())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? trimmed.write(to: folder.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
            }
            currentTitle = trimmed.isEmpty ? nil : trimmed
            elapsedDisplay = "0:00"
            displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsedDisplay = Duration.seconds(self.elapsed).formatted(.time(pattern: .minuteSecond))
                }
            }

            let sink = AudioSink(
                systemURL: folder.appendingPathComponent("system.m4a"),
                micURL: folder.appendingPathComponent("mic.m4a"))
            sink.onStop = { [weak self] error in
                Task { @MainActor in
                    self?.error = error.localizedDescription
                    await self?.stop()
                }
            }
            // Chunks de 16kHz mono direto pro buffer da transcricao ao vivo (fila de audio).
            sink.onSamples = { [box = live.box] speaker, samples in
                box.append(speaker, samples)
            }

            // Pede a permissao de gravacao de tela; lanca se o usuario negar.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw NSError(domain: "ZecaAI", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No display found."])
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true // senao grava o proprio playback
            config.captureMicrophone = true           // macOS 15+: mic na mesma stream, ja alinhado
            config.sampleRate = 48_000
            config.channelCount = 2
            // Video e obrigatorio na stream; mantido no minimo.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()

            self.stream = stream
            self.sink = sink
            currentFolder = folder
            startedAt = Date()
            accumulated = 0
            segmentStart = Date()
            isPaused = false
            isRecording = true
            error = nil
            sessionSummarizer = summarizer
            live.start(folder: folder, transcriber: transcriber, summarizer: summarizer)
        } catch {
            self.error = error.localizedDescription
            self.stream = nil
            self.sink = nil
        }
    }

    /// Pausa/retoma: a stream continua, mas o sink descarta os buffers.
    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            segmentStart = Date()
        } else {
            accumulated = elapsed
            segmentStart = nil
        }
        isPaused.toggle()
        sink?.setPaused(isPaused)
    }

    func stop() async {
        guard isRecording else { return }
        let hadTitle = currentTitle != nil
        isRecording = false
        isPaused = false
        startedAt = nil
        currentTitle = nil
        displayTimer?.invalidate()
        displayTimer = nil
        accumulated = 0
        segmentStart = nil
        try? await stream?.stopCapture()
        if let folder = currentFolder {
            sink?.close(metaURL: folder.appendingPathComponent("offsets.json"))
        }
        await live.stop()
        // Sem titulo do usuario: o Claude batiza a reuniao a partir da transcricao.
        if !hadTitle, !live.turns.isEmpty, let folder = currentFolder, let summarizer = sessionSummarizer {
            let turns = live.turns
            Task { [weak self] in
                guard let title = await summarizer.title(for: turns) else { return }
                try? title.write(to: folder.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
                self?.refresh()
            }
        }
        sessionSummarizer = nil
        currentFolder = nil
        stream = nil
        sink = nil
        refresh()
    }

    /// Apaga a pasta inteira da gravacao (audio, transcricao, resumo).
    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        refresh()
    }

    private static func folderName() -> String {
        Recording.folderFormatter.string(from: Date())
    }
}
