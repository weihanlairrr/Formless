import Foundation

// MARK: - 捷徑寫入的資料
//
// 「設定 Formless 資料」捷徑把值存在這裡（App 群組快取資料夾的 shortcut-values.json），
// 小工具用「捷徑」資料讀取。名稱由使用者取，例如「今日待辦數」「體重」；同名的值會被新值蓋掉。

/// 一個捷徑寫入的值與寫入時間。
struct FormlessShortcutEntry: Codable, Hashable, Sendable {
    var value: FormlessValue
    var updatedAt: Date
}

/// 捷徑傳來的文字要當成哪一種資料。
enum FormlessShortcutValueKind: String, CaseIterable, Sendable {
    case text, number, date, bool, lines, json

    var displayName: String {
        switch self {
        case .text: return "文字"
        case .number: return "數字"
        case .date: return "日期"
        case .bool: return "是非"
        case .lines: return "清單（每行一項）"
        case .json: return "JSON"
        }
    }
}

/// 捷徑的值讀不懂時的錯誤（捷徑會顯示這段說明）。
struct FormlessShortcutValueError: LocalizedError, CustomLocalizedStringResourceConvertible, Hashable, Sendable {
    let message: String
    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

enum FormlessShortcutStore {
    static let fileName = "shortcut-values.json"
    private static let lock = NSLock()

    static func all() -> [String: FormlessShortcutEntry] {
        FormlessCache.load([String: FormlessShortcutEntry].self, name: fileName) ?? [:]
    }

    /// 存一個值（名稱前後的空白去掉；空的名稱不存）。
    static func set(_ value: FormlessValue, for name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        lock.withLock {
            var entries = all()
            entries[name] = FormlessShortcutEntry(value: value.formlessCapped(), updatedAt: Date())
            FormlessCache.save(entries, name: fileName)
        }
    }

    static func remove(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            var entries = all()
            guard entries.removeValue(forKey: name) != nil else { return }
            FormlessCache.save(entries, name: fileName)
        }
    }

    // MARK: 讀懂捷徑傳來的文字

