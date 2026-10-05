import Foundation

// MARK: - 日期與時間
//
// 純計算：不抓資料、不連網，用到時依那一刻的時間算。另外設定一份可以換時區（東京時間）。

struct FormlessDateTimeProvider: FormlessDataProvider {
    let id = "dateTime"
    let name = "日期與時間"
    let symbol = "clock"
    let category = FormlessDataCategory.dateTime
    var fetches: Bool { false }
    var allowsInstances: Bool { true }

    static let timeZones: [FormlessNamedValue] = [
        FormlessNamedValue(id: "", name: "裝置時區"),
        FormlessNamedValue(id: "Asia/Taipei", name: "臺北"),
        FormlessNamedValue(id: "Asia/Tokyo", name: "東京"),
        FormlessNamedValue(id: "Asia/Seoul", name: "首爾"),
        FormlessNamedValue(id: "Asia/Hong_Kong", name: "香港"),
        FormlessNamedValue(id: "Asia/Shanghai", name: "上海"),
        FormlessNamedValue(id: "Asia/Singapore", name: "新加坡"),
        FormlessNamedValue(id: "Asia/Bangkok", name: "曼谷"),
        FormlessNamedValue(id: "Asia/Kolkata", name: "新德里"),
        FormlessNamedValue(id: "Asia/Dubai", name: "杜拜"),
        FormlessNamedValue(id: "Australia/Sydney", name: "雪梨"),
        FormlessNamedValue(id: "Pacific/Auckland", name: "奧克蘭"),
        FormlessNamedValue(id: "Europe/London", name: "倫敦"),
        FormlessNamedValue(id: "Europe/Paris", name: "巴黎"),
        FormlessNamedValue(id: "Europe/Berlin", name: "柏林"),
        FormlessNamedValue(id: "America/New_York", name: "紐約"),
        FormlessNamedValue(id: "America/Chicago", name: "芝加哥"),
        FormlessNamedValue(id: "America/Denver", name: "丹佛"),
        FormlessNamedValue(id: "America/Los_Angeles", name: "洛杉磯"),
        FormlessNamedValue(id: "America/Vancouver", name: "溫哥華"),
        FormlessNamedValue(id: "Pacific/Honolulu", name: "夏威夷"),
        FormlessNamedValue(id: "UTC", name: "世界標準時間")
    ]

    var settings: [FormlessSettingSpec] {
        [FormlessSettingSpec(id: "timeZone", name: "時區", kind: .choice(Self.timeZones), defaultValue: .text(""))]
    }

    func summary(for source: FormlessSource) -> String {
        let zone = source.text("timeZone") ?? ""
        return Self.timeZones.first { $0.id == zone }?.name ?? zone
    }

    func timeZone(_ source: FormlessSource) -> TimeZone {
        source.text("timeZone").flatMap(TimeZone.init(identifier:)) ?? .current
    }

