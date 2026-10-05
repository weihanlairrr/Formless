import Foundation

// MARK: - 天文計算
//
// 日出日落、晨昏蒙影、黃金與藍色時刻、月相、月出月落、分至點，以及節氣用的太陽黃經。
// 全部是純計算：不連網、沒有共用的可變狀態，App 與小工具在任何執行緒都能直接呼叫。
//
// 演算法出自 Jean Meeus《Astronomical Algorithms》第二版：
// - 太陽：VSOP87 截短級數（附錄三，NREL SPA 用的也是這組）加章動、光行差，得視黃經；誤差約 1″（約 25 秒）。
// - 月球：第 47 章（ELP-2000/82 截短級數），誤差約 10″；用於月出月落、照亮比例與月相比例。
// - 月相時刻：第 49 章；分至點：第 27 章的平均時刻當起點，再對太陽視黃經求根。
// - 時間：Date 當作世界時（UT）；天體位置用力學時 TT = UT + ΔT。

/// 某地某一天（當地日曆日）的太陽事件；沒有發生的事件是 nil（永晝、永夜，或太陽升不到那個高度）。
struct FormlessSunTimes: Hashable, Sendable {
    /// 日出、日落：太陽上緣碰到地平線（含大氣折射，太陽中心在 −0.833°）；永夜、永晝時是 nil。
    var sunrise: Date?
    var sunset: Date?
    /// 太陽過中天（正午）。
    var solarNoon: Date
    /// 民用晨光始、昏影終：太陽中心在地平線下 6°。
    var civilDawn: Date?
    var civilDusk: Date?
    /// 航海晨光始、昏影終：−12°。
    var nauticalDawn: Date?
    var nauticalDusk: Date?
    /// 天文晨光始、昏影終：−18°。
    var astronomicalDawn: Date?
    var astronomicalDusk: Date?
    /// 早上的黃金時刻＝日出到太陽升到 +6°；這是結束的時刻。
    var goldenHourMorningEnd: Date?
    /// 傍晚的黃金時刻＝太陽降到 +6° 到日落；這是開始的時刻。
    var goldenHourEveningStart: Date?
    /// 藍色時刻＝太陽在 −6° 到 −4° 之間。
    var blueHourMorningStart: Date?
    var blueHourMorningEnd: Date?
    var blueHourEveningStart: Date?
    var blueHourEveningEnd: Date?
    /// 白天長度（秒）：日出到日落；永夜 0、永晝 86400。
    var dayLength: TimeInterval
}

/// 四個主要月相。
enum FormlessMoonPhaseEvent: String, CaseIterable, Sendable {
    case new, firstQuarter, full, lastQuarter
}

/// 春分、夏至、秋分、冬至（以北半球命名）。
enum FormlessSeasonEvent: String, CaseIterable, Sendable {
    case marchEquinox, juneSolstice, septemberEquinox, decemberSolstice
}

/// 某一刻的月亮。
struct FormlessMoonInfo: Hashable, Sendable {
    /// 月相比例＝月日視黃經差 ÷ 360°：0 新月、0.25 上弦、0.5 滿月、0.75 下弦，接近 1 又回到新月。
    var phase: Double
    /// 照亮比例 0...1。
    var illumination: Double
    /// 月齡：距離上一次新月的天數。
    var age: Double
    /// 新月、眉月、上弦月、盈凸月、滿月、虧凸月、下弦月、殘月。
    var phaseName: String
    /// 對應的 SF Symbol。
    var symbolName: String
    /// 和 `date` 同一個當地日曆日的月出、月落；那天沒有就是 nil。
    var moonrise: Date?
    var moonset: Date?
}

enum FormlessAstronomy {

    // MARK: 太陽

    /// `date` 所在的當地日曆日（`timeZone`）的太陽事件。
    /// 以當天的太陽過中天為準：晨的事件找過中天前 12 小時內，昏的事件找之後 12 小時內
    /// （高緯度夏天的昏影終可能過了午夜，仍算在這一天）。
    static func sunTimes(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> FormlessSunTimes {
        let noon = solarNoon(in: localDay(containing: date, timeZone: timeZone), longitude: longitude)
        let before = noon - 0.5, after = noon + 0.5
        let altitude = { (d: Double) in sunAltitude(d, latitude: latitude, longitude: longitude) }
        let lowBefore = altitude(before), high = altitude(noon), lowAfter = altitude(after)
        // 過中天前太陽一路升高、之後一路降低，所以每個高度在兩段裡最多各跨過一次。
        func rising(_ h: Double) -> Date? {
            guard lowBefore < h, high >= h else { return nil }
            return instant(crossing(before, noon) { altitude($0) - h })
        }
        func setting(_ h: Double) -> Date? {
            guard high >= h, lowAfter < h else { return nil }
            return instant(crossing(noon, after) { altitude($0) - h })
        }
        let sunrise = rising(horizon), sunset = setting(horizon)
        let dayLength: TimeInterval
        switch (sunrise, sunset) {
        case let (rise?, set?): dayLength = set.timeIntervalSince(rise)
        case let (rise?, nil): dayLength = instant(after).timeIntervalSince(rise)
        case let (nil, set?): dayLength = set.timeIntervalSince(instant(before))
        case (nil, nil): dayLength = high > horizon ? 86_400 : 0
        }
        let civilDawn = rising(-6), civilDusk = setting(-6)
        return FormlessSunTimes(
            sunrise: sunrise, sunset: sunset, solarNoon: instant(noon),
            civilDawn: civilDawn, civilDusk: civilDusk,
            nauticalDawn: rising(-12), nauticalDusk: setting(-12),
            astronomicalDawn: rising(-18), astronomicalDusk: setting(-18),
            goldenHourMorningEnd: rising(6), goldenHourEveningStart: setting(6),
            blueHourMorningStart: civilDawn, blueHourMorningEnd: rising(-4),
            blueHourEveningStart: setting(-4), blueHourEveningEnd: civilDusk,
            dayLength: dayLength)
    }

    /// 太陽高度角（度），含大氣折射修正（NOAA 的近似式）。
    static func sunElevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let h = sunAltitude(dayNumber(date), latitude: latitude, longitude: longitude)
        return h + refraction(h)
    }

