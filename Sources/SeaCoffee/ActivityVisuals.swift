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

struct ActivityCore: View {
    var state: ActivityAppearance
    var reducedMotion: Bool
    var timeOverride: Double? = nil
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: state != .running || reducedMotion || timeOverride != nil)) { timeline in
            let time = reducedMotion ? 0 : timeOverride ?? timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if state == .running {
                    Circle().stroke(state.tint.opacity(0.20), lineWidth: 2)
                    Circle().trim(from: 0.05, to: 0.78)
                        .stroke(state.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360))
                    Circle().fill(state.tint).frame(width: 4, height: 4)
                } else {
                    Image(systemName: state == .completed ? "checkmark.circle.fill" : state == .failed ? "exclamationmark.circle.fill" : state == .interrupted ? "pause.circle.fill" : "circle.hexagongrid")
                        .resizable().scaledToFit().padding(2).foregroundStyle(state.tint)
                }
            }
            .padding(1.5)
        }
        .accessibilityLabel(state.label)
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        let amount = motion.mergeProgress
        let baseWidth = motion.returning ? targetWidth : initialWidth
        let baseHeight = motion.returning ? targetHeight : initialHeight
        let width = baseWidth + (badgeWidth - baseWidth) * amount
        let badgeHeight = cameraHeight + 72
        let height = baseHeight + (badgeHeight - baseHeight) * amount
        // The top never leaves the camera: only the sides and lower edge move.
        let topRadius = hasNotch ? 0.0 : 18.0
        let initialRadius = baseHeight > 40 ? 22.0 : 12.0
        let bottomRadius = initialRadius + (18 - initialRadius) * amount
        let shape = UnevenRoundedRectangle(topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius, style: .continuous)
        shape.fill(.black)
        .frame(width: width, height: height)
        // Overlays keep the fading expanded content from determining the badge's layout size.
        .overlay(alignment: .top) {
            content()
                .frame(width: baseWidth, height: baseHeight, alignment: .top)
                .opacity(motion.contentOpacity)
        }
        .overlay(alignment: .top) {
            CompletionTileFrame(motion: motion)
                .padding(.top, cameraHeight * amount)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10 * amount), lineWidth: 0.6))
        .frame(width: 520, height: 370, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本轮已完成")
    }
}