    func calendar(_ source: FormlessSource) -> Calendar {
        var calendar = FormlessLiveTime.calendar
        calendar.timeZone = timeZone(source)
        return calendar
    }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let now = Date()
        return [
            FormlessFieldSpec("now", "現在時間", .date, sample: .date(now), live: true),
            FormlessFieldSpec("today", "今天日期", .date, sample: .date(now, allDay: true)),
            FormlessFieldSpec("weekday", "星期", .text, sample: .text("星期六")),
            FormlessFieldSpec("weekdayShort", "星期（短）", .text, sample: .text("週六")),
            FormlessFieldSpec("year", "年", .number, sample: .number(2026)),
            FormlessFieldSpec("month", "月", .number, sample: .number(10)),
            FormlessFieldSpec("day", "日", .number, sample: .number(4)),
            FormlessFieldSpec("hour", "時", .number, sample: .number(15)),
            FormlessFieldSpec("minute", "分", .number, sample: .number(8)),
            FormlessFieldSpec("weekdayNumber", "星期幾（數字）", .number, sample: .number(6)),
            FormlessFieldSpec("weekOfYear", "第幾週", .number, sample: .number(40)),
            FormlessFieldSpec("dayOfYear", "一年的第幾天", .number, sample: .number(277)),
            FormlessFieldSpec("daysInMonth", "這個月有幾天", .number, sample: .number(31)),
            FormlessFieldSpec("quarter", "第幾季", .number, sample: .number(4)),
            FormlessFieldSpec("isWeekend", "是週末", .bool, sample: .bool(true)),
            FormlessFieldSpec("rocYear", "民國年", .number, sample: .number(115)),
            FormlessFieldSpec("lunarDate", "農曆日期", .text, sample: .text("八月廿四")),
            FormlessFieldSpec("lunarMonth", "農曆月", .text, sample: .text("八月")),
            FormlessFieldSpec("lunarDay", "農曆日", .text, sample: .text("廿四")),
            FormlessFieldSpec("ganzhiYear", "干支年", .text, sample: .text("丙午")),
            FormlessFieldSpec("zodiac", "生肖", .text, sample: .text("馬")),
            FormlessFieldSpec("solarTerm", "目前節氣", .text, sample: .text("秋分")),
            FormlessFieldSpec("solarTermToday", "今天的節氣", .text, sample: .text("寒露")),
            FormlessFieldSpec("nextSolarTerm", "下一個節氣", .text, sample: .text("寒露")),
            FormlessFieldSpec("nextSolarTermDate", "下一個節氣日期", .date, sample: .date(now.addingTimeInterval(4 * 86_400), allDay: true))
        ]
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        let calendar = calendar(source)
        let zone = calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday, .weekOfYear], from: date)
        switch field {
        case "now": return .date(date)
        case "today": return .date(calendar.startOfDay(for: date), allDay: true)
        case "weekday": return .text(FormlessValueFormatter.formatter(pattern: "EEEE", timeZone: zone.identifier, calendar: nil).string(from: date))
        case "weekdayShort": return .text(FormlessValueFormatter.formatter(pattern: "EEE", timeZone: zone.identifier, calendar: nil).string(from: date))
        case "year": return .number(Double(parts.year ?? 0), .none)
        case "month": return .number(Double(parts.month ?? 0), .none)
        case "day": return .number(Double(parts.day ?? 0), .none)
        case "hour": return .number(Double(parts.hour ?? 0), .none)
        case "minute": return .number(Double(parts.minute ?? 0), .none)
        case "weekdayNumber":
            // 1 是星期一、7 是星期日（ISO）。
            let weekday = parts.weekday ?? 1
            return .number(Double(weekday == 1 ? 7 : weekday - 1), .none)
        case "weekOfYear":
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = zone
            return .number(Double(iso.component(.weekOfYear, from: date)), .none)
        case "dayOfYear": return .number(Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 0), .none)
        case "daysInMonth": return .number(Double(calendar.range(of: .day, in: .month, for: date)?.count ?? 30), .none)
        case "quarter": return .number(Double(((parts.month ?? 1) - 1) / 3 + 1), .none)
        case "isWeekend": return .bool(calendar.isDateInWeekend(date))
        case "rocYear": return .number(Double((parts.year ?? 1911) - 1911), .none)
        case "lunarDate": return .text(FormlessChineseCalendar.lunarText(for: date, style: nil, timeZone: zone))
        case "lunarMonth": return .text(FormlessChineseCalendar.lunarText(for: date, style: "month", timeZone: zone))
        case "lunarDay": return .text(FormlessChineseCalendar.lunarText(for: date, style: "day", timeZone: zone))
        case "ganzhiYear": return .text(FormlessChineseCalendar.ganzhiYear(for: date, timeZone: zone))
        case "zodiac": return .text(FormlessChineseCalendar.zodiac(for: date, timeZone: zone))
        case "solarTerm": return .text(FormlessChineseCalendar.currentSolarTerm(at: date).name)
        case "solarTermToday": return .optionalText(FormlessChineseCalendar.solarTerm(on: date, timeZone: zone))
        case "nextSolarTerm": return .text(FormlessChineseCalendar.nextSolarTerm(after: date).name)
        case "nextSolarTermDate": return .date(FormlessChineseCalendar.nextSolarTerm(after: date).date, allDay: true)
        default: return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        let calendar = calendar(source)
        switch field {
        case "hour":
            var result: [Date] = []
            var cursor = calendar.dateInterval(of: .hour, for: from)?.end ?? to
            while cursor < to, result.count < 24 { result.append(cursor); cursor.addTimeInterval(3600) }
            return result
        case "now", "minute":
            return []   // 每 5 分鐘一格由 needsMinuteRefresh 處理
        default:
            let midnight = calendar.dateInterval(of: .day, for: from)?.end ?? to
            return midnight < to ? [midnight] : []
        }
    }
}

// MARK: - 倒數

