import SwiftUI

/// Gradient "comet" spinner: an arc whose tail fades out, turning on the frame clock so it never
/// stutters when the surrounding view re-renders. Reduce Motion leaves a still arc.
struct CometSpinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat? = nil
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let width = lineWidth ?? max(1.6, size / 7)
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let turn = reduceMotion ? 0.2 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(tint.opacity(0.14), lineWidth: width)
                Circle().trim(from: 0, to: 0.74)
                    .stroke(AngularGradient(colors: [tint.opacity(0), tint.opacity(0.55), tint],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(266)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .padding(width / 2)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("正在加载")
    }
}

/// Horizontal shake for a failed action; `shakes` counts up once per failure.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(shakes * .pi * 4), y: 0))
    }
}
