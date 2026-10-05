import Foundation

// MARK: - Open-Meteo 天氣預報與空氣品質
//
// 新資料系統用：組網址、抓取，並把回應解析成 FormlessForecast／FormlessAirQuality。
// 舊的 FormlessWeatherProvider.fetch（FormlessShared.swift）照舊運作，這個檔不碰它。
//
// 時間：API 的時間是地點當地的時間字串（「2026-10-04T15:00」「2026-10-04」），不帶時區。
// 一律把字串當 UTC 讀，再減去回應裡的 utc_offset_seconds，換成絕對時間。
// 一份回應只有一個 utc_offset_seconds，預報期間跨過夏令時間也不變，API 整份的時間都照它排，
// 所以全部用它換算才前後一致。要顯示地點當地的鐘點，用 TimeZone(secondsFromGMT: utcOffsetSeconds)。
//
// 寬鬆解析：選填欄位整欄缺少、某一格是 null、型別不對，都當成沒有值，不讓整份解析失敗；
// 缺少 current、daily 這類必要資料才丟出錯誤。

/// 天氣預報：目前、逐時、每日。溫度 °C、風速 km/h、降水 mm。
struct FormlessForecast: Codable, Hashable, Sendable {

    /// 目前天氣。
    struct Current: Codable, Hashable, Sendable {
        /// 資料的時間（API 每 15 分鐘一筆）
        var time: Date
        var temperature: Double            // °C
        var apparentTemperature: Double?   // 體感溫度 °C
        var humidity: Double?              // 相對濕度 %
        var dewPoint: Double?              // 露點 °C
        var pressure: Double?              // 海平面氣壓 hPa（pressure_msl）
        var visibility: Double?            // 能見度，公尺
        var cloudCover: Double?            // 雲量 %
        var windSpeed: Double?             // 風速 km/h
        var windGusts: Double?             // 陣風 km/h
        var windDirection: Double?         // 風向：風吹來的方向，度（0 北、90 東）
        var uvIndex: Double?               // 紫外線指數
        var precipitation: Double?         // 降水量 mm
        var weatherCode: Int               // WMO 天氣代碼
        var isDay: Bool
    }

    /// 逐時預報的一個鐘點。
    struct Hour: Codable, Hashable, Sendable {
        /// 這個鐘點的開始
        var time: Date
        var temperature: Double
        var apparentTemperature: Double?
        var precipitationProbability: Double?   // 降雨機率 %
        var precipitation: Double?              // 這一小時的降水量 mm
        var weatherCode: Int
        var isDay: Bool
        var windSpeed: Double?
        var uvIndex: Double?
        var humidity: Double?
    }

    /// 每日預報的一天。
    struct Day: Codable, Hashable, Sendable {
        var date: Date                 // 地點當地那一天的午夜（絕對時間）
        var weatherCode: Int
        var high: Double
        var low: Double
        var mean: Double?
        var apparentHigh: Double?
        var apparentLow: Double?
        var precipitationProbability: Double?   // 當天最高的降雨機率 %
        var precipitationSum: Double?           // 當天總降水量 mm
        var sunrise: Date?
        var sunset: Date?
        var uvIndexMax: Double?
        var windSpeedMax: Double?
        var windDirection: Double?              // 當天主要風向，度
        var daylightDuration: Double?           // 日照長度（日出到日落），秒
    }

    /// API 回傳的格點座標，和要求的座標可能差幾公里
    var latitude: Double
    var longitude: Double
    var timeZone: String           // 例如 "Asia/Taipei"
    var utcOffsetSeconds: Int
    var current: Current
    var hourly: [Hour]             // 從現在這個鐘點起，最多 48 筆
    var daily: [Day]               // 第一筆是今天
}

/// 空氣品質：目前與未來 24 小時。是全球模型的推估值，不是測站實測。
struct FormlessAirQuality: Codable, Hashable, Sendable {

    /// 逐時預報的一個鐘點。
    struct Hour: Codable, Hashable, Sendable {
        var time: Date
        var usAQI: Double?
        var europeanAQI: Double?
        var pm25: Double?
    }

