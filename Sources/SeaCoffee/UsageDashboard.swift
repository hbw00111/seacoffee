import SwiftUI
import Charts
import IslandCore

/// Everything the calls tab shows for one range and filter, built off the main thread.
struct UsagePrepared: Sendable {
    var report = UsageStatsReport()
    var unpriced = 0
    /// Logs split by the status filter menu, built once so redraws never scan the whole list.
    var byStatus: [Int: [UsageLog]] = [:]
    static let statuses = [200, 400, 401, 429, 500]
    init() {}
    init(dataset: UsageDataset, range: UsageRange, filter: UsageFilter) {
        report = UsageStatsReport(dataset, range: range, filter: filter)
        for log in report.logs {
            if log.costState == .unpriced { unpriced += 1 }
            if Self.statuses.contains(log.status) { byStatus[log.status, default: []].append(log) }
        }
    }
    func logs(status: Int?) -> [UsageLog] { status.map { byStatus[$0] ?? [] } ?? report.logs }
}

@MainActor
final class UsageDashboardModel: ObservableObject {
    private(set) var dataset = UsageDataset()
    /// DSH keeps its own counters; they are not CC Switch request rows and stay out of that report.
    @Published var dshSessions: [DshSession] = []
    @Published var revision = 0
    @Published var prepared = UsagePrepared()
    @Published var heatmap: UsageHeatmap?
    @Published var preparing = false
    private var reportKey: [String] = []
    private var heatmapKey: [String] = []
    /// Filter options, computed once per reload: deriving them in `body` scanned every log on each redraw.
    private(set) var apps: [String] = [], providers: [String] = [], models: [String] = []

    func prepare(key: [String], range: UsageRange, filter: UsageFilter) async {
        guard reportKey != key else { return }
        preparing = true
        let dataset = dataset
        let result = await Task.detached(priority: .userInitiated) {
            UsagePrepared(dataset: dataset, range: range, filter: filter)
        }.value
        guard !Task.isCancelled else { preparing = false; return }
        prepared = result; reportKey = key; preparing = false
    }
    func prepareHeatmap(key: [String], metric: UsageHeatmapMetric, filter: UsageFilter) async {
        guard heatmapKey != key else { return }
        let dataset = dataset
        let result = await Task.detached(priority: .userInitiated) {
            UsageHeatmap(dataset, metric: metric, filter: filter)
        }.value
        guard !Task.isCancelled else { return }
        heatmap = result; heatmapKey = key
    }

    @Published var history: [QuotaHistoryPoint] = []
    @Published var loading = false
    @Published var error: String?
    @Published var historyError: String?
    @Published var updated: Date?
    func reload(force: Bool = true) async {
        if !force, let updated, Date().timeIntervalSince(updated) < 60 { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await Task.detached(priority: .utility) {
            Swift.Result { let data = try UsageStats.read(); return (data, data.apps, data.providers, data.models) }
        }.value
        let sessions = await Task.detached(priority: .utility) {
            DshStore.read(since: Date().addingTimeInterval(-30 * 86_400))
        }.value
        guard !Task.isCancelled else { return }
        dshSessions = sessions
        switch result {
        case .success(let (data, apps, providers, models)):
            dataset = data; self.apps = apps; self.providers = providers; self.models = models
            error = nil; updated = Date(); revision += 1
        case .failure(let failure): error = failure.localizedDescription
        }
        do { history = try await QuotaHistoryStore().read(); historyError = nil }
        catch { historyError = "额度历史暂时无法读取，现有文件已保留。" }
    }
}

private enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "今天", week = "7 天", month = "30 天"
    var id: String { rawValue }
    var start: Date {
        Calendar.current.date(byAdding: .day, value: self == .today ? 0 : self == .week ? -6 : -29,
                              to: Calendar.current.startOfDay(for: Date()))!
    }
}
private enum UsageTab: String, CaseIterable, Identifiable {
    case calls = "调用统计", dsh = "DSH 记录", quota = "额度趋势"
    var id: String { rawValue }
}
private enum UsageMetric: String, CaseIterable, Identifiable {
    case tokens = "Tokens", requests = "请求", cost = "成本"
    var id: String { rawValue }
}
private enum UsageTable: String, CaseIterable, Identifiable {
    case logs = "请求日志", providers = "供应商", models = "模型"
    var id: String { rawValue }
}

private let allApps = "", allProviders = "", allModels = ""
private let tablePageSize = 20

private func friendlyApp(_ raw: String) -> String {
    switch raw {
    case "claude": return "Claude Code"
    case "codex": return "Codex"
    case "gemini": return "Gemini"
    case "grokbuild": return "Grok Build"
    case "opencode": return "OpenCode"
    case "pi": return "Pi"
    default: return raw
    }
}
private func usd(_ d: Decimal, _ digits: Int = 4) -> String { UsageFormat.usd(NSDecimalNumber(decimal: d).doubleValue, decimals: digits) }

private let timeToday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
private let timeOther: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()
private let timeFull: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
private let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
private let monthFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月"; return f }()

struct UsageDashboard: View {
    @ObservedObject var data: UsageDashboardModel
    @Environment(\.glassSnapshot) private var preview
    @State private var tab: UsageTab = .calls
    @State private var period: UsagePeriod = .week
    @State private var range: UsageRange = .week
    @State private var heatMetric: UsageHeatmapMetric = .tokens
    @State private var dshPeriod: UsagePeriod = .week
    @State private var app = allApps
    @State private var provider = allProviders
    @State private var model = allModels
    @State private var quotaProvider = "Codex API"
    @State private var windowID = "wallet"
    @State private var showMore = false
    var recordingError: String?

