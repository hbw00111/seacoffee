#if SEACOFFEE_DROPPY
import AppKit
import Combine
import SwiftUI
import IslandCore
import DroppyKit

@objc(SeaCoffeeDropletPrincipal)
public final class SeaCoffeeDropletPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { SeaCoffeeDroplet() }
}

@MainActor
public final class SeaCoffeeDroplet: NSObject, ObservableObject, Droplet, HUDPresenting {
    public nonisolated static let id: DropletID = "seacoffee"
    let model = IslandModel()
    private var host: DropletHost?
    private var changes: AnyCancellable?
    private var settingsWindow: NSWindow?
    private let activity = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private var active = false
    private(set) var isPreview = false

    public func activate(host: DropletHost) throws {
        guard !active else { return }
        self.host = host
        active = true
        isPreview = host.environment.isHarness
        model.openSettings = { [weak self] in self?.showSettings() }
        model.noticePresented = { [weak self] session, kind in self?.presentNotice(session, kind: kind) }
        changes = model.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publishActivity() }
        if isPreview {
            // Harness screenshots must not query accounts, read sessions or change credentials.
            model.demo = true
            model.demoRunning = ProcessInfo.processInfo.environment["SEACOFFEE_PREVIEW_IDLE"] != "1"
        } else {
            model.start()
        }
        publishActivity()
        host.log.info("Sea Coffee activated")
    }

    public func deactivate() {
        guard active else { return }
        active = false
        changes?.cancel(); changes = nil
        model.noticePresented = nil; model.openSettings = nil
        model.stop()
        settingsWindow?.close(); settingsWindow = nil
        activity.send(nil)
        host?.hud.dismiss(id: "seacoffee.notice")
        host?.log.info("Sea Coffee deactivated")
        host = nil
    }

    private func publishActivity() {
        guard active else { return }
        // Quotas remain useful between tasks. nil is reserved for deactivation.
        activity.send(LiveActivityState(
            priority: model.asking != nil ? 400 : model.isRunning || model.notice != nil ? 200 : 100,
            accessibilityTitle: model.compactAccessibilityTitle,
            isInteractive: true, joinsPersistentActivitySet: true))
    }

    private func presentNotice(_ session: SessionState, kind: NoticeKind) {
        guard active, let host else { return }
        let question = kind == .question
        let symbol = question ? "questionmark.circle.fill" : session.state == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        let caption = question ? "向你提问" : session.state == .completed ? "本轮已完成" : session.state == .failed ? "运行失败" : "任务已中断"
        let title = "\(session.agent.name) · \(caption)"
        let detail = [session.project, session.channelName, session.modelName].compactMap { $0 }.joined(separator: " · ")
        let tint = question ? NotchPalette.attention : session.state == .completed ? NotchPalette.mint : Color.red
        let request = DropletHUDRequest(id: "seacoffee.notice", duration: question ? 6 : 4,
            priority: question ? .high : .normal, accessibilityLabel: title,
            isExpanded: true, expandedContentHeight: 72) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Text(question ? "提问" : session.state == .completed ? "完成" : "提醒")
                        .font(.system(size: 12, weight: .semibold))
                }.foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            } expanded: {
                VStack(alignment: .leading, spacing: 6) {
                    Label(title, systemImage: symbol).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).lineLimit(2)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        if !host.hud.present(request) {
            // The shelf retains the real session state even if another activity owns the notch.
            host.log.debug("Sea Coffee notice suppressed by host")
        }
    }

    func refresh() { if !isPreview, active { model.refresh() } }

    func showSettings() {
        guard active, !isPreview else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: InterfaceLayout.settingsWidth, height: InterfaceLayout.settingsHeight),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Sea Coffee · 账号与监听"
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.isOpaque = false; window.backgroundColor = .clear
            let content = NSHostingView(rootView: SettingsView(model: model))
            content.sizingOptions = []
            window.contentView = content
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension SeaCoffeeDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [ShelfWidgetDescriptor(id: "dashboard", title: "Sea Coffee", systemImage: "cup.and.saucer.fill",
            layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 240,
                                                   contentHeight: .fixed(340)),
            searchKeywords: ["额度", "余额", "任务", "Codex", "Claude", "Grok", "Cline", "Pi"])]
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(SeaCoffeeWidget(droplet: self, model: model, context: context))
    }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension SeaCoffeeDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> { activity.eraseToAnyPublisher() }
    public func makeCompactLeading() -> AnyView { AnyView(SeaCoffeeActivity(model: model, leading: true)) }
    public func makeCompactTrailing() -> AnyView { AnyView(SeaCoffeeActivity(model: model, leading: false)) }
    public func makeExpanded(context: LiveActivityContext) -> AnyView { AnyView(EmptyView()) }
}

