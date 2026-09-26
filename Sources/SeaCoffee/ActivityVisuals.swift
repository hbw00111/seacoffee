import SwiftUI
import IslandCore

enum ActivityAppearance: Equatable {
    case idle, running, completed, failed, interrupted
    var tint: Color {
        switch self {
        case .idle: return Color.white.opacity(0.48)
        case .running: return Color(red: 1, green: 0.59, blue: 0.16)
        case .completed: return Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
        case .failed, .interrupted: return Color(red: 1, green: 0.27, blue: 0.25)
        }
    }
    var label: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "正在运行"
        case .completed: return "本轮完成"
        case .failed: return "运行失败"
        case .interrupted: return "已中断"
        }
    }
}

/// Liquid core: one blob per running conversation orbits a centre drop and merges with it
/// (blurred shapes cut by an alpha threshold, the classic metaball trick). Completion gathers
/// everything into the centre, failure shivers, idle breathes. Reduce Motion freezes the layout.
struct ActivityCore: View {
    var state: ActivityAppearance
    var reducedMotion: Bool
    var timeOverride: Double? = nil
    /// Running conversations; drawn as orbiting blobs, capped so the drop stays legible.
    var count = 1
    static let maxBlobs = 4
    @State private var countChangedAt = Date.distantPast
    @State private var previousCount = 0

    var body: some View {
        let animated = !reducedMotion && timeOverride == nil
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { timeline in
            let time = timeOverride ?? (reducedMotion ? 0.35 : timeline.date.timeIntervalSinceReferenceDate)
            let since = timeOverride.map { _ in 10 } ?? timeline.date.timeIntervalSince(countChangedAt)
            Canvas { context, size in
                draw(&context, size: size, time: time, sinceCountChange: since)
            }
            .shadow(color: state.tint.opacity(state == .idle ? 0 : 0.55), radius: 3.5)
        }
        .onChange(of: count) { old, _ in previousCount = old; countChangedAt = Date() }
        .accessibilityLabel(state == .running ? "\(state.label)，\(count) 个对话" : state.label)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, sinceCountChange: Double) {
        let side = min(size.width, size.height)
        let unit = side / 23
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.addFilter(.alphaThreshold(min: 0.5, color: state.tint))
        context.addFilter(.blur(radius: 1.7 * unit))
        let blobs = orbiting(time: time, sinceCountChange: sinceCountChange)
        let core = coreRadius(time: time) * unit
        let shiver = state == .failed || state == .interrupted ? CGFloat(sin(time * 38)) * 0.8 * unit * CGFloat(max(0, 1 - (time.truncatingRemainder(dividingBy: 2.4)) / 0.5)) : 0
        context.drawLayer { layer in
            func drop(_ point: CGPoint, _ radius: CGFloat) {
                layer.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white))
            }
            drop(CGPoint(x: center.x + shiver, y: center.y), core)
            for blob in blobs {
                let point = CGPoint(x: center.x + CGFloat(cos(blob.angle)) * blob.distance * unit,
                                    y: center.y + CGFloat(sin(blob.angle)) * blob.distance * unit)
                drop(point, blob.radius * unit)
            }
        }
    }

    private func coreRadius(time: Double) -> CGFloat {
        switch state {
        case .running: return 4.0
        case .completed:
            // A soft bounce once the orbiting drops have been absorbed.
            let beat = max(0, sin(time * 2 * .pi / 1.8))
            return 5.4 + CGFloat(beat) * 0.6
        case .failed, .interrupted: return 5
        case .idle: return 3.4 + CGFloat((sin(time * 2 * .pi / 3.2) + 1) / 2) * 0.7
        }
    }

    private struct Blob { let angle: Double; let distance: CGFloat; let radius: CGFloat }

    private func orbiting(time: Double, sinceCountChange: Double) -> [Blob] {
        guard state == .running else { return [] }
        let shown = min(max(count, 1), Self.maxBlobs)
        // More work turns the drop slightly faster.
        let period = 2.4 - Double(shown - 1) * 0.2
        return (0..<shown).map { index in
            let phase = Double(index) / Double(shown)
            let angle = (time / period + phase) * 2 * .pi
            // Each drop drifts in and out: merged near the core, a separate, countable drop outside it.
            let breathing = sin(time * 2 * .pi / 1.3 + Double(index) * 1.7)
            var distance = CGFloat(7.2 + breathing * 2.6)
            // A new conversation grows out of the centre instead of popping in.
            if index >= previousCount && sinceCountChange < 0.6 {
                distance *= CGFloat(max(0, sinceCountChange / 0.6))
            }
            return Blob(angle: angle, distance: distance, radius: 2.7)
        }
    }
}

struct DrawnCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.51))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.77))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.23))
        return path
    }
}