    /// 太陽的視地心黃經（度，0..<360）。
    static func solarLongitude(at date: Date) -> Double {
        sunPosition(dayNumber(date)).longitude
    }

    /// `year` 年的分點或至點（太陽視黃經 0°、90°、180°、270°）。
    static func season(_ event: FormlessSeasonEvent, year: Int) -> Date {
        // Meeus 表 27.B（1000–3000 年）的平均時刻（儒略日），只當求根的起點。
        let c: [Double]
        switch event {
        case .marchEquinox: c = [2451623.80984, 365242.37404, 0.05169, -0.00411, -0.00057]
        case .juneSolstice: c = [2451716.56767, 365241.62603, 0.00325, 0.00888, -0.00030]
        case .septemberEquinox: c = [2451810.21715, 365242.01767, -0.11575, 0.00337, 0.00078]
        case .decemberSolstice: c = [2451900.05952, 365242.74049, -0.06223, -0.00823, 0.00032]
        }
        let y = (Double(year) - 2000) / 1000
        let jde = c[0] + y * (c[1] + y * (c[2] + y * (c[3] + y * c[4])))
        let index = FormlessSeasonEvent.allCases.firstIndex(of: event) ?? 0
        return moment(solarLongitude: Double(index) * 90, near: instant(jde - 2_451_545))
    }

    /// 太陽視黃經等於 `longitude`（度）的時刻：從 `estimate` 開始找，回傳離它最近（前後半年內）的那一次。
    /// 分至點與節氣共用；同樣的輸入一定得到同一個時刻，精確到 1 毫秒。
    static func moment(solarLongitude longitude: Double, near estimate: Date) -> Date {
        var d = dayNumber(estimate)
        for _ in 0..<20 {
            let step = (longitude - sunPosition(d).longitude).remainder(dividingBy: 360) / meanSolarMotion
            d += step
            if abs(step) < 1e-8 { break }
        }
        return instant(d)
    }

    // MARK: 月亮

    /// `date` 這一刻的月相，以及同一個當地日曆日（`timeZone`）的月出月落。
    static func moon(at date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) -> FormlessMoonInfo {
        let d = dayNumber(date)
        let moon = moonPosition(d), sun = sunPosition(d)
        let phase = normalized(moon.longitude - sun.longitude) / 360
        // 照亮比例（Meeus 48.2、48.3）：由地心的月日角距求相位角。
        let elongation = acos(clamped(cos(moon.latitude * rad) * cos((moon.longitude - sun.longitude) * rad)))
        let phaseAngle = atan2(sun.distance * sin(elongation), moon.distance - sun.distance * cos(elongation))
        let index = phaseIndex(phase)
        let riseSet = moonRiseSet(in: localDay(containing: date, timeZone: timeZone), latitude: latitude, longitude: longitude)
        return FormlessMoonInfo(
            phase: phase, illumination: (1 + cos(phaseAngle)) / 2, age: d - lastNewMoon(atOrBefore: d),
            phaseName: phaseNames[index], symbolName: phaseSymbols[index],
            moonrise: riseSet.rise.map(instant), moonset: riseSet.set.map(instant))
    }

    /// `date` 之後（不含這一刻）第一次出現的月相。
    static func nextMoonPhase(_ phase: FormlessMoonPhaseEvent, after date: Date) -> Date {
        let offset = Double(FormlessMoonPhaseEvent.allCases.firstIndex(of: phase) ?? 0) / 4
        var k = ((dayNumber(date) - 5.09766) / synodicMonth).rounded(.down) + offset
        // 估計值和答案最多差一次（迴圈設上限，不合理的日期也不會卡住）；
        // 用 Date 比較，把上一次的結果傳回來時一定往下一次走。
        for _ in 0..<4 where instant(phaseDayNumber(k, phase)) <= date { k += 1 }
        for _ in 0..<4 where instant(phaseDayNumber(k - 1, phase)) > date { k -= 1 }
        return instant(phaseDayNumber(k, phase))
    }
}

// MARK: - 內部計算

private extension FormlessAstronomy {
    static let rad = Double.pi / 180
    /// 日出日落時太陽中心的幾何高度：折射 34′ 加太陽半徑 16′。
    static let horizon = -0.8333
    static let meanSolarMotion = 0.985_647_36
    static let synodicMonth = 29.530_588_861
    static let astronomicalUnit = 149_597_870.7
    static let earthRadius = 6378.14

    /// 天體的地心視位置（角度都是度）。
    struct Position {
        var longitude: Double
        var latitude: Double
        /// 距離（公里）。
        var distance: Double
        var rightAscension: Double
        var declination: Double
        /// 赤經章動（Δψ·cos ε），把平恆星時換成視恆星時用。
        var equationOfEquinoxes: Double
    }

    // MARK: 時間

    /// 從 J2000.0（2000-01-01 12:00 UT）起算的日數。
    static func dayNumber(_ date: Date) -> Double { (date.timeIntervalSince1970 - 946_728_000) / 86_400 }

    static func instant(_ d: Double) -> Date { Date(timeIntervalSince1970: d * 86_400 + 946_728_000) }

    /// 力學時的儒略世紀數（從 J2000.0 起算）。
    static func centuries(_ d: Double) -> Double { (d + deltaT(d) / 86_400) / 36_525 }