extension SeaCoffeeDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(DropletSettingsPane {
            Section("账号与任务") {
                Text("沿用 Sea Coffee 的账号配置，显示 Codex、Claude、Grok、Cline、Pi 的任务和各渠道额度。")
                    .foregroundStyle(.secondary)
                Button("账号与监听设置…") { [weak self] in self?.showSettings() }
                    .disabled(isPreview)
                Button("刷新额度") { [weak self] in self?.refresh() }.disabled(isPreview)
                Button("预览完成提示") { [weak self] in self?.model.preview() }.disabled(isPreview)
                Button("预览提问提示") { [weak self] in self?.model.previewQuestion() }.disabled(isPreview)
            }
            Section("提示") {
                Text("在 Shelf 的组件页选择 Sea Coffee。音乐或会议占用刘海时，任务与额度仍可在卡片中查看。")
                Text("使用插件时请退出独立 Sea Coffee，避免重复查询和通知。开机启动由 Droppy 管理。")
                    .foregroundStyle(.secondary)
            }
        })
    }
}

// Keep at most two quota rows per wing inside Droppy's 98 × 37 pt content area.
// Use the same primary quota and provider icons as the standalone island.
private extension IslandModel {
    var compactQuotaLanes: [PlanLane] {
        [PlanLane(id: "CX", title: source.title, snapshot: displayedSnapshot,
                  stale: isStale, message: serviceMessage,
                  loading: refreshing && displayedSnapshot == nil)] + planLanes
    }
    var compactAccessibilityTitle: String {
        let quotas = compactQuotaLanes.map { lane in
            "\(lane.title)，\(lane.primary?.label ?? "额度")剩余\(lane.primary.map { "\($0.percent)%" } ?? "未知")\(lane.stale ? "，待更新" : "")"
        }.joined(separator: "；")
        return "\(demo ? "演示数据；" : "")\(statusTitle)；\(quotas)"
    }
}

