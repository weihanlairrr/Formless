import Foundation

// MARK: - 天氣
//
// Open-Meteo 免費端點（自用非商用）。每個地點一份快取，十個圖層用同一份臺北天氣只抓一次。
// 時間線較晚的格子用逐時預報推算當時的溫度與天氣，不必等下一次更新。

struct FormlessWeatherDataProvider: FormlessDataProvider {
    let id = "weather"
    let name = "天氣"
    let symbol = "cloud.sun"
    let category = FormlessDataCategory.weather
    var lifetime: TimeInterval { 30 * 60 }
    var allowsInstances: Bool { true }
    var settings: [FormlessSettingSpec] { [FormlessPlace.setting] }

    func summary(for source: FormlessSource) -> String { FormlessPlace.summary(source) }
    func cacheKey(for source: FormlessSource) -> String { "weather-" + FormlessPlace.resolve(source).cacheKey }

    static let hourFields: [FormlessFieldSpec] = [
        FormlessFieldSpec("time", "時間", .date, sample: .date(Date())),
        FormlessFieldSpec("temperature", "溫度", .number, unit: .celsius, sample: .number(27, .celsius)),
        FormlessFieldSpec("apparentTemperature", "體感溫度", .number, unit: .celsius, sample: .number(30, .celsius)),
        FormlessFieldSpec("condition", "天氣狀態", .text, sample: .text("多雲")),
        FormlessFieldSpec("symbol", "天氣圖示", .symbol, sample: .symbol("cloud.sun.fill")),
        FormlessFieldSpec("precipitationProbability", "降雨機率", .number, unit: .percent, sample: .number(20, .percent)),
        FormlessFieldSpec("precipitation", "降水量", .number, unit: .millimeters, decimals: 1, sample: .number(0, .millimeters)),
        FormlessFieldSpec("windSpeed", "風速", .number, unit: .kilometersPerHour, sample: .number(12, .kilometersPerHour)),
        FormlessFieldSpec("uvIndex", "紫外線指數", .number, unit: .uvIndex, sample: .number(5, .uvIndex)),
        FormlessFieldSpec("humidity", "濕度", .number, unit: .percent, sample: .number(70, .percent))
    ]