    /// 依種類把文字轉成資料值。數字可以有千分位（8,430）與 %；日期可以是 ISO 8601、2026/10/04 15:08、
    /// 2026年10月4日 下午3:08；清單一行一項；JSON 的物件是一筆資料、陣列是清單。讀不懂時丟出說明錯誤。
    static func value(from text: String, as kind: FormlessShortcutValueKind) throws -> FormlessValue {
        let halfWidth = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let trimmed = halfWidth.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text:
            return .text(text)
        case .number:
            var cleaned = trimmed.filter { $0 != "," && !$0.isWhitespace }
            var unit = FormlessUnit.none
            if cleaned.hasSuffix("%") { cleaned.removeLast(); unit = .percent }
            guard let number = Double(cleaned), number.isFinite, cleaned.contains(where: \.isNumber) else {
                throw FormlessShortcutValueError(message: "「\(text)」不是數字")
            }
            return .number(number, unit)
        case .date:
            guard let parsed = date(from: trimmed) else { throw FormlessShortcutValueError(message: "「\(text)」不是日期") }
            return .date(parsed.date, allDay: parsed.allDay)
        case .bool:
            switch trimmed.lowercased() {
            case "是", "true", "yes", "y", "1", "開", "on", "對", "真": return .bool(true)
            case "否", "false", "no", "n", "0", "關", "off", "不是", "假": return .bool(false)
            default: throw FormlessShortcutValueError(message: "「\(text)」不是是非（請填「是」或「否」）")
            }
        case .lines:
            return .list(text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { .text($0) })
        case .json:
            guard let json = try? FormlessJSONPath.parse(Data(text.utf8)) else {
                throw FormlessShortcutValueError(message: "JSON 格式不正確")
            }
            return json.value().formlessCapped()
        }
    }

    /// 日期文字：ISO 8601 與「年-月-日 時:分」（`FormlessValue.parseDate`），再試捷徑常見的
    /// 2026/10/04 15:08、2026年10月4日 下午3:08、Oct 4, 2026 at 3:08 PM。沒有時區用裝置的時區；沒有時間是全天。
    static func date(from text: String) -> (date: Date, allDay: Bool)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = FormlessValue.parseDate(text) { return (date, !text.contains(":")) }
        let formats: [(locale: String, pattern: String)] = [
            ("en_US_POSIX", "yyyy/M/d H:mm:ss"), ("en_US_POSIX", "yyyy/M/d H:mm"), ("en_US_POSIX", "yyyy/M/d"),
            ("en_US_POSIX", "yyyy-M-d H:mm"), ("en_US_POSIX", "yyyy-M-d"), ("en_US_POSIX", "yyyy.M.d H:mm"), ("en_US_POSIX", "yyyy.M.d"),
            ("zh_Hant_TW", "yyyy/M/d ah:mm"), ("zh_Hant_TW", "yyyy/M/d a h:mm"),
            ("zh_Hant_TW", "yyyy年M月d日 ah:mm"), ("zh_Hant_TW", "yyyy年M月d日 a h:mm"), ("zh_Hant_TW", "yyyy年M月d日 H:mm"),
            ("zh_Hant_TW", "yyyy年M月d日"),
            ("en_US_POSIX", "MMM d, yyyy 'at' h:mm a"), ("en_US_POSIX", "MMM d, yyyy h:mm a"), ("en_US_POSIX", "MMM d, yyyy")
        ]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        for format in formats {
            formatter.locale = Locale(identifier: format.locale)
            formatter.dateFormat = format.pattern
            if let date = formatter.date(from: text) { return (date, !format.pattern.contains("m")) }
        }
        return nil
    }

    // MARK: 讀出

    /// 存的值轉成文字（「讀取 Formless 資料」捷徑的結果）：清單一行一項、一筆資料是 JSON，
    /// 日期是 2026/10/04 15:08，這些都能再用「設定 Formless 資料」存回去。
    static func text(_ value: FormlessValue) -> String {
        switch value {
        case .empty: return ""
        case .text(let text), .color(let text), .symbol(let text), .image(let text): return text
        case .bool(let flag): return flag ? "是" : "否"
        case .date(let date, let allDay):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = allDay ? "yyyy/MM/dd" : "yyyy/MM/dd HH:mm"
            return formatter.string(from: date)
        case .number(_, let unit): return (value.rawString ?? "") + (unit == .percent ? "%" : "")
        case .duration: return value.rawString ?? ""
        case .list(let items) where items.allSatisfy({ $0.recordValue == nil && $0.listValue == nil }):
            return items.map(text).joined(separator: "\n")
        case .list, .record:
            let object = jsonObject(value)
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return value.rawString ?? ""
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func jsonObject(_ value: FormlessValue) -> Any {
        switch value {
        case .empty: return NSNull()
        case .bool(let flag): return flag
        case .number(let number, _), .duration(let number):
            // 最短的寫法（31.755，不是 31.754999999999999）
            if number.rounded() == number, abs(number) < 1e15 { return Int64(number) }
            return NSDecimalNumber(string: String(number))
        case .record(let record): return record.fields.mapValues(jsonObject)
        case .list(let items): return items.map(jsonObject)
        case .date: return text(value)
        default: return value.rawString ?? ""
        }
    }
}

// MARK: - 捷徑資料

/// 「我的資料」分類裡的「捷徑」：捷徑存過的每一個值是一個欄位，另外各有一個「更新時間」欄位。
/// 不用事先抓：取值時直接讀捷徑存的檔案。
struct FormlessShortcutDataProvider: FormlessDataProvider {
    let id = "shortcut"
    let name = "捷徑"
    let symbol = "square.on.square.dashed"
    let category = FormlessDataCategory.mine
    var fetches: Bool { false }

    static let updatedPrefix = "updatedAt."

    func summary(for source: FormlessSource) -> String {
        let count = FormlessShortcutStore.all().count
        return count == 0 ? "還沒有資料" : "\(count) 筆"
    }

    /// 依名稱排序；每個值後面接著它的更新時間。
    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let entries = FormlessShortcutStore.all()
        return entries.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { name -> [FormlessFieldSpec] in
            guard let entry = entries[name] else { return [] }
            return [
                FormlessFieldSpec(name, name, entry.value.kind ?? .text, unit: entry.value.unit, sample: entry.value,
                                  items: Self.itemFields(of: entry.value)),
                FormlessFieldSpec(Self.updatedPrefix + name, "「\(name)」更新時間", .date, sample: .date(entry.updatedAt))
            ]
        }
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        let entries = FormlessShortcutStore.all()
        if let entry = entries[field] { return entry.value }
        if field.hasPrefix(Self.updatedPrefix), let entry = entries[String(field.dropFirst(Self.updatedPrefix.count))] {
            return .date(entry.updatedAt)
        }
        return .empty
    }

    /// JSON 存的一筆資料或清單：裡面的欄位（清單看第一筆）。
    static func itemFields(of value: FormlessValue) -> [FormlessFieldSpec] {
        let record = value.recordValue ?? value.listValue?.first?.recordValue
        guard let record else { return [] }
        return record.fields.keys.sorted().map { key in
            FormlessFieldSpec(key, key, record[key].kind ?? .text, unit: record[key].unit)
        }
    }
}