    var time: Date
    var usAQI: Double?             // 美國 AQI
    var europeanAQI: Double?       // 歐洲 AQI
    var pm25: Double?              // µg/m³
    var pm10: Double?              // µg/m³
    var ozone: Double?             // 臭氧 µg/m³
    var nitrogenDioxide: Double?   // 二氧化氮 µg/m³
    var sulphurDioxide: Double?    // 二氧化硫 µg/m³
    var carbonMonoxide: Double?    // 一氧化碳 µg/m³
    /// 花粉（粒／m³），只有歐洲有資料。鍵：alder、birch、grass、mugwort、olive、ragweed；null 的不放。
    var pollen: [String: Double]
    var hourly: [Hour]             // 從現在這個鐘點起的 24 小時
}

/// Open-Meteo 抓取或解析失敗的原因。網路本身的錯誤（離線、逾時、取消）照原樣丟出 URLError。
enum FormlessOpenMeteoError: Error, LocalizedError, Hashable, Sendable {
    /// 伺服器回應不是 2xx；reason 是 API 說明的原因（例如座標超出範圍、超過呼叫次數）
    case http(status: Int, reason: String?)
    /// 回應是 {"error": true, "reason": …}
    case api(reason: String)
    /// 回應不是 JSON 物件
    case invalidResponse
    /// 缺少必要的資料，例如 "current"、"daily.time"
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let reason):
            return "Open-Meteo 回應錯誤（HTTP \(status)）" + (reason.map { "：" + $0 } ?? "")
        case .api(let reason):
            return "Open-Meteo 回報錯誤：" + reason
        case .invalidResponse:
            return "Open-Meteo 的回應不是有效的 JSON"
        case .missing(let field):
            return "Open-Meteo 的回應缺少 " + field
        }
    }
}

enum FormlessOpenMeteo {

    // MARK: 網址

