import AVFoundation
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case recording(Recording)
}

struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @State private var selection: SidebarItem? = .overview
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

    /// Grupos da sidebar: hoje, ontem, ultimos 7/30 dias, mais antigas.
    private var groupedRecordings: [(title: String, items: [Recording])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: today)!
        var groups: [(title: String, items: [Recording])] = [
            ("Today", []), ("Yesterday", []), ("Last week", []), ("Last month", []), ("Older", []),
        ]
        for recording in recorder.recordings {
            guard let date = recording.date else { groups[4].items.append(recording); continue }
            if calendar.isDateInToday(date) { groups[0].items.append(recording) }
            else if calendar.isDateInYesterday(date) { groups[1].items.append(recording) }
            else if date >= weekAgo { groups[2].items.append(recording) }
            else if date >= monthAgo { groups[3].items.append(recording) }
            else { groups[4].items.append(recording) }
        }
        return groups.filter { !$0.items.isEmpty }
    }

    private var main: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
                ForEach(groupedRecordings, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { recording in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recording.title).lineLimit(1)
                                if let date = recording.date {
                                    Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(SidebarItem.recording(recording))
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = recording
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if showingNew || recorder.isRecording {
                NewMeetingView(isPresented: $showingNew, initialTitle: draftTitle)
            } else if case .recording(let recording) = selection {
                RecordingDetail(recording: recording) { pendingDelete = recording }
            } else {
                DashboardView { title, link in
                    if let link { NSWorkspace.shared.open(link) }
                    draftTitle = title
                    selection = .overview
                    showingNew = true
                    Task { await recorder.start(title: title, transcriber: transcriber, summarizer: summarizer) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = .overview
                    draftTitle = ""
                    showingNew = true
                } label: {
                    Label("New meeting", systemImage: "record.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(showingNew || recorder.isRecording)
            }
        }
        .alert("Error", isPresented: .constant(recorder.error != nil)) {
            Button("OK") { recorder.error = nil }
        } message: {
            Text(recorder.error ?? "")
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete meeting", role: .destructive) {
                guard let recording = pendingDelete else { return }
                if selection == .recording(recording) { selection = .overview }
                recorder.delete(recording)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Audio, transcript and summary will be deleted. No undo.")
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
            TextField("Meeting title (optional)", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .disabled(recorder.isRecording)
                .padding(.horizontal)
                .padding(.top)
                .onAppear { if title.isEmpty { title = initialTitle } }

            HStack(spacing: 12) {
                if !recorder.isRecording {
                    Button("Start", systemImage: "record.circle.fill") {
                        Task { await recorder.start(title: title, transcriber: transcriber, summarizer: summarizer) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Button("Cancel") { isPresented = false }
                } else {
                    Button(recorder.isPaused ? "Resume" : "Pause",
                           systemImage: recorder.isPaused ? "play.fill" : "pause.fill") {
                        recorder.togglePause()
                    }
                    Button("Stop", systemImage: "stop.fill") {
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
                    Text("Paused").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    LevelBar(label: "You", level: live.micLevel, tint: .primary)
                    LevelBar(label: "Others", level: live.systemLevel, tint: .secondary)
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
                                Text("The transcript shows up here, sentence by sentence...")
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
                        Label("Live summary", systemImage: "sparkles")
                            .font(.headline)
                        if let summary = live.summary {
                            Text(LocalizedStringKey(summary)).textSelection(.enabled)
                        } else {
                            Text("Updated after every minute of conversation.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .zecaGlass(in: RoundedRectangle(cornerRadius: 18))
                    .padding(10)
                }
                .frame(minWidth: 220)
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
    @State private var notes: String?
    @State private var generatingNotes = false
    @State private var translatedTurns: [Turn]?
    @State private var translationCode: String?
    @State private var translating = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var renamingSpeaker: String?
    @State private var speakerName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryCard
                notesCard
                transcriptCard
            }
            .frame(maxWidth: 760)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .task(id: recording.id) {
            turns = recording.transcript ?? []
            summary = recording.summary
            notes = recording.notes
            translatedTurns = nil
            translationCode = nil
            summarizer.error = nil
            labeler.error = nil
            editingTitle = false
            await autoProcess()
        }
        .alert("Rename speaker", isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            TextField("Name", text: $speakerName)
            Button("Save") { renameSpeaker() }
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
        } message: {
            Text("New name for \"\(renamingSpeaker ?? "")\" across the whole conversation.")
        }
        .toolbar {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
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
                TextField("Meeting title", text: $titleDraft)
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
                    .help("Double-click to rename")
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
                AudioChip(url: recording.mic, label: "You")
                AudioChip(url: recording.system, label: "Others")
                Spacer()
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busyLabel).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Menu {
                        Button("Redo full analysis", systemImage: "wand.and.stars") { redoEverything() }
                        Divider()
                        Button("Redo transcript only", systemImage: "text.bubble") { redoTranscription() }
                        Button("Redo summary only", systemImage: "sparkles") { summarize() }
                            .disabled(turns.isEmpty)
                        Button("Redo point by point only", systemImage: "list.bullet") { generateNotes() }
                            .disabled(turns.isEmpty)
                    } label: {
                        Label("Redo analysis", systemImage: "wand.and.stars")
                    } primaryAction: {
                        redoEverything()
                    }
                    .zecaGlassButton()
                    .fixedSize()
                    .help("Transcript, speakers and summary, using the model from Settings")
                }
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
                            .help("Double-click to rename")
                    }
                }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var summaryCard: some View {
        if let summary, !summarizer.isRunning {
            GeneratedTextCard(title: "Summary", systemImage: "sparkles",
                              text: summary, folder: recording.url, kind: "summary")
                .id(summary)
        } else {
            Card(title: "Summary", systemImage: "sparkles", tint: .primary) {
                if summarizer.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing with \(summarizer.providerName)...").foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(turns.isEmpty ? "Available after transcription." : "Generate a summary with \(summarizer.providerName).")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Summarize", systemImage: "sparkles") { summarize() }
                            .buttonStyle(.borderedProminent)
                            .disabled(turns.isEmpty)
                    }
                }
                if let error = summarizer.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
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

    private var isBusy: Bool {
        transcriber.status != nil || labeler.isRunning || summarizer.isRunning
    }

    private var busyLabel: String {
        transcriber.status ?? (labeler.isRunning
            ? "Identifying speakers..."
            : "Summarizing with \(summarizer.providerName)...")
    }

    /// Refaz a transcricao (modelo das Configuracoes) e por cima o resumo e o ponto a ponto.
    private func redoEverything() {
        summarizer.error = nil
        Task {
            turns = []
            summary = nil
            notes = nil
            try? FileManager.default.removeItem(at: recording.transcriptURL)
            await autoProcess()
            guard !turns.isEmpty else { return }
            summary = await summarizer.run(recording, turns: turns)
            generatingNotes = true
            notes = await summarizer.runNotes(recording, turns: turns)
            generatingNotes = false
        }
    }

    private func generateNotes() {
        summarizer.error = nil
        Task {
            generatingNotes = true
            notes = await summarizer.runNotes(recording, turns: turns)
            generatingNotes = false
        }
    }

    @ViewBuilder
    private var notesCard: some View {
        if let notes, !generatingNotes {
            GeneratedTextCard(title: "Point by point", systemImage: "list.bullet.rectangle",
                              text: notes, folder: recording.url, kind: "notes")
                .id(notes)
        } else {
            Card(title: "Point by point", systemImage: "list.bullet.rectangle", tint: .primary) {
                if generatingNotes {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing notes with \(summarizer.providerName)...").foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(turns.isEmpty ? "Available after transcription."
                                           : "A detailed, paragraph-by-paragraph account of the whole conversation.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Generate", systemImage: "list.bullet") { generateNotes() }
                            .buttonStyle(.borderedProminent)
                            .disabled(turns.isEmpty || generatingNotes)
                    }
                }
            }
        }
    }

    /// Traduz (ou carrega o cache) e mostra no lugar do original.
    private func translate(to code: String) {
        summarizer.error = nil
        Task {
            translating = true
            let cache = recording.url.appendingPathComponent("translation-\(code).json")
            if let data = try? Data(contentsOf: cache),
               let cached = try? JSONDecoder().decode([Turn].self, from: data) {
                translatedTurns = cached
            } else if let translated = await summarizer.translate(turns, to: code) {
                translatedTurns = translated
                if let data = try? JSONEncoder().encode(translated) { try? data.write(to: cache) }
            }
            translationCode = translatedTurns == nil ? nil : code
            translating = false
        }
    }

    private var transcriptCard: some View {
        Card(title: "Conversation", systemImage: "text.bubble", tint: .primary) {
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
                Text("No speech detected in this recording.")
                    .foregroundStyle(.secondary)
            } else {
                if labeler.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Identifying speakers...").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = labeler.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if let code = translationCode,
                   let name = Summarizer.languages.first(where: { $0.code == code })?.label {
                    HStack(spacing: 8) {
                        Text("Translated to \(name)").font(.caption).foregroundStyle(.secondary)
                        Button("Show original") {
                            translatedTurns = nil
                            translationCode = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    // Indice: dois turnos podem ter o mesmo start e colidir no id.
                    ForEach(Array((translatedTurns ?? turns).enumerated()), id: \.offset) {
                        TurnRow(turn: $1, onRename: startRenaming)
                    }
                }
            }
        } accessory: {
            if !turns.isEmpty, transcriber.status == nil {
                TranslateMenu(busy: translating) { translate(to: $0) }
            }
        }
    }
}

/// Card de texto gerado (resumo/ponto a ponto) com traducao no canto e cache por idioma.
private struct GeneratedTextCard: View {
    let title: String
    let systemImage: String
    let text: String
    let folder: URL
    let kind: String
    @EnvironmentObject private var summarizer: Summarizer
    @State private var translated: String?
    @State private var code: String?
    @State private var busy = false

    var body: some View {
        Card(title: title, systemImage: systemImage, tint: .primary) {
            if let code,
               let name = Summarizer.languages.first(where: { $0.code == code })?.label {
                HStack(spacing: 8) {
                    Text("Translated to \(name)").font(.caption).foregroundStyle(.secondary)
                    Button("Show original") {
                        translated = nil
                        self.code = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Text(LocalizedStringKey(translated ?? text))
                .textSelection(.enabled)
                .lineSpacing(3)
        } accessory: {
            TranslateMenu(busy: busy) { translate(to: $0) }
        }
    }

    private func translate(to newCode: String) {
        Task {
            busy = true
            let cache = folder.appendingPathComponent("\(kind)-\(newCode).md")
            if let cached = try? String(contentsOf: cache, encoding: .utf8) {
                translated = cached
            } else if let result = await summarizer.translateText(text, to: newCode) {
                translated = result
                try? result.write(to: cache, atomically: true, encoding: .utf8)
            }
            code = translated == nil ? nil : newCode
            busy = false
        }
    }
}

/// Card com material, borda e titulo — o bloco visual padrao do detalhe.
/// `accessory` fica no canto direito do cabecalho (ex.: menu de traducao).
private struct Card<Content: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Label(title, systemImage: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .zecaGlass(in: RoundedRectangle(cornerRadius: 18))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, tint: tint,
                  content: content, accessory: { EmptyView() })
    }
}

/// Menu de traducao (select de idiomas) usado no canto dos cards.
private struct TranslateMenu: View {
    let busy: Bool
    let action: (String) -> Void

    var body: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Menu {
                ForEach(Summarizer.languages.filter { $0.code != "auto" }, id: \.code) { item in
                    Button(item.label) { action(item.code) }
                }
            } label: {
                Label("Translate", systemImage: "globe")
            }
            .fixedSize()
        }
    }
}

    /// Tons monocromaticos estaveis por falante: "You" forte, demais em cinzas.
    /// Aceita os rotulos antigos em portugues gravados em transcript.json.
enum SpeakerStyle {
    static func color(for label: String) -> Color {
        switch label {
        case "You", "Voce", "Você": return .primary
        case "Others", "Outros": return .secondary
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
        if label.hasPrefix("Speaker") || label.hasPrefix("Falante"),
           let n = label.split(separator: " ").last { return "S\(n)" }
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
        .zecaGlassButton()
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
