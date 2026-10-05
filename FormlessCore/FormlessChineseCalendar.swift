import Foundation

// MARK: - 農曆與節氣
//
// 農曆日期用系統的中國曆（Calendar(identifier: .chinese)，閏月看 DateComponents.isLeapMonth），以裝置目前的時區分日；
// 干支、生肖跟著農曆年，正月初一才換年（不是 1 月 1 日）。
// 節氣是太陽視黃經到達 15° 倍數的時刻（定氣），由 FormlessAstronomy 求根，誤差約 1 分鐘以內。

enum FormlessChineseCalendar {
    /// 二十四節氣，從小寒（太陽黃經 285°）開始，每個相差 15°。
    static let solarTermNames: [String] = [
        "小寒", "大寒", "立春", "雨水", "驚蟄", "春分", "清明", "穀雨", "立夏", "小滿", "芒種", "夏至",
        "小暑", "大暑", "立秋", "處暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
    ]

    private static let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    private static let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
    private static let animals = ["鼠", "牛", "虎", "兔", "龍", "蛇", "馬", "羊", "猴", "雞", "狗", "豬"]
    private static let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "臘月"]
    private static let digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]

    // MARK: 農曆日期

    /// 農曆日期文字。style：nil 或 "md" →「八月十三」（閏月「閏六月初一」）、"full" →「乙巳年八月十三」、
    /// "month" →「八月」、"day" →「十三」、"year" →「乙巳年」、"zodiac" →「蛇年」；其他值當作 nil。
    static func lunarText(for date: Date, style: String?, timeZone: TimeZone = .current) -> String {
        let parts = lunar(for: date, timeZone: timeZone)
        let month = monthName(parts.month, leap: parts.isLeapMonth), day = dayName(parts.day)
        switch style {
        case "full": return ganzhi(parts.year) + "年" + month + day
        case "month": return month
        case "day": return day
        case "year": return ganzhi(parts.year) + "年"
        case "zodiac": return animals[cycle(parts.year, 12)] + "年"
        default: return month + day
        }
    }

    /// 農曆年、月、日與是否閏月。年是這個農曆年開始時的西元年（乙巳年＝2025）。
    static func lunar(for date: Date, timeZone: TimeZone = .current) -> (year: Int, month: Int, day: Int, isLeapMonth: Bool) {
        var calendar = Calendar(identifier: .chinese)
        // 在哪個時區分日：預設裝置時區；「日期與時間」設了時區時用那個時區（東京 10/5 凌晨已經是下一個農曆日）。
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: date)
        // 系統的中國曆以六十年為一輪：era 是第幾輪、year 是輪內第幾年（1＝甲子），換算成西元年。
        let year = ((parts.era ?? 78) - 1) * 60 + (parts.year ?? 1) - 2637
        return (year, parts.month ?? 1, parts.day ?? 1, parts.isLeapMonth ?? false)
    }

    /// 正月、二月…十月、冬月、臘月；閏月前面加「閏」。
    static func monthName(_ month: Int, leap: Bool) -> String {
        let name = (1...12).contains(month) ? months[month - 1] : "\(month)月"
        return leap ? "閏" + name : name
    }

    /// 初一…初十、十一…二十、廿一…廿九、三十。
    static func dayName(_ day: Int) -> String {
        switch day {
        case 1...10: return "初" + digits[day - 1]
        case 11...19: return "十" + digits[day - 11]
        case 20: return "二十"
        case 21...29: return "廿" + digits[day - 21]
        case 30: return "三十"
        default: return "\(day)"
        }
    }

    /// 農曆年的天干地支，例如「乙巳」；正月初一換年。
    static func ganzhiYear(for date: Date, timeZone: TimeZone = .current) -> String {
        ganzhi(lunar(for: date, timeZone: timeZone).year)
    }

    /// 農曆年的生肖，例如「蛇」；正月初一換年。
    static func zodiac(for date: Date, timeZone: TimeZone = .current) -> String {
        animals[cycle(lunar(for: date, timeZone: timeZone).year, 12)]
    }

    private static func ganzhi(_ year: Int) -> String {
        stems[cycle(year, 10)] + branches[cycle(year, 12)]
    }

    /// 西元 4 年是甲子年：從那年起算在 10 或 12 的循環中的位置。
    private static func cycle(_ year: Int, _ length: Int) -> Int {
        ((year - 4) % length + length) % length
    }

    // MARK: 節氣

    /// 西元 `year` 年的 24 個節氣（小寒…冬至），依時間排序；時刻是太陽到達那個黃經的瞬間。
    static func solarTerms(year: Int) -> [(name: String, date: Date)] {
        (0..<24).map { index in (solarTermNames[index], moment(ofTerm: (year - 2000) * 24 + index)) }
    }

    /// `date` 所在的當地日曆日（`timeZone`）有節氣交節時，回傳節氣名稱，否則 nil。
    static func solarTerm(on date: Date, timeZone: TimeZone = .current) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // 先看這一天（前後多留 1 分鐘）太陽黃經有沒有跨過 15° 的倍數，大多數日子不必求根。
        let first = FormlessAstronomy.solarLongitude(at: start.addingTimeInterval(-60))
        let last = FormlessAstronomy.solarLongitude(at: end.addingTimeInterval(60))
        guard (first / 15).rounded(.down) != (last / 15).rounded(.down) else { return nil }
        let n0 = termNumber(near: start)
        return ((n0 - 1)...(n0 + 2)).first { n in
            let t = moment(ofTerm: n)
            return t >= start && t < end
        }.map(name(ofTerm:))
    }

    /// `date`（含這一刻）以前最近的一個節氣。
    static func currentSolarTerm(at date: Date) -> (name: String, date: Date) {
        let n0 = termNumber(near: date)
        let n = stride(from: n0 + 1, through: n0 - 2, by: -1).first { moment(ofTerm: $0) <= date } ?? n0 - 3
        return (name(ofTerm: n), moment(ofTerm: n))
    }

    /// `date` 之後（不含這一刻）的第一個節氣。
    static func nextSolarTerm(after date: Date) -> (name: String, date: Date) {
        let n0 = termNumber(near: date)
        let n = ((n0 - 1)...(n0 + 2)).first { moment(ofTerm: $0) > date } ?? n0 + 3
        return (name(ofTerm: n), moment(ofTerm: n))
    }

    // MARK: 節氣序號
    //
    // 節氣以序號 n 表示：n = 0 是 2000 年的小寒，往後每個節氣 +1（每年 24 個）。
    // 同一個 n 一律從同一個估計值求根，所以各函式回傳的時刻完全一致（可以拿回傳的時刻再查下一個）。

    /// 平太陽黃經 0° 的時刻（2000-03-22 04:35 UTC）。實際節氣和以它推算的平均時刻相差約 ±2 天，
    /// 所以下面各函式只要在估計的序號前後各看一兩個。
    private static let meanEquinox2000 = Date(timeIntervalSince1970: 953_699_700)
    /// 節氣平均間隔（回歸年 ÷ 24，秒）。
    private static let meanTermLength = 365.242_19 / 24 * 86_400

    /// `date` 以前最近的節氣序號（以平均時刻估計）。
    private static func termNumber(near date: Date) -> Int {
        let count = (date.timeIntervalSince(meanEquinox2000) / meanTermLength).rounded(.down)
        return count.isFinite ? Int(min(max(count, -1e9), 1e9)) + 5 : 5
    }

    /// 第 n 個節氣的時刻。
    private static func moment(ofTerm n: Int) -> Date {
        let longitude = Double(((285 + 15 * n) % 360 + 360) % 360)
        let estimate = meanEquinox2000.addingTimeInterval(Double(n - 5) * meanTermLength)
        return FormlessAstronomy.moment(solarLongitude: longitude, near: estimate)
    }

    private static func name(ofTerm n: Int) -> String {
        solarTermNames[(n % 24 + 24) % 24]
    }
}
