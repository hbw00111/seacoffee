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
                Palette.surface
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

/// A quiet, solid pane nested inside the outer glass surface.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(Palette.surface.opacity(0.88))
                    if let tint {
                        shape.fill(tint.opacity(0.025))
                    }
                }
            }
            .overlay(shape.strokeBorder(Palette.border, lineWidth: 0.75))
    }
}

extension View {
    func glassCard(radius: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, tint: tint))
    }
}

/// Compact rounded button; `prominent` supplies a solid accent fill.
struct GlassButtonStyle: ButtonStyle {
    var prominent: Color? = nil
    var compact = false
    var circle = false
    /// While true the label is swapped for a spinner at the same size.
    var loading = false
    /// Read when loading ends: true shows a check, false shakes the button, nil does neither.
    var succeeded: Bool? = nil
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, compact: compact, circle: circle,
                        loading: loading, succeeded: succeeded)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Color?
    let compact: Bool
    let circle: Bool
    let loading: Bool
    let succeeded: Bool?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var showingSuccess = false
    @State private var shakes: CGFloat = 0
    @State private var bounce = 0
    var body: some View {
        let height: CGFloat = compact ? 24 : 32
        let shape = RoundedRectangle(cornerRadius: circle ? height / 2 : compact ? 8 : 10, style: .continuous)
        let ink = prominent == nil ? Color.white.opacity(0.9) : Color.black.opacity(0.82)
        let covered = loading || showingSuccess
        configuration.label
            .font(.system(size: compact ? 11 : 12.5, weight: prominent == nil ? .medium : .semibold))
            .foregroundStyle(ink)
            // The label keeps its space, so the button never changes width while it loads.
            .opacity(covered ? 0 : 1)
            .blur(radius: covered ? 2.5 : 0)
            .overlay {
                if loading {
                    CometSpinner(size: compact ? 12 : 14, tint: ink)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else if showingSuccess {
                    Image(systemName: "checkmark").font(.system(size: compact ? 11 : 12.5, weight: .bold))
                        .foregroundStyle(ink)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : bounce)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .padding(.horizontal, circle ? 0 : compact ? 10 : 14)
            .frame(width: circle ? height : nil, height: height)
            .background {
                if let prominent {
                    shape.fill(prominent.opacity(hovering ? 1 : 0.90))
                } else {
                    shape.fill(.white.opacity(hovering ? 0.15 : 0.08))
                }
            }
            .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.22 : 0.10), lineWidth: 0.75))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .modifier(ShakeEffect(shakes: shakes))
            // A loading button stays fully opaque even though its action is disabled.
            .opacity(enabled || loading ? 1 : 0.42)
            .allowsHitTesting(!loading)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: covered)
            .onHover { hovering = $0 }
            .onChange(of: loading) { wasLoading, isLoading in
                guard wasLoading, !isLoading else { return }
                if succeeded == true {
                    showingSuccess = true; bounce += 1
                    Task { try? await Task.sleep(for: .seconds(1.1)); showingSuccess = false }
                } else if succeeded == false, !reduceMotion {
                    withAnimation(.linear(duration: 0.42)) { shakes += 1 }
                }
            }
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
        .frame(height: 32)
        .background(shape.fill(Palette.canvas.opacity(0.9)))
        .overlay(shape.strokeBorder(Palette.border, lineWidth: 0.8))
        .overlay(shape.strokeBorder(Palette.accent.opacity(focused ? 0.65 : 0), lineWidth: 1.2))
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
