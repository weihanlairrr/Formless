import Foundation

// MARK: - 評估：綁定 → 值 → 文字
//
// `FormlessLiveData` 帶著這份設計的來源與我的資料、抓回來的快照、重複排列的這一筆；App 畫布、首頁縮圖、
// 小工具都用同一份 live 畫，所以三處看到的值一定相同。

extension FormlessLiveData {

    /// 綁定指向的來源實例：這份設計自己的，或 App 預設。
    func source(_ id: String) -> FormlessSource? {
        if let own = sources.first(where: { $0.id == id }) { return own }
        if FormlessProviders.provider(id) != nil { return .appDefault(id) }
        return nil
    }

    func variable(_ id: String) -> FormlessVariable? {
        variables.first { $0.id.uuidString == id }
    }

    /// 我的資料互相引用（自己取用自己、兩份互相取用、運算裡再取用）時最多追幾層；超過就當成沒有值，不會無限遞迴當掉。
    static let maximumDepth = 8

    /// 綁定在 date 那一刻的值（已套用格式裡的運算，還沒轉成文字）。
    func value(_ binding: FormlessBinding, at date: Date) -> FormlessValue {
        value(binding, at: date, depth: 0)
    }

    private func value(_ binding: FormlessBinding, at date: Date, depth: Int) -> FormlessValue {
        guard depth < Self.maximumDepth else { return .empty }
        var value = rawValue(binding, at: date, depth: depth)
        if let operations = binding.format?.operations, !operations.isEmpty {
            value = apply(operations, to: value, at: date, depth: depth + 1)
        }
        if let offset = binding.format?.dayOffset, offset != 0, case .date(let day, let allDay) = value {
            value = .date(Calendar.current.date(byAdding: .day, value: offset, to: day) ?? day, allDay: allDay)
        }
        return value
    }

    func number(_ operand: FormlessOperand?, at date: Date) -> Double? {
        switch operand {
        case .value(let value)?: return value.numberValue
        case .binding(let binding)?: return value(binding, at: date).numberValue
        case nil: return nil
        }
    }

    func value(_ operand: FormlessOperand?, at date: Date) -> FormlessValue {
        switch operand {
        case .value(let value)?: return value
        case .binding(let binding)?: return value(binding, at: date)
        case nil: return .empty
        }
    }

    private func rawValue(_ binding: FormlessBinding, at date: Date, depth: Int) -> FormlessValue {
        guard depth < Self.maximumDepth else { return .empty }   // 我的資料互相引用成環時停下來
        var base: FormlessValue
        switch binding.source {
        case FormlessBindingSource.item:
            guard let item else { return sampleItemValue(binding) }
            base = item[binding.field]
        case FormlessBindingSource.variable:
            guard let variable = variable(binding.field) else { return .empty }
            if let state = variableState[variable.id.uuidString] {
                base = state
            } else if let inner = variable.binding {
                var resolved = rawValue(inner, at: date, depth: depth + 1)
                if let operations = inner.format?.operations, !operations.isEmpty {
                    resolved = apply(operations, to: resolved, at: date, depth: depth + 1)
                }
                base = resolved
            } else {
                base = variable.value
            }
        default:
            guard let source = source(binding.source), let provider = FormlessProviders.provider(source.provider) else {
                return .empty
            }
            if provider.id == FormlessWidgetEnvironmentProvider.providerID {
                // 小工具環境不抓資料，讀畫這個圖層時的顯示環境。
                base = FormlessWidgetEnvironmentProvider.value(binding.field, environment: environment)
            } else if emptyMode && provider.fetches {
                base = .empty
            } else if sampleMode {
                base = provider.field(binding.field, source: source)?.sample ?? .empty
            } else {
                let snapshot = snapshots[provider.cacheKey(for: source)]
                base = provider.value(binding.field, source: source, snapshot: snapshot, at: date)
            }
            if longTextMode { base = base.lengthened }
        }
        return select(base, index: binding.index, itemField: binding.itemField)
    }

