import AppKit
import SwiftUI

/// Liquid-glass building blocks. macOS 26's `glassEffect` is unavailable on macOS 14/15,
/// so the material is composed from a live backdrop blur, a tint, a top sheen and a specular rim.

private struct GlassSnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// ImageRenderer cannot capture live window blur, so exported previews draw a static stand-in.
    var glassSnapshot: Bool {
        get { self[GlassSnapshotKey.self] }
        set { self[GlassSnapshotKey.self] = newValue }
    }
}

/// Live blur of whatever sits behind the window (desktop, other apps).
struct BackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // The island panel never becomes key; keep the blur live instead of falling back to the inactive look.
        view.state = .active
        view.material = material
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Specular edge: bright where the light hits (top leading), a faint reflection on the far edge,
/// and a soft inner glow that gives the pane some thickness.
struct GlassRim<S: InsettableShape>: View {
    let shape: S
    var intensity: Double = 1
    var body: some View {
        ZStack {
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.46 * intensity), location: 0),
                .init(color: .white.opacity(0.12 * intensity), location: 0.3),
                .init(color: .white.opacity(0.04 * intensity), location: 0.62),
                .init(color: .white.opacity(0.20 * intensity), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
            shape.strokeBorder(.white.opacity(0.07 * intensity), lineWidth: 5).blur(radius: 4).clipShape(shape)
        }
        .allowsHitTesting(false)
    }
}

enum GlassBlending { case behindWindow, withinWindow }

/// A free-standing glass pane: blur, tint, sheen and rim.
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .black
    var tintOpacity: Double = 0.28
    var blending: GlassBlending = .behindWindow
    var rim: Double = 1
    @Environment(\.glassSnapshot) private var snapshot
    var body: some View {
        ZStack {
            if snapshot {
                Color(white: 0.15).opacity(0.78)
            } else if blending == .behindWindow {
                BackdropBlur()
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
            tint.opacity(tintOpacity)
            GlassSheen()
        }
        .clipShape(shape)
        .overlay(GlassRim(shape: shape, intensity: rim))
    }
}

/// Light falling on the upper half of a pane.
struct GlassSheen: View {
    var strength: Double = 1
    var body: some View {
        LinearGradient(stops: [
            .init(color: .white.opacity(0.10 * strength), location: 0),
            .init(color: .white.opacity(0.02 * strength), location: 0.42),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }
}

/// A shadow that is only drawn outside the shape, so it never darkens the glass itself.
struct OuterShadow<S: Shape>: View {
    let shape: S
    var opacity: Double
    var radius: CGFloat
    var y: CGFloat
    var body: some View {
        shape.fill(.black)
            .shadow(color: .black.opacity(opacity), radius: radius, y: y)
            .mask {
                Rectangle().padding(-(radius * 3 + abs(y)))
                    .overlay(shape.blendMode(.destinationOut))
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

/// A pane nested inside a glass surface. It does not blur again; it lifts and catches light.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(LinearGradient(colors: [.white.opacity(0.085), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    if let tint {
                        shape.fill(RadialGradient(colors: [tint.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 200))
                    }
                }
            }
            .overlay(GlassRim(shape: shape, intensity: 0.6))
    }
}

extension View {
    func glassCard(radius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, tint: tint))
    }
    func liquidGlass<S: InsettableShape>(_ shape: S, tintOpacity: Double = 0.28, blending: GlassBlending = .behindWindow) -> some View {
        background(GlassSurface(shape: shape, tintOpacity: tintOpacity, blending: blending))
    }
}

/// Capsule glass button. `prominent` fills it with a tint, like the system's prominent glass style.
struct GlassButtonStyle: ButtonStyle {
    var prominent: Color? = nil
    var compact = false
    var circle = false
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, compact: compact, circle: circle)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Color?
    let compact: Bool
    let circle: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        let height: CGFloat = compact ? 24 : 30
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 11 : 12.5, weight: prominent == nil ? .medium : .semibold))
            .foregroundStyle(prominent == nil ? Color.white.opacity(0.9) : Color.black.opacity(0.82))
            .padding(.horizontal, circle ? 0 : compact ? 10 : 14)
            .frame(width: circle ? height : nil, height: height)
            .background {
                if let prominent {
                    shape.fill(LinearGradient(colors: [prominent, prominent.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                        .overlay(shape.inset(by: 1.5).fill(LinearGradient(colors: [.white.opacity(0.5), .clear], startPoint: .top, endPoint: .center)).opacity(0.55))
                        .shadow(color: prominent.opacity(hovering ? 0.45 : 0.3), radius: 10, y: 3)
                } else {
                    shape.fill(.white.opacity(hovering ? 0.15 : 0.08))
                }
            }
            .overlay(GlassRim(shape: shape, intensity: prominent == nil ? 0.85 : 0.7))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .opacity(enabled ? 1 : 0.42)
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Recessed glass well for text input, with a mint ring while focused.
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var monospaced = false
    @FocusState private var focused: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
        .focused($focused)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(shape.fill(.black.opacity(focused ? 0.30 : 0.22)))
        .overlay(shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.3), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .overlay(shape.strokeBorder(Palette.mint.opacity(focused ? 0.65 : 0), lineWidth: 1.2))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Segmented control with a glass pill that slides between options.
struct GlassSegmented<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.58))
                        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(.white.opacity(0.16))
                                    .overlay(GlassRim(shape: Capsule(), intensity: 0.85))
                                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.24)))
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.black.opacity(0.25), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }
}

struct GlassDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) }
}