    private var report: UsageStatsReport { data.prepared.report }
    private var totals: UsageTotals { report.totals }
    private var filter: UsageFilter {
        UsageFilter(app: app == allApps ? nil : app, provider: provider == allProviders ? nil : provider,
                    model: model == allModels ? nil : model)
    }
    private var reportKey: [String] { [String(data.revision), range.rawValue, app, provider, model] }
    private var heatmapKey: [String] { [String(data.revision), heatMetric.rawValue, app, provider, model] }
    private var history: [QuotaHistoryPoint] {
        let start = period.start
        return data.history.filter { $0.provider == quotaProvider && $0.date >= start }.sorted { $0.date < $1.date }
    }
    private var quotaProviders: [String] { Array(Set(data.history.map(\.provider))).sorted() }
    private var quotaWindows: [(String, String)] {
        var seen = Set<String>()
        return history.reversed().flatMap(\.windows).compactMap { window in
            guard seen.insert(window.id).inserted else { return nil }
            return (window.id, window.label)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GlassSegmented(options: UsageTab.allCases, selection: $tab) { $0.rawValue }
                    .frame(maxWidth: 260)
                Spacer(minLength: 4)
                if let updated = data.updated {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(UsageFormat.relative(updated, now: context.date) + "同步")
                            .font(.system(size: 11)).foregroundStyle(Palette.dim)
                    }
                }
                Button { Task { await data.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle(circle: true, loading: data.loading))
                    .disabled(data.loading).help("刷新本机用量记录").accessibilityLabel("刷新用量")
            }
            if tab == .calls {
                GlassSegmented(options: UsageRange.allCases, selection: $range) { $0.rawValue }
            } else {
                HStack {
                    Text("时间范围").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                    Spacer()
                    GlassSegmented(options: UsagePeriod.allCases, selection: tab == .dsh ? $dshPeriod : $period) { $0.rawValue }
                        .frame(maxWidth: 240)
                }
            }
            if tab == .calls { callContent } else if tab == .dsh { dshContent } else { quotaContent }
        }
        .task {
            guard !preview else { return }
            await data.reload(force: false)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await data.reload()
            }
        }
        .task(id: reportKey) {
            guard !preview else { return }
            await data.prepare(key: reportKey, range: range, filter: filter)
        }
        .task(id: heatmapKey) {
            guard !preview else { return }
            await data.prepareHeatmap(key: heatmapKey, metric: heatMetric, filter: filter)
        }
        .onChange(of: quotaProvider) { _, _ in windowID = quotaWindows.first?.0 ?? "wallet" }
        .onChange(of: period) { _, _ in
            if !quotaWindows.contains(where: { $0.0 == windowID }) { windowID = quotaWindows.first?.0 ?? "wallet" }
        }
        .onChange(of: data.history.count) { _, _ in
            if !quotaProviders.contains(quotaProvider) { quotaProvider = quotaProviders.first ?? "Codex API" }
            if !quotaWindows.contains(where: { $0.0 == windowID }) { windowID = quotaWindows.first?.0 ?? "wallet" }
        }
    }

    // MARK: 调用统计

    private var callContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                filterMenu("应用", selection: $app, all: "全部应用", values: data.apps, label: friendlyApp)
                filterMenu("供应商", selection: $provider, all: "全部供应商", values: data.providers) { $0 }
                filterMenu("模型", selection: $model, all: "全部模型", values: data.models) { $0 }
            }
            if data.preparing {
                HStack(spacing: 7) {
                    CometSpinner(size: 12, tint: Palette.accent)
                    Text("正在更新统计…").font(.system(size: 10)).foregroundStyle(Palette.dim)
                }
            }
            if let error = data.error { notice(error, warning: true) }
            heroCards
            moreMetrics
            if data.updated == nil && data.error == nil {
                emptyState(icon: nil, title: "正在读取本机用量", detail: "", loading: true)
            } else if totals.requests == 0 {
                emptyState(icon: "chart.xyaxis.line", title: "暂无调用记录",
                           detail: "该筛选范围没有调用记录。可扩大时间范围，或把应用、供应商、模型切回“全部”。",
                           loading: false)
            } else {
                UsageTrendCard(report: report, rangeLabel: range.rawValue)
            }
            if (data.updated != nil || data.error != nil) {
                UsageHeatmapCard(heatmap: data.heatmap, loading: data.loading, metric: $heatMetric)
            }
            if totals.requests > 0 { UsageTablesCard(prepared: data.prepared, resetKey: reportKey) }
            VStack(alignment: .leading, spacing: 4) {
                Text("来源：本机 CC Switch 的请求日志与按天汇总（明细保留约 30 天，更早的按天合并）。金额按 CC Switch 的价格表计算，未定价的请求不计入，不等同于账单。")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim)
                if data.prepared.unpriced > 0 {
                    Text("\(data.prepared.unpriced) 条请求未定价").font(.system(size: 10)).foregroundStyle(Palette.warning)
                }
            }
        }
    }

    // MARK: DSH 记录

    private var dshContent: some View {
        let start = dshPeriod.start
        let sessions = data.dshSessions.filter { $0.lastPromptAt >= start && ($0.turns > 0 || $0.tokens > 0 || $0.running) }
            .sorted { $0.lastPromptAt > $1.lastPromptAt }
        let tokens = sessions.reduce(0) { $0 + $1.tokens }
        let uncached = sessions.reduce(0) { $0 + $1.uncachedInput }
        let output = sessions.reduce(0) { $0 + $1.output }
        let decodeMs = sessions.reduce(0) { $0 + $1.decodeMs }
        let decodeTokens = sessions.reduce(0) { $0 + $1.decodeTokens }
        let ttftMs = sessions.reduce(0) { $0 + $1.ttftMs }
        let ttftSteps = sessions.reduce(0) { $0 + $1.ttftSteps }
        let speed = decodeMs >= 100 ? decodeTokens / (decodeMs / 1000) : nil
        let running = sessions.filter(\.running).count
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                metricCard("会话数", value: sessions.isEmpty ? "—" : "\(sessions.count)",
                           detail: running > 0 ? "\(running) 个正在运行" : "该范围没有运行中的会话", tint: Palette.ice)
                metricCard("真实消耗 Tokens", value: sessions.isEmpty ? "—" : UsageFormat.tokens(tokens),
                           detail: "新增输入 \(UsageFormat.tokens(uncached)) · 输出 \(UsageFormat.tokens(output))", tint: Palette.accent)
                metricCard("解码速度", value: UsageFormat.tokensPerSecond(speed), detail: "输出 Tokens ÷ 解码时长", tint: Palette.mint)
                metricCard("首字延迟", value: ttftSteps > 0 ? String(format: "%.1f s", ttftMs / Double(ttftSteps) / 1000) : "—",
                           detail: "\(ttftSteps) 个步骤有记录", tint: Palette.blue)
            }
            if sessions.isEmpty {
                emptyState(icon: "terminal", title: "还没有 DSH 记录",
                           detail: "运行一次 dsh web 或 dsh headless 后，这里会按会话列出轮次、步数、Tokens 与速度。",
                           loading: data.loading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    dshRow(nil)
                    ForEach(Array(sessions.prefix(40))) { session in
                        GlassDivider()
                        dshRow(session)
                    }
                }.padding(18).glassCard()
                Text(sessions.count > 40 ? "共 \(sessions.count) 个会话，按最近提问排序，显示最近 40 个。"
                                        : "共 \(sessions.count) 个会话，按最近提问排序。")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
            Text("来源：本机 DSH 的会话投影缓存（~/.dsh/storages/session_projcache），只读轮次、步数、Tokens 与时长，不读对话。缓存每 200 个事件或 5 秒落盘一次，数字可能略晚；速度与首字取自 DSH 自己的统计。")
                .font(.system(size: 10)).foregroundStyle(Palette.dim)
        }
    }

    private enum DshCol { static let time: CGFloat = 112, model: CGFloat = 138, steps: CGFloat = 48, number: CGFloat = 44, speed: CGFloat = 56, ttft: CGFloat = 44 }

    private func dshCell(_ text: String, _ width: CGFloat, header: Bool = false, trailing: Bool = false, dim: Bool = false) -> some View {
        Text(text).font(.system(size: header ? 10.5 : 11.5, weight: header ? .medium : .regular))
            .foregroundStyle(header || dim ? Palette.dim : Palette.text).monospacedDigit().lineLimit(1)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
    }

    @ViewBuilder private func dshRow(_ session: DshSession?) -> some View {
        if let session {
            let today = Calendar.current.isDateInToday(session.lastPromptAt)
            let ttft = session.averageFirstTokenMs.map { String(format: "%.1f s", $0 / 1000) } ?? "—"
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    dshCell((today ? timeToday : timeOther).string(from: session.lastPromptAt), DshCol.time)
                    dshCell(session.project.isEmpty ? "DSH" : session.project, DshCol.time, dim: true).font(.system(size: 10))
                }.frame(width: DshCol.time, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    dshCell(session.displayModel ?? "未记录模型", DshCol.model)
                    dshCell(session.provider ?? "—", DshCol.model, dim: true).font(.system(size: 10))
                }.frame(width: DshCol.model, alignment: .leading)
                Spacer(minLength: 0)
                dshCell("\(session.turns) / \(session.steps)", DshCol.steps, trailing: true)
                dshCell(UsageFormat.tokens(session.uncachedInput), DshCol.number, trailing: true)
                dshCell(UsageFormat.tokens(session.output), DshCol.number, trailing: true)
                dshCell(session.cacheRead > 0 ? UsageFormat.tokens(session.cacheRead) : "—", DshCol.number, trailing: true)
                dshCell(UsageFormat.tokensPerSecond(session.tokensPerSecond), DshCol.speed, trailing: true)
                dshCell(ttft, DshCol.ttft, trailing: true)
                Circle().fill(session.running ? Palette.ice : Color.clear).frame(width: 5, height: 5)
            }
            .padding(.vertical, 8).contentShape(Rectangle())
            .help(session.openStep.map { "\(session.project.isEmpty ? "DSH" : session.project) · 第 \($0) 步运行中" }
                  ?? "\(session.project.isEmpty ? "DSH" : session.project) · 已结束")
        } else {
            HStack(spacing: 6) {
                dshCell("时间 / 项目", DshCol.time, header: true)
                dshCell("模型 / 供应商", DshCol.model, header: true)
                Spacer(minLength: 0)
                dshCell("轮/步", DshCol.steps, header: true, trailing: true)
                dshCell("输入", DshCol.number, header: true, trailing: true)
                dshCell("输出", DshCol.number, header: true, trailing: true)
                dshCell("缓存", DshCol.number, header: true, trailing: true)
                dshCell("速度", DshCol.speed, header: true, trailing: true)
                dshCell("首字", DshCol.ttft, header: true, trailing: true)
                Color.clear.frame(width: 5, height: 5)
            }.padding(.bottom, 8)
        }
    }

    private var heroCards: some View {
        let empty = totals.requests == 0
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            metricCard("总成本", value: empty ? "—" : UsageFormat.usd(totals.cost, decimals: 2), detail: "按 CC Switch 价格表计算", tint: Palette.mint)
                .help(empty ? "" : UsageFormat.usd(totals.cost, decimals: 6))
            metricCard("总请求数", value: empty ? "—" : "\(totals.requests)", detail: "成功率 " + UsageFormat.rate(totals.successRate), tint: Palette.blue)
            metricCard("真实消耗 Tokens", value: empty ? "—" : UsageFormat.tokens(totals.realTokens), detail: "输入+输出+缓存", tint: Palette.accent)
            metricCard("缓存命中率", value: empty ? "—" : UsageFormat.rate(totals.hitRate), detail: "缓存读取 / 全部输入", tint: Palette.lilac)
        }
    }

    private var moreMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                    Text("更多指标").font(.system(size: 11, weight: .medium))
                }.foregroundStyle(Palette.dim).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showMore {
                HStack(spacing: 0) {
                    moreItem("新增输入", totals.freshInput)
                    moreItem("输出", totals.output)
                    moreItem("缓存创建", totals.cacheWrite)
                    moreItem("缓存命中", totals.cacheRead)
                }
            }
        }
    }
    private func moreItem(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.dim)
            Text(totals.requests == 0 ? "—" : UsageFormat.tokens(value)).font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(Palette.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).glassCard(radius: 12).padding(.trailing, 6)
    }

    private func filterMenu(_ title: String, selection: Binding<String>, all: String, values: [String], label: @escaping (String) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
            menuPicker(title, selection: selection, options: [""] + values) { $0.isEmpty ? all : label($0) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 额度趋势

    private var quotaContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = recordingError ?? data.historyError { notice(error, warning: true) }
            if data.history.isEmpty {
                emptyState(icon: "chart.xyaxis.line", title: "额度历史正在积累",
                           detail: "额度历史从本次更新开始记录。账号查询成功后会出现第一个数据点；至少两个数据点才能观察趋势。",
                           loading: data.loading)
            } else {
                HStack(spacing: 10) {
                    menuPicker("账号", selection: $quotaProvider, options: quotaProviders) { $0 }
                    menuPicker("周期", selection: $windowID, options: quotaWindows.map(\.0)) { id in
                        quotaWindows.first(where: { $0.0 == id })?.1 ?? id
                    }
                }
                if let latest = history.last {
                    HStack(spacing: 10) {
                        metricCard("当前余额", value: latest.balance.map(money) ?? "—", detail: quotaProvider, tint: Palette.mint)
                        metricCard("最近剩余额度", value: latest.windows.first(where: { $0.id == windowID }).map { "\(Int($0.percent.rounded()))%" } ?? "—", detail: "最近一次成功查询", tint: Palette.accent)
                    }
                    quotaChart
                    if history.contains(where: { $0.balance != nil }) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("余额趋势 · USD").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                            Chart {
                                ForEach(segmentedHistory, id: \.point.id) { sample in
                                    let point = sample.point
                                    if let balance = point.balance {
                                        LineMark(x: .value("时间", point.date), y: .value("余额", balance), series: .value("连续采样", sample.segment))
                                            .foregroundStyle(Palette.mint)
                                        PointMark(x: .value("时间", point.date), y: .value("余额", balance))
                                            .foregroundStyle(Palette.mint).symbolSize(14)
                                    }
                                }
                            }.frame(height: 160)
                            Text("每个点是一次成功查询的余额，不把余额下降推算为账单。")
                                .font(.system(size: 11)).foregroundStyle(Palette.dim)
                        }.padding(16).glassCard()
                    }
                    Text("最近采样 · " + latest.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(Palette.dim)
                } else { notice("所选时间范围没有额度快照。", warning: false) }
            }
            Text("来源：Sea Coffee 的成功额度查询，每 15 分钟保留最新快照，保留约 30 天。充值、重置和账号切换均可能使曲线上升；曲线表示额度变化，不换算成消费账单。")
                .font(.system(size: 10)).foregroundStyle(Palette.dim)
        }
    }

    // Never interpolate across long offline gaps or a changed quota window.
    private var segmentedHistory: [(point: QuotaHistoryPoint, segment: Int)] {
        var segment = 0
        var previous: QuotaHistoryPoint?
        return history.map { point in
            if let previous {
                let old = previous.windows.first { $0.id == windowID }
                let new = point.windows.first { $0.id == windowID }
                if point.date.timeIntervalSince(previous.date) > 1800
                    || old?.resetsAt != new?.resetsAt || old?.limit != new?.limit
                    || (previous.balance == nil) != (point.balance == nil) { segment += 1 }
            }
            previous = point
            return (point, segment)
        }
    }

    private var quotaChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("剩余额度趋势").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
            Chart {
                ForEach(segmentedHistory, id: \.point.id) { sample in
                    let point = sample.point
                    if let window = point.windows.first(where: { $0.id == windowID }) {
                        PointMark(x: .value("时间", point.date), y: .value("剩余 %", window.percent)).foregroundStyle(Palette.accent).symbolSize(14)
                        LineMark(x: .value("时间", point.date), y: .value("剩余 %", window.percent),
                                 series: .value("连续采样", sample.segment))
                            .foregroundStyle(Palette.accent)
                    }
                }
            }.chartYScale(domain: 0...100).frame(height: 180)
            if history.count < 2 { Text("已记录首个快照，积累更多数据后显示趋势。").font(.system(size: 11)).foregroundStyle(Palette.dim) }
        }.padding(16).glassCard()
    }

    private func metricCard(_ title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            Text(value).font(.system(size: 26, weight: .medium)).monospacedDigit().foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).glassCard()
    }
    private func notice(_ text: String, warning: Bool) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.circle" : "chart.xyaxis.line")
            .font(.system(size: 11)).foregroundStyle(warning ? Palette.warning : Palette.dim)
            .fixedSize(horizontal: false, vertical: true).padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius: 12)
    }
    private func emptyState(icon: String?, title: String, detail: String, loading: Bool) -> some View {
        VStack(spacing: 8) {
            if loading {
                CometSpinner(size: 22, tint: Palette.accent)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Palette.dim)
            }
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118)
        .padding(16)
        .glassCard(radius: 12)
    }
    private func money(_ n: Double) -> String { n.formatted(.currency(code: "USD").precision(.fractionLength(2...4))) }
}
private func menuPicker<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) -> some View {
    Menu {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            Button {
                selection.wrappedValue = option
            } label: {
                HStack {
                    Text(label(option))
                    if option == selection.wrappedValue { Image(systemName: "checkmark") }
                }
            }
        }
    } label: {
        Text(label(selection.wrappedValue)).lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(Palette.text)
    .tint(Palette.text)
    .padding(.leading, 10).padding(.trailing, 28)
    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.65))
    .overlay(alignment: .trailing) {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Palette.dim).padding(.trailing, 10).allowsHitTesting(false).accessibilityHidden(true)
    }
    .accessibilityLabel(title)
}

