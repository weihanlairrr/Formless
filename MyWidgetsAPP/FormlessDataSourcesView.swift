import SwiftUI
import EventKit
#if canImport(CoreMotion)
import CoreMotion
#endif

// MARK: - 設定 › 資料來源（2026-10）
//
// 每種資料只出現一次：設定第一層只有「資料來源」一列；進去依類別列出所有來源；每個來源一頁，
// 放這個來源的全部東西——設定（有才放）、權限（要的才放）、目前讀到的值。
// 原本設定第一層的天氣、行事曆、提醒事項與「資料權限」頁都併進來（使用者：同一種資料分散三處很混亂）。
// 設計裡用這些資料：文字 › 內容 ›「插入資料」，或進度、圖表、條件裡的「選擇資料」。

/// 設定頁的一列：「資料來源」。
struct FormlessDataSourcesRow: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        NavigationLink("資料來源") {
            FormlessDataSourcesView(isRefreshing: isRefreshing, onRefresh: onRefresh)
        }
    }
}

/// 來源需要的系統權限。位置給天氣、空氣品質、天文、位置共用。
enum FormlessSourcePermission {
    case location, calendar, reminders, motion

    static func of(_ providerID: String) -> FormlessSourcePermission? {
        switch providerID {
        case "weather", "airQuality", "astronomy", "place": return .location
        case "calendar": return .calendar
        case "reminders": return .reminders
        case "activity": return .motion
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .location: return "位置權限"
        case .calendar: return "行事曆權限"
        case .reminders: return "提醒事項權限"
        case .motion: return "動作與健身權限"
        }
    }

    enum State { case granted, notDetermined, denied, unavailable }

    @MainActor var state: State {
        switch self {
        case .location:
            switch FormlessLocationProvider.shared.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .granted
            }
        case .calendar, .reminders:
            let type: EKEntityType = self == .calendar ? .event : .reminder
            switch EKEventStore.authorizationStatus(for: type) {
            case .notDetermined: return .notDetermined
            case .fullAccess: return .granted
            default: return .denied
            }
        case .motion:
            #if canImport(CoreMotion)
            guard FormlessStepsProvider.stepsAvailable else { return .unavailable }
            switch CMPedometer.authorizationStatus() {
            case .notDetermined: return .notDetermined
            case .authorized: return .granted
            default: return .denied
            }
            #else
            return .unavailable
            #endif
        }
    }

    /// 還沒問過就讓系統詢問；拒絕過系統不會再問，只能到系統設定開啟。
    @MainActor func request() async {
        guard state == .notDetermined else {
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            return
        }
        switch self {
        case .location: FormlessLocationProvider.shared.requestAccess()
        case .calendar: await FormlessEventsProvider.requestAccess()
        case .reminders: await FormlessRemindersProvider.requestAccess()
        case .motion: _ = await FormlessStepsProvider.pedometerToday()
        }
    }
}

