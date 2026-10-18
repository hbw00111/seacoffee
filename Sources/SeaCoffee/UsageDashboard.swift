import SwiftUI
import Charts
import IslandCore

@MainActor
final class UsageDashboardModel: ObservableObject {
    private(set) var records: [UsageRecord] = []
    private(set) var apps: [String] = [], providers: [String] = [], models: [String] = []
    @Published var revision = 0
    @Published var report = UsageReport()
    @Published var preparing = false
    private var reportKey: [String] = []
    func prepare(key: [String], since: Date, hourly: Bool, app: String?, provider: String?, model: String?) async {
        guard reportKey != key else { return }
        preparing = true
        let records = records
        let result = await Task.detached(priority: .userInitiated) {
            UsageReport(records: records, since: since, hourly: hourly, app: app, provider: provider, model: model)
        }.value
        guard !Task.isCancelled else { return }
        report = result; reportKey = key; preparing = false
    }
    @Published var history: [QuotaHistoryPoint] = []
    @Published var loading = false
    @Published var error: String?
    @Published var historyError: String?
    @Published var truncated = false
    @Published var updated: Date?
    func reload(force: Bool = true) async {
        if !force, let updated, Date().timeIntervalSince(updated) < 60 { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let since = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
        let result = await Task.detached(priority: .utility) {
            Swift.Result {
                let data = try UsageAnalyticsReader.read(since: since)
                return (data, Array(Set(data.records.map(\.app))).sorted(),
                        Array(Set(data.records.map(\.provider))).sorted(), Array(Set(data.records.map(\.model))).sorted())
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (data, apps, providers, models)):
            records = data.records; self.apps = apps; self.providers = providers; self.models = models
            truncated = data.truncated; error = nil; updated = Date(); revision += 1
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
    case calls = "调用统计", quota = "额度趋势"
    var id: String { rawValue }
}
private enum UsageMetric: String, CaseIterable, Identifiable {
    case tokens = "Token", calls = "调用", cost = "费用"
    var id: String { rawValue }
}
struct UsageDashboard: View {
    @ObservedObject var data: UsageDashboardModel
    @Environment(\.glassSnapshot) private var preview
    @State private var tab: UsageTab = .calls
    @State private var period: UsagePeriod = .week
    @State private var metric: UsageMetric = .tokens
    @State private var app = "全部工具"
    @State private var provider = "全部服务商"
    @State private var model = "全部模型"
    @State private var quotaProvider = "Codex API"
    @State private var windowID = "wallet"
    @State private var selectedDate: Date?
    @State private var showMore = false
    var recordingError: String?

    private var rows: [UsageRecord] { data.report.rows }
    private var totals: UsageTotals { data.report.totals }
    private var buckets: [UsageReport.Bucket] { data.report.buckets }
    private var reportKey: [String] { [String(data.revision), period.rawValue, app, provider, model] }
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
                Button { Task { await data.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle(circle: true, loading: data.loading))
                    .disabled(data.loading).help("刷新本机用量记录").accessibilityLabel("刷新用量")
            }
            HStack {
                Text("时间范围").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
                Spacer()
                GlassSegmented(options: UsagePeriod.allCases, selection: $period) { $0.rawValue }
                    .frame(maxWidth: 240)
            }
            if tab == .calls { callContent } else { quotaContent }
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
            await data.prepare(key: reportKey, since: period.start, hourly: period == .today,
                               app: app == "全部工具" ? nil : app,
                               provider: provider == "全部服务商" ? nil : provider,
                               model: model == "全部模型" ? nil : model)
        }
        .onChange(of: quotaProvider) { _, _ in windowID = quotaWindows.first?.0 ?? "wallet" }
        .onChange(of: period) { _, _ in
            selectedDate = nil; showMore = false
            if !quotaWindows.contains(where: { $0.0 == windowID }) { windowID = quotaWindows.first?.0 ?? "wallet" }
        }
        .onChange(of: data.history.count) { _, _ in
            if !quotaProviders.contains(quotaProvider) { quotaProvider = quotaProviders.first ?? "Codex API" }
            if !quotaWindows.contains(where: { $0.0 == windowID }) { windowID = quotaWindows.first?.0 ?? "wallet" }
        }
    }

    private var callContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                filter("工具", selection: $app, all: "全部工具", values: data.apps)
                filter("服务商", selection: $provider, all: "全部服务商", values: data.providers)
                filter("模型", selection: $model, all: "全部模型", values: data.models)
            }
            if data.preparing {
                HStack(spacing: 7) {
                    CometSpinner(size: 12, tint: Palette.accent)
                    Text("正在更新统计…").font(.system(size: 10)).foregroundStyle(Palette.dim)
                }
            }
            if let error = data.error { notice(error, warning: true) }
            if data.truncated { notice("记录超过 20 万条，当前仅展示最近部分，统计不完整。", warning: true) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metricCard("总 Token", value: rows.isEmpty ? "—" : compact(totals.tokens), detail: "含输入、输出和缓存", tint: Palette.accent)
                metricCard("记录费用", value: totals.priced == 0 ? "—" : money(totals.cost), detail: "CC Switch 记录中的估算", tint: Palette.mint)
                metricCard("调用记录", value: rows.isEmpty ? "—" : "\(totals.requests)", detail: "成功率 " + percent(totals.successRate), tint: Palette.blue)
                metricCard("缓存命中", value: percent(totals.hitRate), detail: "缓存读取 / 全部输入", tint: Palette.lilac)
            }
            if rows.isEmpty {
                emptyState(icon: data.loading ? nil : "chart.xyaxis.line",
                           title: data.loading ? "正在读取本机用量" : "暂无调用记录",
                           detail: data.loading ? "" : "该筛选范围没有调用记录。可扩大时间范围或切换工具。",
                           loading: data.loading)
            } else {
                trend
                modelBreakdown
                recentCalls
            }
            Text("来源：本机 CC Switch 已保留的明细记录。未被它记录的调用和已归档明细不在统计内；费用受其定价配置影响，不等同于账单。")
                .font(.system(size: 10)).foregroundStyle(Palette.dim)
            if totals.priced < totals.requests && !rows.isEmpty {
                Text("\(totals.requests - totals.priced) 条记录未提供费用，仅合计已有金额。")
                    .font(.system(size: 10)).foregroundStyle(Palette.warning)
            }
            if let date = data.updated {
                Text("读取于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("用量趋势").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                menuPicker("统计指标", selection: $metric, options: UsageMetric.allCases) { $0.rawValue }
                    .frame(width: 132)
            }
            Chart {
                ForEach(buckets) { bucket in
                    if metric == .tokens {
                        BarMark(x: .value("时间", bucket.date, unit: period == .today ? .hour : .day), y: .value("Token", bucket.totals.input)).foregroundStyle(by: .value("类别", "输入"))
                        BarMark(x: .value("时间", bucket.date, unit: period == .today ? .hour : .day), y: .value("Token", bucket.totals.output)).foregroundStyle(by: .value("类别", "输出"))
                        BarMark(x: .value("时间", bucket.date, unit: period == .today ? .hour : .day), y: .value("Token", bucket.totals.cacheRead)).foregroundStyle(by: .value("类别", "缓存读取"))
                        BarMark(x: .value("时间", bucket.date, unit: period == .today ? .hour : .day), y: .value("Token", bucket.totals.cacheWrite)).foregroundStyle(by: .value("类别", "缓存写入"))
                    } else {
                        BarMark(x: .value("时间", bucket.date, unit: period == .today ? .hour : .day), y: .value(metric.rawValue, metric == .calls ? Double(bucket.totals.requests) : bucket.totals.cost))
                            .foregroundStyle(Palette.accent).cornerRadius(3)
                    }
                }
                if let selectedDate {
                    RuleMark(x: .value("选择时间", selectedDate)).foregroundStyle(Palette.dim)
                }
            }
            .chartForegroundStyleScale(["输入": Palette.blue, "输出": Palette.mint, "缓存读取": Palette.lilac, "缓存写入": Palette.warning])
            .chartXSelection(value: $selectedDate)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
            if let selectedDate, let bucket = buckets.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                Text(bucket.date.formatted(date: .abbreviated, time: period == .today ? .shortened : .omitted)
                     + " · \(bucket.totals.requests) 次 · \(compact(bucket.totals.tokens)) Token · \(money(bucket.totals.cost))")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).monospacedDigit()
            } else {
                Text("点选图表查看分时数据 · " + (period == .today ? "按小时统计" : "按天统计"))
                    .font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
        }.padding(16).glassCard()
    }

    private var modelBreakdown: some View {
        let groups = data.report.models
        return VStack(alignment: .leading, spacing: 12) {
            Text("模型分布").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
            ForEach(Array(groups.prefix(8)), id: \.0) { name, total in
                VStack(spacing: 5) {
                    HStack {
                        Text(name).lineLimit(1).help(name)
                        Spacer()
                        Text(compact(total.tokens)).monospacedDigit()
                        Text(total.priced > 0 ? money(total.cost) : "—").foregroundStyle(Palette.dim).frame(width: 80, alignment: .trailing)
                    }.font(.system(size: 12)).foregroundStyle(Palette.text)
                    GeometryReader { geometry in
                        Capsule().fill(Palette.accent.opacity(0.65)).frame(width: geometry.size.width * (totals.tokens > 0 ? total.tokens / totals.tokens : 0))
                    }.frame(height: 3).background(Capsule().fill(Palette.subtle))
                }
            }
            if groups.count > 8 { Text("展示用量最高的 8 个模型，可通过模型筛选查看其余记录。").font(.system(size: 10.5)).foregroundStyle(Palette.dim) }
        }.padding(16).glassCard()
    }

    private var recentCalls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近调用").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Text("Token / USD").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
            ForEach(Array(rows.prefix(showMore ? 50 : 8).enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 9) {
                    if index > 0 { Divider().overlay(Palette.border) }
                    HStack(spacing: 9) {
                    Image(systemName: row.succeeded == true ? "checkmark.circle" : row.succeeded == false ? "exclamationmark.circle" : "minus.circle")
                        .foregroundStyle(row.succeeded == true ? Palette.mint : row.succeeded == false ? Palette.warning : Palette.dim)
                        .help(row.status.map { "HTTP \($0)" } ?? "未提供状态")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.model).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                        Text(row.app + " · " + row.provider + " · " + row.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10.5)).foregroundStyle(Palette.dim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(compact(row.tokens)).font(.system(size: 12)).foregroundStyle(Palette.text)
                        Text(row.cost.map(money) ?? "—").font(.system(size: 10.5)).foregroundStyle(Palette.dim)
                    }.monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
            }
            if rows.count > 8 {
                Button(showMore ? "收起明细" : "展开最近 50 条") { showMore.toggle() }.buttonStyle(GlassButtonStyle(compact: true))
            }
        }.padding(16).glassCard()
    }

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

    private func filter(_ title: String, selection: Binding<String>, all: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.dim)
            menuPicker(title, selection: selection, options: [all] + values) { $0 }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    private func metricCard(_ title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            Text(value).font(.system(size: 26, weight: .medium)).monospacedDigit().foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).glassCard(radius: 12)
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
    private func compact(_ n: Double) -> String { n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    private func money(_ n: Double) -> String { n.formatted(.currency(code: "USD").precision(.fractionLength(2...4))) }
    private func percent(_ n: Double?) -> String { n.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—" }
}
