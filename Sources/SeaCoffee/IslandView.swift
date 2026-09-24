import SwiftUI
import IslandCore

enum Palette {
    static let mint = Color(red: 0.52, green: 0.94, blue: 0.79)
    static let blue = Color(red: 0.44, green: 0.73, blue: 0.98)
    static let dim = Color.white.opacity(0.43)
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
                        cameraHeight: model.hasNotch ? model.headerHeight : 0, badgeWidth: model.completionWidth, hasNotch: model.hasNotch) {
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
                shape.fill(.black)
                    .overlay(alignment: .bottom) {
                        Ellipse().fill(model.activityAppearance.tint.opacity(model.isRunning ? 0.10 : 0.025))
                            .frame(width: 330, height: 130).blur(radius: 40).offset(y: 65)
                    }
                    .clipShape(shape)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(model.expanded || model.completion != nil ? 0.11 : 0), lineWidth: 0.7))
            .shadow(color: .black.opacity(model.expanded ? 0.4 : model.hasNotch ? 0 : 0.08),
                    radius: model.expanded ? 16 : 3, y: model.expanded ? 9 : 0)
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
                ActivityCore(state: model.activityAppearance, reducedMotion: model.reduceMotion)
                    .frame(width: 23, height: 23)
                if model.activeConversationCount > 0 {
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
                    VStack(alignment: .leading, spacing: 2) {
                        compactQuota("API", quota: model.primary, stale: model.isStale)
                        compactQuota("CL", quota: model.clinePrimary, stale: model.clineIsStale)
                    }

                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: model.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(!model.expanded) }
        .accessibilityLabel("Sea Coffee，\(model.activityAppearance.label)，\(model.activeConversationCount) 个对话正在运行，Codex 剩余\(model.primary.map { "\($0.percent)%" } ?? "未知")，Cline Pass 剩余\(model.clinePrimary.map { "\($0.percent)%" } ?? "未知")")
        .accessibilityAddTraits(.isButton)
    }
    private var detail: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(model.demo ? "Sub2API · 钱包余额" : model.source.title + (model.displayedSnapshot?.balance != nil ? " · 钱包余额" : ""))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                        if model.demo {
                            Text("演示").font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.mint)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Palette.mint.opacity(0.1), in: Capsule())
                        }
                    }
                    Text(amount).font(.system(size: model.primary == nil ? 24 : 29, weight: .medium, design: .rounded))
                        .tracking(-0.5).contentTransition(.numericText()).foregroundStyle(.white.opacity(0.94))
                    Text(quotaCaption).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                ZStack {
                    QuotaRing(fraction: model.primary?.fraction, lineWidth: 4, stale: model.isStale, reducedMotion: model.reduceMotion)
                    VStack(spacing: 2) {
                        Text(model.primary.map { "\($0.percent)%" } ?? "—")
                            .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("剩余").font(.system(size: 8)).foregroundStyle(Palette.dim)
                    }
                }.frame(width: 64, height: 64)
            }
            .frame(height: 78)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cline Pass" + (model.demo ? " · 演示" : ""))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                    Text(model.clinePrimary.map { "\($0.percent)%" } ?? "等待连接")
                        .font(.system(size: 23, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94)).contentTransition(.numericText())
                    Text(clineCaption).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                QuotaRing(fraction: model.clinePrimary?.fraction, lineWidth: 4,
                          stale: model.clineIsStale, reducedMotion: model.reduceMotion)
                    .frame(width: 48, height: 48)
            }
            .frame(height: 66)
            .help(model.clineMessage)

            HStack(spacing: 10) {
                ActivityCore(state: model.activityAppearance, reducedMotion: model.reduceMotion)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.91))
                    Text(model.statusDetail).font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.openCodex() } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.dim).frame(width: 23, height: 28)
                }.buttonStyle(.plain).help("打开 Codex").accessibilityLabel("打开 Codex")
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 5) {
                Circle().fill(model.snapshot != nil || model.demo ? Palette.mint.opacity(0.7) : Color.orange.opacity(0.7)).frame(width: 4, height: 4)
                Text(model.demo ? "演示数据 · 两个账号独立刷新" : "Codex + Cline Pass · 每分钟独立刷新").font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
                    .help(model.serviceMessage)
                Spacer(minLength: 6)
                Button { model.openSettings?() } label: {
                    Label("设置", systemImage: "gearshape").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                        .frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.frame(height: 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(height: model.detailHeight, alignment: .top)
    }
    private func compactQuota(_ label: String, quota: Quota?, stale: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label == "API" && model.source == .official ? "CX" : label)
                .font(.system(size: 7, weight: .medium)).foregroundStyle(Palette.dim).frame(width: 15)
            QuotaRing(fraction: quota?.fraction, lineWidth: 1.5, stale: stale, reducedMotion: model.reduceMotion)
                .frame(width: 10, height: 10)
            Text(quota.map { "\($0.percent)%" } ?? "—")
                .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityLabel("\(label == "CL" ? "Cline Pass" : model.source.title)，剩余\(quota.map { "\($0.percent)%" } ?? "未知")")
    }
    private var clineCaption: String {
        guard let usage = model.displayedClineSnapshot else { return model.clineMessage }
        return usage.quotas.map { "\($0.label) \($0.percent)%" }.joined(separator: " · ")
    }
    private var amount: String {
        guard let usage = model.displayedSnapshot else { return "等待连接" }
        if let balance = usage.balance { return String(format: "$%.2f", balance) }
        if let primary = usage.quotas.first {
            return primary.monetary ? String(format: "$%.2f", max(0, primary.remaining)) : "\(primary.percent)%"
        }
        return "—"
    }
    private var unit: String { model.displayedSnapshot?.balance != nil ? "USD" : "" }
    private var quotaCaption: String {
        guard let q = model.primary else { return "在设置中连接账号" }
        if q.id == "wallet" { return String(format: "满格基准 $%.0f USD", q.limit) }
        let secondary = model.displayedSnapshot?.quotas.dropFirst().prefix(2).map { "\($0.label) \($0.percent)%" }.joined(separator: " · ") ?? ""
        if !secondary.isEmpty { return "\(q.label) · \(secondary)" }
        if let reset = q.resetsAt { return "\(q.label) · \(reset.formatted(date: .omitted, time: .shortened)) 恢复" }
        return "\(q.label) · 剩余额度"
    }
    private var footnote: String {
        if model.demo { return "演示数据 · 不影响真实任务" }
        if let snapshot = model.snapshot, !model.serviceMessage.contains("失败"), !model.serviceMessage.contains("保留") {
            return "更新于 \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
        }
        return model.snapshot == nil ? "尚未连接额度" : model.serviceMessage
    }
    private var statusTint: Color { model.notice?.state == .failed ? .orange : Palette.mint }
    private var statusIcon: String {
        if model.demo && !model.demoRunning || model.notice?.state == .completed { return "checkmark" }
        if model.notice?.state == .failed { return "exclamationmark" }
        if model.notice?.state == .interrupted { return "pause.fill" }
        return model.isRunning ? "sparkles" : "moon.stars"
    }
    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.dim)
                .frame(width: 23, height: 25).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct QuotaRing: View {
    let fraction: Double?
    var lineWidth: CGFloat = 4
    var stale = false
    var reducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color {
        switch QuotaLevel(fraction: fraction) {
        case .healthy: return Palette.mint
        case .warning: return Color(red: 1, green: 0.79, blue: 0.26)
        case .low: return Color(red: 1, green: 0.30, blue: 0.35)
        case .unknown: return .gray
        }
    }
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.09), lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: fraction)
                    .stroke(AngularGradient(colors: [tint.opacity(0.65), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90)).opacity(stale ? 0.45 : 1)
                    .shadow(color: tint.opacity(0.20), radius: 5)
                    .animation(reduceMotion || reducedMotion ? nil : .spring(response: 0.9, dampingFraction: 0.9), value: fraction)
            } else {
                Circle().stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 5]))
            }
        }.padding(lineWidth / 2)
    }
}

struct Waveform: View {
    var reducedMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reducedMotion)) { timeline in
            let time = reducedMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4) { index in
                    Capsule().fill(Palette.mint.opacity(0.8))
                        .frame(width: 2.5, height: 4 + (sin(time * 3.8 + Double(index) * 1.1) + 1) * 4)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityHidden(true)
    }
}
