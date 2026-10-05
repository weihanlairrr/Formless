import Combine
import EventKit
import MapKit
import SwiftUI
import UIKit

/// 小工具「建立行事曆行程」叫出的新增行程面板。版面比照「小工具設定」：滿版面板、標題置中、右上角一個按鈕，
/// 卡片不放標題、每一列左邊名稱右邊內容。往下滑關閉就是不加入。
/// 最常用的標題與時間在最上面，左邊一條行事曆顏色（裝飾，和系統面板一樣）；行事曆在左上角的選單切換，不另佔一列；
/// 接著是地點（打字時列出建議，右邊的地圖按鈕可以在地圖上選）與提示；其餘（整日、重複、網址、附註）收在「更多」裡，
/// 點了才展開（使用者指定）。
struct FormlessNewEventView: View {
    let store: EKEventStore
    /// 關閉時呼叫；有加入行程時傳 true。
    let onFinish: (Bool) -> Void

    @State private var title = ""
    @State private var location = ""
    @State private var allDay = false
    @State private var start: Date
    @State private var end: Date
    @State private var repeatRule: FormlessEventRepeat = .never
    @State private var calendarID: String
    @State private var alert: FormlessEventAlert = .none
    @State private var url = ""
    @State private var notes = ""
    @State private var showsMore = false
    @State private var saveFailed = false
    /// 從建議或地圖選到的地點（有座標）；地點欄的字被改掉就不算數。
    @State private var place: MKMapItem?
    @State private var showsMap = false
    @StateObject private var placeSearch = FormlessPlaceSearch()
    @FocusState private var titleFocused: Bool
    @FocusState private var locationFocused: Bool
    /// 一打開就把游標放到標題欄，但要等 App 完全啟用：從小工具點過來時面板在 App 啟用前就擺好了，
    /// 那時聚焦只有游標、沒有鍵盤（實測）。只自動聚焦這一次，之後由使用者決定。
    @State private var autoFocused = false

    private let calendars: [EKCalendar]