    static let dayFields: [FormlessFieldSpec] = [
        FormlessFieldSpec("date", "日期", .date, sample: .date(Date(), allDay: true)),
        FormlessFieldSpec("weekday", "星期", .text, sample: .text("週六")),
        FormlessFieldSpec("high", "最高溫", .number, unit: .celsius, sample: .number(31, .celsius)),
        FormlessFieldSpec("low", "最低溫", .number, unit: .celsius, sample: .number(24, .celsius)),
        FormlessFieldSpec("mean", "平均溫度", .number, unit: .celsius, sample: .number(27, .celsius)),
        FormlessFieldSpec("condition", "天氣狀態", .text, sample: .text("晴天")),
        FormlessFieldSpec("symbol", "天氣圖示", .symbol, sample: .symbol("sun.max.fill")),
        FormlessFieldSpec("precipitationProbability", "降雨機率", .number, unit: .percent, sample: .number(10, .percent)),
        FormlessFieldSpec("precipitationSum", "降水量", .number, unit: .millimeters, decimals: 1, sample: .number(0.4, .millimeters)),
        FormlessFieldSpec("sunrise", "日出", .date, sample: .date(Date())),
        FormlessFieldSpec("sunset", "日落", .date, sample: .date(Date())),
        FormlessFieldSpec("uvIndexMax", "最高紫外線指數", .number, unit: .uvIndex, sample: .number(8, .uvIndex)),
        FormlessFieldSpec("windSpeedMax", "最大風速", .number, unit: .kilometersPerHour, sample: .number(20, .kilometersPerHour))
    ]

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        func sampleList(_ specs: [FormlessFieldSpec], _ count: Int) -> FormlessValue {
            .list((0..<count).map { index in
                .record(FormlessRecord(id: String(index), fields: Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0.sample) })))
            })
        }
        let now = Date()
        return [
            FormlessFieldSpec("temperature", "目前溫度", .number, unit: .celsius, sample: .number(28, .celsius)),
            FormlessFieldSpec("apparentTemperature", "體感溫度", .number, unit: .celsius, sample: .number(31, .celsius)),
            FormlessFieldSpec("high", "今天最高溫", .number, unit: .celsius, sample: .number(32, .celsius)),
            FormlessFieldSpec("low", "今天最低溫", .number, unit: .celsius, sample: .number(25, .celsius)),
            FormlessFieldSpec("condition", "天氣狀態", .text, sample: .text("多雲")),
            FormlessFieldSpec("conditionDetail", "天氣描述", .text, sample: .text("多雲時晴")),
            FormlessFieldSpec("symbol", "天氣圖示", .symbol, sample: .symbol("cloud.sun.fill")),
            FormlessFieldSpec("precipitationProbability", "今天降雨機率", .number, unit: .percent, sample: .number(20, .percent)),
            FormlessFieldSpec("precipitation", "目前降水量", .number, unit: .millimeters, decimals: 1, sample: .number(0, .millimeters)),
            FormlessFieldSpec("humidity", "濕度", .number, unit: .percent, sample: .number(74, .percent)),
            FormlessFieldSpec("dewPoint", "露點", .number, unit: .celsius, sample: .number(23, .celsius)),
            FormlessFieldSpec("pressure", "氣壓", .number, unit: .hectopascals, sample: .number(1009, .hectopascals)),
            FormlessFieldSpec("visibility", "能見度", .number, unit: .kilometers, decimals: 1, sample: .number(16, .kilometers)),
            FormlessFieldSpec("cloudCover", "雲量", .number, unit: .percent, sample: .number(60, .percent)),
            FormlessFieldSpec("windSpeed", "風速", .number, unit: .kilometersPerHour, sample: .number(12, .kilometersPerHour)),
            FormlessFieldSpec("windGusts", "陣風", .number, unit: .kilometersPerHour, sample: .number(25, .kilometersPerHour)),
            FormlessFieldSpec("windDirection", "風向", .text, sample: .text("東北")),
            FormlessFieldSpec("windDegrees", "風向角度", .number, unit: .degrees, sample: .number(45, .degrees)),
            FormlessFieldSpec("uvIndex", "紫外線指數", .number, unit: .uvIndex, sample: .number(6, .uvIndex)),
            FormlessFieldSpec("isDay", "白天", .bool, sample: .bool(true)),
            FormlessFieldSpec("sunrise", "日出", .date, sample: .date(now)),
            FormlessFieldSpec("sunset", "日落", .date, sample: .date(now)),
            FormlessFieldSpec("placeName", "地點", .text, sample: .text(FormlessPlace.resolve(source).name.isEmpty ? "臺北" : FormlessPlace.resolve(source).name)),
            FormlessFieldSpec("hourly", "逐時預報", .list, sample: sampleList(Self.hourFields, 24), items: Self.hourFields),
            FormlessFieldSpec("daily", "每日預報", .list, sample: sampleList(Self.dayFields, 7), items: Self.dayFields),
            FormlessFieldSpec("updatedAt", "更新時間", .date, sample: .date(now))
        ]
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        let place = FormlessPlace.resolve(source)
        guard let forecast = try? await FormlessOpenMeteo.fetchForecast(latitude: place.latitude, longitude: place.longitude,
                                                                          days: 7, session: FormlessNetwork.session) else {
            return .failure(.failed, "無法連線到天氣服務")
        }
        return Self.snapshot(forecast, place: place)
    }

    static func symbol(code: Int, isDay: Bool) -> String { FormlessOpenMeteo.symbolName(code: code, isDay: isDay) }

    static func snapshot(_ forecast: FormlessForecast, place: FormlessPlace) -> FormlessSnapshot {
        let current = forecast.current
        var now: [String: FormlessValue] = [
            "time": .date(current.time),
            "temperature": .number(current.temperature, .celsius),
            "code": .number(Double(current.weatherCode), .none),
            "isDay": .bool(current.isDay)
        ]
        now["apparentTemperature"] = .optionalNumber(current.apparentTemperature, .celsius)
        now["humidity"] = .optionalNumber(current.humidity, .percent)
        now["dewPoint"] = .optionalNumber(current.dewPoint, .celsius)
        now["pressure"] = .optionalNumber(current.pressure, .hectopascals)
        now["visibility"] = .optionalNumber(current.visibility.map { $0 / 1000 }, .kilometers)
        now["cloudCover"] = .optionalNumber(current.cloudCover, .percent)
        now["windSpeed"] = .optionalNumber(current.windSpeed, .kilometersPerHour)
        now["windGusts"] = .optionalNumber(current.windGusts, .kilometersPerHour)
        now["windDegrees"] = .optionalNumber(current.windDirection, .degrees)
        now["uvIndex"] = .optionalNumber(current.uvIndex, .uvIndex)
        now["precipitation"] = .optionalNumber(current.precipitation, .millimeters)

        let hours: [FormlessValue] = forecast.hourly.map { hour in
            var fields: [String: FormlessValue] = [
                "time": .date(hour.time),
                "temperature": .number(hour.temperature, .celsius),
                "code": .number(Double(hour.weatherCode), .none),
                "isDay": .bool(hour.isDay)
            ]
            fields["apparentTemperature"] = .optionalNumber(hour.apparentTemperature, .celsius)
            fields["precipitationProbability"] = .optionalNumber(hour.precipitationProbability, .percent)
            fields["precipitation"] = .optionalNumber(hour.precipitation, .millimeters)
            fields["windSpeed"] = .optionalNumber(hour.windSpeed, .kilometersPerHour)
            fields["uvIndex"] = .optionalNumber(hour.uvIndex, .uvIndex)
            fields["humidity"] = .optionalNumber(hour.humidity, .percent)
            return .record(FormlessRecord(id: String(Int(hour.time.timeIntervalSince1970)), fields: fields.filter { !$0.value.isEmpty }))
        }

        let days: [FormlessValue] = forecast.daily.map { day in
            var fields: [String: FormlessValue] = [
                "date": .date(day.date, allDay: true),
                "code": .number(Double(day.weatherCode), .none),
                "high": .number(day.high, .celsius),
                "low": .number(day.low, .celsius)
            ]
            fields["mean"] = .optionalNumber(day.mean, .celsius)
            fields["precipitationProbability"] = .optionalNumber(day.precipitationProbability, .percent)
            fields["precipitationSum"] = .optionalNumber(day.precipitationSum, .millimeters)
            fields["sunrise"] = .optionalDate(day.sunrise)
            fields["sunset"] = .optionalDate(day.sunset)
            fields["uvIndexMax"] = .optionalNumber(day.uvIndexMax, .uvIndex)
            fields["windSpeedMax"] = .optionalNumber(day.windSpeedMax, .kilometersPerHour)
            return .record(FormlessRecord(id: String(Int(day.date.timeIntervalSince1970)), fields: fields.filter { !$0.value.isEmpty }))
        }

        return FormlessSnapshot(values: [
            "current": .record(FormlessRecord(id: "current", fields: now.filter { !$0.value.isEmpty })),
            "hourly": .list(hours),
            "daily": .list(days),
            "placeName": .optionalText(place.name),
            "timeZone": .text(forecast.timeZone)
        ], attribution: "Open-Meteo")
    }

    /// 風向角度轉成八方位。
    static func direction(_ degrees: Double) -> String {
        let names = ["北", "東北", "東", "東南", "南", "西南", "西", "西北"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return names[index]
    }

    /// date 那一刻的天氣：抓取後一小時內用目前天氣，之後用逐時預報那個鐘點。
    private func moment(_ snapshot: FormlessSnapshot, at date: Date) -> FormlessRecord? {
        guard let current = snapshot["current"].recordValue else { return nil }
        let currentTime = current["time"].dateValue ?? snapshot.fetchedAt
        if abs(date.timeIntervalSince(currentTime)) < 45 * 60 { return current }
        let hours = (snapshot["hourly"].listValue ?? []).compactMap(\.recordValue)
        guard let hour = hours.last(where: { ($0["time"].dateValue ?? .distantFuture) <= date }) ?? hours.first else { return current }
        var merged = current
        for (key, value) in hour.fields { merged[key] = value }
        return merged
    }

    private func day(_ snapshot: FormlessSnapshot, at date: Date) -> FormlessRecord? {
        let days = (snapshot["daily"].listValue ?? []).compactMap(\.recordValue)
        return days.last { ($0["date"].dateValue ?? .distantFuture) <= date } ?? days.first
    }

    /// 白天或夜晚用那一天的日出日落判斷，時間線的每一格在日出、日落那一刻換圖示。
    private func isDay(_ snapshot: FormlessSnapshot, moment: FormlessRecord?, at date: Date) -> Bool {
        if let today = day(snapshot, at: date), let rise = today["sunrise"].dateValue, let set = today["sunset"].dateValue {
            return date >= rise && date < set
        }
        return moment?["isDay"].boolValue ?? true
    }

    private func decorate(_ record: FormlessRecord, isDay: Bool?) -> FormlessRecord {
        var result = record
        if let code = record["code"].numberValue.map(Int.init) {
            let day = isDay ?? record["isDay"].boolValue ?? true
            result["condition"] = .text(FormlessWeatherCode.text(for: code))
            result["symbol"] = .symbol(Self.symbol(code: code, isDay: day))
        }
        if let date = record["date"].dateValue {
            result["weekday"] = .text(FormlessValueFormatter.formatter(pattern: "EEE", timeZone: nil, calendar: nil).string(from: date))
        }
        return result
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        guard let snapshot, !snapshot.values.isEmpty else { return .empty }
        let now = moment(snapshot, at: date)
        let today = day(snapshot, at: date)
        let daytime = isDay(snapshot, moment: now, at: date)
        switch field {
        case "temperature", "apparentTemperature", "humidity", "dewPoint", "pressure", "visibility", "cloudCover",
             "windSpeed", "windGusts", "windDegrees", "uvIndex", "precipitation":
            return now?[field] ?? .empty
        case "windDirection":
            guard let degrees = now?["windDegrees"].numberValue else { return .empty }
            return .text(Self.direction(degrees))
        case "condition":
            guard let code = now?["code"].numberValue else { return .empty }
            return .text(FormlessWeatherCode.text(for: Int(code)))
        case "conditionDetail":
            guard let code = now?["code"].numberValue else { return .empty }
            return .text(FormlessOpenMeteo.conditionText(code: Int(code)))
        case "symbol":
            guard let code = now?["code"].numberValue else { return .empty }
            return .symbol(Self.symbol(code: Int(code), isDay: daytime))
        case "isDay": return .bool(daytime)
        case "high", "low", "sunrise", "sunset": return today?[field] ?? .empty
        case "precipitationProbability": return today?["precipitationProbability"] ?? .empty
        case "placeName":
            let name = FormlessPlace.resolve(source).name
            return name.isEmpty ? snapshot["placeName"] : .text(name)
        case "updatedAt": return .date(snapshot.fetchedAt)
        case "hourly":
            let start = date.addingTimeInterval(-3599)
            return .list((snapshot["hourly"].listValue ?? []).compactMap(\.recordValue)
                .filter { ($0["time"].dateValue ?? .distantPast) > start }
                .map { .record(decorate($0, isDay: nil)) })
        case "daily":
            let start = FormlessLiveTime.calendar.startOfDay(for: date)
            return .list((snapshot["daily"].listValue ?? []).compactMap(\.recordValue)
                .filter { ($0["date"].dateValue ?? .distantPast) >= start.addingTimeInterval(-12 * 3600) }
                .map { .record(decorate($0, isDay: true)) })
        default:
            return .empty
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        guard let snapshot else { return [] }
        var result: [Date] = []
        // 逐時預報的每個整點（溫度、天氣），與日出日落（白天、夜晚的圖示）。
        if ["temperature", "apparentTemperature", "condition", "symbol", "humidity", "precipitation", "windSpeed",
            "uvIndex", "hourly", "isDay"].contains(field) {
            for hour in (snapshot["hourly"].listValue ?? []).compactMap(\.recordValue) {
                if let time = hour["time"].dateValue, time > from, time < to { result.append(time) }
            }
            for day in (snapshot["daily"].listValue ?? []).compactMap(\.recordValue) {
                for key in ["sunrise", "sunset"] {
                    if let time = day[key].dateValue, time > from, time < to { result.append(time) }
                }
            }
        }
        let midnight = FormlessLiveTime.endOfDay(from)
        if midnight < to { result.append(midnight) }
        return result
    }
}

// MARK: - 空氣品質

/// Open-Meteo 空氣品質（CAMS 模型推估，不是測站實測）。
struct FormlessAirQualityProvider: FormlessDataProvider {
    let id = "airQuality"
    let name = "空氣品質"
    let symbol = "aqi.medium"
    let category = FormlessDataCategory.weather
    var lifetime: TimeInterval { 60 * 60 }
    var allowsInstances: Bool { true }
    var settings: [FormlessSettingSpec] { [FormlessPlace.setting] }

    func summary(for source: FormlessSource) -> String { FormlessPlace.summary(source) }
    func cacheKey(for source: FormlessSource) -> String { "air-" + FormlessPlace.resolve(source).cacheKey }

    static let pollen: [(id: String, name: String)] = [
        ("alder", "赤楊花粉"), ("birch", "樺樹花粉"), ("grass", "禾草花粉"),
        ("mugwort", "艾草花粉"), ("olive", "橄欖花粉"), ("ragweed", "豚草花粉")
    ]

    static let hourFields: [FormlessFieldSpec] = [
        FormlessFieldSpec("time", "時間", .date, sample: .date(Date())),
        FormlessFieldSpec("usAQI", "空氣品質指數", .number, unit: .aqi, sample: .number(42, .aqi)),
        FormlessFieldSpec("europeanAQI", "歐洲空氣品質指數", .number, unit: .aqi, sample: .number(30, .aqi)),
        FormlessFieldSpec("pm25", "PM2.5", .number, unit: .microgramsPerCubicMeter, sample: .number(12, .microgramsPerCubicMeter))
    ]

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        var fields = [
            FormlessFieldSpec("usAQI", "空氣品質指數（美國）", .number, unit: .aqi, sample: .number(42, .aqi)),
            FormlessFieldSpec("category", "空氣品質", .text, sample: .text("良好")),
            FormlessFieldSpec("europeanAQI", "空氣品質指數（歐洲）", .number, unit: .aqi, sample: .number(30, .aqi)),
            FormlessFieldSpec("pm25", "PM2.5", .number, unit: .microgramsPerCubicMeter, sample: .number(12, .microgramsPerCubicMeter)),
            FormlessFieldSpec("pm10", "PM10", .number, unit: .microgramsPerCubicMeter, sample: .number(20, .microgramsPerCubicMeter)),
            FormlessFieldSpec("ozone", "臭氧", .number, unit: .microgramsPerCubicMeter, sample: .number(60, .microgramsPerCubicMeter)),
            FormlessFieldSpec("nitrogenDioxide", "二氧化氮", .number, unit: .microgramsPerCubicMeter, sample: .number(15, .microgramsPerCubicMeter)),
            FormlessFieldSpec("sulphurDioxide", "二氧化硫", .number, unit: .microgramsPerCubicMeter, sample: .number(3, .microgramsPerCubicMeter)),
            FormlessFieldSpec("carbonMonoxide", "一氧化碳", .number, unit: .microgramsPerCubicMeter, sample: .number(180, .microgramsPerCubicMeter))
        ]
        for pollen in Self.pollen {
            fields.append(FormlessFieldSpec("pollen." + pollen.id, pollen.name, .number, sample: .number(5)))
        }
        fields.append(FormlessFieldSpec("hourly", "逐時空氣品質", .list, sample: .list([]), items: Self.hourFields))
        return fields
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        let place = FormlessPlace.resolve(source)
        guard let air = try? await FormlessOpenMeteo.fetchAirQuality(latitude: place.latitude, longitude: place.longitude,
                                                                      session: FormlessNetwork.session) else {
            return .failure(.failed, "無法連線到空氣品質服務")
        }
        var values: [String: FormlessValue] = ["time": .date(air.time)]
        values["usAQI"] = .optionalNumber(air.usAQI, .aqi)
        values["europeanAQI"] = .optionalNumber(air.europeanAQI, .aqi)
        values["pm25"] = .optionalNumber(air.pm25, .microgramsPerCubicMeter)
        values["pm10"] = .optionalNumber(air.pm10, .microgramsPerCubicMeter)
        values["ozone"] = .optionalNumber(air.ozone, .microgramsPerCubicMeter)
        values["nitrogenDioxide"] = .optionalNumber(air.nitrogenDioxide, .microgramsPerCubicMeter)
        values["sulphurDioxide"] = .optionalNumber(air.sulphurDioxide, .microgramsPerCubicMeter)
        values["carbonMonoxide"] = .optionalNumber(air.carbonMonoxide, .microgramsPerCubicMeter)
        for (key, value) in air.pollen { values["pollen." + key] = .number(value, .none) }
        values["hourly"] = .list(air.hourly.map { hour in
            var fields: [String: FormlessValue] = ["time": .date(hour.time)]
            fields["usAQI"] = .optionalNumber(hour.usAQI, .aqi)
            fields["europeanAQI"] = .optionalNumber(hour.europeanAQI, .aqi)
            fields["pm25"] = .optionalNumber(hour.pm25, .microgramsPerCubicMeter)
            return .record(FormlessRecord(id: String(Int(hour.time.timeIntervalSince1970)), fields: fields.filter { !$0.value.isEmpty }))
        })
        return FormlessSnapshot(values: values.filter { !$0.value.isEmpty }, attribution: "Open-Meteo（模型推估）")
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        guard let snapshot else { return .empty }
        let hours = (snapshot["hourly"].listValue ?? []).compactMap(\.recordValue)
        let fetched = snapshot["time"].dateValue ?? snapshot.fetchedAt
        // 抓取一小時後，指數改用逐時預報那個鐘點。
        let hour = abs(date.timeIntervalSince(fetched)) < 3600 ? nil : hours.last { ($0["time"].dateValue ?? .distantFuture) <= date }
        switch field {
        case "category":
            guard let aqi = (hour?["usAQI"] ?? snapshot["usAQI"]).numberValue else { return .empty }
            return .text(FormlessOpenMeteo.aqiCategory(usAQI: aqi))
        case "usAQI", "europeanAQI", "pm25":
            return hour?[field].isEmpty == false ? hour![field] : snapshot[field]
        case "hourly":
            return .list(hours.filter { ($0["time"].dateValue ?? .distantPast) > date.addingTimeInterval(-3599) }.map(FormlessValue.record))
        default:
            return snapshot[field]
        }
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        guard ["usAQI", "europeanAQI", "pm25", "category", "hourly"].contains(field) else { return [] }
        return (snapshot?["hourly"].listValue ?? []).compactMap { $0.recordValue?["time"].dateValue }.filter { $0 > from && $0 < to }
    }
}

