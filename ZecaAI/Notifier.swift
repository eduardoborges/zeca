import AppKit
import UserNotifications

/// Avisa pelo Centro de Notificacoes quando um processamento longo termina.
/// So dispara com o app fora de foco — em foco o proprio card ja mostra o resultado.
@MainActor
enum Notifier {
    private static var authorized: Bool?

    static func finished(_ body: String) {
        guard !NSApp.isActive else { return }
        Task { await send(body) }
    }

    private static func send(_ body: String) async {
        let center = UNUserNotificationCenter.current()
        // A permissao e pedida na primeira notificacao de verdade, nao na abertura
        // do app: assim o usuario ve o pedido num momento em que ele faz sentido.
        if authorized == nil {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Zeca"
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