private struct SeaCoffeeActivity: View {
    @ObservedObject var model: IslandModel
    let leading: Bool
    private var lanes: [PlanLane] {
        let all = model.compactQuotaLanes
        let split = (all.count + 1) / 2
        return leading ? Array(all.prefix(split)) : Array(all.dropFirst(split))
    }
    var body: some View {
        HStack(spacing: 6) {
            if leading {
                VStack(spacing: 0) {
                    ActivityCore(state: model.activityAppearance, reducedMotion: model.reduceMotion,
                                 count: model.activeConversationCount).frame(width: 20, height: 20)
                    if model.demo {
                        Text("演示").font(.system(size: 8))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                }.help(model.statusTitle)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lanes) { lane in
                    SeaCoffeeCompactQuota(lane: lane, reducedMotion: model.reduceMotion)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.compactAccessibilityTitle)
    }
}

private struct SeaCoffeeCompactQuota: View {
    let lane: PlanLane
    let reducedMotion: Bool
    private var style: ServiceStyle { ServiceStyle(laneID: lane.id) }
    private var caption: String {
        "\(lane.title) · \(lane.primary?.label ?? "额度") · \(lane.loading ? "加载中" : lane.primary.map { "剩余 \($0.percent)%" } ?? lane.message)\(lane.stale ? " · 待更新" : "")"
    }
    var body: some View {
        HStack(spacing: 3) {
            style.icon.resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(style.notchTint).frame(width: 10, height: 10)
            Group {
                if lane.loading {
                    CometSpinner(size: 10, lineWidth: 1.5, tint: style.notchTint)
                } else {
                    QuotaRing(fraction: lane.primary?.fraction, lineWidth: 1.5,
                              stale: lane.stale, reducedMotion: reducedMotion)
                }
            }.frame(width: 10, height: 10)
            Text(lane.primary.map { "\($0.percent)%" } ?? "—")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText.opacity(lane.stale ? 0.55 : 1))
            if lane.stale {
                Image(systemName: "clock").font(.system(size: 8))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
        }
        .help(caption)
        .accessibilityLabel(caption)
    }
}

private struct SeaCoffeeWidget: View {
    let droplet: SeaCoffeeDroplet
    @ObservedObject var model: IslandModel
    let context: ShelfWidgetContext
    private enum Page: String, CaseIterable, Identifiable {
        case quotas = "额度", sessions = "任务"
        var id: String { rawValue }
    }
    @State private var page = Page.quotas

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(NotchPalette.accent)
                Text("Sea Coffee").fontWeight(.semibold)
                Spacer(minLength: 0)
                Button { droplet.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle(compact: true, circle: true, ghost: true, darkSurface: true)).help("刷新额度").accessibilityLabel("刷新额度")
                    .disabled(droplet.isPreview)
                Button { droplet.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(GlassButtonStyle(compact: true, circle: true, ghost: true, darkSurface: true)).help("账号与监听设置").accessibilityLabel("账号与监听设置")
                    .disabled(droplet.isPreview)
            }.font(.system(size: 12)).foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            HStack(spacing: 6) {
                Circle().fill(model.activityAppearance.tint).frame(width: 6, height: 6)
                Text(model.statusTitle).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            GlassSegmented(options: Page.allCases, selection: $page, darkSurface: true) { $0.rawValue }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if page == .quotas { quotas } else { sessions }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if droplet.isPreview || model.demo { Text("演示数据").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }

    private var quotas: some View {
        Group {
            SeaCoffeeQuotaRow(title: model.source.title, snapshot: model.displayedSnapshot,
                stale: model.isStale, message: model.serviceMessage,
                loading: model.refreshing && model.displayedSnapshot == nil, compact: context.isCompact)
            ForEach(model.planLanes) { lane in
                Divider()
                SeaCoffeeQuotaRow(title: lane.title, snapshot: lane.snapshot, stale: lane.stale,
                    message: lane.message, loading: lane.loading, compact: context.isCompact)
            }
        }
    }

    private var sessions: some View {
        Group {
            if let message = model.monitorMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if model.sessions.isEmpty {
                Text(droplet.isPreview ? "Codex · 示例项目\n正在运行" : "暂无近期任务。新任务开始后会自动出现在这里。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(model.sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.agent.name).fontWeight(.semibold)
                        Spacer(minLength: 4)
                        Text(session.awaitingAnswer ? "等你回答" : stateLabel(session.state))
                            .foregroundStyle(session.awaitingAnswer ? NotchPalette.attention : .secondary)
                    }.font(.system(size: 11))
                    Text([session.project, session.modelName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Divider()
            }
        }
    }
    private func stateLabel(_ state: RunState) -> String {
        switch state {
        case .running: return "运行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .unknown: return "待确认"
        }
    }
}

private struct SeaCoffeeQuotaRow: View {
    let title: String
    let snapshot: UsageSnapshot?
    let stale: Bool
    let message: String
    let loading: Bool
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 2)
                if let balance = snapshot?.balance { Text("$\(balance, specifier: "%.2f")").monospacedDigit() }
            }.font(.system(size: 12))
            if let snapshot {
                ForEach(snapshot.quotas) { quota in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(quota.label).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(quota.percent)%").monospacedDigit()
                        }.font(.system(size: 11))
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(NotchPalette.subtle)
                                Capsule().fill(QuotaRing.tint(for: quota.fraction, darkSurface: true))
                                    .frame(width: geometry.size.width * quota.fraction)
                            }
                        }.frame(height: 4)
                        .accessibilityLabel("剩余 \(quota.percent)%")
                        if let resetsAt = quota.resetsAt, !compact {
                            Text("重置：\(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                if stale {
                    Text("数据已过期 · \(message)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text(loading ? "正在查询…" : message).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(3)
            }
        }.opacity(stale ? 0.65 : 1)
    }
}
#endif
