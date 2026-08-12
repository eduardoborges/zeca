import AVFoundation
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case recording(Recording)
}

/// Permissoes de captura, checadas ao abrir e ao voltar pro app.
@MainActor
final class PermissionCheck: ObservableObject {
    @Published private(set) var screenMissing = false
    @Published private(set) var micDenied = false
    @Published private(set) var micUnasked = false

    var anyMissing: Bool { screenMissing || micDenied || micUnasked }

    func refresh() {
        screenMissing = !CGPreflightScreenCaptureAccess()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        micDenied = mic == .denied || mic == .restricted
        micUnasked = mic == .notDetermined
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func openScreenSettings() {
        // Registra o app na lista do painel (o prompt do sistema so aparece uma vez).
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openMicSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

/// Banner no topo quando falta permissao de gravacao de tela ou microfone.
private struct PermissionBanner: View {
    @ObservedObject var permissions: PermissionCheck

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
            if permissions.micUnasked {
                Button("Allow microphone") { permissions.requestMic() }
            }
            if permissions.micDenied {
                Button("Microphone settings") { permissions.openMicSettings() }
            }
            if permissions.screenMissing {
                Button("Screen Recording settings") { permissions.openScreenSettings() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var message: String {
        var missing: [String] = []
        if permissions.screenMissing { missing.append("Screen Recording") }
        if permissions.micDenied || permissions.micUnasked { missing.append("Microphone") }
        return "\(missing.joined(separator: " and ")) access is needed to record meetings."
            + (permissions.screenMissing ? " Granting Screen Recording requires reopening the app." : "")
    }
}

struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @State private var selection: Set<SidebarItem> = [.overview]
    @State private var archivePreview: ZecaPreview?
    @State private var showingNew = false
    @State private var draftTitle = ""
    @State private var pendingDelete: [Recording] = []
    @State private var renaming: Recording?
    @State private var renameText = ""
    @StateObject private var permissions = PermissionCheck()
    @AppStorage("onboarded") private var onboarded = false

    /// Gravacoes selecionadas na sidebar (a selecao e um Set por causa do batch).
    private var selectedRecordings: [Recording] {
        recorder.recordings.filter { selection.contains(.recording($0)) }
    }

    var body: some View {
        ZStack {
            main
                .safeAreaInset(edge: .top, spacing: 0) {
                    if onboarded, permissions.anyMissing {
                        PermissionBanner(permissions: permissions)
                    }
                }
            if !onboarded {
                OnboardingView()
                    .background(.background)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.4), value: onboarded)
        .onAppear { permissions.refresh() }
        // Voltou das Ajustes do Sistema: reconfere na hora.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
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
                                Button("Rename", systemImage: "pencil") {
                                    startRename(recording)
                                }
                                Button("Export…", systemImage: "square.and.arrow.up") {
                                    exportRecording(recording)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    // Clique numa linha da selecao age sobre a selecao inteira.
                                    pendingDelete = selection.contains(.recording(recording))
                                        ? selectedRecordings : [recording]
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            // Backspace/Delete com a sidebar focada; o alerta confirma antes.
            .onDeleteCommand {
                if !selectedRecordings.isEmpty { pendingDelete = selectedRecordings }
            }
            // Cmd+Backspace, o atalho do Finder pro mesmo gesto.
            .onKeyPress(keys: [.delete], phases: .down) { press in
                guard press.modifiers.contains(.command), !selectedRecordings.isEmpty else { return .ignored }
                pendingDelete = selectedRecordings
                return .handled
            }
            // Enter renomeia quando ha exatamente uma gravacao selecionada.
            .onKeyPress(.return) {
                guard selectedRecordings.count == 1, let recording = selectedRecordings.first else { return .ignored }
                startRename(recording)
                return .handled
            }
        } detail: {
            if showingNew || recorder.isRecording {
                NewMeetingView(isPresented: $showingNew, initialTitle: draftTitle) { imported in
                    selection = [.recording(imported)]
                }
            } else if selectedRecordings.count > 1 {
                BatchView(recordings: selectedRecordings) { pendingDelete = selectedRecordings }
            } else if let recording = selectedRecordings.first {
                RecordingDetail(recording: recording) { pendingDelete = [recording] }
            } else {
                DashboardView { title, link in
                    if let link { NSWorkspace.shared.open(link) }
                    draftTitle = title
                    selection = [.overview]
                    showingNew = true
                    Task { await recorder.start(title: title, transcriber: transcriber, summarizer: summarizer) }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    importArchives()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a .zeca meeting")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = [.overview]
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
            pendingDelete.count == 1
                ? "Delete \"\(pendingDelete.first?.title ?? "")\"?"
                : "Delete \(pendingDelete.count) meetings?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button(pendingDelete.count == 1 ? "Delete meeting" : "Delete \(pendingDelete.count) meetings",
                   role: .destructive) {
                for recording in pendingDelete {
                    selection.remove(.recording(recording))
                    recorder.delete(recording)
                }
                if selection.isEmpty { selection = [.overview] }
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Audio, transcript and summary will be deleted. No undo.")
        }
        // .zeca arrastado pra janela (Finder entrega file URLs).
        .dropDestination(for: URL.self) { urls, _ in
            let archives = urls.filter { $0.pathExtension == "zeca" }
            guard !archives.isEmpty else { return false }
            openArchives(archives)
            return true
        }
        // .zeca aberto por duplo clique no Finder; um evento por arquivo.
        .onOpenURL { url in
            guard url.pathExtension == "zeca" else { return }
            openArchives([url])
        }
        .sheet(item: $archivePreview) { preview in
            ZecaPreviewSheet(preview: preview) { doImport in
                archivePreview = nil
                if doImport {
                    do {
                        let url = try MeetingArchive.finishImport(preview)
                        recorder.refresh()
                        selection = [.recording(Recording(url: url))]
                    } catch {
                        preview.discard()
                        recorder.error = error.localizedDescription
                    }
                } else {
                    preview.discard()
                }
            }
        }
        .alert("Rename meeting", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave empty to go back to the date.")
        }
    }

    private func startRename(_ recording: Recording) {
        renameText = recording.customTitle ?? ""
        renaming = recording
    }

    private func saveRename() {
        guard let recording = renaming else { return }
        renaming = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = recording.url.appendingPathComponent("title.txt")
        if title.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? title.write(to: url, atomically: true, encoding: .utf8)
        }
        recorder.refresh()
    }

    private func exportRecording(_ recording: Recording) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [MeetingArchive.fileType]
        panel.nameFieldStringValue = recording.title.replacingOccurrences(of: "/", with: "-") + ".zeca"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingArchive.export(recording, to: url)
        } catch {
            recorder.error = error.localizedDescription
        }
    }

    private func importArchives() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [MeetingArchive.fileType]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        openArchives(panel.urls)
    }

    /// Um arquivo abre o preview; varios importam direto (um sheet por vez nao da).
    private func openArchives(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first {
            do {
                // Preview novo por cima de um pendente: joga o antigo fora.
                archivePreview?.discard()
                archivePreview = try MeetingArchive.peek(url)
            } catch {
                recorder.error = error.localizedDescription
            }
            return
        }
        var imported: URL?
        for url in urls {
            do {
                imported = try MeetingArchive.importArchive(from: url)
            } catch {
                recorder.error = error.localizedDescription
            }
        }
        recorder.refresh()
        if let imported {
            selection = [.recording(Recording(url: imported))]
        }
    }
}

/// Visualizacao de um .zeca aberto (duplo clique ou drag): o detalhe completo
/// da reuniao, igualzinho ao pos-import, com a barra de importar em cima.
/// O RecordingDetail opera na pasta temporaria; edicoes vao junto no import.
private struct ZecaPreviewSheet: View {
    let preview: ZecaPreview
    let onClose: (_ doImport: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text("Exported by \(preview.manifest.author) on \(preview.manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onClose(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Import meeting") { onClose(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            RecordingDetail(recording: preview.recording)
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 540, idealHeight: 640)
    }
}

/// Detalhe quando ha varias gravacoes selecionadas: resumo da selecao e acoes em lote.
private struct BatchView: View {
    let recordings: [Recording]
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\(recordings.count) meetings selected")
                .font(.title2.weight(.semibold))
            Text(recordings.map(\.title).joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 480)
            Button("Delete \(recordings.count) meetings", systemImage: "trash", role: .destructive) {
                onDelete()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tela de nova reuniao: titulo, Iniciar/Pausar/Parar e, gravando, a visao ao vivo.
private struct NewMeetingView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var summarizer: Summarizer
    @Binding var isPresented: Bool
    var initialTitle = ""
    var onImport: (Recording) -> Void = { _ in }
    @State private var title = ""
    @State private var importing = false
    @State private var importText = ""
    @State private var importError: String?

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
                    if importing {
                        Button("Create meeting", systemImage: "square.and.arrow.down") { importTranscript() }
                            .buttonStyle(.borderedProminent)
                            .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Back") {
                            importing = false
                            importError = nil
                        }
                    } else {
                        Button("Start", systemImage: "record.circle.fill") {
                            Task { await recorder.start(title: title, transcriber: transcriber, summarizer: summarizer) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        Button("Paste transcript", systemImage: "doc.plaintext") { importing = true }
                            .help("Create the meeting from a transcript you already have (e.g. from Zoom). No audio.")
                        Button("Cancel") { isPresented = false }
                    }
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
            } else if importing {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $importText)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                    }
                    Text("Paste a transcript: Zoom .vtt content or one \"Name: sentence\" per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom])
            } else {
                Spacer()
            }
        }
    }

    private func importTranscript() {
        let turns = Turn.parse(importText)
        guard !turns.isEmpty else {
            importError = "Could not find any speech in the pasted text."
            return
        }
        guard let recording = recorder.importMeeting(title: title, turns: turns) else { return }
        // Mesmo comportamento do fim da gravacao: sem titulo do usuario, o modelo escreve um.
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summarizer = summarizer
            let recorder = recorder
            Task {
                if let generated = await summarizer.title(for: turns) {
                    try? generated.write(to: recording.url.appendingPathComponent("title.txt"),
                                         atomically: true, encoding: .utf8)
                    recorder.refresh()
                }
            }
        }
        importText = ""
        importing = false
        isPresented = false
        onImport(recording)
    }
}