/// Paging, the status filter and the detail popover redraw only the tables.
private struct UsageTablesCard: View {
    let prepared: UsagePrepared
    let resetKey: [String]
    @State private var table: UsageTable = .logs
    @State private var statusFilter = 0
    @State private var page = 0
    @State private var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSegmented(options: UsageTable.allCases, selection: $table) { $0.rawValue }.frame(maxWidth: 300)
            switch table {
            case .logs: logTable
            case .providers: groupTable(prepared.report.providers, providers: true)
            case .models: groupTable(prepared.report.models, providers: false)
            }
        }.padding(18).glassCard()
        .onChange(of: resetKey) { _, _ in page = 0; detail = nil }
        .onChange(of: table) { _, _ in page = 0; detail = nil }
        .onChange(of: statusFilter) { _, _ in page = 0 }
    }

    private func pager(count: Int) -> some View {
        let pages = max(1, (count + tablePageSize - 1) / tablePageSize)
        return HStack(spacing: 10) {
            Text("共 \(count) 条").font(.system(size: 11)).foregroundStyle(Palette.dim).monospacedDigit()
            Spacer()
            Button("上一页") { page = max(0, page - 1) }.buttonStyle(GlassButtonStyle(compact: true)).disabled(page <= 0)
            Text("第 \(min(page, pages - 1) + 1) / \(pages) 页").font(.system(size: 11)).foregroundStyle(Palette.dim).monospacedDigit()
            Button("下一页") { page = min(pages - 1, page + 1) }.buttonStyle(GlassButtonStyle(compact: true)).disabled(page >= pages - 1)
        }
    }
    private func pageSlice<T>(_ items: [T]) -> ArraySlice<T> {
        let pages = max(1, (items.count + tablePageSize - 1) / tablePageSize)
        let start = min(page, pages - 1) * tablePageSize
        return items[start..<min(items.count, start + tablePageSize)]
    }

    // Two-line cells (time over app, model over provider) keep all nine CC Switch columns inside
    // the 640 pt content width, so cost and speed never scroll off.
    private enum Col { static let time: CGFloat = 92, model: CGFloat = 158, number: CGFloat = 56, cost: CGFloat = 70, speed: CGFloat = 70 }

    private var logTable: some View {
        let logs = prepared.logs(status: statusFilter == 0 ? nil : statusFilter)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("状态码").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                menuPicker("状态码", selection: $statusFilter, options: [0] + UsagePrepared.statuses) { $0 == 0 ? "全部" : "\($0)" }
                    .frame(width: 100)
                Spacer()
            }
            if logs.isEmpty {
                Text(statusFilter == 0 ? "该范围内没有明细请求（更早的数据已按天合并，仅计入统计）。" : "没有状态码为 \(statusFilter) 的请求。")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    logRow(header: true, nil)
                    ForEach(pageSlice(logs)) { log in
                        GlassDivider()
                        logRow(header: false, log)
                    }
                }
                pager(count: logs.count)
            }
        }
    }

    private func cell(_ text: String, _ width: CGFloat, header: Bool = false, trailing: Bool = false, dim: Bool = false) -> some View {
        Text(text).font(.system(size: header ? 10.5 : 11.5, weight: header ? .medium : .regular))
            .foregroundStyle(header || dim ? Palette.dim : Palette.text).monospacedDigit().lineLimit(1)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
    }

    @ViewBuilder private func logRow(header: Bool, _ log: UsageLog?) -> some View {
        if let log {
            let today = Calendar.current.isDateInToday(log.date)
            let speed = log.speed.map { UsageFormat.tokensPerSecond($0) }
                ?? log.estimatedSpeed.map { UsageFormat.tokensPerSecond($0, estimated: true) } ?? "—"
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        cell((today ? timeToday : timeOther).string(from: log.date), log.succeeded ? Col.time : Col.time - 34)
                        if !log.succeeded {
                            Text("\(log.status)").font(.system(size: 9.5, weight: .medium)).monospacedDigit().foregroundStyle(Palette.danger)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Palette.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    cell(friendlyApp(log.app), Col.time, dim: true).font(.system(size: 10))
                }.frame(width: Col.time, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    cell(log.model, Col.model)
                    cell(log.provider, Col.model, dim: true).font(.system(size: 10))
                }.frame(width: Col.model, alignment: .leading)
                Spacer(minLength: 0)
                cell(UsageFormat.tokens(log.displayInput), Col.number, trailing: true)
                cell(UsageFormat.tokens(log.output), Col.number, trailing: true)
                cell(log.cacheRead > 0 ? UsageFormat.tokens(log.cacheRead) : "—", Col.number, trailing: true)
                cell(log.costState == .unpriced ? "未定价" : UsageFormat.usd(log.cost, decimals: 4), Col.cost, trailing: true,
                     dim: log.costState == .unpriced)
                    .help(log.costState == .estimated ? "按价格表估算" : "")
                cell(speed, Col.speed, trailing: true)
            }
            .padding(.vertical, 8).contentShape(Rectangle())
            .onTapGesture { detail = log.id }
            .help(log.model)
            .popover(isPresented: Binding(get: { detail == log.id }, set: { if !$0 && detail == log.id { detail = nil } }), arrowEdge: .bottom) {
                logDetail(log)
            }
        } else {
            HStack(spacing: 8) {
                cell("时间 / 应用", Col.time, header: true)
                cell("模型 / 供应商", Col.model, header: true)
                Spacer(minLength: 0)
                cell("新增输入", Col.number, header: true, trailing: true); cell("输出", Col.number, header: true, trailing: true)
                cell("缓存读取", Col.number, header: true, trailing: true); cell("成本", Col.cost, header: true, trailing: true)
                cell("速度", Col.speed, header: true, trailing: true)
            }.padding(.bottom, 8)
        }
    }

    private func logDetail(_ log: UsageLog) -> some View {
        func ms(_ value: Double) -> String { String(format: "%.1f s", value / 1000) }
        var basic: [(String, String)] = [("时间", timeFull.string(from: log.date)), ("应用", friendlyApp(log.app)),
                                         ("供应商", log.provider), ("模型", log.model)]
        if let request = log.requestModel, !request.isEmpty, request != log.model { basic.append(("请求模型", request)) }
        if let pricing = log.pricingModel, !pricing.isEmpty, pricing != log.model { basic.append(("计价模型", pricing)) }
        basic.append(("来源", log.isProxy ? "proxy (\(log.status))" : "会话日志"))
        let tokens: [(String, String)] = [("新增输入", UsageFormat.tokens(log.displayInput) + (log.rawInput != log.displayInput ? "（原始 \(UsageFormat.tokens(log.rawInput))）" : "")),
                                          ("输出", UsageFormat.tokens(log.output)), ("缓存读取", UsageFormat.tokens(log.cacheRead)),
                                          ("缓存写入", UsageFormat.tokens(log.cacheWrite))]
        var cost: [(String, String)] = []
        if let parts = log.costParts {
            cost = [("输入", usd(parts.input)), ("输出", usd(parts.output)), ("缓存读取", usd(parts.cacheRead)), ("缓存写入", usd(parts.cacheWrite))]
        }
        if log.multiplier != 1 { cost.append(("倍率", "\(log.multiplier)×")) }
        cost.append(("总计", log.costState == .unpriced ? "未定价" : UsageFormat.usd(log.cost, decimals: 4)))
        var perf: [(String, String)] = [("速度", log.speed.map { UsageFormat.tokensPerSecond($0) }
                                         ?? log.estimatedSpeed.map { UsageFormat.tokensPerSecond($0, estimated: true) } ?? "—")]
        perf.append(("首字", log.firstTokenMs.map { ms($0) } ?? "—"))
        perf.append(("耗时", log.latencyMs > 0 ? ms(log.latencyMs) : "—"))
        return VStack(alignment: .leading, spacing: 14) {
            detailSection("基本", basic); detailSection("Tokens", tokens)
            detailSection("成本", cost); detailSection("性能", perf)
        }.padding(18).frame(width: 330)
    }
    private func detailSection(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.dim)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.system(size: 11.5)).foregroundStyle(Palette.dim)
                    Spacer(minLength: 12)
                    Text(row.1).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.text)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }
    }

    private func groupTable(_ groups: [UsageGroup], providers: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = pageSlice(groups)
            groupRow(nil, providers: providers, header: true).padding(.bottom, 8)
            ForEach(rows) { group in
                GlassDivider()
                groupRow(group, providers: providers, header: false)
            }
            pager(count: groups.count).padding(.top, 12)
        }
    }
    private func groupRow(_ group: UsageGroup?, providers: Bool, header: Bool) -> some View {
        let t = group?.totals
        func num(_ text: String, _ width: CGFloat) -> some View {
            Text(text).font(.system(size: header ? 10.5 : 11.5, weight: header ? .medium : .regular))
                .foregroundStyle(header ? Palette.dim : Palette.text).monospacedDigit().lineLimit(1)
                .frame(width: width, alignment: .trailing)
        }
        return HStack(spacing: 8) {
            if header {
                Text(providers ? "供应商" : "模型").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let group {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.system(size: 11.5)).foregroundStyle(Palette.text).lineLimit(1)
                    if providers, let app = group.app { Text(friendlyApp(app)).font(.system(size: 10)).foregroundStyle(Palette.dim) }
                }.frame(maxWidth: .infinity, alignment: .leading).help(group.name)
            }
            num(header ? "请求数" : "\(t!.requests)", 58)
            num(header ? "Tokens" : UsageFormat.tokens(t!.realTokens), 62)
            num(header ? "成本" : UsageFormat.usd(t!.cost, decimals: 2), 62)
            num(header ? "成功率" : UsageFormat.rate(t!.successRate), 54)
            num(header ? "速度" : (t!.speed.map { UsageFormat.tokensPerSecond($0.value, estimated: $0.estimated) } ?? "—"), 84)
            if !providers { num(header ? "平均成本" : (t!.averageCost.map { UsageFormat.usd($0, decimals: 4) } ?? "—"), 66) }
        }.padding(.vertical, header ? 0 : 7)
    }

}