/// 倒數到某個時間（生日、紀念日、截止日）。App 預設倒數到新年；每一個倒數是一份來源。
struct FormlessCountdownProvider: FormlessDataProvider {
    let id = "countdown"
    let name = "倒數"
    let symbol = "hourglass"
    let category = FormlessDataCategory.dateTime
    var fetches: Bool { false }
    var allowsInstances: Bool { true }

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "title", name: "名稱", kind: .text(placeholder: "新年")),
            FormlessSettingSpec(id: "target", name: "時間", kind: .dateTime),
            FormlessSettingSpec(id: "yearly", name: "每年重複", kind: .toggle, defaultValue: .bool(false),
                                footer: "過了之後自動換成明年的同一天，適合生日與紀念日。")
        ]
    }

    func summary(for source: FormlessSource) -> String { title(source) }

    func title(_ source: FormlessSource) -> String {
        source.text("title") ?? (source.date("target") == nil ? "新年" : "倒數")
    }

    /// date 那一刻要倒數的時間。
    func target(_ source: FormlessSource, at date: Date) -> Date {
        let calendar = FormlessLiveTime.calendar
        guard let set = source.date("target") else {
            let year = calendar.component(.year, from: date) + 1
            return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
        }
        guard source.flag("yearly") == true, set <= date else { return set }
        var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: set)
        parts.year = calendar.component(.year, from: date)
        var next = calendar.date(from: parts) ?? set
        if next <= date { parts.year = (parts.year ?? 0) + 1; next = calendar.date(from: parts) ?? set }
        return next
    }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let now = Date()
        return [
            FormlessFieldSpec("title", "名稱", .text, sample: .text(title(source))),
            FormlessFieldSpec("target", "時間", .date, sample: .date(now.addingTimeInterval(86 * 86_400)), live: true),
            FormlessFieldSpec("daysLeft", "還有幾天", .number, unit: .days, sample: .number(86, .days)),
            FormlessFieldSpec("remaining", "剩下的時間", .duration, sample: .duration(86 * 86_400 + 3600), live: true),
            FormlessFieldSpec("daysSince", "已經過了幾天", .number, unit: .days, sample: .number(12, .days)),
            FormlessFieldSpec("isPast", "已經到了", .bool, sample: .bool(false))
        ]
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        let calendar = FormlessLiveTime.calendar
        let target = target(source, at: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: target)).day ?? 0
        switch field {
        case "title": return .text(title(source))
        case "target": return .date(target)
        case "daysLeft": return .number(Double(max(0, days)), .days)
        case "remaining": return .duration(max(0, target.timeIntervalSince(date)))
        case "daysSince": return .number(Double(max(0, -days)), .days)
        case "isPast": return .bool(target <= date)
        default: return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        let target = target(source, at: from)
        if target > from, target < to { result.append(target) }
        let midnight = FormlessLiveTime.endOfDay(from)
        if midnight < to { result.append(midnight) }
        return result
    }
}

// MARK: - 時間進度

/// 今天、這週、這個月、今年過了多少，與自訂期間（開始到結束）的進度。
struct FormlessTimeProgressProvider: FormlessDataProvider {
    let id = "timeProgress"
    let name = "時間進度"
    let symbol = "chart.bar.fill"
    let category = FormlessDataCategory.dateTime
    var fetches: Bool { false }
    var allowsInstances: Bool { true }

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "weekStartsMonday", name: "週一開始", kind: .toggle, defaultValue: .bool(true)),
            FormlessSettingSpec(id: "start", name: "自訂期間開始", kind: .dateTime),
            FormlessSettingSpec(id: "end", name: "自訂期間結束", kind: .dateTime,
                                footer: "自訂期間用在「期間進度」，例如學期、專案、旅行。")
        ]
    }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        [
            FormlessFieldSpec("day", "今天", .number, unit: .percent, sample: .number(63, .percent)),
            FormlessFieldSpec("week", "這週", .number, unit: .percent, sample: .number(80, .percent)),
            FormlessFieldSpec("month", "這個月", .number, unit: .percent, sample: .number(13, .percent)),
            FormlessFieldSpec("year", "今年", .number, unit: .percent, sample: .number(76, .percent)),
            FormlessFieldSpec("period", "期間進度", .number, unit: .percent, sample: .number(42, .percent)),
            FormlessFieldSpec("periodDaysLeft", "期間剩下幾天", .number, unit: .days, sample: .number(30, .days))
        ]
    }

    func interval(_ field: String, source: FormlessSource, at date: Date) -> DateInterval? {
        var calendar = FormlessLiveTime.calendar
        switch field {
        case "day": return calendar.dateInterval(of: .day, for: date)
        case "week":
            calendar.firstWeekday = (source.flag("weekStartsMonday") ?? true) ? 2 : 1
            return calendar.dateInterval(of: .weekOfYear, for: date)
        case "month": return calendar.dateInterval(of: .month, for: date)
        case "year": return calendar.dateInterval(of: .year, for: date)
        case "period", "periodDaysLeft":
            guard let start = source.date("start"), let end = source.date("end"), end > start else { return nil }
            return DateInterval(start: start, end: end)
        default: return nil
        }
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        guard let interval = interval(field, source: source, at: date) else { return .empty }
        if field == "periodDaysLeft" {
            let calendar = FormlessLiveTime.calendar
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: interval.end)).day ?? 0
            return .number(Double(max(0, days)), .days)
        }
        let fraction = min(max(date.timeIntervalSince(interval.start) / max(interval.duration, 1), 0), 1)
        return .number(fraction * 100, .percent)
    }

    /// 每過 1% 換一次畫面（今天約 14 分鐘一次），最多排 24 格。
    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        guard let interval = interval(field, source: source, at: from), field != "periodDaysLeft" else {
            let midnight = FormlessLiveTime.endOfDay(from)
            return midnight < to ? [midnight] : []
        }
        let step = interval.duration / 100
        guard step >= 60 else { return [] }
        var result: [Date] = []
        let passed = from.timeIntervalSince(interval.start)
        var next = interval.start.addingTimeInterval((floor(passed / step) + 1) * step)
        while next < to, result.count < 24 { result.append(next); next.addTimeInterval(step) }
        // 期間結束的那一刻（午夜）也要換畫面；已經排進去或超過 24 格時不重複加。
        if interval.end > from, interval.end < to, result.count < 24, !result.contains(interval.end) {
            result.append(interval.end)
        }
        return result.sorted()
    }
}

