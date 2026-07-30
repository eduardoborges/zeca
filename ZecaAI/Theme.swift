import SwiftUI

/// Tema monocromatico, estilo Apple: preto, branco e cinzas.
/// Os nomes zeca* ficam como pontos unicos de ajuste da identidade visual.
extension Color {
    static let zecaDeep = Color.primary.opacity(0.85)
    static let zecaViolet = Color.primary
    static let zecaPink = Color.primary
    static let zecaAmber = Color.secondary
}

extension LinearGradient {
    /// Gradiente discreto da marca (grafite).
    static let zeca = LinearGradient(colors: [.primary, .primary.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}