// MARK: 趋势

/// Hover lives here, outside the chart: moving the pointer redraws the rule and the readout,
/// never the bars.
private final class TrendHover: ObservableObject {
    @Published var bucket: UsageBucket?
    @Published var x: CGFloat?
}

private struct UsageTrendCard: View {
    let report: UsageStatsReport
    let rangeLabel: String
    @State private var metric: UsageMetric = .tokens
    @StateObject private var hover = TrendHover()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("使用趋势 · \(rangeLabel)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                GlassSegmented(options: UsageMetric.allCases, selection: $metric) { $0.rawValue }.frame(width: 210)
            }
            TrendChart(buckets: report.buckets, hourly: report.hourly, metric: metric, hover: hover).frame(height: 190)
            TrendReadout(hover: hover, hourly: report.hourly)
        }
        .padding(18).glassCard()
        .onChange(of: report.start) { _, _ in hover.bucket = nil; hover.x = nil }
    }
}

private struct TrendChart: View {
    let buckets: [UsageBucket]
    let hourly: Bool
    let metric: UsageMetric
    /// Written on hover but not observed, so the marks are built once per data or metric change.
    let hover: TrendHover

    var body: some View {
        let unit: Calendar.Component = hourly ? .hour : .day
        Chart {
            ForEach(buckets) { bucket in
                let x = PlottableValue.value("时间", bucket.start, unit: unit)
                switch metric {
                case .tokens:
                    BarMark(x: x, y: .value("Tokens", bucket.totals.freshInput)).foregroundStyle(by: .value("类别", "新增输入"))
                    BarMark(x: x, y: .value("Tokens", bucket.totals.output)).foregroundStyle(by: .value("类别", "输出"))
                    BarMark(x: x, y: .value("Tokens", bucket.totals.cacheWrite)).foregroundStyle(by: .value("类别", "缓存创建"))
                    BarMark(x: x, y: .value("Tokens", bucket.totals.cacheRead)).foregroundStyle(by: .value("类别", "缓存命中"))
                case .requests:
                    BarMark(x: x, y: .value("请求", bucket.totals.requests)).foregroundStyle(Palette.blue).cornerRadius(2)
                case .cost:
                    BarMark(x: x, y: .value("成本", bucket.totals.cost)).foregroundStyle(Palette.mint).cornerRadius(2)
                }
            }
        }
        .chartForegroundStyleScale(["新增输入": Palette.blue, "输出": Palette.mint, "缓存创建": Palette.warning, "缓存命中": Palette.lilac])
        .chartLegend(metric == .tokens ? .visible : .hidden)
        .chartXAxis {
            if hourly {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                }
            } else {
                AxisMarks { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .cost ? UsageFormat.usd(number, decimals: number < 1 ? 2 : 0) : UsageFormat.tokens(number))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase, plot.contains(point),
                                  let date: Date = proxy.value(atX: point.x - plot.minX),
                                  let nearest = nearest(to: date, unit: unit) else {
                                hover.bucket = nil; hover.x = nil; return
                            }
                            guard nearest.id != hover.bucket?.id else { return }
                            let end = Calendar.current.date(byAdding: unit, value: 1, to: nearest.start) ?? nearest.start
                            if let start = proxy.position(forX: nearest.start), let finish = proxy.position(forX: end) {
                                hover.x = plot.minX + (start + finish) / 2
                            }
                            hover.bucket = nearest
                        }
                    TrendRule(hover: hover, plot: plot)
                }
            }
        }
    }

    /// The bucket whose interval contains the pointer (bars span their whole hour or day).
    private func nearest(to date: Date, unit: Calendar.Component) -> UsageBucket? {
        let index = buckets.lastIndex { $0.start <= date } ?? 0
        return buckets.indices.contains(index) ? buckets[index] : nil
    }
}

