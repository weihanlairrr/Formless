import Foundation
import CoreLocation
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 裝置

/// 電量、充電、低耗電模式、儲存空間、網路、系統版本、語言。主 App 開著時取樣寫入；
/// 小工具行程讀不到電量時保留 App 上次的值。
struct FormlessDeviceProvider: FormlessDataProvider {
    let id = "device"
    let name = "裝置"
    let symbol = "iphone"
    let category = FormlessDataCategory.device
    var lifetime: TimeInterval { 10 * 60 }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        [
            FormlessFieldSpec("battery", "電量", .number, unit: .percent, sample: .number(76, .percent)),
            FormlessFieldSpec("batteryState", "充電狀態", .text, sample: .text("使用電池")),
            FormlessFieldSpec("charging", "正在充電", .bool, sample: .bool(false)),
            FormlessFieldSpec("lowPower", "低耗電模式", .bool, sample: .bool(false)),
            FormlessFieldSpec("storageFree", "可用空間", .number, unit: .bytes, sample: .number(48_000_000_000, .bytes)),
            FormlessFieldSpec("storageTotal", "總容量", .number, unit: .bytes, sample: .number(256_000_000_000, .bytes)),
            FormlessFieldSpec("storageUsed", "已使用空間", .number, unit: .percent, sample: .number(81, .percent)),
            FormlessFieldSpec("network", "網路", .text, sample: .text("Wi-Fi")),
            FormlessFieldSpec("systemVersion", "系統版本", .text, sample: .text("iOS 27.0")),
            FormlessFieldSpec("language", "語言", .text, sample: .text("繁體中文"))
        ]
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        var values: [String: FormlessValue] = [:]
        #if canImport(UIKit)
        let battery = await MainActor.run { () -> (Float, UIDevice.BatteryState, String) in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            return (device.batteryLevel, device.batteryState, device.systemName + " " + device.systemVersion)
        }
        if battery.0 >= 0 {
            values["battery"] = .number(Double(battery.0) * 100, .percent)
            switch battery.1 {
            case .charging: values["batteryState"] = .text("充電中"); values["charging"] = .bool(true)
            case .full: values["batteryState"] = .text("已充飽"); values["charging"] = .bool(true)
            default: values["batteryState"] = .text("使用電池"); values["charging"] = .bool(false)
            }
        }
        values["systemVersion"] = .text(battery.2)
        #endif
        values["lowPower"] = .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)

        if let resources = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = resources.volumeAvailableCapacityForImportantUsage, let total = resources.volumeTotalCapacity, total > 0 {
            values["storageFree"] = .number(Double(free), .bytes)
            values["storageTotal"] = .number(Double(total), .bytes)
            values["storageUsed"] = .number((1 - Double(free) / Double(total)) * 100, .percent)
        }

        values["network"] = .text(await Self.networkType())
        let language = Locale.preferredLanguages.first ?? "zh-Hant"
        values["language"] = .text(Locale(identifier: "zh_Hant_TW").localizedString(forIdentifier: language) ?? language)

        // 小工具行程讀不到電量時不覆蓋 App 上次取樣的值。
        if values["battery"] == nil, let old = FormlessSnapshotStore.load(cacheKey(for: source)) {
            for key in ["battery", "batteryState", "charging"] { values[key] = old[key].isEmpty ? nil : old[key] }
        }
        return FormlessSnapshot(values: values)
    }

    /// 目前的網路類型：等系統第一次回報（最多 2 秒）。
    static func networkType() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let completion = FormlessOneShot<String> { result in
                monitor.cancel()
                continuation.resume(returning: result)
            }
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { completion.resolve("離線"); return }
                if path.usesInterfaceType(.wifi) { completion.resolve("Wi-Fi") }
                else if path.usesInterfaceType(.cellular) { completion.resolve("行動網路") }
                else if path.usesInterfaceType(.wiredEthernet) { completion.resolve("有線網路") }
                else { completion.resolve("已連線") }
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { completion.resolve("未知") }
        }
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        snapshotValue(field, snapshot)
    }
}

// MARK: - 位置

/// 目前位置的地名、城市、縣市、國家、座標，以及到指定地點的距離。位置由主 App 定位後快取，小工具沿用。
struct FormlessPlaceProvider: FormlessDataProvider {
    let id = "place"
    let name = "位置"
    let symbol = "location"
    let category = FormlessDataCategory.location
    var lifetime: TimeInterval { 30 * 60 }
    var allowsInstances: Bool { true }

    var settings: [FormlessSettingSpec] {
        [FormlessSettingSpec(id: "target", name: "計算距離的地點", kind: .location,
                             footer: "「距離」是目前位置到這個地點的直線距離。")]
    }

    func summary(for source: FormlessSource) -> String {
        (source.flag(FormlessPlace.settingKeys.current) ?? true) ? "目前位置" : "到" + (source.text(FormlessPlace.settingKeys.name) ?? "指定地點")
    }