    /// 清單取第幾筆、再取那一筆的欄位。
    private func select(_ value: FormlessValue, index: Int?, itemField: String?) -> FormlessValue {
        var result = value
        if let index {
            guard case .list(let items) = result else { return index == 1 ? result : .empty }
            guard index >= 1, index <= items.count else { return .empty }
            result = items[index - 1]
        }
        if let itemField {
            switch result {
            case .record(let record): return record[itemField]
            case .list(let items):
                // 整個清單取某個欄位：變成那個欄位的清單（圖表、合併文字）。
                return .list(items.map { $0.recordValue?[itemField] ?? .empty })
            default: return .empty
            }
        }
        return result
    }

    /// 編輯器裡群組還沒有清單時（例如畫布外），「這一筆」顯示範例。
    private func sampleItemValue(_ binding: FormlessBinding) -> FormlessValue { .empty }

    private func apply(_ operations: [FormlessMathOperation], to value: FormlessValue, at date: Date, depth: Int) -> FormlessValue {
        guard var number = value.numberValue else { return value }
        var unit = value.unit
        for operation in operations {
            let operand: Double?
            switch operation.operand {
            case .value(let value): operand = value.numberValue
            case .binding(let binding): operand = self.value(binding, at: date, depth: depth + 1).numberValue
            }
            switch operation.kind {
            case .add: number += operand ?? 0
            case .subtract: number -= operand ?? 0
            case .multiply: number *= operand ?? 1
            case .divide:
                guard let operand, operand != 0 else { return .empty }
                number /= operand
            case .percentOf:
                guard let operand, operand != 0 else { return .empty }
                number = number / operand * 100
                unit = .percent
            case .clampMax: if let operand { number = min(number, operand) }
            case .clampMin: if let operand { number = max(number, operand) }
            case .round: number = number.rounded()
            case .absolute: number = abs(number)
            }
        }
        return .number(number, unit)
    }

    // MARK: 欄位說明

    /// 綁定指向的欄位說明（決定預設格式、可用的比較）。
    func fieldSpec(_ binding: FormlessBinding) -> FormlessFieldSpec? {
        fieldSpec(binding, depth: 0)
    }

    private func fieldSpec(_ binding: FormlessBinding, depth: Int) -> FormlessFieldSpec? {
        guard depth < Self.maximumDepth else { return nil }
        switch binding.source {
        case FormlessBindingSource.variable:
            guard let variable = variable(binding.field) else { return nil }
            if let inner = variable.binding, let spec = fieldSpec(inner, depth: depth + 1) {
                return FormlessFieldSpec(variable.id.uuidString, variable.name, spec.kind, unit: spec.unit,
                                         decimals: spec.decimals, grouping: spec.grouping, items: spec.itemFields)
            }
            return FormlessFieldSpec(variable.id.uuidString, variable.name, variable.kind, unit: variable.value.unit)
        case FormlessBindingSource.item:
            return nil
        default:
            guard let source = source(binding.source), let provider = FormlessProviders.provider(source.provider),
                  let spec = provider.field(binding.field, source: source, snapshot: snapshots[provider.cacheKey(for: source)])
            else { return nil }
            if binding.index != nil || binding.itemField != nil {
                if let item = spec.itemField(binding.itemField) { return item }
                if binding.itemField == nil, binding.index != nil {
                    return FormlessFieldSpec(spec.id, spec.name, .record, items: spec.itemFields)
                }
            }
            return spec
        }
    }

    /// 綁定資料目前的狀態（編輯器說明、空值）。
    func status(_ binding: FormlessBinding) -> FormlessDataStatus {
        guard !binding.isVariable, !binding.isItem else { return .ok }
        guard let source = source(binding.source), let provider = FormlessProviders.provider(source.provider) else {
            return .notConfigured
        }
        guard provider.fetches else { return .ok }
        guard let snapshot = snapshots[provider.cacheKey(for: source)] else { return provider.availability(for: source) }
        return snapshot.status
    }

    func snapshot(for source: FormlessSource) -> FormlessSnapshot? {
        guard let provider = FormlessProviders.provider(source.provider) else { return nil }
        return snapshots[provider.cacheKey(for: source)]
    }

    // MARK: 文字

    /// 綁定顯示成的文字。
    func text(_ binding: FormlessBinding, at date: Date) -> String {
        FormlessValueFormatter.text(value(binding, at: date), format: binding.format, spec: fieldSpec(binding), at: date)
    }