private struct TrendRule: View {
    @ObservedObject var hover: TrendHover
    let plot: CGRect
    var body: some View {
        if let x = hover.x {
            Rectangle().fill(Palette.dim.opacity(0.5)).frame(width: 1, height: plot.height)
                .offset(x: x - 0.5, y: plot.minY).allowsHitTesting(false)
        }
    }
}

private struct TrendReadout: View {
    @ObservedObject var hover: TrendHover
    let hourly: Bool
    var body: some View {
        Group {
            if let bucket = hover.bucket {
                Text((hourly ? timeFull.string(from: bucket.start).dropLast(3) : Substring(dayFormat.string(from: bucket.start)))
                     + " · \(bucket.totals.requests) 次 · \(UsageFormat.tokens(bucket.totals.realTokens)) Tokens · \(UsageFormat.usd(bucket.totals.cost, decimals: 4))")
            } else {
                Text("悬停图表查看明细 · " + (hourly ? "按小时统计" : "按天统计"))
            }
        }.font(.system(size: 11)).foregroundStyle(Palette.dim).monospacedDigit()
    }
}

// MARK: 热力图

private struct UsageHeatmapCard: View {
    let heatmap: UsageHeatmap?
    let loading: Bool
    @Binding var metric: UsageHeatmapMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("用量热力图").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                GlassSegmented(options: UsageHeatmapMetric.allCases, selection: $metric) { $0.rawValue }.frame(width: 210)
            }
            if let weeks = heatmap?.weeks, !weeks.isEmpty {
                HeatmapGrid(weeks: weeks, metric: metric)
            } else {
                Text(loading ? "正在读取…" : "暂无数据").font(.system(size: 11)).foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
            HStack(spacing: 4) {
                Text("少").font(.system(size: 10)).foregroundStyle(Palette.dim)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5).fill(HeatmapGrid.color(level: level)).frame(width: 10, height: 10)
                }
                Text("多").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
        }.padding(18).glassCard()
    }
}

