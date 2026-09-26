import SwiftUI
import IslandCore

enum Palette {
    static let mint = Color(red: 0.52, green: 0.94, blue: 0.79)
    static let blue = Color(red: 0.44, green: 0.73, blue: 0.98)
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let silver = Color(white: 0.85)
    static let lilac = Color(red: 0.78, green: 0.62, blue: 1)
    static let dim = Color.white.opacity(0.52)
}

/// Icon and colour for each quota source, shared by the island and Settings.
enum ServiceStyle {
    case codex, cline, claude, grok, pi
    init(agent: Agent) {
        switch agent {
        case .codex: self = .codex
        case .claude: self = .claude
        case .grok: self = .grok
        case .cline: self = .cline
        case .pi: self = .pi
        }
    }
    init(laneID: String?) {
        switch laneID {
        case "CL": self = .cline
        case "CC": self = .claude
        case "GK": self = .grok
        default: self = .codex
        }
    }
    @MainActor var icon: Image { Image(nsImage: ServiceIcon.image(self)).renderingMode(.template) }
    var tint: Color {
        switch self {
        case .codex: return Palette.mint
        case .cline: return Palette.blue
        case .claude: return Palette.clay
        case .grok: return Palette.silver
        case .pi: return Palette.lilac
        }
    }
}

