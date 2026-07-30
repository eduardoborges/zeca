import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @State private var selection: Recording?
    @State private var showingNew = false
    @State private var draftTitle = ""
    @State private var pendingDelete: Recording?
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        ZStack {
            main
            if !onboarded {
                OnboardingView()
                    .background(.background)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.4), value: onboarded)
    }

    private var main: some View {
        NavigationSplitView {
            List(recorder.recordings, selection: $selection) { recording in
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title).lineLimit(1)
                    if let date = recording.date {
                        Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(recording)
                .contextMenu {
                    Button("Excluir", systemImage: "trash", role: .destructive) {
                        pendingDelete = recording
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .overlay {
                if recorder.recordings.isEmpty {
                    ContentUnavailableView("Nenhuma reuniao", systemImage: "waveform",
                                           description: Text("Crie uma nova reuniao para comecar."))
                }
            }
        } detail: {
            if showingNew || recorder.isRecording {
                NewMeetingView(isPresented: $showingNew, initialTitle: draftTitle)
            } else if let selection {
                RecordingDetail(recording: selection) { pendingDelete = selection }
            } else {
                DashboardView { title, link in
                    if let link { NSWorkspace.shared.open(link) }
                    draftTitle = title
                    selection = nil
                    showingNew = true
                    Task { await recorder.start(title: title, transcriber: transcriber, summarizer: summarizer) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Início", systemImage: "house") {
                    selection = nil
                    showingNew = false
                }
                .disabled(recorder.isRecording || (selection == nil && !showingNew))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Nova reunião", systemImage: "plus.circle.fill") {
                    selection = nil
                    draftTitle = ""
                    showingNew = true
                }
                .disabled(showingNew || recorder.isRecording)
            }
        }
        .alert("Erro", isPresented: .constant(recorder.error != nil)) {
            Button("OK") { recorder.error = nil }
        } message: {
            Text(recorder.error ?? "")
        }
        .confirmationDialog(
            "Excluir \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Excluir reunião", role: .destructive) {
                guard let recording = pendingDelete else { return }
                if selection == recording { selection = nil }
                recorder.delete(recording)
                pendingDelete = nil
            }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Áudio, transcrição e resumo serão apagados. Sem volta.")
        }
    }
}

/// Tela de nova reuniao: titulo, Iniciar/Pausar/Parar e, gravando, a visao ao vivo.
private struct NewMeetingView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @Binding var isPresented: Bool
    var initialTitle = ""
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Título da reunião (opcional)", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .disabled(recorder.isRecording)
                .padding(.horizontal)
                .padding(.top)
                .onAppear { if title.isEmpty { title = initialTitle } }

            HStack(spacing: 12) {
                if !recorder.isRecording {
                    Button("Iniciar", systemImage: "record.circle.fill") {
                        Task { await recorder.start(title: title, transcriber: transcriber, summarizer: summarizer) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Button("Cancelar") { isPresented = false }
                } else {
                    Button(recorder.isPaused ? "Retomar" : "Pausar",
                           systemImage: recorder.isPaused ? "play.fill" : "pause.fill") {
                        recorder.togglePause()
                    }
                    Button("Parar", systemImage: "stop.fill") {
                        Task {
                            await recorder.stop()
                            isPresented = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .controlSize(.large)
            .padding(.horizontal)

            if recorder.isRecording {
                LiveRecordingView(live: recorder.live)
            } else {
                Spacer()
            }
        }
    }
}

/// Tela ao vivo: timer, medidores de fala, transcricao incremental e resumo por minuto.
private struct LiveRecordingView: View {
    @EnvironmentObject private var recorder: Recorder
    @ObservedObject var live: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Circle().fill(recorder.isPaused ? Color.secondary : .red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(recorder.isPaused ? .secondary : .primary)
                }
                if recorder.isPaused {
                    Text("Pausado").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    LevelBar(label: "Você", level: live.micLevel, tint: .primary)
                    LevelBar(label: "Outros", level: live.systemLevel, tint: .secondary)
                }
            }
            .padding(.horizontal)

            if let status = live.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            HSplitView {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if live.turns.isEmpty {
                                Text("A transcrição aparece aqui em blocos de ~5s...")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(live.turns.enumerated()), id: \.offset) { TurnRow(turn: $1) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .onChange(of: live.turns.count) {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                }
                .frame(minWidth: 280)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Resumo ao vivo", systemImage: "sparkles")
                            .font(.headline)
                        if let summary = live.summary {
                            Text(LocalizedStringKey(summary)).textSelection(.enabled)
                        } else {
                            Text("Atualizado a cada minuto de conversa.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(minWidth: 220)
                .background(.quaternary.opacity(0.3))
            }
        }
    }
}

private struct LevelBar: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            // Compressao suave pra fala baixa nao ficar invisivel.
            ProgressView(value: min(1, pow(Double(level), 0.5)))
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 140)
                .animation(.linear(duration: 0.1), value: level)
        }
    }
}