    init(store: EKEventStore, onFinish: @escaping (Bool) -> Void) {
        self.store = store
        self.onFinish = onFinish
        // 從目前這個整點開始，一小時（使用者選的預設，和行事曆 App 相同）。
        let now = Date()
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        _start = State(initialValue: hour)
        _end = State(initialValue: hour.addingTimeInterval(3600))
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        calendars = writable
        let preferred = store.defaultCalendarForNewEvents ?? writable.first
        _calendarID = State(initialValue: preferred?.calendarIdentifier ?? "")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 卡片不放標題（使用者規則：全 App 的卡片上方都不放標題）。
                // 這一列延伸到螢幕左右兩邊、內容再內縮 20：表單會把每一列裁成圓角（半徑 26），
                // 顏色條貼在列的最左邊的話，上下兩端會被圓角切掉約 10 pt（實測）。
                Section { headerBlock.padding(.horizontal, Card.inset) }
                    .listSectionMargins(.horizontal, 0)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Section {
                    locationRow
                    if showsSuggestions {
                        ForEach(placeSearch.results, id: \.self) { completion in
                            FormlessPlaceSuggestionRow(completion: completion) { choose(completion) }
                        }
                    }
                }

                Section {
                    Picker("提示", selection: $alert) {
                        ForEach(FormlessEventAlert.options(allDay: allDay)) { Text($0.title(allDay: allDay)).tag($0) }
                    }
                    moreRow
                    if showsMore {
                        Toggle("整日", isOn: $allDay)
                        Picker("重複", selection: $repeatRule) {
                            ForEach(FormlessEventRepeat.allCases) { Text($0.title).tag($0) }
                        }
                        EditorTextRow(title: "網址", placeholder: "https://", text: $url, url: true, singleLine: true)
                        EditorTextRow(title: "附註", text: $notes, singleLine: true)
                    }
                } footer: {
                    if saveFailed { Text("無法加入行程，請確認 Formless 可以存取行事曆。") }
                }
            }
            .navigationTitle("新增行程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { calendarMenu }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") { save() }
                        .disabled(trimmedTitle.isEmpty || calendars.isEmpty)
                }
            }
        }
        .formlessSheetBackground()
        .onAppear { focusTitleIfActive() }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification).receive(on: RunLoop.main)) { _ in
            focusTitleIfActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .formlessNewEventEndTyping)) { _ in
            titleFocused = false
            locationFocused = false
        }
        // 開始時間改了，結束跟著移動、保持原本的長度（和行事曆 App 相同）。
        .onChange(of: start) { old, new in
            end = new.addingTimeInterval(max(end.timeIntervalSince(old), 0))
        }
        .onChange(of: allDay) { _, isAllDay in
            if !FormlessEventAlert.options(allDay: isAllDay).contains(alert) { alert = .none }
        }
        // 打字時更新建議；選好的地點名稱被改掉，就不再帶它的座標。
        .onChange(of: location) { _, text in
            if let place, text != (place.name ?? "") { self.place = nil }
            placeSearch.update(text)
        }
        .sheet(isPresented: $showsMap) {
            FormlessMapPicker(initial: place) { item in
                place = item
                location = item.name ?? ""
                placeSearch.update("")
            }
        }
    }

    // MARK: 標題與時間

    /// 系統表單卡片的尺寸（實測）：列高 52.3、日期列 66.5、卡片之間 35、左右內距 20。
    /// 顏色條要畫在卡片外面、橫跨兩張卡片，表單的卡片做不到，所以這兩張自己畫，其他卡片照用表單。
    private enum Card {
        static let radius: CGFloat = 26
        static let rowHeight: CGFloat = 52.33
        static let dateRowPadding: CGFloat = 15
        static let gap: CGFloat = 35
        static let inset: CGFloat = 20
        /// 顏色條寬 6、離卡片 10（和系統面板相同）。
        static let barWidth: CGFloat = 6
        static let barGap: CGFloat = 10
    }

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: Card.barGap) {
            calendarBar
            VStack(spacing: Card.gap) {
                card {
                    EditorTextRow(title: "標題", text: $title, focus: $titleFocused, singleLine: true)
                        .padding(.horizontal, Card.inset)
                        .frame(minHeight: Card.rowHeight)
                }
                card {
                    VStack(spacing: 0) {
                        dateRow("開始", selection: $start, range: nil)
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 1 / 3)
                            .padding(.horizontal, Card.inset)
                        dateRow("結束", selection: $end, range: start)
                    }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Card.radius, style: .continuous))
    }

    private func dateRow(_ title: String, selection: Binding<Date>, range: Date?) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            if let range {
                DatePicker(title, selection: selection, in: range..., displayedComponents: dateComponents)
                    .labelsHidden()
            } else {
                DatePicker(title, selection: selection, displayedComponents: dateComponents)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, Card.inset)
        .padding(.vertical, Card.dateRowPadding)
    }

    private var currentCalendar: EKCalendar? {
        calendars.first { $0.calendarIdentifier == calendarID }
    }

    /// 行事曆顏色條：純裝飾，顯示目前的行事曆顏色（使用者：橫條只是一個裝飾，不能拿來切換）。
    private var calendarBar: some View {
        Capsule()
            .fill(currentColor)
            .frame(width: Card.barWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var currentColor: Color {
        currentCalendar.map { Color(cgColor: $0.cgColor) } ?? FormlessDesign.Palette.accent
    }

    /// 行事曆選單：左上角一顆按鈕（色點＋名稱＋向下箭頭），和右上角的「加入」左右對稱，「新增行程」維持置中；
    /// 點了列出所有行事曆（使用者選的排法：分類不另佔一列、要容易改）。
    private var calendarMenu: some View {
        Menu {
            Picker("行事曆", selection: $calendarID) {
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    Label {
                        Text(calendar.title)
                    } icon: {
                        Image(uiImage: Self.dot(calendar.cgColor))
                    }
                    .tag(calendar.calendarIdentifier)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(currentColor)
                    .frame(width: 10, height: 10)
                Text(currentCalendar?.title ?? "行事曆")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        // 選單預設用強調色（藍）畫標籤；維持一般文字色，和「加入」一樣。
        .tint(.primary)
        .accessibilityLabel("行事曆")
        .accessibilityValue(currentCalendar?.title ?? "")
    }

    // MARK: 地點

    /// 地點：左名稱、右輸入，最右邊的地圖按鈕打開地圖選點（按鈕只佔自己的範圍，點欄位不會打開地圖）。
    private var locationRow: some View {
        // 名稱和輸入框永遠在同一行：字很長時輸入框橫向捲動，不換成上下兩行。
        HStack(spacing: FormlessDesign.Space.valueGap) {
            Text("地點").lineLimit(1).fixedSize()
            HStack(spacing: 12) {
                TextField("地點", text: $location)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .focused($locationFocused)
                    .frame(maxWidth: .infinity)
                Button {
                    locationFocused = false
                    showsMap = true
                } label: {
                    Image(systemName: "map")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("在地圖上選擇")
            }
        }
    }

    /// 正在打地點、而且還沒選定時才列建議。
    private var showsSuggestions: Bool {
        locationFocused && place == nil && !placeSearch.results.isEmpty
    }

    private func choose(_ completion: MKLocalSearchCompletion) {
        locationFocused = false
        Task {
            let item = await placeSearch.resolve(completion)
            place = item
            location = item?.name ?? completion.title
            placeSearch.update("")
        }
    }

    /// 「更多」：右邊的箭頭和圖層清單的群組一樣，收合時朝右、展開時朝下。
    /// 點擊範圍是整列（contentShape 放在 label 上，中間空白也點得到）。
    private var moreRow: some View {
        Button {
            withAnimation(FormlessMotion.push) { showsMore.toggle() }
        } label: {
            HStack {
                Text("更多")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsMore ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsMore ? "收合更多" : "更多")
    }

    private var dateComponents: DatePickerComponents {
        allDay ? .date : [.date, .hourAndMinute]
    }

    private func focusTitleIfActive() {
        guard !autoFocused else { return }
        let active = UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        guard active else { return }
        autoFocused = true
        titleFocused = true
    }

    private func save() {
        let event = EKEvent(eventStore: store)
        event.title = trimmedTitle
        event.location = location.isEmpty ? nil : location
        // 選過地點就一併存座標：行事曆 App 裡這筆行程會顯示地圖、可以導航。
        if let place { event.structuredLocation = EKStructuredLocation(mapItem: place) }
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = end
        event.calendar = store.calendar(withIdentifier: calendarID) ?? store.defaultCalendarForNewEvents
        if let rule = repeatRule.rule { event.addRecurrenceRule(rule) }
        if let offset = alert.offset(allDay: allDay) { event.addAlarm(EKAlarm(relativeOffset: offset)) }
        event.url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        event.notes = notes.isEmpty ? nil : notes
        do {
            try store.save(event, span: .thisEvent)
            onFinish(true)
        } catch {
            saveFailed = true
        }
    }

    /// 選單裡的行事曆顏色點：選單會把一般圖示染成同一色，要用原色圖片才看得到每本行事曆的顏色。
    /// 圖片右邊留 6 pt 空白：列上的選項裡圓點和名稱之間沒有間距。
    private static func dot(_ color: CGColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 18, height: 12)).image { context in
            UIColor(cgColor: color).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

enum FormlessEventRepeat: String, CaseIterable, Identifiable {
    case never, daily, weekly, biweekly, monthly, yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "永不"
        case .daily: return "每天"
        case .weekly: return "每週"
        case .biweekly: return "每兩週"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }

    var rule: EKRecurrenceRule? {
        switch self {
        case .never: return nil
        case .daily: return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .biweekly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly: return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }
}

/// 提示的選項和行事曆 App 相同：一般行程以開始時間往前算；整日行程以當天上午 9 點為準。
enum FormlessEventAlert: String, CaseIterable, Identifiable {
    case none, atStart, min5, min10, min15, min30, hour1, hour2, day1, day2, week1

    var id: String { rawValue }

    static func options(allDay: Bool) -> [FormlessEventAlert] {
        allDay ? [.none, .atStart, .day1, .day2, .week1] : allCases
    }

    func title(allDay: Bool) -> String {
        switch self {
        case .none: return "無"
        case .atStart: return allDay ? "行程當天（上午 9:00）" : "行程開始時"
        case .min5: return "5 分鐘前"
        case .min10: return "10 分鐘前"
        case .min15: return "15 分鐘前"
        case .min30: return "30 分鐘前"
        case .hour1: return "1 小時前"
        case .hour2: return "2 小時前"
        case .day1: return allDay ? "1 天前（上午 9:00）" : "1 天前"
        case .day2: return allDay ? "2 天前（上午 9:00）" : "2 天前"
        case .week1: return allDay ? "1 週前（上午 9:00）" : "1 週前"
        }
    }

    /// 相對行程開始的秒數；整日行程的開始是當天 0 點，所以加上 9 小時。
    func offset(allDay: Bool) -> TimeInterval? {
        let nine: TimeInterval = allDay ? 9 * 3600 : 0
        switch self {
        case .none: return nil
        case .atStart: return nine
        case .min5: return -5 * 60
        case .min10: return -10 * 60
        case .min15: return -15 * 60
        case .min30: return -30 * 60
        case .hour1: return -3600
        case .hour2: return -2 * 3600
        case .day1: return -86400 + nine
        case .day2: return -2 * 86400 + nine
        case .week1: return -7 * 86400 + nine
        }
    }
}
