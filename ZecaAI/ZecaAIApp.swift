import SwiftUI

@main
struct ZecaAIApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var transcriber = Transcriber()
    @StateObject private var summarizer = Summarizer()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(transcriber)
                .environmentObject(summarizer)
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording {
            Text(recorder.currentTitle ?? "Recording meeting")
            Text(recorder.isPaused ? "Paused" : "Recording...")
            Divider()
            Button(recorder.isPaused ? "Resume" : "Pause") { recorder.togglePause() }
            Button("Stop recording") { Task { await recorder.stop() } }
        } else {
            Text("No recording in progress")
        }
        Divider()
        Button("Open Zeca AI") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