    /// ΔT＝TT − UT（秒）。1900–2025 年用每 5 年的觀測值內插，2025–2050 年平滑銜接到
    /// Espenak–Meeus 的預測，其餘年份用 Espenak–Meeus 的長期公式。
    static func deltaT(_ d: Double) -> Double {
        let year = 2000 + d / 365.25
        let u = (year - 1820) / 100
        switch year {
        case 1900..<2025:
            let x = (year - 1900) / 5
            let i = min(Int(x), deltaTTable.count - 2)
            return deltaTTable[i] + (deltaTTable[i + 1] - deltaTTable[i]) * (x - Double(i))
        case 2025..<2050:
            let s = (year - 2025) / 25
            return 69.10 + (93.0 - 69.10) * s * s
        case 2050..<2150:
            return -20 + 32 * u * u - 0.5628 * (2150 - year)
        default:
            return -20 + 32 * u * u
        }
    }

    /// 1900、1905…2025 年初的 ΔT（秒）。
    static let deltaTTable: [Double] = [
        -2.79, 3.86, 10.38, 17.20, 21.16, 23.62, 24.02, 23.93, 24.33, 26.77, 29.15, 31.07, 33.15,
        35.73, 40.18, 45.48, 50.54, 54.34, 56.86, 60.78, 63.83, 64.69, 66.07, 67.64, 69.36, 69.10,
    ]

    /// 含 `date` 的當地日曆日（開始、結束的日數）。
    static func localDay(containing date: Date, timeZone: TimeZone) -> (start: Double, end: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (dayNumber(start), dayNumber(end))
    }

    // MARK: 共用

    static func normalized(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let n = r < 0 ? r + 360 : r
        return n < 360 ? n : 0
    }

    static func clamped(_ x: Double) -> Double { min(1, max(-1, x)) }

    /// 在 [a, b] 內找 f 的根（f(a)、f(b) 必須異號），用改良試位法（Illinois），精確到約 0.01 秒。
    static func crossing(_ a: Double, _ b: Double, _ f: (Double) -> Double) -> Double {
        var a = a, b = b, fa = f(a), fb = f(b)
        var root = a, side = 0
        for _ in 0..<60 {
            let next = (a * fb - b * fa) / (fb - fa)
            if abs(next - root) < 1e-7 { return next }
            root = next
            let value = f(root)
            if value == 0 { return root }
            if (value > 0) == (fb > 0) {
                b = root; fb = value
                if side == -1 { fa /= 2 }
                side = -1
            } else {
                a = root; fa = value
                if side == 1 { fb /= 2 }
                side = 1
            }
        }
        return root
    }

    /// 章動（Meeus 第 22 章的簡化式，Δψ 誤差 0.5″）：黃經章動與真黃赤交角（度）。
    static func nutation(_ t: Double) -> (longitude: Double, obliquity: Double) {
        let omega = (125.04452 - 1934.136261 * t) * rad
        let sun = (280.4665 + 36000.7698 * t) * 2 * rad
        let moon = (218.3165 + 481267.8813 * t) * 2 * rad
        let dpsi = -17.20 * sin(omega) - 1.32 * sin(sun) - 0.23 * sin(moon) + 0.21 * sin(2 * omega)
        let deps = 9.20 * cos(omega) + 0.57 * cos(sun) + 0.10 * cos(moon) - 0.09 * cos(2 * omega)
        let mean = 84381.448 - 46.8150 * t - 0.00059 * t * t + 0.001813 * t * t * t
        return (dpsi / 3600, (mean + deps) / 3600)
    }

    /// 黃道座標（度，已含黃經章動）轉成地心視位置。
    static func position(longitude: Double, latitude: Double, distance: Double,
                         nutation n: (longitude: Double, obliquity: Double)) -> Position {
        let lambda = longitude * rad, beta = latitude * rad, epsilon = n.obliquity * rad
        let ra = atan2(sin(lambda) * cos(epsilon) - tan(beta) * sin(epsilon), cos(lambda)) / rad
        let dec = asin(clamped(sin(beta) * cos(epsilon) + cos(beta) * sin(epsilon) * sin(lambda))) / rad
        return Position(longitude: longitude, latitude: latitude, distance: distance,
                        rightAscension: normalized(ra), declination: dec,
                        equationOfEquinoxes: n.longitude * cos(epsilon))
    }

    /// 當地時角（度）：格林威治平恆星時（Meeus 12.4）加赤經章動、經度，減赤經。
    static func hourAngle(_ body: Position, at d: Double, longitude: Double) -> Double {
        let t = d / 36_525
        let gmst = 280.46061837 + 360.98564736629 * d + (0.000387933 - t / 38_710_000) * t * t
        return gmst + body.equationOfEquinoxes + longitude - body.rightAscension
    }