    /// 文字區段組成的整行文字（系統即時走動的時間在這裡是當下的樣子，給量測與縮小比例用）。
    func text(_ segments: [FormlessTextSegment], at date: Date) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text
            case .data(let binding): return text(binding, at: date)
            }
        }.joined()
    }

    /// 文字區段轉成可以畫的片段：固定字、資料文字、系統即時走動的時間。
    func pieces(_ segments: [FormlessTextSegment], at date: Date) -> [FormlessTextPiece] {
        segments.map { segment in
            switch segment {
            case .text(let text): return .plain(text)
            case .data(let binding): return piece(binding, at: date)
            }
        }
    }

    func piece(_ binding: FormlessBinding, at date: Date) -> FormlessTextPiece {
        let resolved = value(binding, at: date)
        if let style = binding.format?.dateStyle, let live = FormlessLiveDateStyle(rawValue: style),
           let target = resolved.dateValue ?? (resolved.kind == .duration ? date.addingTimeInterval(resolved.numberValue ?? 0) : nil) {
            return .live(target, live)
        }
        return .plain(FormlessValueFormatter.text(resolved, format: binding.format, spec: fieldSpec(binding), at: date))
    }

    // MARK: 條件

    func matches(_ set: FormlessConditionSet?, at date: Date) -> Bool {
        guard let set, !set.conditions.isEmpty else { return true }
        return set.matchAll
            ? set.conditions.allSatisfy { matches($0, at: date) }
            : set.conditions.contains { matches($0, at: date) }
    }

    func matches(_ condition: FormlessCondition, at date: Date) -> Bool {
        let subject = value(condition.subject, at: date)
        let operand = value(condition.operand, at: date)
        let calendar = Calendar.current

        switch condition.comparison {
        case .isEmpty: return subject.isEmpty
        case .isNotEmpty: return !subject.isEmpty
        case .isTrue: return subject.boolValue == true
        case .isFalse: return subject.boolValue == false
        case .greaterOrEqual, .lessOrEqual, .greater, .less, .equal, .notEqual, .between:
            guard let left = subject.numberValue else {
                // 文字的等於、不等於也走這裡（舊規則只有數字）。
                if condition.comparison == .equal { return subject.rawString == operand.rawString }
                if condition.comparison == .notEqual { return subject.rawString != operand.rawString }
                return false
            }
            guard let right = operand.numberValue else { return false }
            switch condition.comparison {
            case .greaterOrEqual: return left >= right
            case .lessOrEqual: return left <= right
            case .greater: return left > right
            case .less: return left < right
            case .equal: return abs(left - right) < 1e-9
            case .notEqual: return abs(left - right) >= 1e-9
            case .between:
                guard let upper = number(condition.upper, at: date) else { return false }
                return left >= min(right, upper) && left <= max(right, upper)
            default: return false
            }
        case .contains, .notContains, .textEquals, .beginsWith:
            let left = (FormlessValueFormatter.plainText(subject) ?? "").lowercased()
            let right = (FormlessValueFormatter.plainText(operand) ?? "").lowercased()
            switch condition.comparison {
            case .contains: return !right.isEmpty && left.contains(right)
            case .notContains: return right.isEmpty || !left.contains(right)
            case .textEquals: return left == right
            case .beginsWith: return !right.isEmpty && left.hasPrefix(right)
            default: return false
            }
        case .before, .after:
            guard let left = subject.dateValue, let right = operand.dateValue else { return false }
            return condition.comparison == .before ? left < right : left > right
        case .isToday:
            guard let left = subject.dateValue else { return false }
            return calendar.isDate(left, inSameDayAs: date)
        case .isTomorrow:
            guard let left = subject.dateValue, let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return false }
            return calendar.isDate(left, inSameDayAs: tomorrow)
        case .isPast:
            guard let left = subject.dateValue else { return false }
            return left <= date
        case .isFuture:
            guard let left = subject.dateValue else { return false }
            return left > date
        case .timeOfDay:
            guard let left = subject.dateValue, let start = operand.numberValue,
                  let end = number(condition.upper, at: date) else { return false }
            return Self.timeOfDay(left, isBetween: start, and: end, calendar: calendar)
        }
    }

    /// 時刻 left 的「時:分」是否落在 start～end（從午夜起的分鐘數）；end 比 start 小時表示跨午夜。
    static func timeOfDay(_ left: Date, isBetween start: Double, and end: Double, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: left)
        let minute = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        if start <= end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    /// 時段條件在 from～to 之間開始與結束的時刻（每天的那兩個時間），小工具時間線剛好在那一刻換畫面。
    static func timeOfDayChanges(_ condition: FormlessCondition, from: Date, to: Date) -> [Date] {
        guard condition.comparison == .timeOfDay,
              let start = condition.operand?.constant?.numberValue, let end = condition.upper?.constant?.numberValue else { return [] }
        let calendar = Calendar.current
        var result: [Date] = []
        var day = calendar.startOfDay(for: from)
        while day < to, result.count < 8 {
            for minutes in [start, end] {
                let moment = day.addingTimeInterval(minutes * 60)
                if moment > from && moment < to { result.append(moment) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // MARK: 時間線

    /// from 到 to 之間，這個綁定的值會變的時間點（行程結束、倒數到期、日出）。
    func changes(_ binding: FormlessBinding, from: Date, to: Date) -> [Date] {
        changes(binding, from: from, to: to, depth: 0)
    }

    private func changes(_ binding: FormlessBinding, from: Date, to: Date, depth: Int) -> [Date] {
        guard depth < Self.maximumDepth else { return [] }
        var result: [Date] = []
        switch binding.source {
        case FormlessBindingSource.variable:
            if let inner = variable(binding.field)?.binding { result += changes(inner, from: from, to: to, depth: depth + 1) }
        case FormlessBindingSource.item:
            break
        default:
            if let source = source(binding.source), let provider = FormlessProviders.provider(source.provider) {
                result += provider.changes(binding.field, source: source,
                                           snapshot: snapshots[provider.cacheKey(for: source)], from: from, to: to)
            }
        }
        // 「還有幾天」「是今天」在午夜改變。
        if binding.format?.dateStyle == FormlessDateStylePreset.countdownDays {
            let midnight = FormlessLiveTime.endOfDay(from)
            if midnight < to { result.append(midnight) }
        }
        for operation in binding.format?.operations ?? [] {
            if let inner = operation.operand.binding { result += changes(inner, from: from, to: to, depth: depth + 1) }
        }
        return result
    }
}

// MARK: - 文字片段

/// 系統即時走動的時間樣式（不用時間線、不吃更新配額）。
enum FormlessLiveDateStyle: String, CaseIterable, Sendable {
    /// 到那個時間的倒數（00:12:34）。
    case timer
    /// 相對時間（3 小時後）。
    case relative
}

enum FormlessTextPiece: Hashable, Sendable {
    case plain(String)
    case live(Date, FormlessLiveDateStyle)

    /// 量測與縮小用的當下樣子。
    func sample(at date: Date) -> String {
        switch self {
        case .plain(let text): return text
        case .live(let target, .timer):
            let seconds = Int(abs(target.timeIntervalSince(date)))
            return seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .live(let target, .relative):
            return FormlessValueFormatter.relative(target, from: date)
        }
    }
}

// MARK: - 日期樣式

/// 日期樣式的特殊值與範例格式。
enum FormlessDateStylePreset {
    /// 還有幾天（今天、明天、還有 12 天、3 天前）。
    static let countdownDays = "countdownDays"
    /// 靜態的相對時間（3 小時後），在小工具上只在更新時變。
    static let relativeStatic = "relativeText"
    static let timer = FormlessLiveDateStyle.timer.rawValue
    static let relative = FormlessLiveDateStyle.relative.rawValue

    /// 格式面板的日期樣式選單：(id, 名稱)。範例文字依當下時間產生。
    static let options: [(id: String, name: String)] = [
        ("M月d日", "月日"),
        ("M/d", "月/日"),
        ("yyyy/MM/dd", "年/月/日"),
        ("M月d日 EEEE", "月日與星期"),
        ("EEEE", "星期"),
        ("EEE", "星期（短）"),
        ("ah:mm", "時間"),
        ("HH:mm", "時間（24 小時）"),
        ("M月d日 ah:mm", "日期與時間"),
        (countdownDays, "還有幾天"),
        (relative, "相對時間（即時）"),
        (timer, "倒數計時（即時）")
    ]
}

// MARK: - 值轉文字

enum FormlessValueFormatter {

    static let locale = Locale(identifier: "zh_Hant_TW")

    /// 值顯示成文字。format 沒設定的項目用欄位說明的預設。
    static func text(_ value: FormlessValue, format: FormlessFormat?, spec: FormlessFieldSpec?, at date: Date) -> String {
        var text: String
        switch value {
        case .empty:
            return format?.emptyText ?? "－"
        case .text(let string), .color(let string), .symbol(let string), .image(let string):
            text = string
        case .number(let number, let unit):
            text = numberText(number, unit: unit, format: format, spec: spec)
        case .bool(let flag):
            text = flag ? "是" : "否"
        case .date(let day, let allDay):
            text = dateText(day, allDay: allDay, format: format, at: date)
        case .duration(let seconds):
            text = durationText(seconds)
        case .record(let record):
            text = recordTitle(record)
        case .list(let items):
            text = items.prefix(5).map { item -> String in
                switch item {
                case .record(let record): return recordTitle(record)
                default: return Self.text(item, format: format, spec: nil, at: date)
                }
            }.joined(separator: "、")
            if text.isEmpty { return format?.emptyText ?? "－" }
        }
        return transform(text, format: format)
    }

    /// 條件比較用的原始文字。
    static func plainText(_ value: FormlessValue) -> String? {
        switch value {
        case .record(let record): return recordTitle(record)
        default: return value.rawString
        }
    }

    static func recordTitle(_ record: FormlessRecord) -> String {
        for key in ["title", "name", "label", "text"] {
            if case .text(let title) = record[key], !title.isEmpty { return title }
        }
        return record.id
    }

    static func transform(_ text: String, format: FormlessFormat?) -> String {
        guard let format else { return text }
        var result = text
        for replacement in format.replacements ?? [] where !replacement.find.isEmpty {
            switch replacement.mode {
            case "whole":
                if result == replacement.find { result = replacement.replace }
            case "regex":
                if let regex = try? NSRegularExpression(pattern: replacement.find) {
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                            withTemplate: replacement.replace)
                }
            default:
                result = result.replacingOccurrences(of: replacement.find, with: replacement.replace)
            }
        }
        switch format.textCase {
        case "upper": result = result.uppercased()
        case "lower": result = result.lowercased()
        case "capitalized": result = result.capitalized
        default: break
        }
        if let maxLength = format.maxLength, maxLength > 0, result.count > maxLength {
            result = String(result.prefix(maxLength)) + "…"
        }
        return result
    }

    // MARK: 數字

    /// 預設要顯示單位的：物理量與百分比；計數類（步、層、天）由使用者自己打字。
    static func showsUnitByDefault(_ unit: FormlessUnit) -> Bool {
        switch unit {
        case .percent, .celsius, .degrees, .meters, .kilometers, .hectopascals, .millimeters, .kilometersPerHour,
             .microgramsPerCubicMeter, .bytes, .secondsPerKilometer:
            return true
        default:
            return false
        }
    }

    static func numberText(_ raw: Double, unit: FormlessUnit, format: FormlessFormat?, spec: FormlessFieldSpec?) -> String {
        var number = raw
        var suffix = unit.suffix
        if unit == .celsius {
            switch format?.temperatureUnit {
            case "c": break
            case "f": number = raw * 9 / 5 + 32
            default: number = FormlessWeatherStyle.temperature(raw)
            }
        }
        if unit == .bytes { return byteText(number) }
        if unit == .secondsPerKilometer {
            let seconds = Int(number.rounded())
            return String(format: "%d'%02d\"", seconds / 60, seconds % 60) + ((format?.showsUnit ?? true) ? " /公里" : "")
        }
        if !(format?.showsUnit ?? showsUnitByDefault(unit)) { suffix = "" }

        if format?.compact == true, abs(number) >= 10_000 {
            let (scaled, word) = abs(number) >= 100_000_000 ? (number / 100_000_000, "億") : (number / 10_000, "萬")
            let decimals = format?.decimals ?? (abs(scaled) < 10 ? 1 : 0)
            return fixed(scaled, decimals: decimals, grouping: false) + word + suffix
        }

        let decimals = format?.decimals ?? spec?.decimals ?? defaultDecimals(number, unit: unit)
        let grouping = format?.grouping ?? (spec?.grouping ?? false || abs(number) >= 10_000)
        return fixed(number, decimals: decimals, grouping: grouping) + suffix
    }

    static func defaultDecimals(_ number: Double, unit: FormlessUnit) -> Int {
        switch unit {
        case .celsius, .percent, .steps, .count, .floors, .aqi, .degrees, .hectopascals, .days: return 0
        case .kilometers: return 1
        default:
            if number.rounded() == number { return 0 }
            return abs(number) < 10 ? 1 : 0
        }
    }

    private static let numberFormatters = FormlessFormatterCacheLock<String, NumberFormatter>()

    static func fixed(_ number: Double, decimals: Int, grouping: Bool) -> String {
        let key = "\(decimals)|\(grouping)"
        let formatter = numberFormatters.value(for: key) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = grouping
            formatter.minimumFractionDigits = max(0, decimals)
            formatter.maximumFractionDigits = max(0, decimals)
            formatter.roundingMode = .halfUp
            return formatter
        }
        // -0 顯示成 0。
        let value = abs(number) < pow(10, Double(-max(decimals, 0))) / 2 ? 0 : number
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func byteText(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(abs(seconds).rounded())
        let days = total / 86_400, hours = total / 3600 % 24, minutes = total / 60 % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) 天") }
        if hours > 0 { parts.append("\(hours) 小時") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes) 分") }
        return (seconds < 0 ? "-" : "") + parts.prefix(2).joined(separator: " ")
    }

    // MARK: 日期

    private static let dateFormatters = FormlessFormatterCacheLock<String, DateFormatter>()

    static func dateText(_ day: Date, allDay: Bool, format: FormlessFormat?, at now: Date) -> String {
        let style = format?.dateStyle
        switch style {
        case FormlessDateStylePreset.countdownDays?:
            return countdownDays(day, from: now)
        case FormlessDateStylePreset.relativeStatic?, FormlessLiveDateStyle.relative.rawValue?:
            return relative(day, from: now)
        case FormlessLiveDateStyle.timer.rawValue?:
            return FormlessTextPiece.live(day, .timer).sample(at: now)
        default:
            break
        }
        if format?.calendar == "chinese" {
            return FormlessChineseCalendar.lunarText(for: day, style: style)
        }
        var pattern = style ?? (allDay ? "M月d日" : "ah:mm")
        // 整天的項目（全天行程、只有日期的提醒）沒有時間：樣式裡的時間換成「整天」。
        if allDay, pattern.contains(where: { "hHkKm".contains($0) }) {
            let dateOnly = pattern.filter { !"ahHkKms:".contains($0) }.trimmingCharacters(in: .whitespaces)
            let text = dateOnly.isEmpty ? "" : formatter(pattern: dateOnly, timeZone: format?.timeZone, calendar: format?.calendar).string(from: day)
            return text.isEmpty ? "整天" : text + " 整天"
        }
        return formatter(pattern: pattern, timeZone: format?.timeZone, calendar: format?.calendar).string(from: day)
    }

    static func formatter(pattern: String, timeZone: String?, calendar: String?) -> DateFormatter {
        let key = pattern + "|" + (timeZone ?? "") + "|" + (calendar ?? "")
        return dateFormatters.value(for: key) {
            let formatter = DateFormatter()
            formatter.locale = locale
            switch calendar {
            case "roc": formatter.calendar = Calendar(identifier: .republicOfChina)
            case "buddhist": formatter.calendar = Calendar(identifier: .buddhist)
            case "japanese": formatter.calendar = Calendar(identifier: .japanese)
            default: formatter.calendar = Calendar(identifier: .gregorian)
            }
            if let timeZone, let zone = TimeZone(identifier: timeZone) { formatter.timeZone = zone }
            formatter.dateFormat = pattern
            return formatter
        }
    }

    /// 今天、明天、後天、還有 12 天、昨天、3 天前。
    static func countdownDays(_ target: Date, from now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "後天"
        case -1: return "昨天"
        case let value where value > 0: return "還有 \(value) 天"
        default: return "\(-days) 天前"
        }
    }

    static func relative(_ target: Date, from now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: target, relativeTo: now)
    }
}

/// 執行緒安全的格式器快取（小工具時間線在背景執行緒排版）。
final class FormlessFormatterCacheLock<Key: Hashable, Value>: @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    func value(for key: Key, make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[key] { return hit }
        let made = make()
        storage[key] = made
        return made
    }
}