// MARK: - 天文

/// 日出日落、曙暮光、黃金與藍調時刻、月相、月出月落、分至。本機計算，不連網，離線也能用。
struct FormlessAstronomyProvider: FormlessDataProvider {
    let id = "astronomy"
    let name = "天文"
    let symbol = "moon.stars"
    let category = FormlessDataCategory.astronomy
    var fetches: Bool { false }
    var allowsInstances: Bool { true }
    var settings: [FormlessSettingSpec] { [FormlessPlace.setting] }

    func summary(for source: FormlessSource) -> String { FormlessPlace.summary(source) }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        let now = Date()
        return [
            FormlessFieldSpec("sunrise", "日出", .date, sample: .date(now), live: true),
            FormlessFieldSpec("sunset", "日落", .date, sample: .date(now), live: true),
            FormlessFieldSpec("solarNoon", "正午", .date, sample: .date(now)),
            FormlessFieldSpec("dayLength", "日照長度", .duration, sample: .duration(12.5 * 3600)),
            FormlessFieldSpec("remainingDaylight", "剩下的日照", .duration, sample: .duration(3.2 * 3600)),
            FormlessFieldSpec("isDaytime", "白天", .bool, sample: .bool(true)),
            FormlessFieldSpec("sunElevation", "太陽高度角", .number, unit: .degrees, sample: .number(42, .degrees)),
            FormlessFieldSpec("civilDawn", "民用晨光始", .date, sample: .date(now)),
            FormlessFieldSpec("civilDusk", "民用昏影終", .date, sample: .date(now)),
            FormlessFieldSpec("nauticalDawn", "航海晨光始", .date, sample: .date(now)),
            FormlessFieldSpec("nauticalDusk", "航海昏影終", .date, sample: .date(now)),
            FormlessFieldSpec("astronomicalDawn", "天文晨光始", .date, sample: .date(now)),
            FormlessFieldSpec("astronomicalDusk", "天文昏影終", .date, sample: .date(now)),
            FormlessFieldSpec("goldenHourMorning", "早晨黃金時刻結束", .date, sample: .date(now)),
            FormlessFieldSpec("goldenHourEvening", "傍晚黃金時刻開始", .date, sample: .date(now)),
            FormlessFieldSpec("blueHourMorning", "早晨藍調時刻開始", .date, sample: .date(now)),
            FormlessFieldSpec("blueHourEvening", "傍晚藍調時刻開始", .date, sample: .date(now)),
            FormlessFieldSpec("moonPhase", "月相", .text, sample: .text("盈凸月")),
            FormlessFieldSpec("moonSymbol", "月相圖示", .symbol, sample: .symbol("moonphase.waxing.gibbous")),
            FormlessFieldSpec("moonIllumination", "月亮照亮比例", .number, unit: .percent, sample: .number(78, .percent)),
            FormlessFieldSpec("moonAge", "月齡", .number, unit: .days, decimals: 1, sample: .number(10.4, .days)),
            FormlessFieldSpec("moonrise", "月出", .date, sample: .date(now)),
            FormlessFieldSpec("moonset", "月落", .date, sample: .date(now)),
            FormlessFieldSpec("nextFullMoon", "下次滿月", .date, sample: .date(now.addingTimeInterval(4 * 86_400))),
            FormlessFieldSpec("nextNewMoon", "下次新月", .date, sample: .date(now.addingTimeInterval(19 * 86_400))),
            FormlessFieldSpec("nextSeason", "下一個分至", .text, sample: .text("冬至")),
            FormlessFieldSpec("nextSeasonDate", "下一個分至日期", .date, sample: .date(now.addingTimeInterval(78 * 86_400), allDay: true))
        ]
    }

    private func sun(_ source: FormlessSource, at date: Date) -> FormlessSunTimes {
        let place = FormlessPlace.resolve(source)
        return FormlessAstronomy.sunTimes(on: date, latitude: place.latitude, longitude: place.longitude)
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        let place = FormlessPlace.resolve(source)
        switch field {
        case "moonPhase", "moonSymbol", "moonIllumination", "moonAge", "moonrise", "moonset":
            let moon = FormlessAstronomy.moon(at: date, latitude: place.latitude, longitude: place.longitude)
            switch field {
            case "moonPhase": return .text(moon.phaseName)
            case "moonSymbol": return .symbol(moon.symbolName)
            case "moonIllumination": return .number(moon.illumination * 100, .percent)
            case "moonAge": return .number(moon.age, .days)
            case "moonrise": return .optionalDate(moon.moonrise)
            default: return .optionalDate(moon.moonset)
            }
        case "nextFullMoon": return .date(FormlessAstronomy.nextMoonPhase(.full, after: date))
        case "nextNewMoon": return .date(FormlessAstronomy.nextMoonPhase(.new, after: date))
        case "nextSeason", "nextSeasonDate":
            let next = nextSeason(after: date)
            return field == "nextSeason" ? .text(next.name) : .date(next.date, allDay: true)
        case "sunElevation":
            return .number(FormlessAstronomy.sunElevation(at: date, latitude: place.latitude, longitude: place.longitude), .degrees)
        default:
            break
        }
        let times = sun(source, at: date)
        switch field {
        case "sunrise": return .optionalDate(times.sunrise)
        case "sunset": return .optionalDate(times.sunset)
        case "solarNoon": return .date(times.solarNoon)
        case "dayLength": return .duration(times.dayLength)
        case "remainingDaylight":
            guard let set = times.sunset else { return .duration(times.dayLength >= 86_400 ? 86_400 : 0) }
            let rise = times.sunrise ?? .distantPast
            if date < rise { return .duration(times.dayLength) }
            return .duration(max(0, set.timeIntervalSince(date)))
        case "isDaytime":
            guard let rise = times.sunrise, let set = times.sunset else { return .bool(times.dayLength >= 86_400) }
            return .bool(date >= rise && date < set)
        case "civilDawn": return .optionalDate(times.civilDawn)
        case "civilDusk": return .optionalDate(times.civilDusk)
        case "nauticalDawn": return .optionalDate(times.nauticalDawn)
        case "nauticalDusk": return .optionalDate(times.nauticalDusk)
        case "astronomicalDawn": return .optionalDate(times.astronomicalDawn)
        case "astronomicalDusk": return .optionalDate(times.astronomicalDusk)
        case "goldenHourMorning": return .optionalDate(times.goldenHourMorningEnd)
        case "goldenHourEvening": return .optionalDate(times.goldenHourEveningStart)
        case "blueHourMorning": return .optionalDate(times.blueHourMorningStart)
        case "blueHourEvening": return .optionalDate(times.blueHourEveningStart)
        default: return .empty
        }
    }

    private func nextSeason(after date: Date) -> (name: String, date: Date) {
        let year = FormlessLiveTime.calendar.component(.year, from: date)
        let names: [FormlessSeasonEvent: String] = [.marchEquinox: "春分", .juneSolstice: "夏至", .septemberEquinox: "秋分", .decemberSolstice: "冬至"]
        for y in [year, year + 1] {
            for event in FormlessSeasonEvent.allCases {
                let moment = FormlessAstronomy.season(event, year: y)
                if moment > date { return (names[event] ?? "", moment) }
            }
        }
        return ("", date)
    }

    func changes(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        if ["remainingDaylight", "sunElevation"].contains(field) {
            var next = from.addingTimeInterval(900 - from.timeIntervalSince1970.truncatingRemainder(dividingBy: 900))
            while next < to, result.count < 24 { result.append(next); next.addTimeInterval(900) }
        }
        let times = sun(source, at: from)
        for moment in [times.sunrise, times.sunset].compactMap({ $0 }) where moment > from && moment < to { result.append(moment) }
        let midnight = FormlessLiveTime.endOfDay(from)
        if midnight < to { result.append(midnight) }
        return result
    }
}