/// The island's material. Expanded it is dark liquid glass; `blackness` fades it to solid black
/// (collapsed at the notch, completion badge), and `headerBand` keeps the strip under the notch black.
struct IslandSurface<S: InsettableShape>: View {
    let shape: S
    var blackness: Double
    var headerBand: CGFloat
    var glow: Color = .clear
    var glowOpacity: Double = 0
    var body: some View {
        ZStack(alignment: .top) {
            GlassSurface(shape: shape, tintOpacity: 0.42, rim: 0)
            Ellipse().fill(glow.opacity(glowOpacity))
                .frame(width: 340, height: 150).blur(radius: 46)
                .frame(maxHeight: .infinity, alignment: .bottom).offset(y: 70)
            if headerBand > 0 {
                VStack(spacing: 0) {
                    Color.black.frame(height: headerBand)
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 20)
                }
            }
            Color.black.opacity(blackness)
        }
        .clipShape(shape)
        .overlay {
            GlassRim(shape: shape, intensity: 1 - blackness)
                // Keep the rim off the screen edge and the notch strip.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: headerBand > 0 ? headerBand + 14 : 0)
                        Color.white
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        Group {
            if let completion = model.completion {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: model.reduceMotion)) { timeline in
                    let motion = CompletionMotion(elapsed: timeline.date.timeIntervalSince(completion.startedAt), reduced: model.reduceMotion)
                    let returnExpanded = model.pinned || (model.hovered && model.hoverEnabled)
                    CompletionSurface(motion: motion,
                        initialWidth: completion.initialWidth, initialHeight: completion.initialHeight,
                        targetWidth: returnExpanded ? max(360, model.compactWidth) : model.compactWidth,
                        targetHeight: returnExpanded ? model.headerHeight + model.detailHeight : model.headerHeight,
                        cameraHeight: model.hasNotch ? model.headerHeight : 0, badgeWidth: model.completionWidth, hasNotch: model.hasNotch,
                        caption: model.completionCaption) {
                            VStack(spacing: 0) {
                                header
                                if motion.returning ? returnExpanded : completion.wasExpanded { detail }
                            }
                        }
                }.id(completion.id)
            } else { normalIsland }
        }
        .preferredColorScheme(.dark)
    }
    private var normalIsland: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                    header
                    if model.expanded {
                        detail
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -7)), removal: .opacity))
                    }
            }
            .frame(width: model.islandWidth, height: model.islandHeight, alignment: .top)
            .background {
                // Collapsed at the notch the island stays black so it reads as part of the camera housing.
                IslandSurface(shape: shape, blackness: model.hasNotch && !model.expanded ? 1 : 0,
                              headerBand: model.hasNotch ? model.headerHeight : 0,
                              glow: model.activityAppearance.tint, glowOpacity: model.isRunning ? 0.22 : 0.06)
            }
            .background {
                OuterShadow(shape: shape, opacity: model.expanded ? 0.5 : model.hasNotch ? 0 : 0.18,
                            radius: model.expanded ? 22 : 6, y: model.expanded ? 12 : 2)
            }
            .clipShape(shape)
            .animation(model.islandAnimation, value: model.expanded)
            .padding(.top, model.surfaceTopInset)
            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 370, alignment: .top)
        .preferredColorScheme(.dark)
    }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: model.completion != nil ? 22 : model.hasNotch ? 0 : 18,
            bottomLeadingRadius: model.expanded || model.completion != nil ? 22 : 12,
            bottomTrailingRadius: model.expanded || model.completion != nil ? 22 : 12,
            topTrailingRadius: model.completion != nil ? 22 : model.hasNotch ? 0 : 18, style: .continuous)
    }
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ActivityCore(state: model.activityAppearance, reducedMotion: model.reduceMotion,
                             count: model.activeConversationCount)
                    .frame(width: 26, height: 26)
                // The drops already show up to four conversations; only larger counts need a number.
                if model.activeConversationCount > ActivityCore.maxBlobs {
                    Text(model.activeConversationCount > 99 ? "99+" : "\(model.activeConversationCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(model.activityAppearance.tint)
                }
            }
            .frame(maxWidth: .infinity)
            .help("\(model.activeConversationCount) 个对话正在运行")
            .accessibilityLabel("\(model.activityAppearance.label)，\(model.activeConversationCount) 个对话正在运行")
            Color.clear.frame(width: model.hasNotch ? model.notchWidth : 94)
            HStack(spacing: 5) {
                if model.expanded {
                    Text("Sea Coffee").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.dim)
                } else {
                    let lanes = model.planLanes
                    if lanes.count >= 3 {
                        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                            ForEach(Array(stride(from: 0, to: lanes.count + 1, by: 2)), id: \.self) { row in
                                GridRow {
                                    compactItem(row == 0 ? nil : lanes[row - 1])
                                    if row < lanes.count { compactItem(lanes[row]) }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: lanes.count == 2 ? 0 : 2) {
                            compactItem(nil)
                            ForEach(lanes) { compactItem($0) }
                        }
                    }

                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: model.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(!model.expanded) }
        .accessibilityLabel("Sea Coffee，\(model.activityAppearance.label)，\(model.activeConversationCount) 个对话正在运行，Codex 剩余\(model.primary.map { "\($0.percent)%" } ?? "未知")，\(model.planLanes.map { "\($0.title) 剩余\($0.primary.map { "\($0.percent)%" } ?? "未知")" }.joined(separator: "，"))")
        .accessibilityAddTraits(.isButton)
    }
    private var detail: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.demo ? "Sub2API · 钱包余额" : model.source.title + (model.displayedSnapshot?.balance != nil ? " · 钱包余额" : ""))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                        if model.demo { demoBadge }
                    }
                    if model.refreshing && model.displayedSnapshot == nil {
                        SkeletonBar(width: 112, height: 24).padding(.vertical, 5)
                    } else {
                        Text(amount).font(.system(size: model.primary == nil ? 23 : 28, weight: .medium, design: .rounded))
                            .tracking(-0.5).contentTransition(.numericText()).foregroundStyle(.white.opacity(0.96))
                    }
                    Text(quotaCaption).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                ZStack {
                    QuotaRing(fraction: model.primary?.fraction, lineWidth: 5, stale: model.isStale, reducedMotion: model.reduceMotion)
                    VStack(spacing: 1) {
                        Text(model.primary.map { "\($0.percent)%" } ?? "—")
                            .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("剩余").font(.system(size: 8)).foregroundStyle(Palette.dim)
                    }
                }.frame(width: 62, height: 62)
            }
            .padding(.horizontal, 14)
            .frame(height: 92)
            .glassCard(radius: 18, tint: QuotaRing.tint(for: model.primary?.fraction))

            HStack(spacing: 8) {
                ForEach(model.planLanes) { planCard($0, compact: model.planLanes.count >= 3) }
            }
            .frame(height: 72)

            HStack(spacing: 10) {
                ActivityCore(state: model.activityAppearance, reducedMotion: model.reduceMotion,
                             count: model.activeConversationCount)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.statusTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.93))
                    Text(model.statusDetail).font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.demo || model.canOpen(model.focusAgent) {
                    Button { model.openAgent() } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(GlassButtonStyle(compact: true, circle: true))
                    .help("打开 \(model.focusAgent.name)").accessibilityLabel("打开 \(model.focusAgent.name)")
                }
            }
            .padding(.leading, 12).padding(.trailing, 13)
            .frame(height: 50)
            .glassCard(radius: 16, tint: model.activityAppearance == .idle ? nil : model.activityAppearance.tint)

            HStack(spacing: 5) {
                Circle().fill(model.snapshot != nil || model.demo ? Palette.mint : Color.orange)
                    .frame(width: 5, height: 5)
                    .shadow(color: model.snapshot != nil || model.demo ? Palette.mint : Color.orange, radius: 3)
                Text(model.demo ? "演示数据 · 各账号独立刷新" : "Codex · 订阅额度 · 独立刷新").font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
                    .help(model.serviceMessage)
                Spacer(minLength: 6)
                Button { model.openSettings?() } label: {
                    Label("设置", systemImage: "gearshape").font(.system(size: 10, weight: .medium))
                }.buttonStyle(GlassButtonStyle(compact: true))
            }
            .padding(.leading, 6)
            .frame(height: 26)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .frame(height: model.detailHeight, alignment: .top)
    }
    private var demoBadge: some View {
        Text("演示").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.mint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Palette.mint.opacity(0.14)))
            .overlay(GlassRim(shape: Capsule(), intensity: 0.5))
    }
    private func planCard(_ lane: PlanLane, compact: Bool) -> some View {
        let primary = lane.primary
        let ring = QuotaRing(fraction: primary?.fraction, lineWidth: compact ? 2.5 : 4, stale: lane.stale, reducedMotion: model.reduceMotion)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    let style = ServiceStyle(laneID: lane.id)
                    style.icon.resizable().aspectRatio(contentMode: .fit)
                        .foregroundStyle(style.tint).frame(width: 11, height: 11)
                    // Narrow cards drop the product suffix ("Cline Pass" → "Cline"); the icon identifies it.
                    Text(compact ? lane.title.split(separator: " ").first.map(String.init) ?? lane.title : lane.title)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.dim).lineLimit(1)
                    if model.demo && !compact { demoBadge }
                    if compact { Spacer(minLength: 0); ring.frame(width: 15, height: 15) }
                }
                if lane.loading {
                    SkeletonBar(width: compact ? 44 : 52, height: 17).padding(.vertical, 3)
                } else {
                    Text(primary.map { "\($0.percent)%" } ?? "未连接")
                        .font(.system(size: primary == nil ? 15 : 19, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96)).contentTransition(.numericText())
                }
                Text(primary.map { first in
                    ([first.label] + (lane.snapshot?.quotas.dropFirst().prefix(1).map { "\($0.label) \($0.percent)%" } ?? [])).joined(separator: " · ")
                } ?? lane.message)
                    .font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            if !compact {
                Spacer(minLength: 0)
                ring.frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, compact ? 10 : 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard(radius: 16, tint: QuotaRing.tint(for: primary?.fraction))
        .help(lane.message)
        .accessibilityElement(children: .combine)
    }
    /// `nil` is the Codex / API lane; the rest are subscription lanes.
    private func compactItem(_ lane: PlanLane?) -> some View {
        compactQuota(ServiceStyle(laneID: lane?.id), title: lane?.title ?? model.source.title,
                     quota: lane.map(\.primary) ?? model.primary, stale: lane?.stale ?? model.isStale,
                     loading: lane?.loading ?? (model.refreshing && model.displayedSnapshot == nil))
    }
    private func compactQuota(_ style: ServiceStyle, title: String, quota: Quota?, stale: Bool, loading: Bool = false) -> some View {
        HStack(spacing: 4) {
            style.icon.resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(style.tint.opacity(0.95))
                .frame(width: 11, height: 11)
            Group {
                if loading { CometSpinner(size: 10, lineWidth: 1.5, tint: style.tint) }
                else { QuotaRing(fraction: quota?.fraction, lineWidth: 1.5, stale: stale, reducedMotion: model.reduceMotion) }
            }
            .frame(width: 10, height: 10)
            Text(quota.map { "\($0.percent)%" } ?? "—")
                .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityLabel("\(title)，剩余\(quota.map { "\($0.percent)%" } ?? "未知")")
    }
    private var amount: String {
        guard let usage = model.displayedSnapshot else { return "等待连接" }
        if let balance = usage.balance { return String(format: "$%.2f", balance) }
        if let primary = usage.quotas.first {
            return primary.monetary ? String(format: "$%.2f", max(0, primary.remaining)) : "\(primary.percent)%"
        }
        return "—"
    }
    private var quotaCaption: String {
        guard let q = model.primary else { return "在设置中连接账号" }
        if q.id == "wallet" { return String(format: "满格基准 $%.0f USD", q.limit) }
        let secondary = model.displayedSnapshot?.quotas.dropFirst().prefix(2).map { "\($0.label) \($0.percent)%" }.joined(separator: " · ") ?? ""
        if !secondary.isEmpty { return "\(q.label) · \(secondary)" }
        if let reset = q.resetsAt { return "\(q.label) · \(reset.formatted(date: .omitted, time: .shortened)) 恢复" }
        return "\(q.label) · 剩余额度"
    }
}

struct QuotaRing: View {
    let fraction: Double?
    var lineWidth: CGFloat = 4
    var stale = false
    var reducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func tint(for fraction: Double?) -> Color {
        switch QuotaLevel(fraction: fraction) {
        case .healthy: return Palette.mint
        case .warning: return Color(red: 1, green: 0.79, blue: 0.26)
        case .low: return Color(red: 1, green: 0.30, blue: 0.35)
        case .unknown: return .gray
        }
    }
    private var tint: Color { Self.tint(for: fraction) }
    var body: some View {
        ZStack {
            // Recessed glass groove for the track.
            Circle().stroke(.black.opacity(0.28), lineWidth: lineWidth)
            Circle().stroke(LinearGradient(colors: [.white.opacity(0.04), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom), lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: fraction)
                    .stroke(AngularGradient(colors: [tint.opacity(0.65), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90)).opacity(stale ? 0.45 : 1)
                    .shadow(color: tint.opacity(0.45), radius: 6)
                    .animation(reduceMotion || reducedMotion ? nil : .spring(response: 0.9, dampingFraction: 0.9), value: fraction)
            } else {
                Circle().stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 5]))
            }
        }.padding(lineWidth / 2)
    }
}