/// One Canvas instead of 371 cells with their own tooltips; hover redraws only this view.
private struct HeatmapGrid: View {
    let weeks: [[UsageHeatmap.Day]]
    let metric: UsageHeatmapMetric
    @State private var width: CGFloat = 0
    @State private var hovered: UsageHeatmap.Day?
    private static let gap: CGFloat = 2, labelHeight: CGFloat = 14

    static func color(level: Int, future: Bool = false) -> Color {
        if future { return Palette.subtle.opacity(0.35) }
        switch level {
        case 0: return Palette.subtle
        case 1: return Palette.mint.opacity(0.3)
        case 2: return Palette.mint.opacity(0.5)
        case 3: return Palette.mint.opacity(0.75)
        default: return Palette.mint
        }
    }

    var body: some View {
        let count = CGFloat(weeks.count)
        let available = width > 0 ? width : 600
        let cell = max(8, min(11, ((available - (count - 1) * Self.gap) / count).rounded(.down)))
        let step = cell + Self.gap
        let gridWidth = count * step - Self.gap
        let height = Self.labelHeight + 7 * step - Self.gap
        let canvas = Canvas { context, _ in
            let calendar = Calendar.current
            for (column, week) in weeks.enumerated() {
                let x = CGFloat(column) * step
                if let first = week.first(where: { calendar.component(.day, from: $0.date) == 1 }) {
                    context.draw(Text(monthFormat.string(from: first.date)).font(.system(size: 9)).foregroundColor(Palette.dim),
                                 at: CGPoint(x: x, y: 0), anchor: .topLeading)
                }
                for (row, day) in week.enumerated() {
                    let rect = CGRect(x: x, y: Self.labelHeight + CGFloat(row) * step, width: cell, height: cell)
                    let path = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
                    context.fill(path, with: .color(Self.color(level: day.level, future: day.future)))
                    if day.id == hovered?.id { context.stroke(path, with: .color(Palette.text.opacity(0.6)), lineWidth: 1) }
                }
            }
        }
        .frame(width: gridWidth, height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { hovered = nil; return }
            let column = Int(point.x / step), row = Int((point.y - Self.labelHeight) / step)
            let day = weeks.indices.contains(column) && point.y >= Self.labelHeight && (0..<7).contains(row) ? weeks[column][row] : nil
            if day?.id != hovered?.id { hovered = day }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if gridWidth > available + 1 {
                    ScrollView(.horizontal, showsIndicators: false) { canvas }.defaultScrollAnchor(.trailing)
                } else {
                    canvas
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in if abs(new - width) > 0.5 { width = new } }
            })
            Text(hovered.map { dayFormat.string(from: $0.date) + ($0.future ? "" : "  " + value($0.value)) } ?? "悬停查看每天的用量")
                .font(.system(size: 10)).foregroundStyle(Palette.dim).monospacedDigit()
        }
    }

    private func value(_ amount: Double) -> String {
        switch metric {
        case .tokens: return UsageFormat.tokens(amount) + " Tokens"
        case .requests: return "\(Int(amount)) 次请求"
        case .cost: return UsageFormat.usd(amount, decimals: 4)
        }
    }
}