    private static let forecastEndpoint = URL(string: "https://api.open-meteo.com/v1/forecast")!
    private static let airQualityEndpoint = URL(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!

    // 欄位名稱都對過線上 API（名稱錯誤時 API 回 HTTP 400）。
    private static let forecastCurrent = [
        "temperature_2m", "apparent_temperature", "relative_humidity_2m", "dew_point_2m", "pressure_msl",
        "visibility", "cloud_cover", "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m", "uv_index",
        "precipitation", "weather_code", "is_day"
    ]
    private static let forecastHourly = [
        "temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation", "weather_code",
        "is_day", "wind_speed_10m", "uv_index", "relative_humidity_2m"
    ]
    private static let forecastDaily = [
        "weather_code", "temperature_2m_max", "temperature_2m_min", "temperature_2m_mean",
        "apparent_temperature_max", "apparent_temperature_min", "precipitation_probability_max",
        "precipitation_sum", "sunrise", "sunset", "uv_index_max", "wind_speed_10m_max",
        "wind_direction_10m_dominant", "daylight_duration"
    ]
    /// 花粉種類：API 的欄位是「種類_pollen」，FormlessAirQuality.pollen 的鍵是種類
    private static let pollenKinds = ["alder", "birch", "grass", "mugwort", "olive", "ragweed"]
    private static let airCurrent = [
        "us_aqi", "european_aqi", "pm2_5", "pm10", "ozone", "nitrogen_dioxide", "sulphur_dioxide", "carbon_monoxide"
    ] + pollenKinds.map { $0 + "_pollen" }
    private static let airHourly = ["us_aqi", "european_aqi", "pm2_5"]

    /// 預報網址。days 是預報天數（含今天），超出 API 允許的 1–16 天時取最接近的一端。
    static func forecastURL(latitude: Double, longitude: Double, days: Int = 7) -> URL {
        forecastEndpoint.appending(queryItems: [
            URLQueryItem(name: "latitude", value: coordinateText(latitude)),
            URLQueryItem(name: "longitude", value: coordinateText(longitude)),
            URLQueryItem(name: "current", value: forecastCurrent.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: forecastHourly.joined(separator: ",")),
            URLQueryItem(name: "daily", value: forecastDaily.joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(min(max(days, 1), 16)))
        ])
    }

    /// 空氣品質網址。逐時抓兩天，深夜時從現在這個鐘點起的 24 小時也還夠。
    static func airQualityURL(latitude: Double, longitude: Double) -> URL {
        airQualityEndpoint.appending(queryItems: [
            URLQueryItem(name: "latitude", value: coordinateText(latitude)),
            URLQueryItem(name: "longitude", value: coordinateText(longitude)),
            URLQueryItem(name: "current", value: airCurrent.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: airHourly.joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ])
    }

    /// 座標取到小數四位（約 10 公尺），固定用小數點，不受語系影響
    private static func coordinateText(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    // MARK: 抓取

    /// 抓預報並解析。網路錯誤照原樣丟出；伺服器或資料的問題丟出 FormlessOpenMeteoError。
    static func fetchForecast(latitude: Double, longitude: Double, days: Int = 7,
                              session: URLSession = .shared) async throws -> FormlessForecast {
        let url = forecastURL(latitude: latitude, longitude: longitude, days: days)
        return try parseForecast(await download(url, session: session))
    }

    /// 抓空氣品質並解析。網路錯誤照原樣丟出；伺服器或資料的問題丟出 FormlessOpenMeteoError。
    static func fetchAirQuality(latitude: Double, longitude: Double,
                                session: URLSession = .shared) async throws -> FormlessAirQuality {
        let url = airQualityURL(latitude: latitude, longitude: longitude)
        return try parseAirQuality(await download(url, session: session))
    }

    private static func download(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let reason = (try? JSONDecoder().decode(Payload.self, from: data))?.reason
            throw FormlessOpenMeteoError.http(status: http.statusCode, reason: reason)
        }
        return data
    }

    // MARK: 解析

    /// 解析預報。now 決定逐時從哪個鐘點、每日從哪一天開始（測試時可以指定）。
    static func parseForecast(_ data: Data, now: Date = Date()) throws -> FormlessForecast {
        let payload = try Payload.decode(data)
        guard let current = payload.current else { throw FormlessOpenMeteoError.missing("current") }
        guard let daily = payload.daily else { throw FormlessOpenMeteoError.missing("daily") }
        guard let latitude = payload.latitude, let longitude = payload.longitude else {
            throw FormlessOpenMeteoError.missing("latitude／longitude")
        }
        let offset = payload.utcOffset(at: now)

        // 每日：天氣代碼或最高、最低溫是 null 的那天略過
        let dayTable = Table(columns: daily)
        for key in ["time", "weather_code", "temperature_2m_max", "temperature_2m_min"] where !dayTable.has(key) {
            throw FormlessOpenMeteoError.missing("daily." + key)
        }
        var days: [FormlessForecast.Day] = []
        for row in 0..<dayTable.count {
            guard let date = instant(dayTable.text("time", row), offset: offset),
                  let code = dayTable.code("weather_code", row),
                  let high = dayTable.number("temperature_2m_max", row),
                  let low = dayTable.number("temperature_2m_min", row) else { continue }
            days.append(FormlessForecast.Day(
                date: date,
                weatherCode: code,
                high: high,
                low: low,
                mean: dayTable.number("temperature_2m_mean", row),
                apparentHigh: dayTable.number("apparent_temperature_max", row),
                apparentLow: dayTable.number("apparent_temperature_min", row),
                precipitationProbability: dayTable.number("precipitation_probability_max", row),
                precipitationSum: dayTable.number("precipitation_sum", row),
                sunrise: instant(dayTable.text("sunrise", row), offset: offset),
                sunset: instant(dayTable.text("sunset", row), offset: offset),
                uvIndexMax: dayTable.number("uv_index_max", row),
                windSpeedMax: dayTable.number("wind_speed_10m_max", row),
                windDirection: dayTable.number("wind_direction_10m_dominant", row),
                daylightDuration: dayTable.number("daylight_duration", row)
            ))
        }

        // 目前
        guard let time = instant(current["time"]?.text, offset: offset) else {
            throw FormlessOpenMeteoError.missing("current.time")
        }
        guard let temperature = current["temperature_2m"]?.number else {
            throw FormlessOpenMeteoError.missing("current.temperature_2m")
        }
        guard let weatherCode = current["weather_code"]?.code else {
            throw FormlessOpenMeteoError.missing("current.weather_code")
        }
        let currentWeather = FormlessForecast.Current(
            time: time,
            temperature: temperature,
            apparentTemperature: current["apparent_temperature"]?.number,
            humidity: current["relative_humidity_2m"]?.number,
            dewPoint: current["dew_point_2m"]?.number,
            pressure: current["pressure_msl"]?.number,
            visibility: current["visibility"]?.number,
            cloudCover: current["cloud_cover"]?.number,
            windSpeed: current["wind_speed_10m"]?.number,
            windGusts: current["wind_gusts_10m"]?.number,
            windDirection: current["wind_direction_10m"]?.number,
            uvIndex: current["uv_index"]?.number,
            precipitation: current["precipitation"]?.number,
            weatherCode: weatherCode,
            isDay: current["is_day"]?.number.map { $0 != 0 } ?? isDaytime(time, days: days, offset: offset)
        )

        // 逐時：從地點當地現在這個鐘點起，最多 48 筆；溫度或天氣代碼是 null 的鐘點略過
        let hourTable = Table(columns: payload.hourly ?? [:])
        let start = hourStart(now, offset: offset)
        var hours: [FormlessForecast.Hour] = []
        for row in 0..<hourTable.count {
            if hours.count == 48 { break }
            guard let hourTime = instant(hourTable.text("time", row), offset: offset), hourTime >= start,
                  let hourTemperature = hourTable.number("temperature_2m", row),
                  let hourCode = hourTable.code("weather_code", row) else { continue }
            hours.append(FormlessForecast.Hour(
                time: hourTime,
                temperature: hourTemperature,
                apparentTemperature: hourTable.number("apparent_temperature", row),
                precipitationProbability: hourTable.number("precipitation_probability", row),
                precipitation: hourTable.number("precipitation", row),
                weatherCode: hourCode,
                isDay: hourTable.number("is_day", row).map { $0 != 0 }
                    ?? isDaytime(hourTime, days: days, offset: offset),
                windSpeed: hourTable.number("wind_speed_10m", row),
                uvIndex: hourTable.number("uv_index", row),
                humidity: hourTable.number("relative_humidity_2m", row)
            ))
        }

        return FormlessForecast(
            latitude: latitude,
            longitude: longitude,
            timeZone: payload.timeZone ?? TimeZone(secondsFromGMT: offset)?.identifier ?? "GMT",
            utcOffsetSeconds: offset,
            current: currentWeather,
            hourly: hours,
            // 已經過完的日子不放，第一筆是今天
            daily: days.filter { $0.date.addingTimeInterval(86_400) > now }
        )
    }

    /// 解析空氣品質。now 決定逐時從哪個鐘點開始（測試時可以指定）。
    static func parseAirQuality(_ data: Data, now: Date = Date()) throws -> FormlessAirQuality {
        let payload = try Payload.decode(data)
        guard let current = payload.current else { throw FormlessOpenMeteoError.missing("current") }
        let offset = payload.utcOffset(at: now)
        guard let time = instant(current["time"]?.text, offset: offset) else {
            throw FormlessOpenMeteoError.missing("current.time")
        }

        var pollen: [String: Double] = [:]
        for kind in pollenKinds {
            if let value = current[kind + "_pollen"]?.number { pollen[kind] = value }
        }

        // 逐時：從地點當地現在這個鐘點起的 24 筆
        let table = Table(columns: payload.hourly ?? [:])
        let start = hourStart(now, offset: offset)
        var hours: [FormlessAirQuality.Hour] = []
        for row in 0..<table.count {
            if hours.count == 24 { break }
            guard let hourTime = instant(table.text("time", row), offset: offset), hourTime >= start else { continue }
            hours.append(FormlessAirQuality.Hour(
                time: hourTime,
                usAQI: table.number("us_aqi", row),
                europeanAQI: table.number("european_aqi", row),
                pm25: table.number("pm2_5", row)
            ))
        }

        return FormlessAirQuality(
            time: time,
            usAQI: current["us_aqi"]?.number,
            europeanAQI: current["european_aqi"]?.number,
            pm25: current["pm2_5"]?.number,
            pm10: current["pm10"]?.number,
            ozone: current["ozone"]?.number,
            nitrogenDioxide: current["nitrogen_dioxide"]?.number,
            sulphurDioxide: current["sulphur_dioxide"]?.number,
            carbonMonoxide: current["carbon_monoxide"]?.number,
            pollen: pollen,
            hourly: hours
        )
    }

    // MARK: 天氣狀態與 AQI 分級

    /// WMO 天氣代碼 → 繁中天氣狀態，白天晚上同一個字。0、1、2 沿用 App 原本的用語（晴、局部多雲、多雲）。
    static func conditionText(code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "局部多雲"
        case 2: return "多雲"
        case 3: return "陰"
        case 45, 48: return "霧"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "凍毛毛雨"
        case 61: return "小雨"
        case 63: return "雨"
        case 65: return "大雨"
        case 66, 67: return "凍雨"
        case 71: return "小雪"
        case 73: return "雪"
        case 75: return "大雪"
        case 77: return "米雪"
        case 80, 81: return "陣雨"
        case 82: return "大陣雨"
        case 85: return "陣雪"
        case 86: return "大陣雪"
        case 95: return "雷雨"
        case 96, 99: return "雷雨冰雹"
        default: return "未知"
        }
    }

    /// WMO 天氣代碼 → SF Symbol。晴、多雲、陣雨分白天和晚上。
    static func symbolName(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "questionmark.circle.fill"
        }
    }

