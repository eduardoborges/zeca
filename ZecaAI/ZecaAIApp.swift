import SwiftUI

@main
struct ZecaAIApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var transcriber = Transcriber()
    @StateObject private var summarizer = Summarizer()
    @StateObject private var speakerLabeler = SpeakerLabeler()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(transcriber)
                .environmentObject(summarizer)
                .environmentObject(speakerLabeler)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView()
                .environmentObject(summarizer)
        }

        MenuBarExtra {
            StatusMenu()
                .environmentObject(recorder)
        } label: {
            StatusBarLabel()
                .environmentObject(recorder)
        }
    }
}

/// Rotulo na barra de status: icone parado, ou indicador + tempo + titulo gravando.
private struct StatusBarLabel: View {
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        if recorder.isRecording {
            HStack(spacing: 4) {
                Image("MenuBarIcon")
                Image(systemName: recorder.isPaused ? "pause.fill" : "record.circle.fill")
                    .font(.system(size: 9))
                Text(statusText)
            }
        } else {
            Image("MenuBarIcon")
        }
    }

    private var statusText: String {
        let time = recorder.elapsedDisplay
        guard let title = recorder.currentTitle, !title.isEmpty else { return time }
        return "\(time) · \(title.count > 24 ? title.prefix(23) + "…" : title)"
    }
}

private struct StatusMenu: View {
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        if recorder.isRecording {
            Text(recorder.currentTitle ?? "Gravando reunião")
            Text(recorder.isPaused ? "Pausado" : "Gravando...")
            Divider()
            Button(recorder.isPaused ? "Retomar" : "Pausar") { recorder.togglePause() }
            Button("Parar gravação") { Task { await recorder.stop() } }
        } else {
            Text("Nenhuma gravação em andamento")
        }
        Divider()
        Button("Abrir o Zeca AI") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title.contains("Zeca") || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}