    /// 地心高度角（度，不含折射）。
    static func altitude(_ body: Position, at d: Double, latitude: Double, longitude: Double) -> Double {
        let h = hourAngle(body, at: d, longitude: longitude) * rad
        let phi = latitude * rad, dec = body.declination * rad
        return asin(clamped(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h))) / rad
    }

    /// 大氣折射（度），輸入幾何高度角；NOAA 太陽位置計算用的分段式。
    static func refraction(_ h: Double) -> Double {
        guard h <= 85 else { return 0 }
        let te = tan(h * rad)
        let arcseconds: Double
        if h > 5 {
            arcseconds = 58.1 / te - 0.07 / (te * te * te) + 0.000086 / pow(te, 5)
        } else if h > -0.575 {
            arcseconds = 1735 + h * (-518.2 + h * (103.4 + h * (-12.79 + h * 0.711)))
        } else {
            arcseconds = -20.772 / te
        }
        return arcseconds / 3600
    }

    // MARK: 太陽位置

    static func sunPosition(_ d: Double) -> Position {
        let t = centuries(d), tau = t / 10
        let l = vsop(earthL, tau), b = vsop(earthB, tau), r = vsop(earthR, tau)
        // 日心的地球 → 地心的太陽：黃經加 180°、黃緯變號；再加 FK5 修正、章動與光行差。
        let n = nutation(t)
        let correction = -0.09033 / 3600 + n.longitude - 20.4898 / 3600 / r
        return position(longitude: normalized(l / rad + 180 + correction), latitude: -b / rad,
                        distance: r * astronomicalUnit, nutation: n)
    }

    /// 太陽的站心高度角（度，不含折射）：地心高度減去視差（8.794″ ÷ 日地距離）。
    static func sunAltitude(_ d: Double, latitude: Double, longitude: Double) -> Double {
        let sun = sunPosition(d)
        let h = altitude(sun, at: d, latitude: latitude, longitude: longitude)
        return h - 8.794 / 3600 * astronomicalUnit / sun.distance * geocentricRadius(latitude) * cos(h * rad)
    }

    /// 觀測者到地心的距離（以赤道半徑為 1），修正地球扁率。
    static func geocentricRadius(_ latitude: Double) -> Double {
        0.99833 + 0.00167 * cos(2 * latitude * rad)
    }

    /// 當地日曆日內太陽過中天的時刻：從當天中間開始，用時角修正。
    static func solarNoon(in day: (start: Double, end: Double), longitude: Double) -> Double {
        var d = (day.start + day.end) / 2
        for _ in 0..<8 {
            let h = hourAngle(sunPosition(d), at: d, longitude: longitude).remainder(dividingBy: 360)
            d -= h / 360
            if abs(h) < 1e-5 { break }
        }
        return d
    }

    /// VSOP87 級數求和（弧度或 AU）；每組依序是 A、B、C：A·cos(B + C·τ)，τ 是儒略千年。
    static func vsop(_ series: [[Double]], _ tau: Double) -> Double {
        var total = 0.0, power = 1.0
        for terms in series {
            var sum = 0.0
            for i in stride(from: 0, to: terms.count, by: 3) {
                sum += terms[i] * cos(terms[i + 1] + terms[i + 2] * tau)
            }
            total += sum * power
            power *= tau
        }
        return total / 1e8
    }

    // MARK: 月亮位置

    static func moonPosition(_ d: Double) -> Position {
        let t = centuries(d), t2 = t * t, t3 = t2 * t, t4 = t3 * t
        let lp = 218.3164477 + 481267.88123421 * t - 0.0015786 * t2 + t3 / 538_841 - t4 / 65_194_000
        let dd = normalized(297.8501921 + 445267.1114034 * t - 0.0018819 * t2 + t3 / 545_868 - t4 / 113_065_000) * rad
        let m = normalized(357.5291092 + 35999.0502909 * t - 0.0001536 * t2 + t3 / 24_490_000) * rad
        let mp = normalized(134.9633964 + 477198.8675055 * t + 0.0087414 * t2 + t3 / 69_699 - t4 / 14_712_000) * rad
        let f = normalized(93.2720950 + 483202.0175233 * t - 0.0036539 * t2 - t3 / 3_526_000 + t4 / 863_310_000) * rad
        let e = 1 - 0.002516 * t - 0.0000074 * t2
        // 含太陽平近點角 M 的項要乘上 E（M 的倍數是 ±2 時乘 E²）。
        func factor(_ multiple: Double) -> Double { multiple == 0 ? 1 : abs(multiple) == 1 ? e : e * e }
        var sl = 0.0, sr = 0.0, sb = 0.0
        let lr = moonLR, b = moonB
        for i in stride(from: 0, to: lr.count, by: 6) {
            let angle = lr[i] * dd + lr[i + 1] * m + lr[i + 2] * mp + lr[i + 3] * f
            let k = factor(lr[i + 1])
            sl += lr[i + 4] * k * sin(angle)
            sr += lr[i + 5] * k * cos(angle)
        }
        for i in stride(from: 0, to: b.count, by: 5) {
            sb += b[i + 4] * factor(b[i + 1]) * sin(b[i] * dd + b[i + 1] * m + b[i + 2] * mp + b[i + 3] * f)
        }
        let a1 = (119.75 + 131.849 * t) * rad, a2 = (53.09 + 479264.290 * t) * rad, a3 = (313.45 + 481266.484 * t) * rad
        let lpr = lp * rad
        sl += 3958 * sin(a1) + 1962 * sin(lpr - f) + 318 * sin(a2)
        sb += -2235 * sin(lpr) + 382 * sin(a3) + 175 * sin(a1 - f) + 175 * sin(a1 + f)
        sb += 127 * sin(lpr - mp) - 115 * sin(lpr + mp)
        let n = nutation(t)
        return position(longitude: normalized(lp + sl / 1e6 + n.longitude), latitude: sb / 1e6,
                        distance: 385_000.56 + sr / 1000, nutation: n)
    }

    /// 當地日曆日內的月出、月落（日數）。每半小時取樣月亮高度，跨過地平線的那一段再求根。
    /// 以月亮上緣碰到地平線為準（折射 34′、月亮半徑、視差）：地心高度 = (ρ − 0.2725) × 地平視差 − 0.5667°
    /// （Meeus 第 15 章的 0.7275π − 34′，再用 ρ 修正地球扁率）。
    static func moonRiseSet(in day: (start: Double, end: Double), latitude: Double, longitude: Double) -> (rise: Double?, set: Double?) {
        let span = day.end - day.start
        guard span.isFinite, span > 0, span < 2 else { return (nil, nil) }
        let rho = geocentricRadius(latitude)
        func height(_ d: Double) -> Double {
            let moon = moonPosition(d)
            let parallax = asin(earthRadius / moon.distance) / rad
            return altitude(moon, at: d, latitude: latitude, longitude: longitude) - ((rho - 0.2725) * parallax - 0.5667)
        }
        var rise: Double?, set: Double?
        var t0 = day.start, h0 = height(t0)
        let steps = Int((span * 48).rounded(.up))
        for i in 1...steps {
            let t1 = min(day.start + Double(i) / 48, day.end), h1 = height(t1)
            if rise == nil, h0 < 0, h1 >= 0 { rise = crossing(t0, t1, height) }
            if set == nil, h0 >= 0, h1 < 0 { set = crossing(t0, t1, height) }
            t0 = t1
            h0 = h1
        }
        return (rise.flatMap { $0 < day.end ? $0 : nil }, set.flatMap { $0 < day.end ? $0 : nil })
    }

    // MARK: 月相

    static let phaseNames = ["新月", "眉月", "上弦月", "盈凸月", "滿月", "虧凸月", "下弦月", "殘月"]
    static let phaseSymbols = [
        "moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter", "moonphase.waxing.gibbous",
        "moonphase.full.moon", "moonphase.waning.gibbous", "moonphase.last.quarter", "moonphase.waning.crescent",
    ]

    /// 月相比例 → 名稱序號。四個主要月相只佔前後各約 1 天（比例 ±1/29.53，月亮移動快慢不同，
    /// 實際約 ±0.8～1.1 天），所以「滿月」只在接近滿月時出現；其餘時間是中間的四個月相。
    static func phaseIndex(_ phase: Double) -> Int {
        let window = 1 / synodicMonth
        guard phase.isFinite, phase >= window, phase <= 1 - window else { return 0 }
        for (i, center) in [0.25, 0.5, 0.75].enumerated() where abs(phase - center) < window { return 2 * (i + 1) }
        return 2 * min(3, Int(phase * 4)) + 1
    }

    /// 這一刻（含）以前最近一次新月的日數。
    static func lastNewMoon(atOrBefore d: Double) -> Double {
        var k = ((d - 5.09766) / synodicMonth).rounded(.down)
        for _ in 0..<4 where phaseDayNumber(k + 1, .new) <= d { k += 1 }
        for _ in 0..<4 where phaseDayNumber(k, .new) > d { k -= 1 }
        return phaseDayNumber(k, .new)
    }

    /// Meeus 第 49 章：第 k 次月相的時刻（日數，UT）。k 是整數加 0、0.25、0.5、0.75；k = 0 是 2000-01-06 的新月。
    static func phaseDayNumber(_ k: Double, _ phase: FormlessMoonPhaseEvent) -> Double {
        let t = k / 1236.85, t2 = t * t, t3 = t2 * t, t4 = t3 * t
        var jde = 2451550.09766 + synodicMonth * k + 0.00015437 * t2 - 0.000000150 * t3 + 0.00000000073 * t4
        let e = 1 - 0.002516 * t - 0.0000074 * t2
        let m = (2.5534 + 29.10535670 * k - 0.0000014 * t2 - 0.00000011 * t3) * rad
        let mp = (201.5643 + 385.81693528 * k + 0.0107582 * t2 + 0.00001238 * t3 - 0.000000058 * t4) * rad
        let f = (160.7108 + 390.67050284 * k - 0.0016118 * t2 - 0.00000227 * t3 + 0.000000011 * t4) * rad
        let omega = (124.7746 - 1.56375588 * k + 0.0020672 * t2 + 0.00000215 * t3) * rad
        let table: [Double]
        switch phase {
        case .new: table = newMoonTerms
        case .full: table = fullMoonTerms
        case .firstQuarter, .lastQuarter: table = quarterTerms
        }
        for row in stride(from: 0, to: table.count, by: 6) {
            let angle = table[row + 1] * m + table[row + 2] * mp + table[row + 3] * f + table[row + 4] * omega
            jde += table[row] * pow(e, table[row + 5]) * sin(angle)
        }
        if phase == .firstQuarter || phase == .lastQuarter {
            var w = 0.00306 - 0.00038 * e * cos(m) + 0.00026 * cos(mp)
            w += -0.00002 * cos(mp - m) + 0.00002 * cos(mp + m) + 0.00002 * cos(2 * f)
            jde += phase == .firstQuarter ? w : -w
        }
        for row in stride(from: 0, to: planetaryTerms.count, by: 3) {
            var angle = planetaryTerms[row + 1] + planetaryTerms[row + 2] * k
            if row == 0 { angle -= 0.009173 * t2 }
            jde += planetaryTerms[row] * sin(angle * rad)
        }
        let d = jde - 2_451_545
        return d - deltaT(d) / 86_400
    }

    // MARK: 表格

    /// Meeus 第 49 章新月的修正項。每列：係數、M、M′、F、Ω 的倍數、E 的次方。
    static let newMoonTerms: [Double] = [
        -0.40720, 0, 1, 0, 0, 0, 0.17241, 1, 0, 0, 0, 1, 0.01608, 0, 2, 0, 0, 0, 0.01039, 0, 0, 2, 0, 0,
        0.00739, -1, 1, 0, 0, 1, -0.00514, 1, 1, 0, 0, 1, 0.00208, 2, 0, 0, 0, 2, -0.00111, 0, 1, -2, 0, 0,
        -0.00057, 0, 1, 2, 0, 0, 0.00056, 1, 2, 0, 0, 1, -0.00042, 0, 3, 0, 0, 0, 0.00042, 1, 0, 2, 0, 1,
        0.00038, 1, 0, -2, 0, 1, -0.00024, -1, 2, 0, 0, 1, -0.00017, 0, 0, 0, 1, 0, -0.00007, 2, 1, 0, 0, 0,
        0.00004, 0, 2, -2, 0, 0, 0.00004, 3, 0, 0, 0, 0, 0.00003, 1, 1, -2, 0, 0, 0.00003, 0, 2, 2, 0, 0,
        -0.00003, 1, 1, 2, 0, 0, 0.00003, -1, 1, 2, 0, 0, -0.00002, -1, 1, -2, 0, 0, -0.00002, 1, 3, 0, 0, 0,
        0.00002, 0, 4, 0, 0, 0,
    ]

    /// Meeus 第 49 章滿月的修正項（排列同新月）。
    static let fullMoonTerms: [Double] = [
        -0.40614, 0, 1, 0, 0, 0, 0.17302, 1, 0, 0, 0, 1, 0.01614, 0, 2, 0, 0, 0, 0.01043, 0, 0, 2, 0, 0,
        0.00734, -1, 1, 0, 0, 1, -0.00515, 1, 1, 0, 0, 1, 0.00209, 2, 0, 0, 0, 2, -0.00111, 0, 1, -2, 0, 0,
        -0.00057, 0, 1, 2, 0, 0, 0.00056, 1, 2, 0, 0, 1, -0.00042, 0, 3, 0, 0, 0, 0.00042, 1, 0, 2, 0, 1,
        0.00038, 1, 0, -2, 0, 1, -0.00024, -1, 2, 0, 0, 1, -0.00017, 0, 0, 0, 1, 0, -0.00007, 2, 1, 0, 0, 0,
        0.00004, 0, 2, -2, 0, 0, 0.00004, 3, 0, 0, 0, 0, 0.00003, 1, 1, -2, 0, 0, 0.00003, 0, 2, 2, 0, 0,
        -0.00003, 1, 1, 2, 0, 0, 0.00003, -1, 1, 2, 0, 0, -0.00002, -1, 1, -2, 0, 0, -0.00002, 1, 3, 0, 0, 0,
        0.00002, 0, 4, 0, 0, 0,
    ]

    /// Meeus 第 49 章上弦、下弦的修正項（排列同新月）。
    static let quarterTerms: [Double] = [
        -0.62801, 0, 1, 0, 0, 0, 0.17172, 1, 0, 0, 0, 1, -0.01183, 1, 1, 0, 0, 1, 0.00862, 0, 2, 0, 0, 0,
        0.00804, 0, 0, 2, 0, 0, 0.00454, -1, 1, 0, 0, 1, 0.00204, 2, 0, 0, 0, 2, -0.00180, 0, 1, -2, 0, 0,
        -0.00070, 0, 1, 2, 0, 0, -0.00040, 0, 3, 0, 0, 0, -0.00034, -1, 2, 0, 0, 1, 0.00032, 1, 0, 2, 0, 1,
        0.00032, 1, 0, -2, 0, 1, -0.00028, 2, 1, 0, 0, 2, 0.00027, 1, 2, 0, 0, 1, -0.00017, 0, 0, 0, 1, 0,
        -0.00005, -1, 1, -2, 0, 0, 0.00004, 0, 2, 2, 0, 0, -0.00004, 1, 1, 2, 0, 0, 0.00004, -2, 1, 0, 0, 0,
        0.00003, 1, 1, -2, 0, 0, 0.00003, 3, 0, 0, 0, 0, 0.00002, 0, 2, -2, 0, 0, 0.00002, -1, 1, 2, 0, 0,
        -0.00002, 1, 3, 0, 0, 0,
    ]

    /// Meeus 第 49 章行星造成的修正（A1…A14）。每列：係數、起始角、每次月相增加的角度。
    static let planetaryTerms: [Double] = [
        0.000325, 299.77, 0.107408, 0.000165, 251.88, 0.016321, 0.000164, 251.83, 26.651886,
        0.000126, 349.42, 36.412478, 0.000110, 84.66, 18.206239, 0.000062, 141.74, 53.303771,
        0.000060, 207.14, 2.453732, 0.000056, 154.84, 7.306860, 0.000047, 34.52, 27.261239,
        0.000042, 207.19, 0.121824, 0.000040, 291.34, 1.844379, 0.000037, 161.72, 24.198154,
        0.000035, 239.56, 25.513099, 0.000023, 331.55, 3.592518,
    ]

    /// Meeus 表 47.A：月亮黃經（10⁻⁶ 度）與距離（10⁻³ 公里）。每列：D、M、M′、F 的倍數、黃經係數、距離係數。
    static let moonLR: [Double] = [
        0, 0, 1, 0, 6288774, -20905355, 2, 0, -1, 0, 1274027, -3699111, 2, 0, 0, 0, 658314, -2955968,
        0, 0, 2, 0, 213618, -569925, 0, 1, 0, 0, -185116, 48888, 0, 0, 0, 2, -114332, -3149,
        2, 0, -2, 0, 58793, 246158, 2, -1, -1, 0, 57066, -152138, 2, 0, 1, 0, 53322, -170733,
        2, -1, 0, 0, 45758, -204586, 0, 1, -1, 0, -40923, -129620, 1, 0, 0, 0, -34720, 108743,
        0, 1, 1, 0, -30383, 104755, 2, 0, 0, -2, 15327, 10321, 0, 0, 1, 2, -12528, 0,
        0, 0, 1, -2, 10980, 79661, 4, 0, -1, 0, 10675, -34782, 0, 0, 3, 0, 10034, -23210,
        4, 0, -2, 0, 8548, -21636, 2, 1, -1, 0, -7888, 24208, 2, 1, 0, 0, -6766, 30824,
        1, 0, -1, 0, -5163, -8379, 1, 1, 0, 0, 4987, -16675, 2, -1, 1, 0, 4036, -12831,
        2, 0, 2, 0, 3994, -10445, 4, 0, 0, 0, 3861, -11650, 2, 0, -3, 0, 3665, 14403,
        0, 1, -2, 0, -2689, -7003, 2, 0, -1, 2, -2602, 0, 2, -1, -2, 0, 2390, 10056,
        1, 0, 1, 0, -2348, 6322, 2, -2, 0, 0, 2236, -9884, 0, 1, 2, 0, -2120, 5751,
        0, 2, 0, 0, -2069, 0, 2, -2, -1, 0, 2048, -4950, 2, 0, 1, -2, -1773, 4130,
        2, 0, 0, 2, -1595, 0, 4, -1, -1, 0, 1215, -3958, 0, 0, 2, 2, -1110, 0,
        3, 0, -1, 0, -892, 3258, 2, 1, 1, 0, -810, 2616, 4, -1, -2, 0, 759, -1897,
        0, 2, -1, 0, -713, -2117, 2, 2, -1, 0, -700, 2354, 2, 1, -2, 0, 691, 0,
        2, -1, 0, -2, 596, 0, 4, 0, 1, 0, 549, -1423, 0, 0, 4, 0, 537, -1117,
        4, -1, 0, 0, 520, -1571, 1, 0, -2, 0, -487, -1739, 2, 1, 0, -2, -399, 0,
        0, 0, 2, -2, -381, -4421, 1, 1, 1, 0, 351, 0, 3, 0, -2, 0, -340, 0,
        4, 0, -3, 0, 330, 0, 2, -1, 2, 0, 327, 0, 0, 2, 1, 0, -323, 1165,
        1, 1, -1, 0, 299, 0, 2, 0, 3, 0, 294, 0, 2, 0, -1, -2, 0, 8752,
    ]

    /// Meeus 表 47.B：月亮黃緯（10⁻⁶ 度）。每列：D、M、M′、F 的倍數、係數。
    static let moonB: [Double] = [
        0, 0, 0, 1, 5128122, 0, 0, 1, 1, 280602, 0, 0, 1, -1, 277693, 2, 0, 0, -1, 173237,
        2, 0, -1, 1, 55413, 2, 0, -1, -1, 46271, 2, 0, 0, 1, 32573, 0, 0, 2, 1, 17198,
        2, 0, 1, -1, 9266, 0, 0, 2, -1, 8822, 2, -1, 0, -1, 8216, 2, 0, -2, -1, 4324,
        2, 0, 1, 1, 4200, 2, 1, 0, -1, -3359, 2, -1, -1, 1, 2463, 2, -1, 0, 1, 2211,
        2, -1, -1, -1, 2065, 0, 1, -1, -1, -1870, 4, 0, -1, -1, 1828, 0, 1, 0, 1, -1794,
        0, 0, 0, 3, -1749, 0, 1, -1, 1, -1565, 1, 0, 0, 1, -1491, 0, 1, 1, 1, -1475,
        0, 1, 1, -1, -1410, 0, 1, 0, -1, -1344, 1, 0, 0, -1, -1335, 0, 0, 3, 1, 1107,
        4, 0, 0, -1, 1021, 4, 0, -1, 1, 833, 0, 0, 1, -3, 777, 4, 0, -2, 1, 671,
        2, 0, 0, -3, 607, 2, 0, 2, -1, 596, 2, -1, 1, -1, 491, 2, 0, -2, 1, -451,
        0, 0, 3, -1, 439, 2, 0, 2, 1, 422, 2, 0, -3, -1, 421, 2, 1, -1, 1, -366,
        2, 1, 0, 1, -351, 4, 0, 0, 1, 331, 2, -1, 1, 1, 315, 2, -2, 0, -1, 302,
        0, 0, 1, 3, -283, 2, 1, 1, -1, -229, 1, 1, 0, -1, 223, 1, 1, 0, 1, 223,
        0, 1, -2, -1, -220, 2, 1, -1, -1, -220, 1, 0, 1, 1, -185, 2, -1, -2, -1, 181,
        0, 1, 2, 1, -177, 4, 0, -2, -1, 176, 4, -1, -1, -1, 166, 1, 0, 1, -1, -164,
        4, 0, 1, -1, 132, 1, 0, -1, -1, -119, 4, -1, 0, -1, 115, 2, -2, 0, 1, 107,
    ]

    /// VSOP87 地球日心黃經 L0…L5（Meeus 附錄三）。
    static let earthL: [[Double]] = [
        [175347046, 0, 0, 3341656, 4.6692568, 6283.07585, 34894, 4.6261, 12566.1517, 3497, 2.7441, 5753.3849,
         3418, 2.8289, 3.5231, 3136, 3.6277, 77713.7715, 2676, 4.4181, 7860.4194, 2343, 6.1352, 3930.2097,
         1324, 0.7425, 11506.7698, 1273, 2.0371, 529.691, 1199, 1.1096, 1577.3435, 990, 5.233, 5884.927,
         902, 2.045, 26.298, 857, 3.508, 398.149, 780, 1.179, 5223.694, 753, 2.533, 5507.553,
         505, 4.583, 18849.228, 492, 4.205, 775.523, 357, 2.92, 0.067, 317, 5.849, 11790.629,
         284, 1.899, 796.298, 271, 0.315, 10977.079, 243, 0.345, 5486.778, 206, 4.806, 2544.314,
         205, 1.869, 5573.143, 202, 2.458, 6069.777, 156, 0.833, 213.299, 132, 3.411, 2942.463,
         126, 1.083, 20.775, 115, 0.645, 0.98, 103, 0.636, 4694.003, 102, 0.976, 15720.839,
         102, 4.267, 7.114, 99, 6.21, 2146.17, 98, 0.68, 155.42, 86, 5.98, 161000.69,
         85, 1.3, 6275.96, 85, 3.67, 71430.7, 80, 1.81, 17260.15, 79, 3.04, 12036.46,
         75, 1.76, 5088.63, 74, 3.5, 3154.69, 74, 4.68, 801.82, 70, 0.83, 9437.76,
         62, 3.98, 8827.39, 61, 1.82, 7084.9, 57, 2.78, 6286.6, 56, 4.39, 14143.5,
         56, 3.47, 6279.55, 52, 0.19, 12139.55, 52, 1.33, 1748.02, 51, 0.28, 5856.48,
         49, 0.49, 1194.45, 41, 5.37, 8429.24, 41, 2.4, 19651.05, 39, 6.17, 10447.39,
         37, 6.04, 10213.29, 37, 2.57, 1059.38, 36, 1.71, 2352.87, 36, 1.78, 6812.77,
         33, 0.59, 17789.85, 30, 0.44, 83996.85, 30, 2.74, 1349.87, 25, 3.16, 4690.48],
        [628331966747, 0, 0, 206059, 2.678235, 6283.07585, 4303, 2.6351, 12566.1517, 425, 1.59, 3.523,
         119, 5.796, 26.298, 109, 2.966, 1577.344, 93, 2.59, 18849.23, 72, 1.14, 529.69,
         68, 1.87, 398.15, 67, 4.41, 5507.55, 59, 2.89, 5223.69, 56, 2.17, 155.42,
         45, 0.4, 796.3, 36, 0.47, 775.52, 29, 2.65, 7.11, 21, 5.34, 0.98,
         19, 1.85, 5486.78, 19, 4.97, 213.3, 17, 2.99, 6275.96, 16, 0.03, 2544.31,
         16, 1.43, 2146.17, 15, 1.21, 10977.08, 12, 2.83, 1748.02, 12, 3.26, 5088.63,
         12, 5.27, 1194.45, 12, 2.08, 4694, 11, 0.77, 553.57, 10, 1.3, 6286.6,
         10, 4.24, 1349.87, 9, 2.7, 242.73, 9, 5.64, 951.72, 8, 5.3, 2352.87,
         6, 2.65, 9437.76, 6, 4.67, 4690.48],
        [52919, 0, 0, 8720, 1.0721, 6283.0758, 309, 0.867, 12566.152, 27, 0.05, 3.52,
         16, 5.19, 26.3, 16, 3.68, 155.42, 10, 0.76, 18849.23, 9, 2.06, 77713.77,
         7, 0.83, 775.52, 5, 4.66, 1577.34, 4, 1.03, 7.11, 4, 3.44, 5573.14,
         3, 5.14, 796.3, 3, 6.05, 5507.55, 3, 1.19, 242.73, 3, 6.12, 529.69,
         3, 0.31, 398.15, 3, 2.28, 553.57, 2, 4.38, 5223.69, 2, 3.75, 0.98],
        [289, 5.844, 6283.076, 35, 0, 0, 17, 5.49, 12566.15, 3, 5.2, 155.42,
         1, 4.72, 3.52, 1, 5.3, 18849.23, 1, 5.97, 242.73],
        [114, 3.142, 0, 8, 4.13, 6283.08, 1, 3.84, 12566.15],
        [1, 3.14, 0],
    ]

    /// VSOP87 地球日心黃緯 B0、B1。
    static let earthB: [[Double]] = [
        [280, 3.199, 84334.662, 102, 5.422, 5507.553, 80, 3.88, 5223.69, 44, 3.7, 2352.87, 32, 4, 1577.34],
        [9, 3.9, 5507.55, 6, 1.73, 5223.69],
    ]

    /// VSOP87 日地距離 R0…R4（AU）。
    static let earthR: [[Double]] = [
        [100013989, 0, 0, 1670700, 3.0984635, 6283.07585, 13956, 3.05525, 12566.1517, 3084, 5.1985, 77713.7715,
         1628, 1.1739, 5753.3849, 1576, 2.8469, 7860.4194, 925, 5.453, 11506.77, 542, 4.564, 3930.21,
         472, 3.661, 5884.927, 346, 0.964, 5507.553, 329, 5.9, 5223.694, 307, 0.299, 5573.143,
         243, 4.273, 11790.629, 212, 5.847, 1577.344, 186, 5.022, 10977.079, 175, 3.012, 18849.228,
         110, 5.055, 5486.778, 98, 0.89, 6069.78, 86, 5.69, 15720.84, 86, 1.27, 161000.69,
         65, 0.27, 17260.15, 63, 0.92, 529.69, 57, 2.01, 83996.85, 56, 5.24, 71430.7,
         49, 3.25, 2544.31, 47, 2.58, 775.52, 45, 5.54, 9437.76, 43, 6.01, 6275.96,
         39, 5.36, 4694, 38, 2.39, 8827.39, 37, 0.83, 19651.05, 37, 4.9, 12139.55,
         36, 1.67, 12036.46, 35, 1.84, 2942.46, 33, 0.24, 7084.9, 32, 0.18, 5088.63,
         32, 1.78, 398.15, 28, 1.21, 6286.6, 28, 1.9, 6279.55, 26, 4.59, 10447.39],
        [103019, 1.10749, 6283.07585, 1721, 1.0644, 12566.1517, 702, 3.142, 0, 32, 1.02, 18849.23,
         31, 2.84, 5507.55, 25, 1.32, 5223.69, 18, 1.42, 1577.34, 10, 5.91, 10977.08,
         9, 1.42, 6275.96, 9, 0.27, 5486.78],
        [4359, 5.7846, 6283.0758, 124, 5.579, 12566.152, 12, 3.14, 0, 9, 3.63, 77713.77,
         6, 1.87, 5573.14, 3, 5.47, 18849.23],
        [145, 4.273, 6283.076, 7, 3.92, 12566.15],
        [4, 2.56, 6283.08],
    ]
}