    func cacheKey(for source: FormlessSource) -> String { "place" }

    func availability(for source: FormlessSource) -> FormlessDataStatus {
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted: return .unauthorized
        default: return .loading
        }
    }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        [
            FormlessFieldSpec("name", "地名", .text, sample: .text("信義區")),
            FormlessFieldSpec("city", "城市", .text, sample: .text("臺北市")),
            FormlessFieldSpec("district", "區", .text, sample: .text("信義區")),
            FormlessFieldSpec("country", "國家或地區", .text, sample: .text("臺灣")),
            FormlessFieldSpec("latitude", "緯度", .number, decimals: 4, sample: .number(25.0330)),
            FormlessFieldSpec("longitude", "經度", .number, decimals: 4, sample: .number(121.5654)),
            FormlessFieldSpec("distance", "距離", .number, unit: .kilometers, decimals: 1, sample: .number(12.4, .kilometers))
        ]
    }

    func fetch(_ source: FormlessSource) async -> FormlessSnapshot? {
        guard let coordinate = FormlessCache.load(FormlessCoordinate.self, name: FormlessWeatherProvider.locationCacheName) else {
            return .failure(availability(for: source) == .unauthorized ? .unauthorized : .failed, "還沒有定位")
        }
        var values: [String: FormlessValue] = [
            "latitude": .number(coordinate.latitude, .none),
            "longitude": .number(coordinate.longitude, .none),
            "name": .optionalText(coordinate.name)
        ]
        // 同一個座標不重複反查地名。
        if let old = FormlessSnapshotStore.load(cacheKey(for: source)),
           old["latitude"].numberValue == coordinate.latitude, old["longitude"].numberValue == coordinate.longitude,
           !old["city"].isEmpty {
            return old
        }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let mark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_Hant_TW")).first {
            values["city"] = .optionalText(mark.locality ?? mark.administrativeArea)
            values["district"] = .optionalText(mark.subLocality ?? mark.subAdministrativeArea)
            values["country"] = .optionalText(mark.country)
            if coordinate.name.isEmpty { values["name"] = .optionalText(mark.subLocality ?? mark.locality) }
        }
        return FormlessSnapshot(values: values.filter { !$0.value.isEmpty })
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        guard field == "distance" else { return snapshotValue(field, snapshot) }
        guard !(source.flag(FormlessPlace.settingKeys.current) ?? true),
              let lat = source.number(FormlessPlace.settingKeys.latitude), let lon = source.number(FormlessPlace.settingKeys.longitude),
              let hereLat = snapshot?["latitude"].numberValue, let hereLon = snapshot?["longitude"].numberValue else { return .empty }
        let meters = CLLocation(latitude: hereLat, longitude: hereLon).distance(from: CLLocation(latitude: lat, longitude: lon))
        return .number(meters / 1000, .kilometers)
    }
}

// MARK: - 小工具環境（2026-10，規劃第 5.2 節）

/// 小工具這一刻怎麼被顯示：深淺色、主畫面透明或染色、StandBy。主要給條件用，
/// 例如「透明或染色時隱藏照片、改顯示另一組圖層」。不抓資料，值在畫圖層時從 SwiftUI 環境帶入。
struct FormlessWidgetEnvironmentProvider: FormlessDataProvider {
    static let providerID = "widgetEnvironment"
    let id = FormlessWidgetEnvironmentProvider.providerID
    let name = "小工具環境"
    let symbol = "rectangle.on.rectangle"
    let category = FormlessDataCategory.device
    var fetches: Bool { false }

    func fields(for source: FormlessSource, snapshot: FormlessSnapshot?) -> [FormlessFieldSpec] {
        [
            FormlessFieldSpec("appearance", "外觀", .text, sample: .text("淺色")),
            FormlessFieldSpec("isDark", "深色外觀", .bool, sample: .bool(false)),
            FormlessFieldSpec("mode", "顯示方式", .text, sample: .text("全彩")),
            FormlessFieldSpec("isTinted", "透明或染色", .bool, sample: .bool(false)),
            FormlessFieldSpec("isStandBy", "StandBy", .bool, sample: .bool(false))
        ]
    }

    func value(_ field: String, source: FormlessSource, snapshot: FormlessSnapshot?, at date: Date) -> FormlessValue {
        Self.value(field, environment: FormlessRenderEnvironment())
    }

    static func value(_ field: String, environment: FormlessRenderEnvironment) -> FormlessValue {
        switch field {
        case "appearance": return .text(environment.dark ? "深色" : "淺色")
        case "isDark": return .bool(environment.dark)
        case "mode":
            switch environment.mode {
            case .fullColor: return .text(environment.standBy ? "StandBy" : "全彩")
            case .accented: return .text("透明或染色")
            case .vibrant: return .text("StandBy 夜間")
            }
        case "isTinted": return .bool(environment.mode == .accented)
        case "isStandBy": return .bool(environment.standBy)
        default: return .empty
        }
    }
}