/// The same perspective-projected paths are used by the native panel and frame exporter.
struct FlippingOrbit: Shape {
    var degrees: Double
    var axisX: Double
    var axisY: Double
    func path(in rect: CGRect) -> Path {
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let length = hypot(axisX, axisY), ax = axisX / length, ay = axisY / length
        let radius = min(rect.width, rect.height) * 0.46
        var path = Path()
        for step in 0...96 {
            let t = Double(step) / 96 * 2 * .pi
            let x = cos(t), y = sin(t), dot = ax * x + ay * y
            let rx = x * cosine + ax * dot * (1 - cosine)
            let ry = y * cosine + ay * dot * (1 - cosine)
            let rz = (ax * y - ay * x) * sine
            let perspective = 1 / (1 + rz * 0.18)
            let point = CGPoint(x: rect.midX + rx * radius * perspective, y: rect.midY + ry * radius * perspective)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

struct CompletionGlyph: View {
    let motion: CompletionMotion
    var body: some View {
        ZStack {
            // The main orbit settles into the final circle instead of fading away.
            FlippingOrbit(degrees: motion.rotation, axisX: 0.35, axisY: 1)
                .stroke(ActivityAppearance.completed.tint, lineWidth: 3)
            FlippingOrbit(degrees: -motion.rotation, axisX: 1, axisY: 0.35)
                .stroke(ActivityAppearance.completed.tint.opacity(0.65), lineWidth: 2.8)
                .opacity(motion.spinningOpacity)
            DrawnCheckmark().trim(from: 0, to: motion.checkProgress)
                .stroke(ActivityAppearance.completed.tint, style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round))
                .padding(6)
                .scaleEffect(x: cos(65 * (1 - motion.checkProgress) * .pi / 180), y: 1)
        }
        .scaleEffect(motion.scale)
        .opacity(motion.glyphOpacity)
    }
}

struct CompletionTileFrame: View {
    let motion: CompletionMotion
    var isDemo: Bool = false
    var body: some View {
        CompletionGlyph(motion: motion).frame(width: 38, height: 38)
            .frame(width: 72, height: 72)
            .accessibilityLabel(isDemo ? "演示：本轮已完成" : "本轮已完成")
    }
}

/// Names the agent (and model) whose task just finished, under the check.
struct CompletionCaption: Equatable {
    static let height: CGFloat = 20
    let style: ServiceStyle
    let text: String
}

private struct CompletionCaptionView: View {
    let caption: CompletionCaption
    var body: some View {
        HStack(spacing: 4) {
            caption.style.icon.resizable().aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10).foregroundStyle(caption.style.tint)
            Text(caption.text).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .frame(height: CompletionCaption.height, alignment: .top)
    }
}

/// The surface stays attached to the screen edge throughout the morph.
struct CompletionSurface<Content: View>: View {
    let motion: CompletionMotion
    let initialWidth: CGFloat
    let initialHeight: CGFloat
    let targetWidth: CGFloat
    let targetHeight: CGFloat
    let cameraHeight: CGFloat
    let badgeWidth: CGFloat
    let hasNotch: Bool
    var caption: CompletionCaption? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let amount = motion.mergeProgress
        let baseWidth = motion.returning ? targetWidth : initialWidth
        let baseHeight = motion.returning ? targetHeight : initialHeight
        let width = baseWidth + (badgeWidth - baseWidth) * amount
        let badgeHeight = cameraHeight + 72 + (caption == nil ? 0 : CompletionCaption.height)
        let height = baseHeight + (badgeHeight - baseHeight) * amount
        // The top never leaves the camera: only the sides and lower edge move.
        let topRadius = hasNotch ? 0.0 : 18.0
        let initialRadius = baseHeight > 40 ? 22.0 : 12.0
        let bottomRadius = initialRadius + (18 - initialRadius) * amount
        let shape = UnevenRoundedRectangle(topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius, style: .continuous)
        // Glass states (expanded, or any state without a notch) darken into the black badge as it merges.
        let glassy = baseHeight > 40 || !hasNotch
        IslandSurface(shape: shape, blackness: glassy ? amount : 1, headerBand: hasNotch ? cameraHeight : 0)
        .frame(width: width, height: height)
        // Overlays keep the fading expanded content from determining the badge's layout size.
        .overlay(alignment: .top) {
            content()
                .frame(width: baseWidth, height: baseHeight, alignment: .top)
                .opacity(motion.contentOpacity)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                CompletionTileFrame(motion: motion)
                if let caption { CompletionCaptionView(caption: caption).opacity(motion.captionOpacity) }
            }
            .padding(.top, cameraHeight * amount)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10 * amount), lineWidth: 0.6))
        .frame(width: 520, height: 370, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\($0.text) 本轮已完成" } ?? "本轮已完成")
    }
}
