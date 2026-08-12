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

extension View {
    /// Liquid Glass no macOS 26+; material com borda (visual anterior) no macOS 15.
    @ViewBuilder
    func zecaGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 1))
        }
    }

    /// Botao de vidro no macOS 26+; bordered no macOS 15.
    @ViewBuilder
    func zecaGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
