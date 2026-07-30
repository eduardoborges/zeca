import AVFoundation
import Charts
import EventKit
import SwiftUI

/// Agenda do dia para o dashboard: junta o calendario do macOS (EventKit)
/// com o Google Calendar (quando conectado) e remove duplicatas.
@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var todayEvents: [DayEvent] = []
    @Published private(set) var denied = false
    @Published private(set) var accessError: String?

    private let store = EKEventStore()

    func refresh() async {
        var events: [DayEvent] = []

        // EventKit (calendario do sistema)
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
            accessError = nil
        } catch {
            granted = false
            accessError = error.localizedDescription
        }
        denied = !granted
        if granted {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events += store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .map { event in
                    DayEvent(id: event.eventIdentifier ?? UUID().uuidString,
                             title: event.title ?? "Untitled",
                             start: event.startDate,
                             end: event.endDate,
                             link: Self.meetingLink(of: event))
                }
        }

        // Google Calendar (conta conectada nas Configuracoes)
        events += await GoogleCalendar.shared.todayEvents()

        // Mesma reuniao nas duas fontes: fica uma (prefere a que tem link).
        var seen: [String: DayEvent] = [:]
        for event in events {
            let key = "\(event.title.lowercased())|\(Int(event.start.timeIntervalSince1970 / 60))"
            if let existing = seen[key], existing.link != nil, event.link == nil { continue }
            seen[key] = event
        }
        todayEvents = seen.values.sorted { $0.start < $1.start }
    }

    /// Link de videoconferencia do evento, se houver.
    static func meetingLink(of event: EKEvent) -> URL? {
        var candidates: [String] = []
        if let url = event.url?.absoluteString { candidates.append(url) }
        if let location = event.location { candidates.append(location) }
        if let notes = event.notes { candidates.append(notes) }
        let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)[^\s<>"]*"#
        for text in candidates {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return URL(string: String(text[range]))
            }
        }
        return nil
    }
}

/// Dashboard: agenda de hoje + insights das gravacoes da semana.
struct DashboardView: View {
    @EnvironmentObject private var recorder: Recorder
    @StateObject private var calendar = CalendarStore()
    /// Chamado quando o usuario quer gravar uma reuniao (titulo, link opcional).
    let onRecord: (String, URL?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.largeTitle.weight(.bold))

                agendaSection
                insightsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Atualiza ao abrir e depois a cada minuto (novos eventos, contas recem-adicionadas).
            while !Task.isCancelled {
                await calendar.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Today's schedule", systemImage: "calendar").font(.title3.weight(.semibold))
            if calendar.denied {
                Text(calendar.accessError.map { "Couldn't request access: \($0)" }
                     ?? "No calendar access. Allow it in System Settings > Privacy > Calendars.")
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await calendar.refresh() } }
            } else if calendar.todayEvents.isEmpty {
                Text("No events today.").foregroundStyle(.secondary)
            } else {
                ForEach(calendar.todayEvents) { event in
                    EventRow(event: event, onRecord: onRecord)
                }
            }
        }
    }

    private var insightsSection: some View {
        let week = weekStats()
        return VStack(alignment: .leading, spacing: 10) {
            Label("This week", systemImage: "chart.bar.fill").font(.title3.weight(.semibold))
            HStack(spacing: 24) {
                StatBox(value: "\(week.count)", label: week.count == 1 ? "meeting" : "meetings")
                StatBox(value: Duration.seconds(week.totalSeconds).formatted(.time(pattern: .hourMinute)),
                        label: "recorded")
            }
            Chart(week.perDay, id: \.day) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Minutes", item.minutes)
                )
                .foregroundStyle(Color.primary.opacity(0.8))
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 140)
        }
    }

    private struct WeekStats {
        var count = 0
        var totalSeconds = 0.0
        var perDay: [(day: Date, minutes: Double)] = []
    }

    /// Ultimos 7 dias, com duracao lida dos arquivos de audio.
    private func weekStats() -> WeekStats {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
        var stats = WeekStats()
        var byDay: [Date: Double] = [:]
        for offset in 0..<7 {
            byDay[calendar.date(byAdding: .day, value: offset, to: start)!] = 0
        }
        for recording in recorder.recordings {
            guard let date = recording.date, date >= start else { continue }
            let seconds = Self.duration(of: recording)
            stats.count += 1
            stats.totalSeconds += seconds
            byDay[calendar.startOfDay(for: date), default: 0] += seconds / 60
        }
        stats.perDay = byDay.sorted { $0.key < $1.key }.map { (day: $0.key, minutes: $0.value) }
        return stats
    }

    private static var durationCache: [URL: TimeInterval] = [:]
    private static func duration(of recording: Recording) -> TimeInterval {
        if let cached = durationCache[recording.url] { return cached }
        let file = try? AVAudioFile(forReading: recording.mic)
        let seconds = file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        durationCache[recording.url] = seconds
        return seconds
    }
}

private struct EventRow: View {
    let event: DayEvent
    let onRecord: (String, URL?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).fontWeight(.medium)
                Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.link != nil {
                Button("Join & record", systemImage: "video.fill") {
                    onRecord(event.title, event.link)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Record", systemImage: "record.circle") {
                    onRecord(event.title, nil)
                }
            }
        }
        .padding(10)
        .zecaGlass(in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StatBox: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 110, alignment: .leading)
        .zecaGlass(in: RoundedRectangle(cornerRadius: 12))
    }
}
