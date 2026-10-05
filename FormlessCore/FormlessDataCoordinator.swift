import Foundation

// MARK: - 一份設計用到哪些資料
//
// 相依分析：找出文字、條件、進度、圖表、重複排列、屬性、我的資料裡所有的綁定 → 用到的來源 →
// 同一個快取鍵只抓一次、依各來源的有效期限決定要不要重抓 → 以同一個時間點畫出解析後的設計。

extension FormlessOperand {
    var bindings: [FormlessBinding] {
        guard case .binding(let binding) = self else { return [] }
        return binding.allBindings
    }
}

extension FormlessBinding {
    /// 自己與格式運算裡引用的其他資料。
    var allBindings: [FormlessBinding] {
        [self] + (format?.operations ?? []).flatMap { $0.operand.bindings }
    }
}

extension FormlessCondition {
    var bindings: [FormlessBinding] {
        subject.allBindings + (operand?.bindings ?? []) + (upper?.bindings ?? [])
    }
}

extension FormlessLayer {
    /// 這個圖層用到的所有資料。
    var dataBindings: [FormlessBinding] {
        var result: [FormlessBinding] = []
        for segment in segments ?? [] { if let binding = segment.binding { result += binding.allBindings } }
        for condition in visibility?.conditions ?? [] { result += condition.bindings }
        for rule in colorRules ?? [] {
            if let subject = rule.subject { result += subject.allBindings }
            result += rule.threshold?.bindings ?? []
        }
        if let progress {
            result += progress.value.bindings + progress.goal.bindings + (progress.minimum?.bindings ?? [])
        }
        if let series = chart?.series { result += series.allBindings }
        if let scale = colorScale { result += scale.subject.allBindings }
        if let heatmap = calendarOptions?.heatmap { result += heatmap.allBindings }
        if let collection = repeatSpec?.collection { result += collection.allBindings }
        for binding in (bindings ?? [:]).values { result += binding.allBindings }
        return result
    }

    /// 用了新資料系統（文字區段、條件、進度、圖表…）。
    var usesDataSystem: Bool { !dataBindings.isEmpty }
}

extension FormlessDocument {
    var dataBindings: [FormlessBinding] {
        layers.flatMap(\.dataBindings) + (variables ?? []).flatMap { $0.binding?.allBindings ?? [] }
    }
}

enum FormlessDataCoordinator {

    /// 綁定指向的來源（我的資料往下追到它取用的來源）。
    static func sources(usedBy document: FormlessDocument) -> [FormlessSource] {
        var seen = Set<String>()
        var result: [FormlessSource] = []
        let own = document.sources ?? []
        for binding in document.dataBindings where !binding.isVariable && !binding.isItem {
            guard seen.insert(binding.source).inserted else { continue }
            if let source = own.first(where: { $0.id == binding.source }) {
                result.append(source)
            } else if FormlessProviders.provider(binding.source) != nil {
                result.append(.appDefault(binding.source))
            }
        }
        return result
    }

    /// 這份設計需要的快照（從快取讀）。
    static func snapshots(for document: FormlessDocument) -> [String: FormlessSnapshot] {
        var result: [String: FormlessSnapshot] = [:]
        for source in sources(usedBy: document) {
            guard let provider = FormlessProviders.provider(source.provider), provider.fetches else { continue }
            let key = provider.cacheKey(for: source)
            if result[key] == nil, let snapshot = FormlessSnapshotStore.load(key) { result[key] = snapshot }
        }
        return result
    }

    /// 抓這些設計用到、而且過期的資料。force 時不看有效期限（點一下重新整理）。
    static func warm(_ documents: [FormlessDocument], force: Bool = false) async {
        var jobs: [String: (any FormlessDataProvider, FormlessSource)] = [:]
        for document in documents {
            for source in sources(usedBy: document) {
                guard let provider = FormlessProviders.provider(source.provider), provider.fetches else { continue }
                let key = provider.cacheKey(for: source)
                guard jobs[key] == nil else { continue }
                if !force, let old = FormlessSnapshotStore.load(key), old.status == .ok || old.status == .empty,
                   Date().timeIntervalSince(old.fetchedAt) < FormlessWebRefresh.lifetime(for: source, provider: provider) { continue }
                jobs[key] = (provider, source)
            }
        }
        guard !jobs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for (key, job) in jobs {
                group.addTask {
                    await FormlessLiveData.bounded(10) {
                        if let snapshot = await job.0.fetch(job.1) { FormlessSnapshotStore.save(snapshot, key: key) }
                    }
                }
            }
        }
    }

    /// from 到 to 之間畫面會變的時間點。
    static func changes(for document: FormlessDocument, live: FormlessLiveData, from: Date, to: Date) -> [Date] {
        var result = Set<Date>()
        for binding in document.dataBindings {
            for date in live.changes(binding, from: from, to: to) where date > from && date < to { result.insert(date) }
        }
        // 「時段」條件的開始與結束（每天固定的時間），相簿輪播換下一張的時刻。
        for layer in document.layers {
            for date in layer.slideshowChanges(from: from, to: to) { result.insert(date) }
            for condition in layer.visibility?.conditions ?? [] {
                for date in FormlessLiveData.timeOfDayChanges(condition, from: from, to: to) { result.insert(date) }
            }
        }
        return result.sorted()
    }

    /// 需要每 5 分鐘一格（時鐘、自訂格式裡有時或分）。系統即時走動的樣式不需要。
    static func needsMinuteRefresh(_ document: FormlessDocument) -> Bool {
        document.dataBindings.contains { binding in
            guard !binding.isVariable, !binding.isItem else { return false }
            let style = binding.format?.dateStyle
            if let style, FormlessLiveDateStyle(rawValue: style) != nil { return false }
            // 只有「現在時間」會每分鐘變；行程開始時間這類固定的時間不用。
            let provider = document.sources?.first { $0.id == binding.source }?.provider ?? binding.source
            if provider == "dateTime", ["now", "minute"].contains(binding.field) { return true }
            return style == FormlessDateStylePreset.relativeStatic
        }
    }
}