    /// 美國 AQI 分級（先四捨五入到整數再分級）。
    static func aqiCategory(usAQI: Double) -> String {
        guard !usAQI.isNaN else { return "未知" }
        switch usAQI.rounded() {
        case ...50: return "良好"
        case ...100: return "普通"
        case ...150: return "對敏感族群不健康"
        case ...200: return "對所有族群不健康"
        case ...300: return "非常不健康"
        default: return "危害"
        }
    }

    // MARK: 時間

    /// 當地時間字串 → 絕對時間：把字串當 UTC 讀，再減去 utc_offset_seconds
    private static func instant(_ text: String?, offset: Int) -> Date? {
        guard let text, let seconds = localSeconds(text) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds - offset))
    }

    /// 「2026-10-04」「2026-10-04T15:00」「2026-10-04T15:00:00」→ 當成 UTC 時從 1970-01-01 起的秒數。
    /// 自己拆數字、不用 DateFormatter：快，也不受語系與曆法設定影響。
    private static func localSeconds(_ text: String) -> Int? {
        var numbers: [Int] = []
        var separators: [UInt8] = []
        var value = 0
        var digits = 0
        for byte in text.utf8 {
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                guard digits < 4 else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
                digits += 1
            } else {
                guard digits > 0 else { return nil }
                numbers.append(value)
                separators.append(byte)
                value = 0
                digits = 0
            }
        }
        guard digits > 0 else { return nil }
        numbers.append(value)

        // 只接受 年-月-日、年-月-日T時:分、年-月-日T時:分:秒
        guard [3, 5, 6].contains(numbers.count),
              separators == Array("--T::".utf8.prefix(separators.count)) else { return nil }
        let hour = numbers.count > 3 ? numbers[3] : 0
        let minute = numbers.count > 4 ? numbers[4] : 0
        let second = numbers.count > 5 ? numbers[5] : 0
        guard (1...12).contains(numbers[1]), (1...31).contains(numbers[2]), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let days = daysSince1970(year: numbers[0], month: numbers[1], day: numbers[2])
        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }

    /// 西元日期 → 從 1970-01-01 起的天數（Howard Hinnant 的 days_from_civil 演算法）
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year           // 把 1、2 月算成前一年的最後兩個月
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1   // 從 3 月 1 日起算
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// 地點當地現在這個鐘點的開始。照當地時間對齊，所以印度、尼泊爾這類差半點或 45 分的時區也對。
    private static func hourStart(_ now: Date, offset: Int) -> Date {
        let local = now.timeIntervalSince1970 + Double(offset)
        return Date(timeIntervalSince1970: (local / 3_600).rounded(.down) * 3_600 - Double(offset))
    }

    /// is_day 缺值時的備援：落在當天日出與日落之間算白天；那天沒有日出日落時，當地 6 點到 18 點算白天
    private static func isDaytime(_ time: Date, days: [FormlessForecast.Day], offset: Int) -> Bool {
        if let day = days.first(where: { time >= $0.date && time < $0.date.addingTimeInterval(86_400) }),
           let sunrise = day.sunrise, let sunset = day.sunset {
            return time >= sunrise && time < sunset
        }
        let seconds = Int(time.timeIntervalSince1970.rounded(.down)) + offset
        let hour = (seconds % 86_400 + 86_400) % 86_400 / 3_600
        return (6..<18).contains(hour)
    }

    // MARK: JSON

    /// JSON 裡的一個值。型別不對（例如物件、陣列）一律當成 null，不讓整份解析失敗。
    private enum JSONValue: Decodable {
        case number(Double)
        case text(String)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .text(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .number(value ? 1 : 0)
            } else {
                self = .null
            }
        }

        /// 數字；寫成文字的數字也接受。NaN、無限大不算（JSONEncoder 存不了）。
        var number: Double? {
            let value: Double?
            switch self {
            case .number(let number): value = number
            case .text(let text): value = Double(text.trimmingCharacters(in: .whitespaces))
            case .null: value = nil
            }
            guard let value, value.isFinite else { return nil }
            return value
        }

        var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        /// 整數（天氣代碼、時差秒數）
        var code: Int? {
            number.flatMap { Int(exactly: $0.rounded()) }
        }
    }

    /// 逐時或每日的一欄。不是陣列時當成空的。
    private struct Column: Decodable {
        var values: [JSONValue]

        init(from decoder: Decoder) throws {
            values = (try? [JSONValue](from: decoder)) ?? []
        }
    }

    /// 回應的最外層。每一項各自寬鬆地解，缺少或型別不對就是 nil。
    private struct Payload: Decodable {
        var latitude: Double?
        var longitude: Double?
        var timeZone: String?
        var utcOffsetSeconds: Int?
        var isError = false
        var reason: String?
        var current: [String: JSONValue]?
        var hourly: [String: [JSONValue]]?
        var daily: [String: [JSONValue]]?

        private enum Key: String, CodingKey {
            case latitude, longitude, timezone, error, reason, current, hourly, daily
            case utcOffsetSeconds = "utc_offset_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            func value(_ key: Key) -> JSONValue? {
                try? container.decodeIfPresent(JSONValue.self, forKey: key)
            }
            latitude = value(.latitude)?.number
            longitude = value(.longitude)?.number
            timeZone = value(.timezone)?.text
            utcOffsetSeconds = value(.utcOffsetSeconds)?.code
            isError = (value(.error)?.number ?? 0) != 0
            reason = value(.reason)?.text
            current = try? container.decodeIfPresent([String: JSONValue].self, forKey: .current)
            hourly = (try? container.decodeIfPresent([String: Column].self, forKey: .hourly))?.mapValues(\.values)
            daily = (try? container.decodeIfPresent([String: Column].self, forKey: .daily))?.mapValues(\.values)
        }

        /// 解出最外層：不是 JSON 物件丟出 invalidResponse，API 回報錯誤丟出 api(reason:)
        static func decode(_ data: Data) throws -> Payload {
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                throw FormlessOpenMeteoError.invalidResponse
            }
            if payload.isError { throw FormlessOpenMeteoError.api(reason: payload.reason ?? "") }
            return payload
        }

        /// 時差：回應的 utc_offset_seconds；沒有就用 timezone 推算，再沒有就當 UTC
        func utcOffset(at date: Date) -> Int {
            utcOffsetSeconds ?? timeZone.flatMap { TimeZone(identifier: $0)?.secondsFromGMT(for: date) } ?? 0
        }
    }

    /// 逐時或每日的表格：欄位名稱 → 一欄值，第幾列對應 time 欄的第幾個時間。
    private struct Table {
        let columns: [String: [JSONValue]]

        /// 列數以 time 欄為準
        var count: Int { columns["time"]?.count ?? 0 }

        func has(_ key: String) -> Bool { !(columns[key] ?? []).isEmpty }

        func number(_ key: String, _ row: Int) -> Double? { value(key, row)?.number }
        func text(_ key: String, _ row: Int) -> String? { value(key, row)?.text }
        func code(_ key: String, _ row: Int) -> Int? { value(key, row)?.code }

        private func value(_ key: String, _ row: Int) -> JSONValue? {
            guard let column = columns[key], column.indices.contains(row) else { return nil }
            return column[row]
        }
    }
}