// MARK: - 隨機

/// 隨機數與從清單隨機挑一項。同一段時間（同一天、同一小時）的結果固定，App 與小工具看到的一樣。
struct FormlessRandomProvider: FormlessDataProvider {
    let id = "random"
    let name = "隨機"
    let symbol = "dice"
    let category = FormlessDataCategory.mine
    var fetches: Bool { false }
    var allowsInstances: Bool { true }

    static let periods = [
        FormlessNamedValue(id: "day", name: "每天"),
        FormlessNamedValue(id: "hour", name: "每小時"),
        FormlessNamedValue(id: "quarter", name: "每 15 分鐘")
    ]

    var settings: [FormlessSettingSpec] {
        [
            FormlessSettingSpec(id: "minimum", name: "最小", kind: .number(min: -1_000_000, max: 1_000_000, step: 1), defaultValue: .number(1, .none)),
            FormlessSettingSpec(id: "maximum", name: "最大", kind: .number(min: -1_000_000, max: 1_000_000, step: 1), defaultValue: .number(100, .none)),
            FormlessSettingSpec(id: "lines", name: "清單", kind: .lines, footer: "一行一項，「隨機一項」從這裡挑。"),
            FormlessSettingSpec(id: "period", name: "多久換一次", kind: .choice(Self.periods), defaultValue: .text("day"))
        ]
    }

    func summary(for source: FormlessSource) -> String {
        let period = source.text("period") ?? "day"
        return Self.periods.first { $0.id == period }?.name ?? ""
    }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        [
            FormlessFieldSpec("number", "隨機數", .number, sample: .number(42)),
            FormlessFieldSpec("item", "隨機一項", .text, sample: .text(source.list("lines").first ?? "今天也要加油"))
        ]
    }

    private func slot(_ source: FormlessSource, at date: Date) -> (index: Int, start: Date, length: TimeInterval) {
        let length: TimeInterval
        switch source.text("period") ?? "day" {
        case "hour": length = 3600
        case "quarter": length = 900
        default: length = 86_400
        }
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        let index = Int(floor((date.timeIntervalSince1970 + offset) / length))
        return (index, Date(timeIntervalSince1970: Double(index + 1) * length - offset), length)
    }

    /// 以來源與時段算出固定的亂數（SplitMix64）。
    private func seed(_ source: FormlessSource, _ index: Int) -> UInt64 {
        var x = UInt64(bitPattern: Int64(index)) &+ UInt64(source.id.hashValueStable) &* 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        let random = seed(source, slot(source, at: date).index)
        switch field {
        case "number":
            // 範圍限制在 ±1,000,000（和設定頁相同）：匯入或手寫的設計檔可能帶極大值或非數字，直接轉整數會當掉。
            func bounded(_ value: Double?, _ fallback: Int) -> Int {
                guard let value, value.isFinite else { return fallback }
                return Int(max(-1_000_000, min(1_000_000, value.rounded())))
            }
            let low = bounded(source.number("minimum"), 1), high = bounded(source.number("maximum"), 100)
            let (a, b) = (min(low, high), max(low, high))
            return .number(Double(a + Int(random % UInt64(b - a + 1))), .none)
        case "item":
            let lines = source.list("lines").filter { !$0.isEmpty }
            guard !lines.isEmpty else { return .empty }
            return .text(lines[Int(random % UInt64(lines.count))])
        default: return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        let slot = slot(source, at: from)
        var result: [Date] = []
        var next = slot.start
        while next < to, result.count < 24 { result.append(next); next.addTimeInterval(slot.length) }
        return result
    }
}