struct FormlessDataSourcesView: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var location = FormlessLocationProvider.shared
    @State private var calendarSummary = ""
    @State private var tick = 0

    /// 列出的資料：網路資料（JSON、RSS、CSV）要在設計裡填網址才有內容，這裡不列；小工具環境只在畫小工具時才有值。
    static var providers: [any FormlessDataProvider] {
        FormlessProviders.all.filter { !FormlessWebRefresh.providerIDs.contains($0.id) && $0.id != FormlessWidgetEnvironmentProvider.providerID }
    }

    /// 卡片：天氣／行事曆與提醒事項／時間與天文／其他，避免每個類別各一張卡片拉得太長。
    private static let groups: [[FormlessDataCategory]] = [
        [.weather], [.calendar, .reminders], [.dateTime, .astronomy],
        [.activity, .device, .location, .photos, .mine]
    ]

    var body: some View {
        List {
            ForEach(Self.groups, id: \.self) { group in
                let items = Self.providers.filter { group.contains($0.category) }
                if !items.isEmpty {
                    Section {
                        ForEach(items, id: \.id) { provider in
                            NavigationLink {
                                FormlessProviderDetailView(provider: provider, onChange: onRefresh)
                            } label: {
                                LabeledContent {
                                    Text(summary(provider))
                                } label: {
                                    Label(provider.name, systemImage: provider.symbol)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Button(action: onRefresh) {
                    HStack {
                        Text(isRefreshing ? "正在更新資料…" : "更新資料")
                        Spacer()
                        if isRefreshing { ProgressView() }
                    }
                }
                .disabled(isRefreshing)
            } footer: {
                Text("設定套用至所有設計。桌面更新時間由系統安排。")
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle("資料來源")
        // 每次回到這一頁都重讀右邊的摘要（剛在下一層改過）。行事曆要建 EventKit 的資料庫，放到背景讀。
        .onAppear {
            tick += 1
            Task { calendarSummary = await Task.detached { AppSettingsView.calendarSummary() }.value }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { tick += 1 } }
    }

    /// 右邊的灰字：權限沒開就提示；否則是這個來源最主要的設定。
    private func summary(_ provider: any FormlessDataProvider) -> String {
        _ = tick
        _ = location.authorizationStatus
        if let permission = FormlessSourcePermission.of(provider.id), permission.state == .notDetermined || permission.state == .denied {
            return "尚未允許"
        }
        switch provider.id {
        case "weather": return FormlessWeatherStyle.current().unit == "f" ? "°F" : "°C"
        case "calendar": return calendarSummary
        case "reminders": return FormlessReminderSettings.current().range.displayName
        default: return ""
        }
    }
}

/// 一種資料的全部：設定、權限、目前的值。
struct FormlessProviderDetailView: View {
    let provider: any FormlessDataProvider
    let onChange: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var location = FormlessLocationProvider.shared
    @State private var snapshot: FormlessSnapshot?
    @State private var loading = false
    @State private var now = Date()
    @State private var calendarSummary = ""
    @State private var weatherUnit = FormlessWeatherStyle.current().unit ?? "c"
    @State private var reminderRange = FormlessReminderSettings.current().range
    @State private var requesting = false

    private var source: FormlessSource { .appDefault(provider.id) }
    private var permission: FormlessSourcePermission? { FormlessSourcePermission.of(provider.id) }

    var body: some View {
        List {
            settings

            if let permission {
                Section {
                    permissionRow(permission)
                }
            }

            Section {
                ForEach(provider.fields(for: source, snapshot: snapshot)) { field in
                    LabeledContent(field.name) { valueView(field) }
                }
            } footer: {
                if provider.fetches { Text(statusText) }
            }
        }
        .contentMargins(.top, FormlessDesign.Space.pageTop, for: .scrollContent)
        .formlessPageTitle(provider.name)
        .task { await reload() }
        .onAppear {
            if provider.id == "calendar" {
                Task { calendarSummary = await Task.detached { AppSettingsView.calendarSummary() }.value }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .onChange(of: location.authorizationStatus) { _, _ in
            Task { await reload() }
            onChange()
        }
    }

    // MARK: 設定（只有天氣、行事曆、提醒事項有全 App 共用的設定；其他來源的設定在各圖層裡）

    @ViewBuilder private var settings: some View {
        switch provider.id {
        case "weather":
            Section {
                Picker("溫度單位", selection: $weatherUnit) {
                    Text("攝氏 °C").tag("c")
                    Text("華氏 °F").tag("f")
                }
                NavigationLink("天氣文字與圖片") {
                    WeatherStyleView(onChange: onChange, showsUnit: false, title: "天氣文字與圖片")
                }
            }
            .onChange(of: weatherUnit) { _, value in
                var style = FormlessWeatherStyle.current()
                style.unit = value
                FormlessWeatherStyle.save(style)
                now = Date()
                onChange()
            }
        case "calendar":
            Section {
                NavigationLink {
                    CalendarPickerView(onChange: onChange)
                } label: {
                    LabeledContent("行事曆來源", value: calendarSummary)
                }
                NavigationLink("類別名稱") {
                    CalendarNamesView(onChange: onChange)
                }
                NavigationLink("行程地點") {
                    EventLocationSettingsView()
                }
            }
        case "reminders":
            Section {
                Picker("範圍", selection: $reminderRange) {
                    ForEach(FormlessReminderRange.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            .onChange(of: reminderRange) { _, value in
                var settings = FormlessReminderSettings.current()
                settings.range = value
                FormlessReminderSettings.save(settings)
                onChange()
                Task { await reload() }
            }
        default:
            EmptyView()
        }
    }

    // MARK: 權限

    private func permissionRow(_ permission: FormlessSourcePermission) -> some View {
        let state = permission.state
        let value: String
        switch state {
        case .granted: value = "已允許"
        case .notDetermined: value = "允許"
        case .denied: value = "前往設定開啟"
        case .unavailable: value = "此裝置不支援"
        }
        let actionable = state == .notDetermined || state == .denied
        return Button {
            requesting = true
            Task {
                await permission.request()
                requesting = false
                await reload()
                onChange()
            }
        } label: {
            LabeledContent {
                Text(value).foregroundStyle(actionable ? Color.accentColor : .secondary)
            } label: {
                Text(permission.title).foregroundStyle(Color.primary)
            }
        }
        .disabled(!actionable || requesting)
    }

    // MARK: 目前的值

    /// 圖示和顏色直接畫出來，不顯示內部名稱。
    @ViewBuilder private func valueView(_ field: FormlessFieldSpec) -> some View {
        switch provider.value(field.id, source: source, snapshot: snapshot, at: now) {
        case .symbol(let name) where !name.isEmpty:
            Image(systemName: name).symbolRenderingMode(.multicolor)
        case .color(let hex) where !hex.isEmpty:
            Circle().fill(Color(formlessHex: hex)).frame(width: 20, height: 20)
        case .image(let name) where !name.isEmpty:
            Text("圖片")
        default:
            Text(text(field))
        }
    }

    private func text(_ field: FormlessFieldSpec) -> String {
        let value = provider.value(field.id, source: source, snapshot: snapshot, at: now)
        if case .list(let items) = value { return "\(items.count) 筆" }
        if value.isEmpty { return provider.fetches && snapshot == nil ? "—" : "沒有資料" }
        return FormlessValueFormatter.text(value, format: nil, spec: field, at: now)
    }

    private var statusText: String {
        guard let snapshot else { return loading ? "正在取得資料…" : "還沒有資料" }
        switch snapshot.status {
        case .unauthorized: return "需要權限"
        case .unsupported: return "這個安裝方式無法讀取這項資料"
        case .failed: return "暫時無法更新，顯示上次的資料"
        default:
            let minutes = Int(Date().timeIntervalSince(snapshot.fetchedAt) / 60)
            return minutes < 1 ? "剛剛更新" : "\(minutes) 分鐘前更新"
        }
    }

    /// 先顯示上次存的值，再到背景取最新的。
    private func reload() async {
        let key = provider.cacheKey(for: source)
        snapshot = await Task.detached { FormlessSnapshotStore.load(key) }.value
        now = Date()
        guard provider.fetches, !loading else { return }
        loading = true
        if let fetched = await provider.fetch(source) { FormlessSnapshotStore.save(fetched, key: key) }
        snapshot = FormlessSnapshotStore.load(key) ?? snapshot
        now = Date()
        loading = false
    }
}