/// Tela ao vivo: timer e espectro de fala. A transcricao segue rodando por
/// tras (transcript.json + titulo automatico); a tela so nao mostra mais.
private struct LiveRecordingView: View {
    @EnvironmentObject private var recorder: Recorder
    @ObservedObject var live: LiveSession
    // Checado uma vez por gravacao; trocar de dispositivo no meio e raro.
    @State private var routeMismatch = AudioRoute.mismatch

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

            if routeMismatch {
                Label("Mic and audio output are different devices. On loudspeakers, the meeting audio can leak into your mic. Use headphones, or route both through the same device.",
                      systemImage: "speaker.wave.2.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }
}

/// Barra de nivel estilo VU ao lado do timer: ancorada a direita, enchendo
/// pra esquerda. Ataque instantaneo, decaimento gradual (sem pisca-pisca).
private struct LevelBar: View {
    let label: String
    let level: Float
    let tint: Color
    @State private var displayed: Float = 0

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    Capsule().fill(.quaternary)
                    // Compressao suave pra fala baixa nao ficar invisivel.
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(1, pow(Double(displayed), 0.5))))
                }
            }
            .frame(width: 140, height: 6)
            .onChange(of: level) { _, new in
                displayed = max(new, displayed * 0.82)
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
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
    @EnvironmentObject private var recorder: Recorder
    @State private var turns: [Turn] = []
    @State private var summary: String?
    @State private var notes: String?
    @State private var generatingNotes = false
    @State private var generatingSummary = false
    @State private var generatingTitle = false
    @StateObject private var player = PlayerModel()
    @State private var playerSource = "meeting" // "meeting" | "you" | "others"
    /// Task da geracao em andamento (resumo/ponto a ponto), cancelavel pelo usuario.
    @State private var generationTask: Task<Void, Never>?
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
                if hasAudio { playerCard }
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

    /// `notify` fica falso quando a transcricao e so a primeira etapa de um
    /// fluxo maior — um aviso no fim de tudo vale mais que um por etapa.
    private func autoProcess(notify: Bool = true) async {
        if turns.isEmpty {
            guard let transcribed = await transcriber.run(recording), !transcribed.isEmpty else { return }
            turns = transcribed
            if notify { Notifier.finished("Transcript ready: \(recording.title)") }
        }
    }

    private func summarize() {
        summarizer.error = nil
        generationTask = Task {
            generatingSummary = true
            let result = await summarizer.run(recording, turns: turns)
            if !Task.isCancelled {
                summary = result
                if result != nil { Notifier.finished("Summary ready: \(recording.title)") }
            }
            generatingSummary = false
            generationTask = nil
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generatingSummary = false
        generatingNotes = false
        generatingTitle = false
    }

    // MARK: - Header

    /// Reuniao importada de transcricao nao tem trilha nenhuma: sem player, sem re-transcricao.
    private var hasAudio: Bool {
        FileManager.default.fileExists(atPath: recording.mic.path)
            || FileManager.default.fileExists(atPath: recording.system.path)
    }

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
            recorder.refresh()
            generateTitle() // campo esvaziado = pedir um titulo novo ao modelo
        } else {
            try? title.write(to: url, atomically: true, encoding: .utf8)
            recorder.refresh()
        }
    }

    /// Titulo automatico sob demanda (usuario limpou o campo e deu Enter).
    private func generateTitle() {
        guard !turns.isEmpty else { return }
        summarizer.error = nil
        generationTask = Task {
            generatingTitle = true
            let title = await summarizer.title(for: turns)
            if let title, !Task.isCancelled {
                try? title.write(to: recording.url.appendingPathComponent("title.txt"),
                                 atomically: true, encoding: .utf8)
                recorder.refresh()
            }
            generatingTitle = false
            generationTask = nil
        }
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
                TextField("Meeting title (leave empty to generate one)", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .onSubmit { saveTitle() }
                    .onExitCommand { editingTitle = false }
                    .help("Press Enter with the field empty and the model writes a title from the transcript.")
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
                Spacer()
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busyLabel).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1)
                        if generationTask != nil {
                            Button("Cancel") { cancelGeneration() }
                                .help("Stops the text being generated right now.")
                        }
                    }
                } else {
                    Menu {
                        if hasAudio {
                            Button("Redo full analysis", systemImage: "wand.and.stars") { redoEverything() }
                            Divider()
                            Button("Redo transcript only", systemImage: "text.bubble") { redoTranscription() }
                        }
                        Button("Redo summary only", systemImage: "sparkles") { summarize() }
                            .disabled(turns.isEmpty)
                        Button("Redo point by point only", systemImage: "list.bullet") { generateNotes() }
                            .disabled(turns.isEmpty)
                        Button("Redo title only", systemImage: "character.cursor.ibeam") { generateTitle() }
                            .disabled(turns.isEmpty)
                    } label: {
                        Label(hasAudio ? "Redo analysis" : "Redo summary", systemImage: "wand.and.stars")
                    } primaryAction: {
                        if hasAudio { redoEverything() } else { summarize() }
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

    /// Player: faixa combinada (mixada sob demanda) ou cada trilha separada.
    private var playerCard: some View {
        Card(title: "Playback", systemImage: "waveform", tint: .primary) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $playerSource) {
                        Text("Meeting").tag("meeting")
                        Text("You").tag("you")
                        Text("Others").tag("others")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    Spacer()
                    if player.preparing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Mixing tracks...").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                    .disabled(player.duration == 0)
                    Text(timeLabel(player.progress))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { player.progress },
                        set: { player.progress = $0 }
                    ), in: 0...max(player.duration, 0.01)) { editing in
                        player.scrubbing = editing
                        if !editing { player.seek(to: player.progress) }
                    }
                    .disabled(player.duration == 0)
                    Text(timeLabel(player.duration))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = player.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: recording.id.path + playerSource) { await loadPlayerSource() }
        .onDisappear { player.unload() }
    }

    private func timeLabel(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private func loadPlayerSource() async {
        let resume = player.isPlaying
        switch playerSource {
        case "you": player.load(recording.mic, autoplay: resume)
        case "others": player.load(recording.system, autoplay: resume)
        default:
            player.preparing = true
            defer { player.preparing = false }
            do {
                let url = try await MeetingAudio.buildCombined(for: recording)
                player.load(url, autoplay: resume)
            } catch {
                player.error = "Could not mix the tracks: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary, !generatingSummary {
            GeneratedTextCard(title: "Summary", systemImage: "sparkles",
                              text: summary, folder: recording.url, kind: "summary")
                .id(summary)
        } else {
            Card(title: "Summary", systemImage: "sparkles", tint: .primary) {
                if generatingSummary {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing with \(summarizer.providerName)...").foregroundStyle(.secondary)
                    }
                    StreamingText(text: summarizer.streaming)
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
        transcriber.status != nil || summarizer.isRunning
    }

    private var busyLabel: String {
        if let live = transcriber.status ?? summarizer.status { return live }
        if generatingTitle { return "Generating title with \(summarizer.providerName)..." }
        return generatingNotes
            ? "Writing notes with \(summarizer.providerName)..."
            : "Summarizing with \(summarizer.providerName)..."
    }

    /// Refaz a transcricao (modelo das Configuracoes) e por cima o resumo e o ponto a ponto.
    private func redoEverything() {
        summarizer.error = nil
        generationTask = Task {
            turns = []
            summary = nil
            notes = nil
            try? FileManager.default.removeItem(at: recording.transcriptURL)
            await autoProcess(notify: false)
            guard !turns.isEmpty, !Task.isCancelled else { generationTask = nil; return }
            generatingSummary = true
            let newSummary = await summarizer.run(recording, turns: turns)
            if !Task.isCancelled { summary = newSummary }
            generatingSummary = false
            guard !Task.isCancelled else { generationTask = nil; return }
            generatingNotes = true
            let newNotes = await summarizer.runNotes(recording, turns: turns)
            if !Task.isCancelled {
                notes = newNotes
                Notifier.finished("Analysis ready: \(recording.title)")
            }
            generatingNotes = false
            generationTask = nil
        }
    }

    private func generateNotes() {
        summarizer.error = nil
        generationTask = Task {
            generatingNotes = true
            let result = await summarizer.runNotes(recording, turns: turns)
            if !Task.isCancelled {
                notes = result
                if result != nil { Notifier.finished("Point by point ready: \(recording.title)") }
            }
            generatingNotes = false
            generationTask = nil
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
                    StreamingText(text: summarizer.streaming)
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

/// Texto que chega token a token durante a geracao, sempre rolado pro fim.
/// Altura fixa pra pagina nao ficar pulando enquanto o modelo escreve.
private struct StreamingText: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("tail")
                }
                .frame(height: 180)
                .onChange(of: text) { proxy.scrollTo("tail", anchor: .bottom) }
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
            if let model = try? String(contentsOf: folder.appendingPathComponent("\(kind).model.txt"),
                                       encoding: .utf8) {
                Text("Generated by \(model.trimmingCharacters(in: .whitespacesAndNewlines))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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

