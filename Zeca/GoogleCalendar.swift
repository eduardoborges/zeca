import AppKit
import CryptoKit
import Foundation
import Network
import SwiftUI

/// Evento do dia, de qualquer fonte (EventKit ou Google).
struct DayEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let link: URL?
}

/// Integracao direta com o Google Calendar: OAuth 2.0 + PKCE com callback em
/// localhost, refresh de token e leitura dos eventos do dia. Sem SDK.
@MainActor
final class GoogleCalendar: ObservableObject {
    static let shared = GoogleCalendar()

    @AppStorage("googleClientId") var clientId = ""
    @AppStorage("googleClientSecret") var clientSecret = ""
    @AppStorage("googleRefreshToken") private var refreshToken = ""
    @Published var error: String?
    @Published private(set) var connecting = false

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var listener: NWListener?

    var isConnected: Bool { !refreshToken.isEmpty }

    func disconnect() {
        refreshToken = ""
        accessToken = nil
    }

    func cancelConnect() {
        listener?.cancel()
        listener = nil
        connecting = false
    }

    // MARK: - OAuth

    /// Abre o navegador para autorizar e espera o callback em 127.0.0.1.
    func connect() {
        guard !clientId.isEmpty else { error = "Paste your Google OAuth Client ID first."; return }
        error = nil
        connecting = true

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)).map { $0 })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        do {
            // So loopback: o callback vem do navegador local, nada da rede deve conectar.
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let code = request.split(separator: "\n").first
                        .flatMap { line -> String? in
                            guard let range = line.range(of: "code=") else { return nil }
                            return line[range.upperBound...]
                                .split(whereSeparator: { $0 == "&" || $0 == " " })
                                .first.map(String.init)
                        }
                    let body = "<html><body style=\"font-family:sans-serif;text-align:center;padding-top:80px\"><h2>Zeca connected \(code == nil ? "failed" : "successfully") ✓</h2>You can close this window.</body></html>"
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n\(body)".utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.listener?.cancel()
                        self.listener = nil
                        if let code {
                            await self.exchange(code: code, verifier: verifier, port: listener.port?.rawValue ?? 0)
                        } else {
                            self.error = "Authorization was cancelled."
                            self.connecting = false
                        }
                    }
                }
            }
            listener.start(queue: .main)
            guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }

            var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            parts.queryItems = [
                .init(name: "client_id", value: clientId),
                .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: "https://www.googleapis.com/auth/calendar.readonly"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(parts.url!)
        } catch {
            self.error = "Could not start the local callback server: \(error.localizedDescription)"
            connecting = false
        }
    }

    private func exchange(code: String, verifier: String, port: UInt16) async {
        defer { connecting = false }
        let fields = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": "http://127.0.0.1:\(port)",
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        guard let json = await Self.tokenRequest(fields) else {
            error = "Token exchange failed. Check the Client ID and Secret."
            return
        }
        guard let refresh = json["refresh_token"] as? String else {
            error = (json["error_description"] as? String) ?? "Google did not return a refresh token."
            return
        }
        refreshToken = refresh
        accessToken = json["access_token"] as? String
        accessTokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
    }

    private func validAccessToken() async -> String? {
        if let accessToken, accessTokenExpiry > Date() { return accessToken }
        guard isConnected else { return nil }
        let json = await Self.tokenRequest([
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let token = json?["access_token"] as? String else {
            error = "Google session expired. Connect again in Settings."
            refreshToken = ""
            return nil
        }
        accessToken = token
        accessTokenExpiry = Date().addingTimeInterval(((json?["expires_in"] as? Double) ?? 3600) - 60)
        return token
    }

    private static func tokenRequest(_ fields: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Eventos

    /// Eventos de hoje de todos os calendarios selecionados da conta.
    func todayEvents() async -> [DayEvent] {
        guard let token = await validAccessToken() else { return [] }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let iso = ISO8601DateFormatter()

        var events: [DayEvent] = []
        for calendarId in await calendarIds(token: token) {
            var parts = URLComponents(string:
                "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarId)/events")!
            parts.queryItems = [
                .init(name: "timeMin", value: iso.string(from: dayStart)),
                .init(name: "timeMax", value: iso.string(from: dayEnd)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "50"),
            ]
            guard let json = await Self.get(parts.url!, token: token),
                  let items = json["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let startText = (item["start"] as? [String: Any])?["dateTime"] as? String,
                      let endText = (item["end"] as? [String: Any])?["dateTime"] as? String,
                      let start = iso.date(from: startText) ?? Self.flexibleDate(startText),
                      let end = iso.date(from: endText) ?? Self.flexibleDate(endText)
                else { continue } // all-day (so "date") fica de fora, como no EventKit
                events.append(DayEvent(
                    id: (item["id"] as? String) ?? UUID().uuidString,
                    title: (item["summary"] as? String) ?? "Untitled",
                    start: start,
                    end: end,
                    link: Self.meetingLink(item)))
            }
        }
        return events
    }

    private func calendarIds(token: String) async -> [String] {
        guard let json = await Self.get(
            URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!, token: token),
            let items = json["items"] as? [[String: Any]] else { return ["primary"] }
        let ids = items
            .filter { ($0["selected"] as? Bool ?? true) }
            .compactMap { $0["id"] as? String }
        return ids.isEmpty ? ["primary"] : ids
    }

    private static func get(_ url: URL, token: String) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func meetingLink(_ item: [String: Any]) -> URL? {
        if let hangout = item["hangoutLink"] as? String, let url = URL(string: hangout) { return url }
        if let conference = item["conferenceData"] as? [String: Any],
           let entryPoints = conference["entryPoints"] as? [[String: Any]],
           let video = entryPoints.first(where: { $0["entryPointType"] as? String == "video" }),
           let uri = video["uri"] as? String, let url = URL(string: uri) { return url }
        // fallback: link de reuniao em location/description
        let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)[^\s<>"]*"#
        for key in ["location", "description"] {
            if let text = item[key] as? String,
               let range = text.range(of: pattern, options: .regularExpression) {
                return URL(string: String(text[range]))
            }
        }
        return nil
    }

    // Google usa fracao de segundo/offset variados; ISO8601 estrito falha as vezes.
    private static func flexibleDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func randomURLSafe(_ count: Int) -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }
}