/// Detalhe da reuniao: header com metadados, card de resumo e feed da conversa.
/// Transcricao e identificacao de falantes rodam automaticamente ao abrir.
private struct RecordingDetail: View {
    let recording: Recording
    var onDelete: () -> Void = {}
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @EnvironmentObject private var labeler: SpeakerLabeler
    @EnvironmentObject private var recorder: Recorder
    @State private var turns: [Turn] = []
    @State private var summary: String?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var renamingSpeaker: String?
    @State private var speakerName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryCard
                transcriptCard
            }
            .frame(maxWidth: 760)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .task(id: recording.id) {
            turns = recording.transcript ?? []
            summary = recording.summary
            summarizer.error = nil
            labeler.error = nil
            editingTitle = false
            await autoProcess()
        }
        .alert("Renomear falante", isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            TextField("Nome", text: $speakerName)
            Button("Salvar") { renameSpeaker() }
            Button("Cancelar", role: .cancel) { renamingSpeaker = nil }
        } message: {
            Text("Novo nome para \"\(renamingSpeaker ?? "")\" em toda a conversa.")
        }
        .toolbar {
            Button("Mostrar no Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Excluir", systemImage: "trash", role: .destructive) { onDelete() }
        }
    }

    // MARK: - Processamento automatico

    private func autoProcess() async {
        if turns.isEmpty {
            guard let transcribed = await transcriber.run(recording), !transcribed.isEmpty else { return }
            turns = transcribed
        }
        if !turns.contains(where: { $0.who != nil }), turns.contains(where: { $0.speaker == .others }),
           let labeled = await labeler.run(recording, turns: turns) {
            turns = labeled
        }
    }

    private func summarize() {
        summarizer.error = nil
        Task { summary = await summarizer.run(recording, turns: turns) }
    }

    // MARK: - Header

    private var speakers: [String] {
        var seen: [String] = []
        for turn in turns where !seen.contains(turn.label) { seen.append(turn.label) }
        return seen
    }

    private var durationSeconds: Double {
        (try? AVAudioFile(forReading: recording.mic)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
    }

    private func saveTitle() {
        editingTitle = false
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = recording.url.appendingPathComponent("title.txt")
        if title.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? title.write(to: url, atomically: true, encoding: .utf8)
        }
        recorder.refresh()
    }

    private func renameSpeaker() {
        guard let old = renamingSpeaker else { return }
        renamingSpeaker = nil
        let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        turns = turns.map { turn in
            guard turn.label == old else { return turn }
            var turn = turn
            turn.who = name
            return turn
        }
        if let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: recording.transcriptURL)
        }
    }

    private func startRenaming(_ label: String) {
        speakerName = label
        renamingSpeaker = label
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editingTitle {
                TextField("Título da reunião", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .onSubmit { saveTitle() }
                    .onExitCommand { editingTitle = false }
            } else {
                Text(recording.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .onTapGesture(count: 2) {
                        titleDraft = recording.customTitle ?? ""
                        editingTitle = true
                    }
                    .help("Clique duas vezes para renomear")
            }
            HStack(spacing: 14) {
                if let date = recording.date {
                    Label(date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()),
                          systemImage: "calendar")
                }
                if durationSeconds > 0 {
                    Label(Duration.seconds(durationSeconds).formatted(.time(pattern: .minuteSecond)),
                          systemImage: "clock")
                }
                AudioChip(url: recording.mic, label: "Você")
                AudioChip(url: recording.system, label: "Outros")
                Spacer()
                Button("Refazer análise", systemImage: "wand.and.stars") { redoEverything() }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(transcriber.status != nil || labeler.isRunning || summarizer.isRunning)
                    .help("Refaz a transcrição com o modelo das Configurações, os falantes e o resumo")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if speakers.count > 1 {
                HStack(spacing: 6) {
                    ForEach(speakers, id: \.self) { name in
                        Text(name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(SpeakerStyle.color(for: name).opacity(0.15), in: Capsule())
                            .foregroundStyle(SpeakerStyle.color(for: name))
                            .onTapGesture(count: 2) { startRenaming(name) }
                            .help("Clique duas vezes para renomear")
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var summaryCard: some View {
        Card(title: "Resumo", systemImage: "sparkles", tint: .primary) {
            if summarizer.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Resumindo com o Claude...").foregroundStyle(.secondary)
                }
            } else if let summary {
                Text(LocalizedStringKey(summary))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                HStack {
                    Spacer()
                    Button("Refazer resumo", systemImage: "arrow.clockwise") { summarize() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text(turns.isEmpty ? "Disponível após a transcrição." : "Gere um resumo desta reunião com o Claude.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Resumir", systemImage: "sparkles") { summarize() }
                        .buttonStyle(.borderedProminent)
                        .disabled(turns.isEmpty)
                }
            }
            if let error = summarizer.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func redoTranscription() {
        Task {
            turns = []
            try? FileManager.default.removeItem(at: recording.transcriptURL)
            await autoProcess()
        }
    }

    /// Refaz a transcricao (modelo das Configuracoes) e por cima gera o resumo novo.
    private func redoEverything() {
        summarizer.error = nil
        Task {
            turns = []
            summary = nil
            try? FileManager.default.removeItem(at: recording.transcriptURL)
            await autoProcess()
            guard !turns.isEmpty else { return }
            summary = await summarizer.run(recording, turns: turns)
        }
    }

    private var transcriptCard: some View {
        Card(title: "Conversa", systemImage: "text.bubble", tint: .primary) {
            if let status = transcriber.status {
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = transcriber.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } else if turns.isEmpty {
                Text("Nenhuma fala detectada nesta gravação.")
                    .foregroundStyle(.secondary)
            } else {
                if labeler.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Identificando falantes...").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = labeler.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    // Indice: dois turnos podem ter o mesmo start e colidir no id.
                    ForEach(Array(turns.enumerated()), id: \.offset) {
                        TurnRow(turn: $1, onRename: startRenaming)
                    }
                }
                if !labeler.isRunning {
                    HStack {
                        Spacer()
                        Button("Refazer transcrição", systemImage: "arrow.clockwise") { redoTranscription() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Transcreve de novo com o modelo escolhido nas Configurações")
                    }
                }
            }
        }
    }
}

/// Card com material, borda e titulo — o bloco visual padrao do detalhe.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1))
    }
}

    /// Tons monocromaticos estaveis por falante: "Voce" forte, demais em cinzas.
enum SpeakerStyle {
    static func color(for label: String) -> Color {
        switch label {
        case "Voce", "Você": return .primary
        case "Outros": return .secondary
        default:
            // Distingue falantes por tom de cinza, nao por matiz.
            let shades: [Color] = [Color.primary.opacity(0.8), .secondary,
                                   Color.primary.opacity(0.6), Color.secondary.opacity(0.7)]
            var hash = 0
            for scalar in label.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
            return shades[abs(hash) % shades.count]
        }
    }

    static func initials(for label: String) -> String {
        if label.hasPrefix("Falante"), let n = label.split(separator: " ").last { return "F\(n)" }
        return String(label.prefix(1))
    }
}

private struct TurnRow: View {
    let turn: Turn
    var onRename: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(SpeakerStyle.color(for: turn.label).opacity(0.18))
                .frame(width: 30, height: 30)
                .overlay {
                    Text(SpeakerStyle.initials(for: turn.label))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SpeakerStyle.color(for: turn.label))
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(turn.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpeakerStyle.color(for: turn.label))
                        .onTapGesture(count: 2) { onRename?(turn.label) }
                    Text(Duration.seconds(turn.start).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(turn.text).textSelection(.enabled)
            }
        }
    }
}

/// ponytail: play/pause simples. AVKit nao tem view nativa de audio no macOS,
/// e VideoPlayer aborta ao instanciar o metadata generico.
private struct AudioChip: View {
    let url: URL
    let label: String
    @State private var player: AVPlayer?

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        Button {
            toggle()
        } label: {
            Label(label, systemImage: player == nil ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.bordered)
        .clipShape(Capsule())
        .disabled(!exists)
        .onDisappear { player = nil }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            if let item = note.object as? AVPlayerItem, item === player?.currentItem { player = nil }
        }
    }

    private func toggle() {
        if player != nil {
            player = nil
        } else {
            let player = AVPlayer(url: url)
            player.play()
            self.player = player
        }
    }
}
