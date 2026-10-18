import AppKit
import SwiftUI

/// Shared native controls, with warm surfaces and restrained borders inspired by CDS.
/// The legacy Glass names remain shared with the island and the Droppy extension.

private struct InterfaceReduceMotionKey: EnvironmentKey { static let defaultValue = false }

private struct GlassSnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// App preference, combined with the read-only system accessibility setting by controls.
    var interfaceReduceMotion: Bool {
        get { self[InterfaceReduceMotionKey.self] }
        set { self[InterfaceReduceMotionKey.self] = newValue }
    }

    /// Export previews without loading credentials or starting usage-data polling.
    var glassSnapshot: Bool {
        get { self[GlassSnapshotKey.self] }
        set { self[GlassSnapshotKey.self] = newValue }
    }
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

/// A quiet, solid card with a fine border.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    var tint: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(Palette.surface)
                    if let tint {
                        shape.fill(tint.opacity(0.025))
                    }
                }
            }
            .overlay(shape.strokeBorder(Palette.border, lineWidth: 0.65))
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
    var ghost = false
    var darkSurface = false
    /// While true the label is swapped for a spinner at the same size.
    var loading = false
    /// Read when loading ends: true shows a check, false shakes the button, nil does neither.
    var succeeded: Bool? = nil
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, compact: compact, circle: circle, ghost: ghost, darkSurface: darkSurface,
                        loading: loading, succeeded: succeeded)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Color?
    let compact: Bool
    let circle: Bool
    let ghost: Bool
    let darkSurface: Bool
    @Environment(\.isFocused) private var focused
    let loading: Bool
    let succeeded: Bool?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.interfaceReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    @State private var hovering = false
    @State private var showingSuccess = false
    @State private var shakes: CGFloat = 0
    @State private var bounce = 0
    var body: some View {
        let height: CGFloat = compact ? 24 : 32
        let shape = RoundedRectangle(cornerRadius: circle ? height / 2 : compact ? 6 : 8, style: .continuous)
        let ink = prominent == nil ? (darkSurface ? NotchPalette.text : Palette.text) : Color(red: 0.14, green: 0.08, blue: 0.05)
        let covered = loading || showingSuccess
        configuration.label
            .font(.system(size: compact ? 11 : 12.5, weight: prominent == nil ? .medium : .semibold))
            .foregroundStyle(ink)
            // The label keeps its space, so the button never changes width while it loads.
            .opacity(covered ? 0 : 1)
            .blur(radius: covered && !reduceMotion ? 2.5 : 0)
            .overlay {
                if loading {
                    CometSpinner(size: compact ? 12 : 14, tint: ink)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                } else if showingSuccess {
                    Image(systemName: "checkmark").font(.system(size: compact ? 11 : 12.5, weight: .bold))
                        .foregroundStyle(ink)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : bounce)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .padding(.horizontal, circle ? 0 : compact ? 10 : 14)
            .frame(width: circle ? height : nil, height: height)
            .background {
                if let prominent {
                    shape.fill(prominent.opacity(hovering ? 0.88 : 1))
                } else {
                    shape.fill((darkSurface ? NotchPalette.subtle : Palette.subtle).opacity(hovering ? 1 : ghost ? 0 : 0.65))
                }
            }
            .overlay(shape.strokeBorder(Palette.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
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

/// Native text editing in a raised, softly outlined field with a clay focus ring.
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var monospaced = false
    var savedValuePreview: String? = nil
    @FocusState private var focused: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if secure { SecureField(savedValuePreview == nil ? placeholder : "", text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
        .focused($focused)
        .overlay(alignment: .leading) {
            if text.isEmpty, let savedValuePreview {
                Text(savedValuePreview)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(savedValuePreview.map { "已保存密钥 \($0)，输入新 Key 可替换" } ?? "")
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(shape.fill(Palette.raised))
        .overlay(shape.strokeBorder(Palette.border, lineWidth: 0.8))
        .overlay(shape.strokeBorder(Palette.accent.opacity(focused ? 0.65 : 0), lineWidth: 1.2))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Shared timing for short, interruptible control transitions.
enum InterfaceMotion {
    static let selection = Animation.spring(response: 0.35, dampingFraction: 0.88)
    static let feedback = Animation.easeOut(duration: 0.15)
}

/// Persistent selection and a separate travelling hover highlight keep navigation legible.
struct GlassNavigation<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: (Value) -> String
    @Namespace private var namespace
    @State private var hovered: Value?
    @FocusState private var focused: Value?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.interfaceReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    var body: some View {
        VStack(spacing: 5) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    focused = option
                    guard selection != option else { return }
                    withAnimation(reduceMotion ? nil : InterfaceMotion.selection) { selection = option }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(option))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? Palette.accent : Palette.dim)
                            .frame(width: 18)
                        Text(title(option)).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)

                    }
                    .foregroundStyle(selected ? Palette.text : Palette.dim)
                    .padding(.horizontal, 12).frame(height: 40)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Palette.surface)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                        if hovered == option {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Palette.subtle.opacity(0.65))
                                .matchedGeometryEffect(id: "hover", in: namespace)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                        Palette.accent.opacity(focused == option ? 0.75 : 0), lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .focusable()
                .focusEffectDisabled()
                .focused($focused, equals: option)
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard enabled else { return .ignored }
                    if selection != option {
                        withAnimation(reduceMotion ? nil : InterfaceMotion.selection) { selection = option }
                    }
                    return .handled
                }
                .onHover { inside in
                    withAnimation(reduceMotion ? nil : InterfaceMotion.selection) {
                        if inside { hovered = option }
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .onHover { inside in
            if !inside {
                withAnimation(reduceMotion ? nil : InterfaceMotion.feedback) { hovered = nil }
            }
        }
    }
}

/// Segmented control with a restrained pill that slides between options.
struct GlassSegmented<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    var darkSurface = false
    let title: (Value) -> String
    @Namespace private var namespace
    @State private var hovered: Value?
    @FocusState private var focused: Value?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.interfaceReduceMotion) private var appReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    focused = option
                    guard selection != option else { return }
                    withAnimation(reduceMotion ? nil : InterfaceMotion.selection) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? (darkSurface ? NotchPalette.text : Palette.text) : (darkSurface ? NotchPalette.dim : Palette.dim))
                        .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if selected {
                                Capsule().fill((darkSurface ? NotchPalette.segmentThumb : Palette.segmentThumb))
                                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            } else if hovered == option {
                                Capsule().fill((darkSurface ? NotchPalette.subtle : Palette.subtle).opacity(0.65))
                            }
                        }
                        .overlay(Capsule().strokeBorder((darkSurface ? NotchPalette.accent : Palette.accent).opacity(focused == option ? 0.75 : 0), lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable()
                .focusEffectDisabled()
                .focused($focused, equals: option)
                .onKeyPress(keys: [.space, .return]) { _ in
                    guard enabled else { return .ignored }
                    if selection != option {
                        withAnimation(reduceMotion ? nil : InterfaceMotion.selection) { selection = option }
                    }
                    return .handled
                }
                .onHover { inside in
                    withAnimation(InterfaceMotion.feedback) {
                        if inside { hovered = option }
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .onHover { inside in
            if !inside { withAnimation(InterfaceMotion.feedback) { hovered = nil } }
        }
        .padding(3)
        .background(Capsule().fill((darkSurface ? NotchPalette.subtle : Palette.subtle).opacity(0.65)))
    }
}

struct GlassDivider: View {
    var darkSurface = false
    var body: some View { Rectangle().fill((darkSurface ? NotchPalette.border : Palette.border).opacity(0.65)).frame(height: 0.5) }
}
