import SwiftUI

// Liquid Glass on macOS 26: every element is its own glass shape inside one GlassEffectContainer,
// so neighbours blend like liquid and shapes morph as tasks come and go. macOS 15 falls back to
// materials.

extension EnvironmentValues {
    /// Use the more transparent `.clear` glass instead of `.regular`.
    @Entry var clearGlass = false
}

private struct LiquidGlass<S: Shape>: ViewModifier {
    @Environment(\.clearGlass) private var clearGlass
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Glass.tint is greyed out in windows that aren't key, and this panel never is,
            // so the colour goes in as a translucent fill on top of the glass instead.
            content
                .background((tint ?? .clear).gradient.opacity(0.3), in: shape)
                .glassEffect((clearGlass ? Glass.clear : .regular).interactive(interactive), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.5), in: shape)
        }
    }
}

extension View {
    /// Makes this view a liquid glass shape, optionally tinted and reacting to touch.
    func liquidGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
    }

    /// Gives a glass shape an identity so it morphs (merges, splits) when it appears or disappears.
    @ViewBuilder func liquidGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Round glass icon buttons.
    @ViewBuilder func glassIconButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.borderless)
        }
    }

    /// Text buttons: glass, or prominent (tinted) glass for the main action.
    @ViewBuilder func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups glass shapes so that ones closer than `spacing` blend and morph together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
