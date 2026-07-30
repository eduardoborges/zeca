import AVFoundation
import Charts
import EventKit
import SwiftUI

/// Le a agenda do usuario (EventKit) para o dashboard.
@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var todayEvents: [EKEvent] = []
    @Published private(set) var denied = false
    @Published private(set) var accessError: String?

    private let store = EKEventStore()

    func refresh() async {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
            accessError = nil
        } catch {
            granted = false
            accessError = error.localizedDescription
        }
        guard granted else { denied = true; return }
        denied = false
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        todayEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
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
        .task { await calendar.refresh() }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agenda de hoje", systemImage: "calendar").font(.title3.weight(.semibold))
            if calendar.denied {
                Text(calendar.accessError.map { "Erro ao pedir acesso: \($0)" }
                     ?? "Sem acesso a agenda. Libere em Ajustes do Sistema > Privacidade > Calendarios.")
                    .foregroundStyle(.secondary)
                Button("Tentar de novo") { Task { await calendar.refresh() } }
            } else if calendar.todayEvents.isEmpty {
                Text("Nenhum evento hoje.").foregroundStyle(.secondary)
            } else {
                ForEach(calendar.todayEvents, id: \.eventIdentifier) { event in
                    EventRow(event: event, onRecord: onRecord)
                }
            }
        }
    }

    private var insightsSection: some View {
        let week = weekStats()
        return VStack(alignment: .leading, spacing: 10) {
            Label("Esta semana", systemImage: "chart.bar.fill").font(.title3.weight(.semibold))
            HStack(spacing: 24) {
                StatBox(value: "\(week.count)", label: week.count == 1 ? "reunião" : "reuniões")
                StatBox(value: Duration.seconds(week.totalSeconds).formatted(.time(pattern: .hourMinute)),
                        label: "gravado")
            }
            Chart(week.perDay, id: \.day) { item in
                BarMark(
                    x: .value("Dia", item.day, unit: .day),
                    y: .value("Minutos", item.minutes)
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
    let event: EKEvent
    let onRecord: (String, URL?) -> Void

    var body: some View {
        let link = CalendarStore.meetingLink(of: event)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Sem título").fontWeight(.medium)
                Text("\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if link != nil {
                Button("Entrar e gravar", systemImage: "video.fill") {
                    onRecord(event.title ?? "", link)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Gravar", systemImage: "record.circle") {
                    onRecord(event.title ?? "", nil)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
