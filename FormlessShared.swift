import Foundation
import Combine
import CryptoKit
import SwiftUI
import CoreText
import AppIntents
import WidgetKit
import EventKit
import CoreLocation

#if canImport(HealthKit)
import HealthKit
#endif

#if canImport(CoreMotion)
import CoreMotion
#endif

#if canImport(UIKit)
import UIKit
import CoreText
#endif


// MARK: - 點一下重新整理（不跳轉）

/// 這個型別放在共用檔，兩個目標都編得到。改用 LiveActivityIntent 之後，系統會在
/// 主 App 的行程裡執行，步數（HealthKit）才讀得到；小工具行程沒有健康權限。
struct FormlessRefreshIntent: LiveActivityIntent {

    nonisolated static let title: LocalizedStringResource = "重新整理小工具"

    nonisolated static let description = IntentDescription("重新讀取資料，不會開啟 App。")

    nonisolated static let isDiscoverable: Bool = false

    nonisolated static let openAppWhenRun: Bool = false

    @Parameter(title: "種類")
    var kind: String

    @Parameter(title: "設計")
    var documentID: String

    init() {
        self.kind = ""
        self.documentID = ""
    }

    init(kind: String, documentID: String) {
        self.kind = kind
        self.documentID = documentID
    }

    func perform() async throws -> some IntentResult {

        if let document = FormlessStorage.load(idString: documentID) {
            await FormlessLiveData.bounded(10) {
                await FormlessLiveData.warmCaches(for: [document], force: true)
            }
        }

        if kind.isEmpty {
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }

        return .result()
    }
}


// MARK: - 常數

enum FormlessConstants {
    /// App 與小工具共用資料夾的名稱。用 Xcode 安裝時就是 `group.com.weihan.formless`；
    /// 透過 SideStore 安裝時它會改名（後面加上帳號代碼），實際名稱寫在 Info.plist 的 `ALTAppGroups`，
    /// App 和小工具都從那裡讀，兩邊才找得到同一個資料夾。
    static let appGroupID: String = {
        let base = "group.com.weihan.formless"
        var candidates = (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? [])
            .filter { $0.hasPrefix(base) }
        // SideStore 不一定改名（實測這支手機沒有改）；帳號代碼那一種也列進來，但只用真的打得開的那一個，
        // 用猜的會開到另一個空資料夾，設計全部看不到（2026-09-27 發生過）。
        let parts = (Bundle.main.bundleIdentifier ?? "").split(separator: ".")
        if parts.count >= 4, parts[3].count == 10, parts[3].allSatisfy({ $0.isLetter || $0.isNumber }) {
            candidates.append(base + "." + parts[3])
        }
        return ([base] + candidates).first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        } ?? base
    }()
    static let fileExtension = "formless"
}


// MARK: - 尺寸

enum FormlessWidgetFamily: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large
    /// iOS 27 新增的直式超大尺寸（主畫面 4 × 6 格，`systemExtraLargePortrait`）。
    case extraLarge

    var displayName: String {
        switch self {
        case .small: return "小型"
        case .medium: return "中型"
        case .large: return "大型"
        case .extraLarge: return "超大型"
        }
    }

    /// 桌面實際比例（寬 ÷ 高）
    var aspectRatio: CGFloat {
        switch self {
        case .small: return 1.0
        case .medium: return 2.14
        case .large: return 0.955
        case .extraLarge: return Self.extraLargeAspect
        }
    }

    /// 字級換算基準高度
    var referenceHeight: CGFloat {
        switch self {
        case .small: return 158
        case .medium: return 158
        case .large: return 354
        case .extraLarge: return Self.extraLargeReferenceHeight
        }
    }

    /// 小工具外框的圓角（以參考尺寸計）。
    var cornerRadius: CGFloat { 22 }

    /// 超大型的比例：iPhone Air 上實測 366.67 × 591.33 pt（大型 366.67 × 382、中型 366.67 × 172.67，
    /// 超大型剛好是中型＋大型＋兩個小工具之間的 36.67 pt 間距）。
    static let extraLargeAspect: CGFloat = 0.62
    /// 和大型用同一個字級比例：同樣的字級在大型和超大型上一樣大（591.33 × 354 ÷ 382）。
    static let extraLargeReferenceHeight: CGFloat = 548

    var referenceWidth: CGFloat {
        referenceHeight * aspectRatio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "medium"
        self = FormlessWidgetFamily(rawValue: raw) ?? .medium
    }
}


// MARK: - 位置尺寸

struct FormlessFrame: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(
        x: Double = 0,
        y: Double = 0,
        width: Double = 1,
        height: Double = 1
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? c.decode(Double.self, forKey: .x)) ?? 0
        y = (try? c.decode(Double.self, forKey: .y)) ?? 0
        width = (try? c.decode(Double.self, forKey: .width)) ?? 1
        height = (try? c.decode(Double.self, forKey: .height)) ?? 1
    }
}


// MARK: - 元件內部偏移

struct FormlessOffset: Codable, Hashable, Sendable {

    var x: Double
    var y: Double

    init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? c.decode(Double.self, forKey: .x)) ?? 0
        y = (try? c.decode(Double.self, forKey: .y)) ?? 0
    }

    var isZero: Bool { x == 0 && y == 0 }
}


/// 每種進階元件可以單獨微調的部位
struct FormlessPart: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

enum FormlessParts {

    static func list(for type: FormlessLayerType) -> [FormlessPart] {
        switch type {
        case .calendar:
            return [
                FormlessPart(id: "panel", displayName: "左側面板"),
                FormlessPart(id: "weekday", displayName: "星期"),
                FormlessPart(id: "day", displayName: "大日期"),
                FormlessPart(id: "month", displayName: "月份標題"),
                FormlessPart(id: "weekdayRow", displayName: "星期列"),
                FormlessPart(id: "grid", displayName: "日期格")
            ]

        case .events:
            return [
                FormlessPart(id: "title", displayName: "標題"),
                FormlessPart(id: "count", displayName: "數量"),
                FormlessPart(id: "ruler", displayName: "刻度軸"),
                FormlessPart(id: "cards", displayName: "事件卡")
            ]

        case .reminders:
            return [
                FormlessPart(id: "icon", displayName: "圖示"),
                FormlessPart(id: "title", displayName: "標題"),
                FormlessPart(id: "list", displayName: "項目清單")
            ]

        case .weather:
            return [
                FormlessPart(id: "place", displayName: "地區"),
                FormlessPart(id: "condition", displayName: "天氣狀態"),
                FormlessPart(id: "icon", displayName: "天氣圖示"),
                FormlessPart(id: "now", displayName: "溫度"),
                FormlessPart(id: "forecast", displayName: "預報列")
            ]

        case .steps:
            return [
                FormlessPart(id: "icon", displayName: "圖示圓形"),
                FormlessPart(id: "count", displayName: "步數"),
                FormlessPart(id: "label", displayName: "下方文字")
            ]

        case .yearProgress:
            return [
                FormlessPart(id: "header", displayName: "年份"),
                FormlessPart(id: "percent", displayName: "百分比"),
                FormlessPart(id: "grid", displayName: "進度格")
            ]

        default:
            return []
        }
    }
}


// MARK: - 圖層種類

enum FormlessLayerType: String, Codable, CaseIterable, Sendable {
    case text
    case date
    case time
    case shape
    case image
    case remoteImage
    case symbol
    case bundleImage
    case liveText
    case ruler
    case calendarGrid
    case eventList
    case reminderList
    case weatherForecast
    case yearGrid
    case calendar
    case events
    case reminders
    case weather
    case steps
    case yearProgress
    case gradient
    /// 進度：值 ÷ 目標畫成線形、環形、弧形或分段（2026-10 通用化）。
    case progress
    /// 圖表：一份清單畫成長條、折線、面積、點、圓餅或環形。
    case chart
    /// 指針時鐘：時針、分針（沒有秒針：小工具不能每秒更新），可選刻度、數字與時區（2026-10）。
    case clock

    /// 編輯器呈現給使用者的素材分類，避免把渲染器的細分型別當成可編輯設定。
    var editorCategoryName: String {
        switch self {
        case .text, .date, .time, .liveText: return "文字"
        case .image, .remoteImage, .bundleImage: return "圖片"
        case .shape, .gradient: return "形狀"
        case .symbol: return "圖示"
        case .calendar, .calendarGrid: return "月曆"
        case .events, .eventList: return "行程"
        case .reminders, .reminderList: return "提醒事項"
        case .weather, .weatherForecast: return "天氣"
        case .steps: return "步數"
        case .yearProgress, .yearGrid: return "年度進度"
        case .ruler: return "裝飾"
        case .progress: return "進度"
        case .chart: return "圖表"
        case .clock: return "時鐘"
        }
    }

    var displayName: String {
        switch self {
        case .text: return "文字"
        case .date: return "日期"
        case .time: return "時間"
        case .shape: return "色塊"
        case .image: return "圖片"
        case .remoteImage: return "網路圖片"
        case .symbol: return "圖示"
        case .bundleImage: return "圖片"
        case .liveText: return "即時文字"
        case .ruler: return "刻度軸"
        case .calendarGrid: return "月曆格"
        case .eventList: return "事件清單"
        case .reminderList: return "提醒清單"
        case .weatherForecast: return "天氣預報列"
        case .yearGrid: return "年度進度格"
        case .calendar: return "完整月曆"
        case .events: return "今日行程"
        case .reminders: return "提醒事項"
        case .weather: return "天氣"
        case .steps: return "步數"
        case .yearProgress: return "年度進度"
        case .gradient: return "漸層"
        case .progress: return "進度"
        case .chart: return "圖表"
        case .clock: return "時鐘"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "textformat"
        case .date: return "calendar.badge.clock"
        case .time: return "clock"
        case .shape: return "square.fill"
        case .image: return "photo"
        case .remoteImage: return "globe"
        case .symbol: return "star"
        case .bundleImage: return "photo.on.rectangle"
        case .liveText: return "textformat.123"
        case .ruler: return "ruler"
        case .calendarGrid: return "square.grid.3x3"
        case .eventList: return "list.bullet"
        case .reminderList: return "checklist.unchecked"
        case .weatherForecast: return "thermometer.medium"
        case .yearGrid: return "square.grid.4x3.fill"
        case .calendar: return "calendar"
        case .events: return "list.bullet.rectangle"
        case .reminders: return "checklist"
        case .weather: return "cloud.sun"
        case .steps: return "figure.walk"
        case .yearProgress: return "chart.bar.fill"
        case .gradient: return "square.filled.and.line.vertical.and.square"
        case .progress: return "circle.dashed.inset.filled"
        case .chart: return "chart.bar.xaxis"
        case .clock: return "deskclock"
        }
    }

    /// 進階元件自己決定內部排版，不需要字級與內容欄位
    var isComponent: Bool {
        switch self {
        case .calendar, .events, .reminders, .weather, .steps, .yearProgress:
            return true

        case .ruler, .calendarGrid, .eventList, .reminderList, .weatherForecast, .yearGrid:
            return true
        default: return false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "text"
        self = FormlessLayerType(rawValue: raw) ?? .text
    }
}


// MARK: - 圖層

struct FormlessLayer: Codable, Identifiable, Hashable, Sendable {

    var id: UUID
    var name: String
    var type: FormlessLayerType
    var frame: FormlessFrame

    var opacity: Double
    var rotation: Double
    var zIndex: Int

    var value: String?
    var colorHex: String?
    /// 條件顏色：由上往下第一條成立的，主要顏色（colorHex）改成那條的顏色；都不成立就用 colorHex。
    var colorRules: [FormlessColorRule]?
    /// 色階：一份數字對應顏色，介於兩個顏色點之間取中間色（2026-10，規劃第 4.3 節）。
    var colorScale: FormlessColorScale?
    var fontSize: Double?
    var fontWeight: String?
    /// 字型：system / rounded / serif / monospaced
    var fontFamily: String?
    var cornerRadius: Double?
    /// 色塊形狀：rect（預設，可用 cornerRadius）、circle（正圓，直徑取短邊）、capsule。
    var shape: String?
    /// 色塊填色：nil 或 solid 用 colorHex 單色；linear 直線漸層、radial 放射漸層，顏色點見 gradientStops。
    var fill: String?
    /// 漸層的顏色點（顏色可帶透明度 #RRGGBBAA，位置 0–1）。
    var gradientStops: [FormlessGradientStop]?
    /// 直線漸層的方向（度，0–360）：漸層往哪個方向走，0 往上、90 往右、180 往下、270 往左。
    var gradientAngle: Double?
    /// 放射漸層的半徑：1 表示從中心到框的邊（框不是正方形時是橢圓）。
    var gradientRadius: Double?
    var actionURL: String?
    /// 點這個圖層時的動作，蓋過小工具的「點一下小工具」；nil 表示跟著小工具。
    var tapAction: FormlessLayerTapAction?
    /// 動作的對象：捷徑名稱、我的資料的 id。
    var tapTarget: String?
    /// 加減我的資料的數（可以是負數）。
    var tapAmount: Double?

    // 進階元件專用
    var secondaryColorHex: String?
    var panelColorHex: String?
    var textColorHex: String?
    var showsPanel: Bool?
    var weekStartsOnMonday: Bool?

    // 天氣與行程
    var latitude: Double?
    var longitude: Double?
    var locationName: String?
    var useCurrentLocation: Bool?
    var maxItems: Int?

    /// 文字對齊：leading / center / trailing
    var alignment: String?

    /// 綁定第幾筆即時資料：event1…event5、reminder1…reminder3、forecast1…forecast5。
    /// 該筆不存在時整個圖層不繪製；colorHex 為 auto 時取該筆自己的顏色。
    var dataIndex: String?

    /// 文字過長時是否先縮小再截斷。false 表示不縮小，直接以「…」截斷。
    var autoShrink: Bool?

    // 外框與陰影，對應 Widgy 的 stroke 與 shadow
    var strokeColorHex: String?
    var strokeWidth: Double?
    var shadowColorHex: String?
    var shadowRadius: Double?
    var shadowOffsetY: Double?

    // 元件內部微調
    var partOffsets: [String: FormlessOffset]?

    // 群組
    var isGroup: Bool?
    var parentID: UUID?
    var isCollapsed: Bool?

    // 編輯狀態
    var isHidden: Bool?
    var isLocked: Bool?

    // 資料、呈現、規則（2026-10 通用化）
    /// 文字圖層的內容：固定字與資料組成（「今天走了 8,430 步」）；nil 時是 value 的固定文字。
    var segments: [FormlessTextSegment]?
    /// 何時顯示：條件成立才畫（和 dataIndex 同時生效）。
    var visibility: FormlessConditionSet?
    var progress: FormlessProgressSpec?
    var chart: FormlessChartSpec?
    /// 群組的重複排列。
    var repeatSpec: FormlessRepeatSpec?
    /// 其他屬性取用的資料，鍵是 `FormlessBindableProperty`：symbol（圖示）、image（圖片）、url（點一下的網址）。
    var bindings: [String: FormlessBinding]?
    /// 文字最多幾行；nil 是 1 行，0 是不限。
    var lineLimit: Int?
    /// 行距（pt，以小工具參考尺寸計）。
    var lineSpacing: Double?
    /// 字距（pt，以小工具參考尺寸計）。
    var tracking: Double?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    /// 陰影的水平位移（垂直位移是 shadowOffsetY）。
    var shadowOffsetX: Double?
    /// 外框畫成虛線。
    var strokeDash: Bool?
    /// 模糊半徑（以小工具參考尺寸計）。
    var blur: Double?
    /// 混合模式（multiply、screen、overlay…）；小工具的染色與透明模式下系統不套用。
    var blendMode: String?
    var flipHorizontal: Bool?
    var flipVertical: Bool?
    /// 主畫面選「透明」或「染色」時，這張圖片保留原本的顏色；nil 是跟系統一起去色（`desaturated`）。
    var keepsFullColor: Bool?
    /// 文字沿圓弧排（曲線文字）："top" 在圓的上方、"bottom" 在下方；nil 是直線。圓是圖層框的內切圓。
    var textArc: String?
    /// 指針時鐘的設定。
    var clock: FormlessClockSpec?
    /// 月曆格的延伸設定：前後月份、農曆、週數、週末顏色、依資料上色（2026-10）。
    var calendarOptions: FormlessCalendarOptions?
    /// 圖示的上色方式：nil 單色、hierarchical 階層、palette 調色盤（主要顏色＋次要顏色）、multicolor 多色。
    var symbolMode: String?
    /// 四個角分開的圓角（左上、右上、右下、左下，以參考尺寸計）；nil 是四角都用 cornerRadius。只用在矩形色塊與圖片。
    var cornerRadii: [Double]?
    /// 相簿輪播（2026-10）：value 之後再輪流顯示的圖片（圖片庫的名稱）。
    var imageSet: [String]?
    /// 輪播每張顯示多久（分鐘）；nil 是 60。
    var imageInterval: Int?
    /// 這個版本不認得的欄位（較新版本寫入的），原樣保留、存檔時寫回。
    var preserved: [String: FormlessJSON]?

    init(
        id: UUID = UUID(),
        name: String = "圖層",
        type: FormlessLayerType = .text,
        frame: FormlessFrame = FormlessFrame(),
        opacity: Double = 1,
        rotation: Double = 0,
        zIndex: Int = 0,
        value: String? = nil,
        colorHex: String? = nil,
        fontSize: Double? = nil,
        fontWeight: String? = nil,
        fontFamily: String? = nil,
        cornerRadius: Double? = nil,
        shape: String? = nil,
        fill: String? = nil,
        gradientStops: [FormlessGradientStop]? = nil,
        gradientAngle: Double? = nil,
        gradientRadius: Double? = nil,
        actionURL: String? = nil,
        secondaryColorHex: String? = nil,
        panelColorHex: String? = nil,
        textColorHex: String? = nil,
        showsPanel: Bool? = nil,
        weekStartsOnMonday: Bool? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        useCurrentLocation: Bool? = nil,
        maxItems: Int? = nil,
        alignment: String? = nil,
        dataIndex: String? = nil,
        autoShrink: Bool? = nil,
        strokeColorHex: String? = nil,
        strokeWidth: Double? = nil,
        shadowColorHex: String? = nil,
        shadowRadius: Double? = nil,
        shadowOffsetY: Double? = nil,
        partOffsets: [String: FormlessOffset]? = nil,
        isGroup: Bool? = nil,
        parentID: UUID? = nil,
        isCollapsed: Bool? = nil,
        isHidden: Bool? = nil,
        isLocked: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.frame = frame
        self.opacity = opacity
        self.rotation = rotation
        self.zIndex = zIndex
        self.value = value
        self.colorHex = colorHex
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontFamily = fontFamily
        self.cornerRadius = cornerRadius
        self.shape = shape
        self.fill = fill
        self.gradientStops = gradientStops
        self.gradientAngle = gradientAngle
        self.gradientRadius = gradientRadius
        self.actionURL = actionURL
        self.secondaryColorHex = secondaryColorHex
        self.panelColorHex = panelColorHex
        self.textColorHex = textColorHex
        self.showsPanel = showsPanel
        self.weekStartsOnMonday = weekStartsOnMonday
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.useCurrentLocation = useCurrentLocation
        self.maxItems = maxItems
        self.alignment = alignment
        self.dataIndex = dataIndex
        self.autoShrink = autoShrink
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.shadowColorHex = shadowColorHex
        self.shadowRadius = shadowRadius
        self.shadowOffsetY = shadowOffsetY
        self.partOffsets = partOffsets
        self.isGroup = isGroup
        self.parentID = parentID
        self.isCollapsed = isCollapsed
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "圖層"
        type = (try? c.decode(FormlessLayerType.self, forKey: .type)) ?? .text
        frame = (try? c.decode(FormlessFrame.self, forKey: .frame)) ?? FormlessFrame()

        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? 1
        rotation = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        zIndex = (try? c.decode(Int.self, forKey: .zIndex)) ?? 0

        value = try? c.decode(String.self, forKey: .value)
        colorHex = try? c.decode(String.self, forKey: .colorHex)
        fontSize = try? c.decode(Double.self, forKey: .fontSize)
        fontWeight = try? c.decode(String.self, forKey: .fontWeight)
        fontFamily = try? c.decode(String.self, forKey: .fontFamily)
        cornerRadius = try? c.decode(Double.self, forKey: .cornerRadius)
        shape = try? c.decode(String.self, forKey: .shape)
        fill = try? c.decode(String.self, forKey: .fill)
        gradientStops = try? c.decode([FormlessGradientStop].self, forKey: .gradientStops)
        gradientAngle = try? c.decode(Double.self, forKey: .gradientAngle)
        gradientRadius = try? c.decode(Double.self, forKey: .gradientRadius)
        actionURL = try? c.decode(String.self, forKey: .actionURL)
        tapAction = try? c.decode(FormlessLayerTapAction.self, forKey: .tapAction)
        tapTarget = try? c.decode(String.self, forKey: .tapTarget)
        tapAmount = try? c.decode(Double.self, forKey: .tapAmount)

        secondaryColorHex = try? c.decode(String.self, forKey: .secondaryColorHex)
        panelColorHex = try? c.decode(String.self, forKey: .panelColorHex)
        textColorHex = try? c.decode(String.self, forKey: .textColorHex)
        showsPanel = try? c.decode(Bool.self, forKey: .showsPanel)
        weekStartsOnMonday = try? c.decode(Bool.self, forKey: .weekStartsOnMonday)

        latitude = try? c.decode(Double.self, forKey: .latitude)
        longitude = try? c.decode(Double.self, forKey: .longitude)
        locationName = try? c.decode(String.self, forKey: .locationName)
        useCurrentLocation = try? c.decode(Bool.self, forKey: .useCurrentLocation)
        maxItems = try? c.decode(Int.self, forKey: .maxItems)

        alignment = try? c.decode(String.self, forKey: .alignment)

        dataIndex = try? c.decode(String.self, forKey: .dataIndex)
        autoShrink = try? c.decode(Bool.self, forKey: .autoShrink)
        strokeColorHex = try? c.decode(String.self, forKey: .strokeColorHex)
        strokeWidth = try? c.decode(Double.self, forKey: .strokeWidth)
        shadowColorHex = try? c.decode(String.self, forKey: .shadowColorHex)
        shadowRadius = try? c.decode(Double.self, forKey: .shadowRadius)
        shadowOffsetY = try? c.decode(Double.self, forKey: .shadowOffsetY)

        partOffsets = try? c.decode([String: FormlessOffset].self, forKey: .partOffsets)

        isGroup = try? c.decode(Bool.self, forKey: .isGroup)
        parentID = try? c.decode(UUID.self, forKey: .parentID)
        isCollapsed = try? c.decode(Bool.self, forKey: .isCollapsed)

        isHidden = try? c.decode(Bool.self, forKey: .isHidden)
        isLocked = try? c.decode(Bool.self, forKey: .isLocked)

        colorRules = try? c.decode([FormlessColorRule].self, forKey: .colorRules)
        colorScale = try? c.decode(FormlessColorScale.self, forKey: .colorScale)

        segments = try? c.decode([FormlessTextSegment].self, forKey: .segments)
        visibility = try? c.decode(FormlessConditionSet.self, forKey: .visibility)
        progress = try? c.decode(FormlessProgressSpec.self, forKey: .progress)
        chart = try? c.decode(FormlessChartSpec.self, forKey: .chart)
        repeatSpec = try? c.decode(FormlessRepeatSpec.self, forKey: .repeatSpec)
        bindings = try? c.decode([String: FormlessBinding].self, forKey: .bindings)
        lineLimit = try? c.decode(Int.self, forKey: .lineLimit)
        lineSpacing = try? c.decode(Double.self, forKey: .lineSpacing)
        tracking = try? c.decode(Double.self, forKey: .tracking)
        italic = try? c.decode(Bool.self, forKey: .italic)
        underline = try? c.decode(Bool.self, forKey: .underline)
        strikethrough = try? c.decode(Bool.self, forKey: .strikethrough)
        shadowOffsetX = try? c.decode(Double.self, forKey: .shadowOffsetX)
        strokeDash = try? c.decode(Bool.self, forKey: .strokeDash)
        blur = try? c.decode(Double.self, forKey: .blur)
        blendMode = try? c.decode(String.self, forKey: .blendMode)
        flipHorizontal = try? c.decode(Bool.self, forKey: .flipHorizontal)
        flipVertical = try? c.decode(Bool.self, forKey: .flipVertical)
        keepsFullColor = try? c.decode(Bool.self, forKey: .keepsFullColor)
        textArc = try? c.decode(String.self, forKey: .textArc)
        clock = try? c.decode(FormlessClockSpec.self, forKey: .clock)
        calendarOptions = try? c.decode(FormlessCalendarOptions.self, forKey: .calendarOptions)
        symbolMode = try? c.decode(String.self, forKey: .symbolMode)
        cornerRadii = (try? c.decode([Double].self, forKey: .cornerRadii)).flatMap { $0.count == 4 ? $0 : nil }
        imageSet = try? c.decode([String].self, forKey: .imageSet)
        imageInterval = try? c.decode(Int.self, forKey: .imageInterval)
        preserved = decoder.formlessUnknownFields(known: Set(CodingKeys.allCases.map(\.stringValue)))

        // 舊版的「漸層」圖層併進色塊（使用者規則：漸層是形狀的一種填色）：轉成直線漸層，外觀和原本一樣——
        // 由上往下，上半段完全透明，下半段漸變到原本的顏色。
        if type == .gradient { convertLegacyGradient() }
    }

    /// 欄位名稱（preserved 不在裡面：它是這個版本不認得、原樣保留的欄位）。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, type, frame, opacity, rotation, zIndex, value, colorHex, colorRules, fontSize, fontWeight
        case fontFamily, cornerRadius, shape, fill, gradientStops, gradientAngle, gradientRadius, actionURL
        case tapAction, secondaryColorHex, panelColorHex, textColorHex, showsPanel, weekStartsOnMonday, latitude
        case longitude, locationName, useCurrentLocation, maxItems, alignment, dataIndex, autoShrink, strokeColorHex
        case strokeWidth, shadowColorHex, shadowRadius, shadowOffsetY, partOffsets, isGroup, parentID, isCollapsed
        case isHidden, isLocked, segments, visibility, progress, chart, repeatSpec, bindings, lineLimit, lineSpacing
        case tracking, italic, underline, strikethrough
        case shadowOffsetX, strokeDash, blur, blendMode, flipHorizontal, flipVertical, keepsFullColor, colorScale
        case textArc, clock, calendarOptions, symbolMode, cornerRadii, imageSet, imageInterval
        case tapTarget, tapAmount
    }

    /// 和原本自動產生的編碼相同（沒有值的欄位不寫），最後寫回保留的未知欄位。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(frame, forKey: .frame)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(zIndex, forKey: .zIndex)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(colorHex, forKey: .colorHex)
        try c.encodeIfPresent(colorRules, forKey: .colorRules)
        try c.encodeIfPresent(colorScale, forKey: .colorScale)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        try c.encodeIfPresent(fontWeight, forKey: .fontWeight)
        try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try c.encodeIfPresent(cornerRadius, forKey: .cornerRadius)
        try c.encodeIfPresent(shape, forKey: .shape)
        try c.encodeIfPresent(fill, forKey: .fill)
        try c.encodeIfPresent(gradientStops, forKey: .gradientStops)
        try c.encodeIfPresent(gradientAngle, forKey: .gradientAngle)
        try c.encodeIfPresent(gradientRadius, forKey: .gradientRadius)
        try c.encodeIfPresent(actionURL, forKey: .actionURL)
        try c.encodeIfPresent(tapAction, forKey: .tapAction)
        try c.encodeIfPresent(tapTarget, forKey: .tapTarget)
        try c.encodeIfPresent(tapAmount, forKey: .tapAmount)
        try c.encodeIfPresent(secondaryColorHex, forKey: .secondaryColorHex)
        try c.encodeIfPresent(panelColorHex, forKey: .panelColorHex)
        try c.encodeIfPresent(textColorHex, forKey: .textColorHex)
        try c.encodeIfPresent(showsPanel, forKey: .showsPanel)
        try c.encodeIfPresent(weekStartsOnMonday, forKey: .weekStartsOnMonday)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(locationName, forKey: .locationName)
        try c.encodeIfPresent(useCurrentLocation, forKey: .useCurrentLocation)
        try c.encodeIfPresent(maxItems, forKey: .maxItems)
        try c.encodeIfPresent(alignment, forKey: .alignment)
        try c.encodeIfPresent(dataIndex, forKey: .dataIndex)
        try c.encodeIfPresent(autoShrink, forKey: .autoShrink)
        try c.encodeIfPresent(strokeColorHex, forKey: .strokeColorHex)
        try c.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try c.encodeIfPresent(shadowColorHex, forKey: .shadowColorHex)
        try c.encodeIfPresent(shadowRadius, forKey: .shadowRadius)
        try c.encodeIfPresent(shadowOffsetY, forKey: .shadowOffsetY)
        try c.encodeIfPresent(partOffsets, forKey: .partOffsets)
        try c.encodeIfPresent(isGroup, forKey: .isGroup)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encodeIfPresent(isCollapsed, forKey: .isCollapsed)
        try c.encodeIfPresent(isHidden, forKey: .isHidden)
        try c.encodeIfPresent(isLocked, forKey: .isLocked)
        try c.encodeIfPresent(segments, forKey: .segments)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        try c.encodeIfPresent(progress, forKey: .progress)
        try c.encodeIfPresent(chart, forKey: .chart)
        try c.encodeIfPresent(repeatSpec, forKey: .repeatSpec)
        try c.encodeIfPresent(bindings, forKey: .bindings)
        try c.encodeIfPresent(lineLimit, forKey: .lineLimit)
        try c.encodeIfPresent(lineSpacing, forKey: .lineSpacing)
        try c.encodeIfPresent(tracking, forKey: .tracking)
        try c.encodeIfPresent(italic, forKey: .italic)
        try c.encodeIfPresent(underline, forKey: .underline)
        try c.encodeIfPresent(strikethrough, forKey: .strikethrough)
        try c.encodeIfPresent(shadowOffsetX, forKey: .shadowOffsetX)
        try c.encodeIfPresent(strokeDash, forKey: .strokeDash)
        try c.encodeIfPresent(blur, forKey: .blur)
        try c.encodeIfPresent(blendMode, forKey: .blendMode)
        try c.encodeIfPresent(flipHorizontal, forKey: .flipHorizontal)
        try c.encodeIfPresent(flipVertical, forKey: .flipVertical)
        try c.encodeIfPresent(keepsFullColor, forKey: .keepsFullColor)
        try c.encodeIfPresent(textArc, forKey: .textArc)
        try c.encodeIfPresent(clock, forKey: .clock)
        try c.encodeIfPresent(calendarOptions, forKey: .calendarOptions)
        try c.encodeIfPresent(symbolMode, forKey: .symbolMode)
        try c.encodeIfPresent(cornerRadii, forKey: .cornerRadii)
        try c.encodeIfPresent(imageSet, forKey: .imageSet)
        try c.encodeIfPresent(imageInterval, forKey: .imageInterval)
        try encoder.formlessWriteUnknownFields(preserved)
    }

    /// 舊版「漸層」圖層 → 直線漸層的色塊：由上往下，上半段完全透明，下半段漸變到原本的顏色（外觀不變）。
    mutating func convertLegacyGradient() {
        let base = FormlessGradientStop.opaqueHex(colorHex ?? "#FFFFFF")
        type = .shape
        fill = FormlessFillStyle.linear.rawValue
        gradientAngle = 180
        gradientStops = [
            FormlessGradientStop(colorHex: base + "00", location: 0),
            FormlessGradientStop(colorHex: base + "00", location: 0.5),
            FormlessGradientStop(colorHex: base, location: 1)
        ]
    }

    /// 由上往下淡出到指定顏色的色塊（原本的「漸層」圖層）。
    static func fade(name: String, frame: FormlessFrame, colorHex: String) -> FormlessLayer {
        var layer = FormlessLayer(name: name, type: .shape, frame: frame, colorHex: colorHex)
        layer.convertLegacyGradient()
        return layer
    }

    var shapeKind: FormlessShapeKind { FormlessShapeKind(rawValue: shape ?? "") ?? .rectangle }
    var fillStyle: FormlessFillStyle { FormlessFillStyle(rawValue: fill ?? "") ?? .solid }
    var visible: Bool { !(isHidden ?? false) }
    var locked: Bool { isLocked ?? false }
    var group: Bool { isGroup ?? false }
    var collapsed: Bool { isCollapsed ?? false }

    var textAlignment: Alignment {
        switch alignment {
        case "center": return .center
        case "trailing": return .trailing
        default: return .leading
        }
    }

    var multilineAlignment: TextAlignment {
        switch alignment {
        case "center": return .center
        case "trailing": return .trailing
        default: return .leading
        }
    }

    func offset(_ part: String) -> FormlessOffset {
        partOffsets?[part] ?? FormlessOffset()
    }

    mutating func setOffset(_ value: FormlessOffset, for part: String) {
        var table = partOffsets ?? [:]

        if value.isZero {
            table.removeValue(forKey: part)
        } else {
            table[part] = value
        }

        partOffsets = table.isEmpty ? nil : table
    }
}


// MARK: - 色塊形狀

enum FormlessShapeKind: String, CaseIterable, Identifiable, Sendable {
    case rectangle = "rect"
    case circle
    case capsule
    case fourPointStar = "star4"
    case triangle
    case rightTriangle
    case diamond
    case parallelogram
    case trapezoid
    case pentagon
    case hexagon
    case octagon
    case fivePointStar = "star5"
    case sixPointStar = "star6"
    case heart
    case cross
    case semicircle
    case sector
    case arrow
    case speechBubble = "bubble"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rectangle: return "矩形"
        case .circle: return "圓形"
        case .capsule: return "膠囊"
        case .fourPointStar: return "四角星"
        case .triangle: return "三角形"
        case .rightTriangle: return "直角三角形"
        case .diamond: return "菱形"
        case .parallelogram: return "平行四邊形"
        case .trapezoid: return "梯形"
        case .pentagon: return "五邊形"
        case .hexagon: return "六邊形"
        case .octagon: return "八邊形"
        case .fivePointStar: return "五角星"
        case .sixPointStar: return "六角星"
        case .heart: return "愛心"
        case .cross: return "十字"
        case .semicircle: return "半圓"
        case .sector: return "扇形"
        case .arrow: return "箭頭"
        case .speechBubble: return "對話框"
        }
    }

    /// 在框內畫的形狀，一律填滿框（寬高可以各自調，和矩形一樣）：矩形依圓角；圓形是內接框的圓
    /// （編輯器讓圓形的框保持正圓，見 `EditorModel.circleFrame`）；膠囊兩端全圓；其他形狀的圓角設定不起作用。
    /// 方向只有一種，其他方向用旋轉：箭頭朝右，半圓平邊朝下，扇形與直角三角形的直角在左下，對話框的尾巴在左下。
    func path(in rect: CGRect, cornerRadius: CGFloat) -> Path {
        /// 0–1 的比例對到框裡的點。
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func polygon(_ points: [CGPoint]) -> Path {
            var path = Path()
            path.addLines(points.map { pt($0.x, $0.y) })
            path.closeSubpath()
            return path
        }
        /// 四分之一橢圓弧的控制點比例。
        let k: CGFloat = 0.5522847

        switch self {
        case .rectangle:
            return Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        case .circle:
            return Path(ellipseIn: rect)
        case .capsule:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2, style: .continuous)
        case .fourPointStar:
            return FormlessFourPointStar().path(in: rect)
        case .triangle:
            return polygon([CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        case .rightTriangle:
            return polygon([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        case .diamond:
            return polygon([CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)])
        case .parallelogram:
            return polygon([CGPoint(x: 0.25, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.75, y: 1), CGPoint(x: 0, y: 1)])
        case .trapezoid:
            return polygon([CGPoint(x: 0.25, y: 0), CGPoint(x: 0.75, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        case .pentagon:
            return polygon(Self.pentagonPoints)
        case .hexagon:
            return polygon(Self.hexagonPoints)
        case .octagon:
            return polygon(Self.octagonPoints)
        case .fivePointStar:
            return polygon(Self.fivePointStarPoints)
        case .sixPointStar:
            return polygon(Self.sixPointStarPoints)
        case .cross:
            let a: CGFloat = 1.0 / 3, b: CGFloat = 2.0 / 3
            return polygon([CGPoint(x: a, y: 0), CGPoint(x: b, y: 0), CGPoint(x: b, y: a), CGPoint(x: 1, y: a),
                            CGPoint(x: 1, y: b), CGPoint(x: b, y: b), CGPoint(x: b, y: 1), CGPoint(x: a, y: 1),
                            CGPoint(x: a, y: b), CGPoint(x: 0, y: b), CGPoint(x: 0, y: a), CGPoint(x: a, y: a)])
        case .arrow:
            return polygon([CGPoint(x: 0, y: 0.35), CGPoint(x: 0.55, y: 0.35), CGPoint(x: 0.55, y: 0.1), CGPoint(x: 1, y: 0.5),
                            CGPoint(x: 0.55, y: 0.9), CGPoint(x: 0.55, y: 0.65), CGPoint(x: 0, y: 0.65)])
        case .heart:
            var path = Path()
            path.move(to: pt(0.5, 0.22))
            path.addCurve(to: pt(0.26, 0), control1: pt(0.5, 0.08), control2: pt(0.38, 0))
            path.addCurve(to: pt(0, 0.28), control1: pt(0.11, 0), control2: pt(0, 0.12))
            path.addCurve(to: pt(0.5, 1), control1: pt(0, 0.56), control2: pt(0.28, 0.76))
            path.addCurve(to: pt(1, 0.28), control1: pt(0.72, 0.76), control2: pt(1, 0.56))
            path.addCurve(to: pt(0.74, 0), control1: pt(1, 0.12), control2: pt(0.89, 0))
            path.addCurve(to: pt(0.5, 0.22), control1: pt(0.62, 0), control2: pt(0.5, 0.08))
            path.closeSubpath()
            return path
        case .semicircle:
            // 上半個橢圓：平邊在框的底邊，頂點碰到框的上緣。
            var path = Path()
            path.move(to: pt(0, 1))
            path.addCurve(to: pt(0.5, 0), control1: pt(0, 1 - k), control2: pt(0.5 - 0.5 * k, 0))
            path.addCurve(to: pt(1, 1), control1: pt(0.5 + 0.5 * k, 0), control2: pt(1, 1 - k))
            path.closeSubpath()
            return path
        case .sector:
            // 四分之一個橢圓：圓心在框的左下角。
            var path = Path()
            path.move(to: pt(0, 1))
            path.addLine(to: pt(0, 0))
            path.addCurve(to: pt(1, 1), control1: pt(k, 0), control2: pt(1, 1 - k))
            path.closeSubpath()
            return path
        case .speechBubble:
            // 圓角的框佔上面 78%，尾巴從左下往下伸到框的底邊。
            let bodyBottom = rect.minY + rect.height * 0.78
            let radius = min(rect.width * 0.16, (bodyBottom - rect.minY) * 0.3)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: bodyBottom), radius: radius)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bodyBottom), tangent2End: CGPoint(x: rect.minX, y: bodyBottom), radius: radius)
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: bodyBottom))
            path.addLine(to: pt(0.13, 1))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: bodyBottom))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: bodyBottom), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
            path.closeSubpath()
            return path
        }
    }

    /// 正多邊形與星形的頂點：從正上方開始順時針，縮放到剛好填滿 0–1 的方框。
    /// inner 是星形內凹點的半徑（外圈是 1），nil 是正多邊形；rotation 是整體轉動的角度。
    private static func radialPoints(count: Int, inner: Double? = nil, rotation: Double = 0) -> [CGPoint] {
        let steps = inner == nil ? count : count * 2
        let raw = (0..<steps).map { index -> (Double, Double) in
            let angle = (-90 + rotation + Double(index) * 360 / Double(steps)) * .pi / 180
            let radius = (inner != nil && index % 2 == 1) ? inner! : 1
            return (cos(angle) * radius, sin(angle) * radius)
        }
        let minX = raw.map(\.0).min() ?? -1, maxX = raw.map(\.0).max() ?? 1
        let minY = raw.map(\.1).min() ?? -1, maxY = raw.map(\.1).max() ?? 1
        return raw.map { CGPoint(x: ($0.0 - minX) / (maxX - minX), y: ($0.1 - minY) / (maxY - minY)) }
    }

    private static let pentagonPoints = radialPoints(count: 5)
    private static let hexagonPoints = radialPoints(count: 6)
    private static let octagonPoints = radialPoints(count: 8, rotation: 22.5)
    private static let fivePointStarPoints = radialPoints(count: 5, inner: 0.381966)
    private static let sixPointStarPoints = radialPoints(count: 6, inner: 1 / 3.0.squareRoot())
}

/// 色塊的填色方式。
enum FormlessFillStyle: String, CaseIterable, Identifiable, Sendable {
    case solid
    case linear
    case radial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solid: return "單色"
        case .linear: return "直線漸層"
        case .radial: return "放射漸層"
        }
    }
}

/// 漸層的一個顏色點。
struct FormlessGradientStop: Codable, Hashable, Sendable {
    var colorHex: String
    var location: Double

    /// 去掉透明度的 #RRGGBB（後面接 00 就是同色的完全透明）。
    static func opaqueHex(_ hex: String) -> String {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        let six = clean.count >= 6 ? String(clean.prefix(6)) : (clean.count == 3 ? clean.map { "\($0)\($0)" }.joined() : "FFFFFF")
        return "#" + six.uppercased()
    }
}


// MARK: - 條件顏色

/// 條件顏色的比較方式。
enum FormlessColorComparison: String, Codable, CaseIterable, Identifiable, Sendable {
    case atLeast = ">="
    case atMost = "<="
    case equal = "="

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .atLeast: return "≥"
        case .atMost: return "≤"
        case .equal: return "="
        }
    }
}

/// 一條條件顏色：資料（即時文字裡的數字資料）和數值比較成立時，圖層的主要顏色改成 colorHex。
/// 比的是精確值：年度百分比不四捨五入，溫度是換算成目前單位後、還沒取整數的值。拿不到資料時條件不成立。
/// 月曆格的延伸設定（全部選用，沒設定時和原本的月曆格完全一樣）。
struct FormlessCalendarOptions: Codable, Hashable, Sendable {
    /// 顯示前後第幾個月；0 或 nil 是這個月。
    var monthOffset: Int?
    /// 日期下面加農曆日（初一、十五…，初一顯示月份）。
    var showsLunar: Bool?
    /// 左邊加一欄週數（ISO 8601）。
    var showsWeekNumbers: Bool?
    /// 週六、週日的日期顏色；nil 和平日相同。
    var weekendColorHex: String?
    /// 依資料上色（熱圖）：一份清單，每一筆的日期落在哪天，那天的底色就依數量或數值加深。
    var heatmap: FormlessBinding?
    /// 清單每一筆要加總的數字欄位；nil 是算筆數（例如每天有幾個行程）。
    var heatmapField: String?

    var isEmpty: Bool { self == FormlessCalendarOptions() }
}

extension FormlessLayer {
    /// 月曆格的週末顏色（顏色面板用 key path 直接改）。
    var calendarWeekendColorHex: String? {
        get { calendarOptions?.weekendColorHex }
        set {
            var options = calendarOptions ?? FormlessCalendarOptions()
            options.weekendColorHex = newValue
            calendarOptions = options.isEmpty ? nil : options
        }
    }
}

/// 指針時鐘的設定。顏色用圖層既有的欄位：時針 colorHex、分針 secondaryColorHex（沒設跟時針一樣）、
/// 刻度與數字 textColorHex、錶盤 panelColorHex（沒設是透明）。
struct FormlessClockSpec: Codable, Hashable, Sendable {
    /// none、hours、minutes（`FormlessClockMarks`）。
    var marks: String?
    /// none、quarters、all（`FormlessClockNumerals`）。
    var numerals: String?
    /// 時區識別碼（Asia/Tokyo）；nil 是裝置目前的時區。
    var timeZone: String?
    /// 指針與刻度的粗細倍率，1 是預設。
    var weight: Double?

    init(marks: String? = nil, numerals: String? = nil, timeZone: String? = nil, weight: Double? = nil) {
        self.marks = marks
        self.numerals = numerals
        self.timeZone = timeZone
        self.weight = weight
    }
}

/// 色階的一個顏色點。
struct FormlessColorScaleStop: Codable, Hashable, Sendable {
    var value: Double
    var colorHex: String
}

/// 色階（Widgy 的 Smart Colors）：數字由小到大對應顏色點，介於兩點之間取中間色；比最小還小、比最大還大時用兩端的顏色。
struct FormlessColorScale: Codable, Hashable, Sendable {
    var subject: FormlessBinding
    var stops: [FormlessColorScaleStop]

    func colorHex(for number: Double) -> String? {
        let sorted = stops.sorted { $0.value < $1.value }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if number <= first.value { return first.colorHex }
        if number >= last.value { return last.colorHex }
        for (low, high) in zip(sorted, sorted.dropFirst()) where number <= high.value {
            let span = high.value - low.value
            let t = span > 0 ? (number - low.value) / span : 0
            return Self.mix(low.colorHex, high.colorHex, t)
        }
        return last.colorHex
    }

    /// 兩個顏色依比例混合（sRGB 各分量直線內插，含透明度）。
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let x = rgba(a), y = rgba(b)
        let c = (0..<4).map { x[$0] + (y[$0] - x[$0]) * t }
        let bytes = c.map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return bytes[3] >= 255
            ? String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
            : String(format: "#%02X%02X%02X%02X", bytes[0], bytes[1], bytes[2], bytes[3])
    }

    static func rgba(_ hex: String) -> [Double] {
        var clean = (FormlessDualColor.light(hex) ?? hex).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if clean.count == 3 { clean = clean.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(clean, radix: 16), clean.count == 6 || clean.count == 8 else { return [0, 0, 0, 1] }
        if clean.count == 8 {
            return [Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255]
        }
        return [Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255, 1]
    }
}

struct FormlessColorRule: Codable, Hashable, Sendable {
    /// FormlessLiveSource 的 rawValue（舊規則）；有 subject 時以 subject 為準。
    var source: String
    var comparison: FormlessColorComparison
    var value: Double
    var colorHex: String
    /// 比較的資料（2026-10 起可以選任何資料，例如我的資料、天氣的任何數字）。
    var subject: FormlessBinding?
    /// 和誰比；有設定時取代固定的 value（例如「步數 ≥ 目標」）。
    var threshold: FormlessOperand?

    /// 一個圖層最多兩條（使用者規則）：顏色面板不捲動，每多一條，調色盤就矮一列。
    static let maxCount = 2

    init(source: FormlessLiveSource, comparison: FormlessColorComparison, value: Double, colorHex: String) {
        self.source = source.rawValue
        self.comparison = comparison
        self.value = value
        self.colorHex = colorHex
    }

    init(subject: FormlessBinding, comparison: FormlessColorComparison, value: Double, colorHex: String) {
        self.source = ""
        self.subject = subject
        self.comparison = comparison
        self.value = value
        self.colorHex = colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decode(String.self, forKey: .source)) ?? FormlessLiveSource.yearPercent.rawValue
        comparison = (try? c.decode(FormlessColorComparison.self, forKey: .comparison)) ?? .atLeast
        value = (try? c.decode(Double.self, forKey: .value)) ?? 0
        colorHex = (try? c.decode(String.self, forKey: .colorHex)) ?? "#000000"
        subject = try? c.decode(FormlessBinding.self, forKey: .subject)
        threshold = try? c.decode(FormlessOperand.self, forKey: .threshold)
    }

    var liveSource: FormlessLiveSource? { subject == nil ? FormlessLiveSource(rawValue: source) : nil }

    func matches(date: Date, live: FormlessLiveData) -> Bool {
        let current = subject.map { live.value($0, at: date).numberValue } ?? liveSource?.conditionNumber(live: live, date: date)
        guard let number = current else { return false }
        let target = threshold.flatMap { live.number($0, at: date) } ?? value
        switch comparison {
        case .atLeast: return number >= target
        case .atMost: return number <= target
        case .equal: return abs(number - target) < 1e-9
        }
    }
}

extension FormlessLiveSource {
    /// 條件顏色可以比的資料：即時文字裡是數字的那幾項，依選單順序。
    static let conditionSources: [FormlessLiveSource] = [.yearPercent, .eventCount, .reminderCount, .steps, .weatherTemp]

    /// 條件比較用的精確數字；沒有這份資料時是 nil。
    func conditionNumber(live: FormlessLiveData, date: Date) -> Double? {
        switch self {
        case .yearPercent: return FormlessYearMath.progress(for: date) * 100
        case .eventCount: return Double(live.todayEventCount)
        case .reminderCount: return Double(live.todayReminderCount)
        case .steps: return live.steps.map(Double.init)
        case .weatherTemp: return live.weather.map { FormlessWeatherStyle.temperature($0.temperature) }
        default: return nil
        }
    }

    /// 條件數值後面接的單位。
    var conditionUnit: String {
        switch self {
        case .yearPercent: return "%"
        case .weatherTemp: return "°"
        default: return ""
        }
    }
}

extension FormlessLayer {
    /// 主要顏色（文字色、色塊的單色填色、圖示色）：條件顏色由上往下第一條成立的優先，都不成立就用原本的顏色；
    /// 原本的顏色是 auto 時，取綁定那一筆行程或提醒事項自己的顏色。
    func resolvedColorHex(date: Date, live: FormlessLiveData) -> String? {
        if let rule = colorRules?.first(where: { $0.matches(date: date, live: live) }) { return rule.colorHex }
        // 取用資料的顏色（行程的行事曆顏色、清單的顏色…）：拿得到就用，拿不到用平常的顏色。
        if let binding = bindings?[FormlessBindableProperty.color.rawValue],
           case .color(let hex) = live.value(binding, at: date) {
            return hex
        }
        // 色階：數字落在哪裡就取那裡的顏色；沒有數字時用平常的顏色。
        if let scale = colorScale, let number = live.value(scale.subject, at: date).numberValue,
           let hex = scale.colorHex(for: number) {
            return hex
        }
        guard (colorHex ?? "").lowercased() == "auto" else { return colorHex }
        return FormlessDataBinding.colorHex(dataIndex, live: live)
    }
}

extension UUID {
    /// 由來源 id 和名稱推算的固定 id（RFC 4122 第 5 版，和 Python 的 uuid5 相同）：同一份舊檔每次轉出來的圖層 id 都一樣。
    init(formlessName name: String, in namespace: UUID) {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        self = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension FormlessLayer {
    /// 色塊的填色：單色、直線漸層（依角度與框的長寬算出起訖點，漸層剛好蓋滿整個框）或放射漸層（從中心往外）。
    func shapeFill(size: CGSize, solidHex: String?) -> AnyShapeStyle {
        let stops = (gradientStops ?? [])
            .sorted { $0.location < $1.location }
            .map { Gradient.Stop(color: Color(formlessHex: $0.colorHex, fallback: "#000000"), location: min(max($0.location, 0), 1)) }
        switch fillStyle {
        case .solid:
            return AnyShapeStyle(Color(formlessHex: solidHex, fallback: "#E6E6E8"))
        case .linear:
            guard stops.count >= 2 else { return AnyShapeStyle(stops.first?.color ?? Color(formlessHex: solidHex, fallback: "#E6E6E8")) }
            let angle = (gradientAngle ?? 180) * .pi / 180
            let dx = sin(angle), dy = -cos(angle)
            let w = max(size.width, 1), h = max(size.height, 1)
            // 漸層線通過中心，長度剛好讓兩端的垂直線碰到框的角（和 CSS linear-gradient 相同）。
            let length = abs(w * dx) + abs(h * dy)
            let start = UnitPoint(x: 0.5 - dx * length / (2 * w), y: 0.5 - dy * length / (2 * h))
            let end = UnitPoint(x: 0.5 + dx * length / (2 * w), y: 0.5 + dy * length / (2 * h))
            return AnyShapeStyle(LinearGradient(stops: stops, startPoint: start, endPoint: end))
        case .radial:
            guard stops.count >= 2 else { return AnyShapeStyle(stops.first?.color ?? Color(formlessHex: solidHex, fallback: "#E6E6E8")) }
            let radius = max(0.01, gradientRadius ?? 1)
            return AnyShapeStyle(EllipticalGradient(stops: stops, center: .center,
                                                    startRadiusFraction: 0, endRadiusFraction: 0.5 * radius))
        }
    }
}

/// 依圖層的形狀設定畫出來的 Shape；色塊的填色與外框都用它。
struct FormlessLayerShape: Shape {
    let kind: FormlessShapeKind
    let cornerRadius: CGFloat
    /// 四個角分開的圓角（左上、右上、右下、左下，已乘上縮放）；只用在矩形。
    var radii: [CGFloat]? = nil
    func path(in rect: CGRect) -> Path {
        if kind == .rectangle, let radii, radii.count == 4 {
            let limit = min(rect.width, rect.height) / 2
            return UnevenRoundedRectangle(topLeadingRadius: min(radii[0], limit), bottomLeadingRadius: min(radii[3], limit),
                                          bottomTrailingRadius: min(radii[2], limit), topTrailingRadius: min(radii[1], limit),
                                          style: .continuous).path(in: rect)
        }
        return kind.path(in: rect, cornerRadius: cornerRadius)
    }
}

extension FormlessLayer {
    /// 相簿輪播的全部圖片：原本那張在最前面。
    var slideshowImages: [String] {
        guard let extra = imageSet, !extra.isEmpty else { return value.map { [$0] } ?? [] }
        return (value.map { [$0] } ?? []) + extra
    }

    /// 每張顯示幾秒。
    var slideshowSeconds: TimeInterval { TimeInterval(max(1, imageInterval ?? 60) * 60) }

    /// date 那一刻要顯示的圖片：依時間輪流（每台裝置、每次更新算出來的都一樣）。
    func slideshowImage(at date: Date) -> String? {
        let images = slideshowImages
        guard images.count > 1 else { return value }
        let slot = Int((date.timeIntervalSince1970 / slideshowSeconds).rounded(.down))
        return images[((slot % images.count) + images.count) % images.count]
    }

    /// from～to 之間換下一張的時刻（小工具時間線在那一刻換畫面）。
    func slideshowChanges(from: Date, to: Date) -> [Date] {
        guard slideshowImages.count > 1 else { return [] }
        let step = slideshowSeconds
        var next = Date(timeIntervalSince1970: ((from.timeIntervalSince1970 / step).rounded(.down) + 1) * step)
        var result: [Date] = []
        while next < to, result.count < 24 {
            result.append(next)
            next.addTimeInterval(step)
        }
        return result
    }

    /// 畫的時候用的四個角圓角（乘上縮放）；沒有分開設定時是 nil。
    func scaledCornerRadii(_ scale: CGFloat) -> [CGFloat]? {
        cornerRadii.map { $0.map { CGFloat($0) * scale } }
    }
}


// MARK: - 時間樣式

enum FormlessTimeStyle: String, CaseIterable, Identifiable, Sendable {
    case auto
    case timer
    case countdown
    case relative
    case day

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "時鐘"
        case .timer: return "計時器"
        case .countdown: return "倒數"
        case .relative: return "相對時間"
        case .day: return "日期"
        }
    }
}


// MARK: - 點擊動作

enum FormlessTapAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case refresh
    case openApp
    case openURL
    case createEvent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .refresh: return "重新整理，不跳轉"
        case .openApp: return "開啟 Formless"
        case .openURL: return "開啟網址"
        case .createEvent: return "建立行事曆行程"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "refresh"
        self = FormlessTapAction(rawValue: raw) ?? .refresh
    }
}

/// 圖層自己的點擊動作：點到這個圖層就用它，其他地方照小工具的「點一下小工具」。
enum FormlessLayerTapAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case openURL
    case createEvent
    /// 執行捷徑（tapTarget 是捷徑名稱）。
    case runShortcut
    /// 開啟 Formless。
    case openFormless
    /// 重新整理資料，不跳轉。
    case refresh
    /// 切換我的資料（是非）。
    case toggleVariable
    /// 我的資料加減一個數（tapAmount）。
    case adjustVariable
    /// 完成這一筆提醒事項（放在重複排列的提醒事項裡）。
    case completeReminder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openURL: return "開啟網址"
        case .createEvent: return "建立行事曆行程"
        case .runShortcut: return "執行捷徑"
        case .openFormless: return "開啟 Formless"
        case .refresh: return "重新整理資料"
        case .toggleVariable: return "切換我的資料"
        case .adjustVariable: return "加減我的資料"
        case .completeReminder: return "完成提醒事項"
        }
    }

    /// 在小工具上直接執行、不打開 App 的動作（按鈕）。
    var isInteractive: Bool {
        switch self {
        case .refresh, .toggleVariable, .adjustVariable, .completeReminder: return true
        default: return false
        }
    }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "openURL"
        self = FormlessLayerTapAction(rawValue: raw) ?? .openURL
    }
}

/// Formless 自己的網址：小工具點下去用它叫起 App 做事。
enum FormlessDeepLink {
    /// 打開 Formless，直接跳出系統的新增行程面板。
    static let createEvent = URL(string: "formless://create-event")!
    /// 只打開 Formless。
    static let openApp = URL(string: "formless://open")!

    static func isCreateEvent(_ url: URL) -> Bool {
        url.scheme == createEvent.scheme && url.host() == createEvent.host()
    }
}

extension FormlessLayer {
    /// 實際生效的點擊動作。舊設計只填了 actionURL、沒有 tapAction 時視為開啟網址。
    var effectiveTapAction: FormlessLayerTapAction? {
        if let tapAction { return tapAction }
        let url = (actionURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : .openURL
    }

    /// 點這個圖層要開的網址；nil 表示這個圖層沒有自己的點擊動作（或是在小工具上直接執行的按鈕）。
    var tapDestination: URL? { tapDestination(live: FormlessLiveData(), date: Date()) }

    /// 網址可以取用資料（例如 RSS 文章的連結、行程的網址）。
    func tapDestination(live: FormlessLiveData, date: Date) -> URL? {
        switch effectiveTapAction {
        case .openURL:
            if let binding = bindings?[FormlessBindableProperty.url.rawValue],
               let text = live.value(binding, at: date).rawString?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return FormlessRemoteImageCache.url(from: text) ?? URL(string: text)
            }
            return URL(string: (actionURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case .createEvent: return FormlessDeepLink.createEvent
        case .runShortcut:
            let name = (tapTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "shortcuts://run-shortcut?name=" + encoded)
        case .openFormless: return FormlessDeepLink.openApp
        case .refresh, .toggleVariable, .adjustVariable, .completeReminder, nil: return nil
        }
    }

    /// 一次寫入（一個復原步驟）。改回跟隨小工具時一併清掉網址，不然舊網址會讓它又變回開啟網址；
    /// 換到用不到的動作時清掉它的參數。
    mutating func setTapAction(_ action: FormlessLayerTapAction?) {
        tapAction = action
        if action == nil { actionURL = nil }
        if ![.runShortcut, .toggleVariable, .adjustVariable].contains(action) { tapTarget = nil }
        if action != .adjustVariable { tapAmount = nil }
        if action != .openURL, var table = bindings {
            table[FormlessBindableProperty.url.rawValue] = nil
            bindings = table.isEmpty ? nil : table
        }
    }
}


// MARK: - 設計檔

struct FormlessDocument: Codable, Identifiable, Hashable, Sendable {

    var formatVersion: Int
    var id: UUID
    var name: String
    var family: FormlessWidgetFamily

    var backgroundColorHex: String?
    var backgroundImageName: String?
    /// 底色目前用的是圖片還是顏色（兩者都會保留，只是切換）；nil 表示舊檔：有圖片就用圖片。
    var backgroundUsesImage: Bool?

    var layers: [FormlessLayer]

    /// 要求的自動更新間隔（分鐘）。Apple 規定時間軸項目至少相隔約 5 分鐘，
    /// 且每顆小工具一天只有 40～70 次配額，因此下限壓在 5、預設 15。
    var refreshMinutes: Int?

    var tapAction: FormlessTapAction?
    var tapURL: String?
    /// 已結束的行程、時間已過的提醒也照常顯示（原本的做法）；nil／false 是依時間篩掉（`FormlessLiveData.at`）。
    var showsPastItems: Bool?

    /// 這份設計自己的資料來源（臺北天氣、東京天氣、工作行程）；沒有列出的用 App 預設。
    var sources: [FormlessSource]?
    /// 我的資料：設計內的具名值。
    var variables: [FormlessVariable]?
    /// 這個版本不認得的欄位，原樣保留。
    var preserved: [String: FormlessJSON]?

    /// 這個版本寫的檔案格式。2：加入資料來源、我的資料、文字區段、條件、進度、圖表與保留未知欄位（2026-10）。
    /// 只有設計與圖層最上層會保留不認得的欄位；在巢狀物件（綁定、格式、條件…）加欄位時要把這個數字加一，
    /// 舊版遇到較新的檔案只能看、不能存，才不會把新欄位弄丟。
    static let currentFormatVersion = 2

    /// 較新版本的 Formless 建立的設計：這個版本可能看不懂部分內容，只能看、不能存。
    var isFromNewerVersion: Bool { formatVersion > Self.currentFormatVersion }

    init(
        formatVersion: Int = FormlessDocument.currentFormatVersion,
        id: UUID = UUID(),
        name: String = "未命名小工具",
        family: FormlessWidgetFamily = .medium,
        backgroundColorHex: String? = "#F4F4F4",
        backgroundImageName: String? = nil,
        backgroundUsesImage: Bool? = nil,
        layers: [FormlessLayer] = [],
        refreshMinutes: Int? = nil,
        tapAction: FormlessTapAction? = nil,
        tapURL: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.family = family
        self.backgroundColorHex = backgroundColorHex
        self.backgroundImageName = backgroundImageName
        self.backgroundUsesImage = backgroundUsesImage
        self.layers = layers
        self.refreshMinutes = refreshMinutes
        self.tapAction = tapAction
        self.tapURL = tapURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.layers) else {
            throw DecodingError.keyNotFound(CodingKeys.layers, .init(codingPath: decoder.codingPath, debugDescription: "缺少設計圖層"))
        }

        // 舊檔（沒有版本或版本 1）讀進來就是目前版本：新格式只多不少，舊檔是它的子集合。
        // 比目前新的保留原版本號，編輯器據此唯讀（`isFromNewerVersion`）。
        formatVersion = max((try? c.decode(Int.self, forKey: .formatVersion)) ?? 1, Self.currentFormatVersion)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "未命名小工具"
        family = (try? c.decode(FormlessWidgetFamily.self, forKey: .family)) ?? .medium

        backgroundColorHex = try? c.decode(String.self, forKey: .backgroundColorHex)
        backgroundImageName = try? c.decode(String.self, forKey: .backgroundImageName)
        backgroundUsesImage = try? c.decode(Bool.self, forKey: .backgroundUsesImage)

        // 舊檔裡沒拆解的年度進度元件，讀進來就換成一般圖層（小工具與 App 讀檔都經過這裡）。
        layers = FormlessTemplate.expandLegacyLayers(try c.decode([FormlessLayer].self, forKey: .layers), family: family)

        refreshMinutes = try? c.decode(Int.self, forKey: .refreshMinutes)
        tapAction = try? c.decode(FormlessTapAction.self, forKey: .tapAction)
        tapURL = try? c.decode(String.self, forKey: .tapURL)
        showsPastItems = try? c.decode(Bool.self, forKey: .showsPastItems)
        sources = try? c.decode([FormlessSource].self, forKey: .sources)
        variables = try? c.decode([FormlessVariable].self, forKey: .variables)
        preserved = decoder.formlessUnknownFields(known: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion, id, name, family, backgroundColorHex, backgroundImageName, backgroundUsesImage, layers
        case refreshMinutes, tapAction, tapURL, showsPastItems, sources, variables
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(family, forKey: .family)
        try c.encodeIfPresent(backgroundColorHex, forKey: .backgroundColorHex)
        try c.encodeIfPresent(backgroundImageName, forKey: .backgroundImageName)
        try c.encodeIfPresent(backgroundUsesImage, forKey: .backgroundUsesImage)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(refreshMinutes, forKey: .refreshMinutes)
        try c.encodeIfPresent(tapAction, forKey: .tapAction)
        try c.encodeIfPresent(tapURL, forKey: .tapURL)
        try c.encodeIfPresent(showsPastItems, forKey: .showsPastItems)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encodeIfPresent(variables, forKey: .variables)
        try encoder.formlessWriteUnknownFields(preserved)
    }

    /// 預設 15 分鐘，也就是官方配額換算下來最密集而不浪費的間隔
    var effectiveRefreshMinutes: Int {
        min(max(refreshMinutes ?? 15, 5), 240)
    }

    var effectiveTapAction: FormlessTapAction {
        tapAction ?? .refresh
    }

    var sortedLayers: [FormlessLayer] {
        layers.sorted { $0.zIndex < $1.zIndex }
    }

    private var hiddenGroupIDs: Set<UUID> {
        Set(layers.filter { $0.group && !$0.visible }.map(\.id))
    }

    private var lockedGroupIDs: Set<UUID> {
        Set(layers.filter { $0.group && $0.locked }.map(\.id))
    }

    var groups: [FormlessLayer] {
        layers.filter(\.group)
    }

    func effectivelyHidden(_ layer: FormlessLayer) -> Bool {
        if !layer.visible { return true }
        if let parent = layer.parentID, hiddenGroupIDs.contains(parent) { return true }
        return false
    }

    func effectivelyLocked(_ layer: FormlessLayer) -> Bool {
        if layer.locked { return true }
        if let parent = layer.parentID, lockedGroupIDs.contains(parent) { return true }
        return false
    }

    func children(of groupID: UUID) -> [FormlessLayer] {
        layers.filter { $0.parentID == groupID }
    }

    var visibleSortedLayers: [FormlessLayer] {
        let hidden = hiddenGroupIDs

        return sortedLayers.filter { layer in
            if layer.group { return false }
            if !layer.visible { return false }
            if let parent = layer.parentID, hidden.contains(parent) { return false }
            return true
        }
    }

    /// 天氣、行程、步數需要較頻繁更新
    var needsFrequentRefresh: Bool {
        layers.contains {
            $0.type == .weather
                || $0.type == .events
                || $0.type == .reminders
                || $0.type == .steps
        }
    }

    /// 是否需要每分鐘更新
    var needsMinuteRefresh: Bool {
        layers.contains { layer in
            if layer.type == .time {
                // 計時器、倒數、相對時間由系統自己走，不必靠時間軸。時鐘（`.time` 樣式）和自訂格式顯示的是
                // 那一格的固定時間，不會自己走（Apple「Displaying dynamic dates」：只有 relative、offset、timer
                // 會持續更新），要靠時間軸換畫面；原本把時鐘也當成會自己走，桌面上的時鐘停在上次重新整理的時間
                // （2026-10-03 模擬器實測停了 18 分鐘）。日期樣式和日期圖層一樣，跨日靠下一次重新整理。
                switch FormlessTimeStyle(rawValue: layer.value ?? FormlessTimeStyle.auto.rawValue) {
                case .timer, .countdown, .relative, .day: return false
                case .auto, .none: return true
                }
            }

            if layer.type == .date {
                let format = layer.value ?? ""
                return format.contains("H") || format.contains("m") || format.contains("h")
            }

            // 指針時鐘顯示的是那一格的時間，靠時間軸換畫面（和數字時鐘一樣）。
            if layer.type == .clock { return true }

            return false
        } || FormlessDataCoordinator.needsMinuteRefresh(self)
    }
}


// MARK: - 範本

extension FormlessDocument {
    /// 目前生效的背景圖片：選了「顏色」就是 nil（圖片仍保留在 backgroundImageName，隨時可切回）。
    var activeBackgroundImageName: String? {
        guard let backgroundImageName else { return nil }
        return (backgroundUsesImage ?? true) ? backgroundImageName : nil
    }
}

enum FormlessTemplate {

    static func calendarDocument(editable: Bool = true) -> FormlessDocument {
        let document = FormlessDocument(
            name: "日期月曆",
            family: .medium,
            backgroundColorHex: "#F4F4F4",
            layers: [
                FormlessLayer(
                    name: "完整月曆",
                    type: .calendar,
                    frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 0,
                    value: "自動",
                    colorHex: "#FF3B30",
                    fontWeight: "medium",
                    cornerRadius: 15,
                    secondaryColorHex: "#808495",
                    panelColorHex: "#E6E6E8",
                    textColorHex: "#000000",
                    showsPanel: true,
                    weekStartsOnMonday: false
                )
            ]
        )
        return editable ? editableDocument(document) : document
    }

    static func yearProgressDocument(editable: Bool = true) -> FormlessDocument {
        let document = FormlessDocument(
            name: "年度進度",
            family: .medium,
            backgroundColorHex: "#F4F4F4",
            layers: [
                FormlessLayer(
                    name: "年度進度",
                    type: .yearProgress,
                    frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 0,
                    colorHex: "#000000",
                    secondaryColorHex: "#808495",
                    textColorHex: "#D8D8DA"
                )
            ]
        )
        return editable ? editableDocument(document) : document
    }

    static func eventsDocument(editable: Bool = true) -> FormlessDocument {
        let document = FormlessDocument(
            name: "今日行程",
            family: .large,
            backgroundColorHex: "#F9F8F9",
            layers: [
                FormlessLayer(
                    name: "今日行程",
                    type: .events,
                    frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 0,
                    value: "Today's Events",
                    colorHex: "#000000",
                    secondaryColorHex: "#808080",
                    panelColorHex: "#FFFFFF",
                    textColorHex: "#808080",
                    maxItems: 5
                )
            ]
        )
        return editable ? editableDocument(document) : document
    }

    static func remindersDocument(editable: Bool = true) -> FormlessDocument {
        let document = FormlessDocument(
            name: "提醒事項",
            family: .small,
            backgroundColorHex: "#F4F4F4",
            layers: [
                FormlessLayer(
                    name: "提醒事項",
                    type: .reminders,
                    frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 0,
                    value: "Reminders",
                    colorHex: "#000000",
                    secondaryColorHex: "#757575",
                    textColorHex: "#424242",
                    showsPanel: true,
                    maxItems: 3
                )
            ]
        )
        return editable ? editableDocument(document) : document
    }

    static func stepsDocument(editable: Bool = true) -> FormlessDocument {
        let document = FormlessDocument(
            name: "步數",
            family: .small,
            backgroundColorHex: "#FDFDFD",
            layers: [
                FormlessLayer(
                    name: "步數",
                    type: .steps,
                    frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 0,
                    value: "步數",
                    colorHex: "#9DE14E",
                    secondaryColorHex: "#808495",
                    panelColorHex: "#EEF8DF",
                    textColorHex: "#000000"
                )
            ]
        )
        return editable ? editableDocument(document) : document
    }

    static func weatherDocument(editable: Bool = true) -> FormlessDocument {
        let document = FormlessDocument(
            name: "天氣",
            family: .medium,
            backgroundColorHex: "#F4F4F4",
            layers: [
                FormlessLayer(
                    name: "天氣",
                    type: .weather,
                    frame: FormlessFrame(x: 0, y: 0, width: 1, height: 1),
                    zIndex: 0,
                    colorHex: "#000000",
                    secondaryColorHex: "#808495",
                    panelColorHex: "#FFFFFF",
                    latitude: 25.0330,
                    longitude: 121.5654,
                    locationName: "台北",
                    useCurrentLocation: true
                )
            ]
        )
        return editable ? editableDocument(document) : document
    }

    static func blankDocument(
        name: String,
        family: FormlessWidgetFamily
    ) -> FormlessDocument {
        FormlessDocument(
            name: name,
            family: family,
            backgroundColorHex: "#F4F4F4",
            layers: []
        )
    }

    static func defaultLayer(
        for type: FormlessLayerType
    ) -> FormlessLayer {

        switch type {

        case .text:
            return FormlessLayer(
                name: "文字",
                type: .text,
                frame: FormlessFrame(x: 0.08, y: 0.36, width: 0.5, height: 0.25),
                value: "文字",
                colorHex: "#000000",
                fontSize: 22,
                fontWeight: "bold"
            )

        case .date:
            return FormlessLayer(
                name: "日期",
                type: .date,
                frame: FormlessFrame(x: 0.08, y: 0.36, width: 0.55, height: 0.25),
                value: "M月d日",
                colorHex: "#000000",
                fontSize: 22,
                fontWeight: "bold"
            )

        case .time:
            return FormlessLayer(
                name: "時間",
                type: .time,
                frame: FormlessFrame(x: 0.08, y: 0.36, width: 0.45, height: 0.25),
                value: FormlessTimeStyle.auto.rawValue,
                colorHex: "#000000",
                fontSize: 30,
                fontWeight: "bold"
            )

        case .shape:
            return FormlessLayer(
                name: "色塊",
                type: .shape,
                frame: FormlessFrame(x: 0.1, y: 0.25, width: 0.35, height: 0.45),
                colorHex: "#E6E6E8",
                cornerRadius: 16
            )

        case .image:
            return FormlessLayer(
                name: "圖片",
                type: .image,
                frame: FormlessFrame(x: 0.1, y: 0.2, width: 0.35, height: 0.5)
            )

        case .remoteImage:
            return FormlessLayer(
                name: "網路圖片",
                type: .remoteImage,
                frame: FormlessFrame(x: 0.1, y: 0.2, width: 0.35, height: 0.5),
                value: "https://"
            )

        case .symbol:
            return FormlessLayer(
                name: "圖示",
                type: .symbol,
                frame: FormlessFrame(x: 0.1, y: 0.3, width: 0.16, height: 0.3),
                value: "star.fill",
                colorHex: "#000000"
            )

        case .bundleImage:
            return FormlessLayer(
                name: "圖片",
                type: .bundleImage,
                frame: FormlessFrame(x: 0.1, y: 0.1, width: 0.27, height: 0.27),
                value: "ReminderIcon"
            )

        case .liveText:
            return FormlessLayer(
                name: "即時文字",
                type: .liveText,
                frame: FormlessFrame(x: 0.08, y: 0.36, width: 0.5, height: 0.25),
                value: FormlessLiveSource.eventCount.rawValue,
                colorHex: "#000000",
                fontSize: 28,
                fontWeight: "bold"
            )

        case .ruler:
            return FormlessLayer(
                name: "刻度軸",
                type: .ruler,
                frame: FormlessFrame(x: 0.05, y: 0, width: 0.025, height: 1),
                colorHex: "#000000",
                maxItems: 70
            )

        case .calendarGrid:
            return FormlessLayer(
                name: "月曆格",
                type: .calendarGrid,
                // 大小與位置和使用者的「日期月曆」日期格相同（使用者：原本的預設比較大，不對）。
                frame: FormlessFrame(x: 0.495, y: 0.205, width: 0.46, height: 0.7425),
                // 強調色預設是系統紅 #FF3B30（使用者指定），和繪製時沒設定顏色的預設值一致。
                colorHex: "#FF3B30",
                fontSize: 10,
                fontWeight: "medium",
                secondaryColorHex: "#808495",
                textColorHex: "#000000"
            )

        case .eventList:
            return FormlessLayer(
                name: "事件清單",
                type: .eventList,
                frame: FormlessFrame(x: 0.113, y: 0.244, width: 0.843, height: 0.73),
                colorHex: "#000000",
                panelColorHex: "#FFFFFF",
                textColorHex: "#666666",
                maxItems: 5
            )

        case .reminderList:
            return FormlessLayer(
                name: "提醒清單",
                type: .reminderList,
                frame: FormlessFrame(x: 0.06, y: 0.50, width: 0.88, height: 0.45),
                fontSize: 15,
                textColorHex: "#1C1C1E",
                maxItems: 3
            )

        case .weatherForecast:
            return FormlessLayer(
                name: "天氣預報列",
                type: .weatherForecast,
                frame: FormlessFrame(x: 0.055, y: 0.477, width: 0.89, height: 0.42),
                fontSize: 11.5,
                secondaryColorHex: "#80828E",
                panelColorHex: "#FFFFFF",
                maxItems: 5
            )

        case .yearGrid:
            return FormlessLayer(
                name: "年度進度格",
                type: .yearGrid,
                frame: FormlessFrame(x: 0.045, y: 0.27, width: 0.91, height: 0.70),
                colorHex: "#000000",
                textColorHex: "#D8D8DA"
            )

        case .gradient:
            return FormlessLayer.fade(name: "漸層", frame: FormlessFrame(x: 0, y: 0.5, width: 1, height: 0.5), colorHex: "#FFFFFF")

        case .calendar:
            return FormlessTemplate.calendarDocument(editable: false).layers[0]

        case .events:
            return FormlessTemplate.eventsDocument(editable: false).layers[0]

        case .reminders:
            return FormlessTemplate.remindersDocument(editable: false).layers[0]

        case .weather:
            return FormlessTemplate.weatherDocument(editable: false).layers[0]

        case .steps:
            return FormlessTemplate.stepsDocument(editable: false).layers[0]

        case .yearProgress:
            return FormlessTemplate.yearProgressDocument(editable: false).layers[0]

        case .progress:
            var layer = FormlessLayer(
                name: "進度",
                type: .progress,
                frame: FormlessFrame(x: 0.08, y: 0.44, width: 0.6, height: 0.12),
                colorHex: "#007AFF"
            )
            layer.progress = FormlessProgressSpec(value: .number(60), goal: .number(100), style: .linear)
            return layer

        case .clock:
            // 錶盤是框的內切圓：中型上大約是正方形（寬 0.36 × 338 ≈ 高 0.8 × 158）。
            var layer = FormlessLayer(
                name: "時鐘",
                type: .clock,
                frame: FormlessFrame(x: 0.08, y: 0.1, width: 0.36, height: 0.8),
                colorHex: "#000000"
            )
            layer.textColorHex = "#8E8E93"
            layer.clock = FormlessClockSpec(marks: FormlessClockMarks.hours.rawValue, numerals: FormlessClockNumerals.none.rawValue)
            return layer

        case .chart:
            var layer = FormlessLayer(
                name: "圖表",
                type: .chart,
                frame: FormlessFrame(x: 0.08, y: 0.2, width: 0.55, height: 0.6),
                colorHex: "#007AFF",
                fontSize: 10
            )
            layer.chart = FormlessChartSpec(series: FormlessBinding(source: "activity", field: "history"),
                                            valueField: "steps", labelField: "date", kind: .bar, maxPoints: 7)
            return layer
        }
    }
}


// MARK: - 儲存

private let formlessSharedContainerURL: URL? = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: FormlessConstants.appGroupID
)


struct FormlessTrashItem: Identifiable, Sendable {
    let document: FormlessDocument
    let deletedAt: Date
    var id: UUID { document.id }

    /// 還剩幾天會被永久刪除，最少顯示 1 天。
    var remainingDays: Int {
        let elapsed = Date().timeIntervalSince(deletedAt) / 86_400
        return max(1, FormlessStorage.trashRetentionDays - Int(elapsed))
    }
}

enum FormlessStorage {

    /// 問系統要共用資料夾的成本不低，畫面重繪時會被叫很多次，用全域常數只算一次
    nonisolated static var sharedContainerURL: URL? {
        formlessSharedContainerURL
    }

    nonisolated private static func directory(_ name: String) -> URL? {
        guard let root = formlessSharedContainerURL else { return nil }

        let url = root.appendingPathComponent(name, isDirectory: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }

        return url
    }

    nonisolated static var widgetsDirectoryURL: URL? {
        directory("Widgets")
    }

    nonisolated static var assetsDirectoryURL: URL? {
        directory("Assets")
    }

    nonisolated static var cacheDirectoryURL: URL? {
        directory("Cache")
    }

    // MARK: 最近刪除

    nonisolated static var trashDirectoryURL: URL? {
        directory("Trash")
    }

    /// 刪掉的設計先留在「最近刪除」，超過天數才真的消失。
    nonisolated static let trashRetentionDays = 10

    nonisolated static func trashFileURL(for id: UUID) throws -> URL {
        guard let directory = trashDirectoryURL else {
            throw FormlessError.noSharedContainer
        }

        return directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(FormlessConstants.fileExtension)
    }

    /// 移到「最近刪除」：先留一份副本，再把正式檔案刪掉。
    nonisolated static func trash(_ document: FormlessDocument) throws {
        let url = try trashFileURL(for: document.id)
        try encode(document).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        try delete(id: document.id)
    }

    nonisolated static func purgeExpiredTrash() {
        guard let directory = trashDirectoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }

        let deadline = Date().addingTimeInterval(-Double(trashRetentionDays) * 86_400)

        for fileURL in files where fileURL.pathExtension == FormlessConstants.fileExtension {
            let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if date < deadline {
                try? FileManager.default.removeItem(at: fileURL)
                // 設計永久刪除了，它的版本紀錄也不再需要。
                if let id = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent) { FormlessVersionStore.deleteAll(of: id) }
            }
        }
    }

    nonisolated static func trashItems() -> [FormlessTrashItem] {
        purgeExpiredTrash()

        guard let directory = trashDirectoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return [] }

        let decoder = JSONDecoder()
        var result: [FormlessTrashItem] = []

        for fileURL in files where fileURL.pathExtension == FormlessConstants.fileExtension {
            guard let data = try? Data(contentsOf: fileURL),
                  let document = try? decoder.decode(FormlessDocument.self, from: data) else { continue }
            let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            result.append(FormlessTrashItem(document: document, deletedAt: date))
        }

        return result.sorted { $0.deletedAt > $1.deletedAt }
    }

    nonisolated static func restoreFromTrash(id: UUID) throws {
        let url = try trashFileURL(for: id)
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(FormlessDocument.self, from: data)
        try save(document)
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func removeFromTrash(id: UUID) {
        guard let url = try? trashFileURL(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
        FormlessVersionStore.deleteAll(of: id)
    }

    nonisolated static func emptyTrash() {
        guard let directory = trashDirectoryURL,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for fileURL in files {
            try? FileManager.default.removeItem(at: fileURL)
            if let id = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent) { FormlessVersionStore.deleteAll(of: id) }
        }
    }

    nonisolated static func fileURL(for id: UUID) throws -> URL {
        guard let directory = widgetsDirectoryURL else {
            throw FormlessError.noSharedContainer
        }

        return directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(FormlessConstants.fileExtension)
    }

    nonisolated static func encode(_ document: FormlessDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    nonisolated static func save(_ document: FormlessDocument) throws {
        // 較新版本建立的設計只能看：這個版本看不懂的部分存回去會遺失。
        guard !document.isFromNewerVersion else { throw FormlessError.newerVersion }
        let url = try fileURL(for: document.id)
        backupOldFormat(at: url, id: document.id)
        let data = try encode(document)
        // 版本紀錄（2026-10）：距離上一個版本超過 10 分鐘、內容有變時，把要被蓋掉的舊檔留成一個版本（最多 10 個）。
        FormlessVersionStore.recordPrevious(fileAt: url, for: document.id, before: data)
        try data.write(to: url, options: .atomic)
    }

    nonisolated static var formatBackupDirectoryURL: URL? {
        directory("Backups")
    }

    /// 舊格式（版本 1）的設計第一次被新格式覆蓋前，留一份原檔在 Backups/v1/：回到舊版 App 時可以取回原本的樣子。
    nonisolated static func backupOldFormat(at url: URL, id: UUID) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let version = (object["formatVersion"] as? Int) ?? 1
        guard version < FormlessDocument.currentFormatVersion, let root = formatBackupDirectoryURL else { return }
        let folder = root.appendingPathComponent("v\(version)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(id.uuidString).appendingPathExtension(FormlessConstants.fileExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try? data.write(to: target, options: .atomic)
    }

    nonisolated static func loadAll() -> [FormlessDocument] {
        guard let directory = widgetsDirectoryURL else { return [] }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()

        var result: [FormlessDocument] = []

        for fileURL in files {
            guard fileURL.pathExtension == FormlessConstants.fileExtension else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let document = try? decoder.decode(FormlessDocument.self, from: data) else { continue }
            result.append(document)
        }

        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func load(idString: String) -> FormlessDocument? {
        guard let id = UUID(uuidString: idString) else { return nil }
        guard let url = try? fileURL(for: id) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FormlessDocument.self, from: data)
    }

    /// 刪除。找不到檔名時會再掃一次資料夾比對內容，避免舊檔命名不一致而刪不掉。
    nonisolated static func delete(id: UUID) throws {
        guard let directory = widgetsDirectoryURL else {
            throw FormlessError.noSharedContainer
        }

        let manager = FileManager.default
        var removed = false

        let direct = directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension(FormlessConstants.fileExtension)

        if manager.fileExists(atPath: direct.path) {
            try manager.removeItem(at: direct)
            removed = true
        }

        if let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let decoder = JSONDecoder()

            for fileURL in files {
                guard fileURL.pathExtension == FormlessConstants.fileExtension else { continue }
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                guard let document = try? decoder.decode(FormlessDocument.self, from: data) else { continue }

                if document.id == id {
                    try manager.removeItem(at: fileURL)
                    removed = true
                }
            }
        }

        if !removed {
            throw FormlessError.deleteFailed
        }
    }

    nonisolated static func delete(_ document: FormlessDocument) throws {
        try delete(id: document.id)
    }

    nonisolated static func duplicate(_ document: FormlessDocument) throws -> FormlessDocument {
        var copy = document
        copy.id = UUID()
        copy.name = document.name + "（複製）"
        var identifiers: [UUID: UUID] = [:]
        for layer in document.layers { identifiers[layer.id] = UUID() }
        copy.layers = document.layers.map { layer in
            var newLayer = layer
            newLayer.id = identifiers[layer.id] ?? UUID()
            newLayer.parentID = layer.parentID.flatMap { identifiers[$0] }
            return newLayer
        }
        try save(copy)
        return copy
    }

    nonisolated static func encodeBundle(_ documents: [FormlessDocument]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var bundle = FormlessBundle(designs: documents)
        var names = Set<String>()
        for document in documents {
            if let name = document.backgroundImageName { names.insert(name) }
            for layer in document.layers where layer.type == .image {
                if let name = layer.value { names.insert(name) }
                // 相簿輪播的其他照片一起匯出。
                for name in layer.imageSet ?? [] { names.insert(name) }
            }
        }
        for name in names {
            guard name == URL(fileURLWithPath: name).lastPathComponent,
                  let directory = assetsDirectoryURL else { throw FormlessError.missingAsset }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                throw FormlessError.missingAsset
            }
            bundle.assets[name] = data
        }
        return try encoder.encode(bundle)
    }

    /// 匯入。單份設計、設計陣列、或匯出包都吃得下。
    @discardableResult
    nonisolated static func importDocuments(from sourceURL: URL) throws -> [FormlessDocument] {
        let gotAccess = sourceURL.startAccessingSecurityScopedResource()

        defer {
            if gotAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var incoming: [FormlessDocument] = []
        var assets: [String: Data] = [:]

        if let bundle = try? decoder.decode(FormlessBundle.self, from: data) {
            guard bundle.version == 1 else { throw FormlessError.unsupportedVersion }
            incoming = bundle.designs
            assets = bundle.assets
        } else if let list = try? decoder.decode([FormlessDocument].self, from: data) {
            incoming = list
        } else {
            incoming = [try decoder.decode(FormlessDocument.self, from: data)]
        }

        guard !incoming.isEmpty else {
            throw FormlessError.emptyImport
        }

        for document in incoming {
            guard Set(document.layers.map(\.id)).count == document.layers.count else {
                throw FormlessError.invalidLayers
            }
        }
        var renamedAssets: [String: String] = [:]
        for (name, data) in assets {
            // 走圖片庫的加入流程：內容相同就沿用既有那一張，不再每次匯入都另存一份。
            guard let item = FormlessAssetLibrary.add(data: data) else { throw FormlessError.missingAsset }
            renamedAssets[name] = item.id
        }

        var existing = Set(loadAll().map(\.name))
        var saved: [FormlessDocument] = []

        for var document in incoming {
            document.id = UUID()
            if let name = document.backgroundImageName, let replacement = renamedAssets[name] {
                document.backgroundImageName = replacement
            }
            for index in document.layers.indices where document.layers[index].type == .image {
                if let name = document.layers[index].value, let replacement = renamedAssets[name] {
                    document.layers[index].value = replacement
                }
                if let set = document.layers[index].imageSet {
                    document.layers[index].imageSet = set.map { renamedAssets[$0] ?? $0 }
                }
            }

            if existing.contains(document.name) {
                var candidate = document.name + "（匯入）"
                var index = 2

                while existing.contains(candidate) {
                    candidate = document.name + "（匯入 \(index)）"
                    index += 1
                }

                document.name = candidate
            }

            existing.insert(document.name)

            try save(document)
            saved.append(document)
        }

        return saved
    }

    @discardableResult
    nonisolated static func importDocument(from sourceURL: URL) throws -> FormlessDocument {
        guard let first = try importDocuments(from: sourceURL).first else {
            throw FormlessError.emptyImport
        }

        return first
    }

    /// 匯出到暫存資料夾，回傳可分享的檔案位置
    nonisolated static func exportFile(for document: FormlessDocument) throws -> URL {
        let safeName = document.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension(FormlessConstants.fileExtension)

        let data = try encode(document)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)

        return url
    }

    nonisolated static func saveAsset(data: Data) throws -> String {
        guard let directory = assetsDirectoryURL else {
            throw FormlessError.noSharedContainer
        }

        let name = UUID().uuidString + ".image"
        let url = directory.appendingPathComponent(name)

        try data.write(to: url, options: .atomic)
        FormlessAssetCache.shared.invalidate(name)

        return name
    }

    nonisolated static func assetData(named name: String) -> Data? {
        FormlessAssetCache.shared.data(named: name)
    }

    /// 清掉已經沒有任何設計在用的圖片，避免共用資料夾一直長大
    nonisolated static func pruneAssets() {
        guard let directory = assetsDirectoryURL else { return }
        guard let widgets = widgetsDirectoryURL else { return }

        guard (try? FileManager.default.contentsOfDirectory(
            at: widgets,
            includingPropertiesForKeys: nil
        )) != nil else {
            return
        }

        let documents = loadAll()
        var used = Set<String>()

        for document in documents {
            if let name = document.backgroundImageName { used.insert(name) }

            for layer in document.layers where layer.type == .image {
                if let name = layer.value { used.insert(name) }
                for name in layer.imageSet ?? [] { used.insert(name) }
            }
        }

        for name in FormlessWeatherStyle.current().images.values {
            used.insert(name)
        }

        for item in FormlessAssetLibrary.all() {
            used.insert(item.id)
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            let name = file.lastPathComponent

            guard name.hasSuffix(".image") else { continue }
            guard !used.contains(name) else { continue }
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) > 86_400 else { continue }

            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name + ".thumb")
            )

            try? FileManager.default.removeItem(at: file)
        }
    }
}


/// 匯出包。一個檔案可以帶多份設計與用到的圖片。只放設計資料本身，不附任何說明文字（使用者要求）；
/// 舊版匯出檔裡的「增修指南」在讀取時直接忽略。
struct FormlessBundle: Codable, Sendable {

    var format: String
    var version: Int
    var exportedAt: Date
    var designs: [FormlessDocument]
    var assets: [String: Data] = [:]

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case exportedAt
        case designs
        case assets
    }

    init(designs: [FormlessDocument]) {
        self.format = "formless.bundle"
        self.version = 1
        self.exportedAt = Date()
        self.designs = designs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        format = (try? c.decode(String.self, forKey: .format)) ?? ""
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        exportedAt = (try? c.decode(Date.self, forKey: .exportedAt)) ?? Date()
        designs = try c.decode([FormlessDocument].self, forKey: .designs)
        assets = try c.decodeIfPresent([String: Data].self, forKey: .assets) ?? [:]
    }


}


enum FormlessError: LocalizedError {
    case noSharedContainer
    case deleteFailed
    case emptyImport
    case missingAsset
    case unsupportedVersion
    case invalidLayers
    case newerVersion

    var errorDescription: String? {
        switch self {
        case .noSharedContainer:
            return "暫時無法存取設計資料。請重新開啟 App 後再試。"
        case .deleteFailed:
            return "找不到要刪除的檔案。"
        case .emptyImport:
            return "檔案裡沒有可用的設計。"
        case .missingAsset:
            return "設計中的圖片遺失或無法讀取，請重新選擇圖片後再試。"
        case .unsupportedVersion:
            return "此設計檔使用較新的格式，請更新 App 後再匯入。"
        case .invalidLayers:
            return "設計檔包含重複的圖層識別碼，請修正檔案後再匯入。"
        case .newerVersion:
            return "這份設計由較新版本的 Formless 建立，這個版本只能檢視、不能修改。"
        }
    }
}


// MARK: - 顏色

extension Color {

    init(formlessHex hex: String) {
        // 淺色、深色兩個值（「#淺色|#深色」，2026-10）：跟著外觀自動換，小工具上由系統依主畫面的深淺色決定。
        if let pair = FormlessDualColor.split(hex) {
            #if canImport(UIKit)
            let light = UIColor(Color(formlessHex: pair.light)), dark = UIColor(Color(formlessHex: pair.dark))
            self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
            #else
            self.init(formlessHex: pair.light)
            #endif
            return
        }
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: "#", with: "")

        if clean.count == 3 {
            clean = clean.map { "\($0)\($0)" }.joined()
        }

        if clean.count == 8 {
            if let value = UInt64(clean, radix: 16) {
                self.init(
                    .sRGB,
                    red: Double((value >> 24) & 0xFF) / 255,
                    green: Double((value >> 16) & 0xFF) / 255,
                    blue: Double((value >> 8) & 0xFF) / 255,
                    opacity: Double(value & 0xFF) / 255
                )
                return
            }
        }

        if clean.count == 6, let value = UInt64(clean, radix: 16) {
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1
            )
            return
        }

        self = .black
    }

    init(formlessHex hex: String?, fallback: String) {
        if let hex, !hex.isEmpty {
            self.init(formlessHex: hex)
        } else {
            self.init(formlessHex: fallback)
        }
    }

    var formlessHex: String {
        #if canImport(UIKit)
        let native = UIColor(self)

        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        native.getRed(&r, green: &g, blue: &b, alpha: &a)

        let ri = Int(round(max(0, min(1, r)) * 255))
        let gi = Int(round(max(0, min(1, g)) * 255))
        let bi = Int(round(max(0, min(1, b)) * 255))
        let ai = Int(round(max(0, min(1, a)) * 255))

        if ai < 255 {
            return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
        }
        return String(format: "#%02X%02X%02X", ri, gi, bi)
        #else
        return "#000000"
        #endif
    }
}


/// 一個顏色欄位存淺色、深色兩個值：「#淺色|#深色」。舊版 App 讀到會當成無效顏色（顯示黑色），
/// 所以只有使用者打開「淺色、深色分開設定」的顏色才會這樣存。
enum FormlessDualColor {
    static let separator: Character = "|"

    /// 有兩個值時回傳兩個值；只有一個值回 nil。
    static func split(_ hex: String?) -> (light: String, dark: String)? {
        guard let hex, let bar = hex.firstIndex(of: separator) else { return nil }
        let light = String(hex[..<bar]).trimmingCharacters(in: .whitespaces)
        let dark = String(hex[hex.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        return (light, dark.isEmpty ? light : dark)
    }

    static func join(light: String, dark: String) -> String {
        light + String(separator) + dark
    }

    /// 淺色那個值（只有一個值時就是它）。
    static func light(_ hex: String?) -> String? {
        split(hex)?.light ?? hex
    }
}

func formlessFontWeight(_ value: String?) -> Font.Weight {
    switch value {
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return .regular
    }
}

struct FormlessNamedOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

/// 文字的字型：匯入的字型（fontFamily 是「custom:PostScript 名稱」）裝得到就用它，否則是系統字型的四種樣式。
/// 匯入的字型粗細是字型檔本身決定的，不套 fontWeight。舊版 App 讀到 custom: 會退回系統字型。
func formlessFont(size: CGFloat, weight: String?, family: String?) -> Font {
    if let name = FormlessFontLibrary.postScriptName(fromFamily: family), FormlessFontLibrary.isAvailable(name) {
        return .custom(name, fixedSize: size)
    }
    return .system(size: size, weight: formlessFontWeight(weight), design: formlessFontDesign(family))
}

func formlessFontDesign(_ value: String?) -> Font.Design {
    switch value {
    case "rounded": return .rounded
    case "serif": return .serif
    case "monospaced": return .monospaced
    default: return .default
    }
}

let formlessFontFamilyOptions: [FormlessNamedOption] = [
    FormlessNamedOption(id: "system", displayName: "系統"),
    FormlessNamedOption(id: "rounded", displayName: "圓體"),
    FormlessNamedOption(id: "serif", displayName: "襯線"),
    FormlessNamedOption(id: "monospaced", displayName: "等寬")
]

let formlessFontWeightOptions: [FormlessNamedOption] = [
    FormlessNamedOption(id: "light", displayName: "細"),
    FormlessNamedOption(id: "regular", displayName: "一般"),
    FormlessNamedOption(id: "medium", displayName: "中等"),
    FormlessNamedOption(id: "semibold", displayName: "半粗"),
    FormlessNamedOption(id: "bold", displayName: "粗"),
    FormlessNamedOption(id: "heavy", displayName: "特粗"),
    FormlessNamedOption(id: "black", displayName: "最粗")
]

struct FormlessCityOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let latitude: Double
    let longitude: Double

    init(_ name: String, _ latitude: Double, _ longitude: Double) {
        self.id = name
        self.displayName = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

let formlessCityOptions: [FormlessCityOption] = [
    FormlessCityOption("台北", 25.0330, 121.5654),
    FormlessCityOption("新北", 25.0169, 121.4627),
    FormlessCityOption("基隆", 25.1276, 121.7392),
    FormlessCityOption("桃園", 24.9936, 121.3010),
    FormlessCityOption("新竹", 24.8138, 120.9675),
    FormlessCityOption("苗栗", 24.5602, 120.8214),
    FormlessCityOption("台中", 24.1477, 120.6736),
    FormlessCityOption("彰化", 24.0718, 120.5624),
    FormlessCityOption("南投", 23.9609, 120.9719),
    FormlessCityOption("雲林", 23.7092, 120.4313),
    FormlessCityOption("嘉義", 23.4801, 120.4491),
    FormlessCityOption("台南", 22.9997, 120.2270),
    FormlessCityOption("高雄", 22.6273, 120.3014),
    FormlessCityOption("屏東", 22.6813, 120.4879),
    FormlessCityOption("宜蘭", 24.7021, 121.7378),
    FormlessCityOption("花蓮", 23.9871, 121.6015),
    FormlessCityOption("台東", 22.7583, 121.1444),
    FormlessCityOption("澎湖", 23.5711, 119.5793)
]

let formlessDateFormatSamples: [FormlessNamedOption] = [
    FormlessNamedOption(id: "yyyy/MM/dd", displayName: "年月日"),
    FormlessNamedOption(id: "M月d日", displayName: "中式日期"),
    FormlessNamedOption(id: "EEEE", displayName: "星期"),
    FormlessNamedOption(id: "d", displayName: "日"),
    FormlessNamedOption(id: "HH:mm", displayName: "24 小時"),
    FormlessNamedOption(id: "a h:mm", displayName: "12 小時")
]

/// DateFormatter 建立成本高，畫面每次重繪都建一個會拖慢主執行緒，因此依格式快取。
private let formlessDateFormatters = FormlessFormatterCache()

final class FormlessFormatterCache: @unchecked Sendable {

    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func formatter(_ format: String) -> DateFormatter? {
        lock.lock()
        defer { lock.unlock() }

        if let hit = formatters[format] { return hit }
        guard !Thread.isMainThread || FormlessRenderContext.isExtension else { return nil }

        let made = DateFormatter()
        made.locale = Locale(identifier: "zh_Hant_TW")
        made.calendar = Calendar(identifier: .gregorian)
        made.dateFormat = format

        // 格式只在背景準備，避免清空後使仍在畫面上的日期失去格式。
        formatters[format] = made

        return made
    }
}

func formlessFormatted(_ format: String, date: Date) -> String {
    formlessDateFormatters.formatter(format)?.string(from: date) ?? ""
}


// MARK: - 整份設計的繪製

/// 主 App 的圖片從工作載入，桌面擴充沿用時間軸同步快取。
enum FormlessRenderContext {
    static let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
    /// 產生縮圖快照時為 true：資源改為同步取用，否則 ImageRenderer 會拍到還沒載入的空畫面。
    @MainActor static var synchronousAssets = false
    @MainActor static var loadsAssetsNow: Bool { isExtension || synchronousAssets }
    static func prepare(_ document: FormlessDocument) {
        let common = ["yyyy/MM/dd", "M月d日", "EEEE", "EEE", "d", "HH:mm", "a h:mm", "MM/dd", "M月", "yyyy"]
        for format in common { _ = formlessFormatted(format, date: Date()) }
        for layer in document.layers where layer.type == .date || layer.type == .time {
            if let format = layer.value { _ = formlessFormatted(format, date: Date()) }
        }
        _ = FormlessWeatherStyle.current()
    }
}

struct FormlessLoadedAsset<Content: View>: View {
    let name: String?
    /// 畫出來的大小（pt）：有給就只解碼到這個大小 × 3，省小工具的記憶體；nil 是原尺寸（圖片庫的原圖）。
    var drawnSize: CGSize? = nil
    /// 填滿（背景）還是完整放進框裡（圖片圖層）。
    var fill = false
    @ViewBuilder var content: (UIImage?) -> Content
    @State private var image: UIImage?

    private struct LoadKey: Hashable { let name: String?; let width: Int; let height: Int }

    private static func load(_ name: String?, _ size: CGSize?, _ fill: Bool) -> UIImage? {
        guard let name else { return nil }
        guard let size else { return FormlessAssetCache.shared.image(named: name) }
        return FormlessAssetCache.shared.image(named: name, drawnIn: size, fill: fill)
    }

    var body: some View {
        content(FormlessRenderContext.loadsAssetsNow ? Self.load(name, drawnSize, fill) : image)
            .task(id: LoadKey(name: name, width: Int(drawnSize?.width ?? 0), height: Int(drawnSize?.height ?? 0))) {
                guard !FormlessRenderContext.loadsAssetsNow else { return }
                let snapshot = name, size = drawnSize, fill = fill
                let loaded = await Task.detached { Self.load(snapshot, size, fill) }.value
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

struct FormlessDocumentView: View {

    @State private var resourcesReady = false
    let document: FormlessDocument
    var date: Date = Date()
    var live: FormlessLiveData = FormlessLiveData()
    /// 小工具上是 false：底色與背景圖放在系統的 `containerBackground`，StandBy、透明與染色模式才能正確拿掉或換成玻璃。
    /// App 裡的縮圖是 true，自己畫。
    var drawsBackground = true

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let scale = canvas.height / document.family.referenceHeight

            ZStack(alignment: .topLeading) {

                if drawsBackground {
                    Color(
                        formlessHex: document.backgroundColorHex,
                        fallback: "#F4F4F4"
                    )

                    backgroundImage(canvas)
                }

                // 重複排列的群組展開成每一筆一份（`renderedLayers`），其他圖層照原本。
                ForEach(document.renderedLayers(document.visibleSortedLayers, live: live, date: date)) { item in
                    FormlessLayerView(
                        layer: item.layer,
                        canvasSize: canvas,
                        scale: scale,
                        date: date,
                        live: item.live
                    )
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipped()
        }
        .opacity(resourcesReady || FormlessRenderContext.loadsAssetsNow ? 1 : 0)
        .task(id: document) {
            resourcesReady = false
            let snapshot = document
            await Task.detached { FormlessRenderContext.prepare(snapshot) }.value
            resourcesReady = true
        }
    }

    /// 背景圖填滿畫布，但大小固定在畫布上：只用 scaledToFill 的話，比例和畫布不同的圖（例如正方形圖放在大型、超大型）
    /// 會把整個 ZStack 撐大，所有圖層跟著往左上偏（大型實測偏 7.7 pt、超大型偏 112 pt），和編輯器畫布不一致。
    @ViewBuilder
    private func backgroundImage(_ canvas: CGSize) -> some View {
        #if canImport(UIKit)
        FormlessLoadedAsset(name: document.activeBackgroundImageName, drawnSize: canvas, fill: true) { image in
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
            }
        }
        #endif
    }
}


/// 設計的底色與背景圖（小工具放在 `containerBackground` 裡，系統在 StandBy、透明、染色時會拿掉或換成玻璃）。
struct FormlessDocumentBackground: View {
    let document: FormlessDocument

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(formlessHex: document.backgroundColorHex, fallback: "#F4F4F4")
                #if canImport(UIKit)
                FormlessLoadedAsset(name: document.activeBackgroundImageName, drawnSize: geometry.size, fill: true) { image in
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
                #endif
            }
        }
    }
}


// MARK: - 資料綁定

/// dataIndex 例如 event3、reminder2、forecast4。
/// 該筆資料不存在時，掛在上面的圖層完全不繪製；colorHex 為 auto 時取該筆自己的顏色。
enum FormlessDataBinding {

    static func parse(_ raw: String?) -> (kind: String, index: Int)? {
        // 取結尾所有的數字：只取最後一個字元的話 event10 會變成「event1 的第 0 筆」（2026-10 修正）。
        guard let raw else { return nil }
        let digits = String(raw.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        guard !digits.isEmpty, let number = Int(digits), number >= 0 else { return nil }
        return (String(raw.dropLast(digits.count)), number)
    }

    static func satisfied(_ raw: String?, live: FormlessLiveData) -> Bool {
        guard let parsed = parse(raw) else { return true }

        // 序號 0 表示「完全沒有資料時才顯示」
        switch parsed.kind {
        case "event":
            return parsed.index == 0 ? live.events.isEmpty : parsed.index <= live.events.count

        case "reminder":
            return parsed.index == 0 ? live.reminders.isEmpty : parsed.index <= live.reminders.count

        case "forecast":
            let days = (live.weather?.days ?? []).dropFirst().count
            return parsed.index == 0 ? days == 0 : parsed.index <= days

        default:
            return true
        }
    }

    static func colorHex(_ raw: String?, live: FormlessLiveData) -> String? {
        guard let parsed = parse(raw) else { return nil }

        guard parsed.index >= 1 else { return nil }

        switch parsed.kind {
        case "event":
            guard parsed.index <= live.events.count else { return nil }
            return live.events[parsed.index - 1].calendarColorHex

        case "reminder":
            guard parsed.index <= live.reminders.count else { return nil }
            return live.reminders[parsed.index - 1].colorHex

        default:
            return nil
        }
    }

    static func event(_ raw: String?, live: FormlessLiveData) -> FormlessEventItem? {
        guard
            let parsed = parse(raw),
            parsed.kind == "event",
            parsed.index >= 1,
            parsed.index <= live.events.count
        else {
            return nil
        }

        return live.events[parsed.index - 1]
    }

    static func reminder(_ raw: String?, live: FormlessLiveData) -> FormlessReminderItem? {
        guard
            let parsed = parse(raw),
            parsed.kind == "reminder",
            parsed.index >= 1,
            parsed.index <= live.reminders.count
        else {
            return nil
        }

        return live.reminders[parsed.index - 1]
    }

    static func day(_ raw: String?, live: FormlessLiveData) -> FormlessWeatherDay? {
        guard let parsed = parse(raw), parsed.kind == "forecast", parsed.index >= 1 else { return nil }

        let days = Array((live.weather?.days ?? []).dropFirst())

        guard parsed.index <= days.count else { return nil }

        return days[parsed.index - 1]
    }
}


// MARK: - 單一圖層

/// 繪製與編輯選取共用同一個圖層矩形，避免小圖層被不同的最小尺寸撐大。
enum FormlessLayerLayout {
    static func rect(for layer: FormlessLayer, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: canvasSize.width * layer.frame.x,
            y: canvasSize.height * layer.frame.y,
            width: max(1, canvasSize.width * layer.frame.width),
            height: max(1, canvasSize.height * layer.frame.height)
        )
    }

    static func visibleRect(for layer: FormlessLayer, canvasSize: CGSize, scale: CGFloat) -> CGRect {
        let box = rect(for: layer, canvasSize: canvasSize)
        guard let width = layer.strokeWidth, width > 0, let color = layer.strokeColorHex else { return box }
        let hex = color.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if hex.count == 8 && UInt8(String(hex.suffix(2)), radix: 16) == 0 { return box }
        let outset = max(CGFloat(width) * scale, 0.5) / 2
        return box.insetBy(dx: -outset, dy: -outset)
    }

    static func rotatedVisibleBounds(for layer: FormlessLayer, canvasSize: CGSize, scale: CGFloat) -> CGRect {
        let box = visibleRect(for: layer, canvasSize: canvasSize, scale: scale)
        let angle = CGFloat(layer.rotation * .pi / 180)
        let width = abs(cos(angle)) * box.width + abs(sin(angle)) * box.height
        let height = abs(sin(angle)) * box.width + abs(cos(angle)) * box.height
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }
}

// MARK: - 文字筆畫貼齊框的邊

/// 字型裡每個字的左右都自帶一小段空白。文字圖層畫的時候去掉這段空白，筆畫就貼齊框的邊（使用者選定）：
/// 靠左時第一個字的筆畫從框的左緣開始，靠右時最後一個字的筆畫在框的右緣結束，置中時筆畫置中。
/// 編輯器的位置與大小（文字行）用同一組數字，「左」「右」就是筆畫的位置，和月曆格、圖片的量法一致；
/// 位置跟著框走，內容換字時數字也不會變。原本文字量的是文字框：月份標題和月曆格的星期列都填左 826，
/// 粗體「9」的筆畫卻比「日」往右約 3 px（使用者回報：數字一樣，畫出來差很多）。
struct FormlessTextInkLayout: Equatable {
    /// 畫的時候整行文字的水平位移。
    let offset: CGFloat
    /// 筆畫的左緣（以框的左緣為 0）與寬度。
    let inkX: CGFloat
    let inkWidth: CGFloat
    /// 「縮小文字」縮小的比例；沒有縮小是 1。
    let factor: CGFloat
}

enum FormlessTextInk {
    #if canImport(UIKit)
    /// 與繪製時 `.system(size:weight:design:)` 相同的字型。
    static func font(size: CGFloat, weight: String?, family: String?) -> UIFont {
        // 匯入的字型：量測用的字型和畫的一樣（`formlessFont`）。
        if let name = FormlessFontLibrary.postScriptName(fromFamily: family), FormlessFontLibrary.isAvailable(name),
           let custom = UIFont(name: name, size: size) {
            return custom
        }
        let uiWeight: UIFont.Weight
        switch weight {
        case "light": uiWeight = .light
        case "medium": uiWeight = .medium
        case "semibold": uiWeight = .semibold
        case "bold": uiWeight = .bold
        case "heavy": uiWeight = .heavy
        case "black": uiWeight = .black
        default: uiWeight = .regular
        }
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let design: UIFontDescriptor.SystemDesign
        switch family {
        case "rounded": design = .rounded
        case "serif": design = .serif
        case "monospaced": design = .monospaced
        default: return base
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    private final class Metrics {
        /// 排版寬度，以及頭尾兩個字自帶的空白（筆畫超出排版範圍時是負的）。
        let width: CGFloat, lead: CGFloat, trail: CGFloat
        init(width: CGFloat, lead: CGFloat, trail: CGFloat) { self.width = width; self.lead = lead; self.trail = trail }
    }

    /// 畫布每秒重畫，同一段字不重算。
    private static let cache: NSCache<NSString, Metrics> = {
        let cache = NSCache<NSString, Metrics>()
        cache.countLimit = 400
        return cache
    }()

    private static func metrics(_ content: String, font: UIFont) -> Metrics {
        let key = "\(font.fontName)|\(font.pointSize)|\(content)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let result = ink.isNull || ink.width <= 0
            ? Metrics(width: width, lead: 0, trail: 0)
            : Metrics(width: width, lead: ink.minX, trail: width - ink.maxX)
        cache.setObject(result, forKey: key)
        return result
    }

    /// 放不下、會被截斷（以省略號截斷模式）。截斷由系統處理，切在哪裡編輯器用量像素得知（`EditorPaintedBounds`）。
    static func truncates(_ content: String, font: UIFont, boxWidth: CGFloat, autoShrink: Bool?, fixed: Bool) -> Bool {
        !fixed && autoShrink == false && metrics(content, font: font).width > boxWidth
    }

    /// 一行文字在框裡的位置。縮小與截斷的算法與繪製相同：「縮小文字」最多縮到 0.4 倍；
    /// 「以省略號截斷」排滿到框的右緣才截斷（系統預設），截斷後最後一個字是「…」；`fixed`（溫度帶次要色）不縮不截。
    static func layout(_ content: String, font: UIFont, alignment: String?, boxWidth: CGFloat,
                       autoShrink: Bool?, fixed: Bool) -> FormlessTextInkLayout {
        let metrics = metrics(content, font: font)
        var width = metrics.width
        var lead = metrics.lead
        var trail = metrics.trail
        var factor: CGFloat = 1
        if !fixed {
            if autoShrink == false {
                if metrics.width > boxWidth {
                    width = boxWidth
                    trail = Self.metrics("…", font: font).trail
                }
            } else if metrics.width > boxWidth {
                factor = max(0.4, boxWidth / metrics.width)
                width = min(metrics.width * factor, boxWidth)
                lead *= factor
                trail *= factor
            }
        }
        let inkWidth = max(1, width - lead - trail)
        switch alignment {
        case "center":
            return FormlessTextInkLayout(offset: (trail - lead) / 2, inkX: (boxWidth - inkWidth) / 2,
                                         inkWidth: inkWidth, factor: factor)
        case "trailing":
            return FormlessTextInkLayout(offset: trail, inkX: boxWidth - inkWidth, inkWidth: inkWidth, factor: factor)
        default:
            return FormlessTextInkLayout(offset: -lead, inkX: 0, inkWidth: inkWidth, factor: factor)
        }
    }
    #endif
}

struct FormlessLayerView: View {

    let layer: FormlessLayer
    let canvasSize: CGSize
    let scale: CGFloat
    let date: Date
    var live: FormlessLiveData = FormlessLiveData()
    var showsShadow = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.formlessPreviewAppearance) private var previewAppearance

    private var boxSize: CGSize {
        FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize).size
    }

    private var center: CGPoint {
        let rect = FormlessLayerLayout.rect(for: layer, canvasSize: canvasSize)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// 這一刻的顯示環境：編輯器用預覽外觀模擬，小工具與縮圖用系統給的真實模式。
    private var renderEnvironment: FormlessRenderEnvironment {
        if let previewAppearance {
            return previewAppearance.environment(appScheme: colorScheme)
        }
        return FormlessRenderEnvironment(colorScheme: colorScheme, renderingMode: widgetRenderingMode,
                                         showsBackground: showsWidgetContainerBackground)
    }

    var body: some View {
        let environment = renderEnvironment
        positioned(environment)
            // 編輯器模擬系統的透明、染色、StandBy 夜間畫法；小工具上由系統自己處理，這裡不動。
            .modifier(FormlessRenderModeEmulation(environment: environment,
                                                  emulates: previewAppearance != nil,
                                                  isPhoto: layer.type == .image || layer.type == .remoteImage,
                                                  keepsFullColor: layer.keepsFullColor == true))
    }

    private func positioned(_ environment: FormlessRenderEnvironment) -> some View {
        var live = self.live
        live.environment = environment
        return FormlessLayerContentView(
            layer: layer,
            boxSize: boxSize,
            scale: scale,
            date: date,
            live: live
        )
        .frame(width: boxSize.width, height: boxSize.height)
        .modifier(FormlessLayerEffects(layer: layer, scale: scale))
        .overlay(stroke)
        .shadow(
            color: showsShadow ? Color(formlessHex: layer.shadowColorHex, fallback: "#00000000") : .clear,
            radius: (layer.shadowRadius ?? 0) * scale,
            x: (layer.shadowOffsetX ?? 0) * scale,
            y: (layer.shadowOffsetY ?? 0) * scale
        )
        .opacity(layer.opacity)
        .rotationEffect(.degrees(layer.rotation))
        .position(x: center.x, y: center.y)
    }

    @ViewBuilder
    private var stroke: some View {
        if let width = layer.strokeWidth, width > 0 {
            // 色塊的外框跟著它的形狀（圓形、膠囊）；其他圖層維持圓角矩形。
            FormlessLayerShape(kind: layer.type == .shape ? layer.shapeKind : .rectangle,
                               cornerRadius: (layer.cornerRadius ?? 0) * scale,
                               radii: layer.scaledCornerRadii(scale))
            .stroke(
                Color(formlessHex: layer.strokeColorHex, fallback: "#00000000"),
                style: StrokeStyle(lineWidth: max(width * scale, 0.5),
                                   dash: layer.strokeDash == true ? [max(width * scale, 0.5) * 3, max(width * scale, 0.5) * 2] : [])
            )
        }
    }
}


// MARK: - 圖層內容（不含定位，編輯器與桌面共用）

struct FormlessLayerContentView: View {

    let layer: FormlessLayer
    let boxSize: CGSize
    let scale: CGFloat
    var date: Date = Date()
    var live: FormlessLiveData = FormlessLiveData()
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var remoteData: Data? {
        live.remoteImages[layer.id]
    }

    /// 主要顏色：條件顏色優先；colorHex 填 auto 時，取綁定那一筆資料自己的顏色
    private var resolvedColorHex: String? {
        layer.resolvedColorHex(date: date, live: live)
    }

    @ViewBuilder
    var body: some View {
        if FormlessDataBinding.satisfied(layer.dataIndex, live: live), live.matches(layer.visibility, at: date) {
            content
                .frame(width: boxSize.width, height: boxSize.height)
        }
    }

    /// 圖示取用資料時（例如天氣圖示、月相），以那份資料的圖示名稱畫。
    private var boundLayer: FormlessLayer {
        guard let binding = layer.bindings?[FormlessBindableProperty.symbol.rawValue],
              let name = live.value(binding, at: date).rawString, !name.isEmpty else { return layer }
        var copy = layer
        copy.value = name
        return copy
    }

    @ViewBuilder
    private var content: some View {
        switch layer.type {

        case .text:
            if let placement = layer.textArc.flatMap(FormlessArcPlacement.init(rawValue:)) {
                arcText(placement)
            } else if let segments = layer.segments, !segments.isEmpty {
                segmentedText(segments)
            } else {
                textView(layer.value ?? "")
            }

        case .progress:
            FormlessProgressView(layer: layer, size: boxSize, scale: scale, date: date, live: live,
                                 colorHex: resolvedColorHex)

        case .chart:
            FormlessChartView(layer: layer, size: boxSize, scale: scale, date: date, live: live,
                              colorHex: resolvedColorHex)

        case .clock:
            clockView

        case .date:
            textView(formlessFormatted(layer.value ?? "yyyy/MM/dd", date: date))

        case .time:
            timeView

        case .shape:
            FormlessLayerShape(kind: layer.shapeKind, cornerRadius: (layer.cornerRadius ?? 0) * scale, radii: layer.scaledCornerRadii(scale))
                .fill(layer.shapeFill(size: boxSize, solidHex: resolvedColorHex))

        case .gradient:
            LinearGradient(
                stops: [
                    .init(color: Color(formlessHex: layer.colorHex, fallback: "#FFFFFF").opacity(0), location: 0),
                    .init(color: Color(formlessHex: layer.colorHex, fallback: "#FFFFFF").opacity(0), location: 0.5),
                    .init(color: Color(formlessHex: layer.colorHex, fallback: "#FFFFFF"), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

        case .image:
            localImage

        case .remoteImage:
            networkImage

        case .symbol:
            FormlessSymbolView(layer: boundLayer, size: boxSize, live: live, date: date)

        case .bundleImage:
            Image(layer.value ?? "")
                .resizable()
                .scaledToFit()
                .frame(width: boxSize.width, height: boxSize.height)

        case .liveText:
            liveTextView

        case .ruler:
            FormlessRulerView(layer: layer, size: boxSize)

        case .calendarGrid:
            FormlessCalendarGridView(
                layer: layer,
                size: boxSize,
                date: date,
                scale: scale,
                live: live
            )

        case .eventList:
            FormlessEventListView(
                layer: layer,
                size: boxSize,
                live: live,
                scale: scale
            )

        case .reminderList:
            FormlessReminderListView(
                layer: layer,
                size: boxSize,
                live: live,
                scale: scale
            )

        case .weatherForecast:
            FormlessWeatherForecastView(
                layer: layer,
                size: boxSize,
                live: live,
                scale: scale
            )

        case .yearGrid:
            // 舊版寫死的年度進度格已不再支援（使用者已刪掉舊檔）：進度格改用一般的四角星色塊加條件顏色。
            EmptyView()

        case .calendar:
            FormlessCalendarView(
                layer: layer,
                size: boxSize,
                date: date
            )

        case .yearProgress:
            FormlessYearProgressView(
                layer: layer,
                size: boxSize,
                date: date
            )

        case .events:
            FormlessEventsView(
                layer: layer,
                size: boxSize,
                date: date,
                live: live
            )

        case .reminders:
            FormlessRemindersView(
                layer: layer,
                size: boxSize,
                live: live
            )

        case .weather:
            FormlessWeatherView(
                layer: layer,
                size: boxSize,
                date: date,
                live: live
            )

        case .steps:
            FormlessStepsView(
                layer: layer,
                size: boxSize,
                live: live
            )
        }
    }

    private func textView(_ string: String) -> some View {
        styled(Text(string), ink: string)
    }

    /// 固定字與資料組成的一行字。系統即時走動的時間（倒數、相對時間）保留系統的動態文字，不必靠時間線。
    private func segmentedText(_ segments: [FormlessTextSegment]) -> some View {
        let pieces = live.pieces(segments, at: date)
        let text = pieces.reduce(Text(verbatim: "")) { result, piece in
            let next: Text
            switch piece {
            case .plain(let string):
                next = Text(verbatim: string)
            case .live(let target, .timer):
                next = target > date
                    ? Text(timerInterval: date...target, countsDown: true)
                    : Text(target, style: .timer)
            case .live(let target, .relative):
                next = Text(target, style: .relative)
            }
            return Text("\(result)\(next)")
        }
        let isStatic = !pieces.contains { if case .live = $0 { return true } else { return false } }
        // 資料變了（時間線換格）時數字用系統的跳字轉場（小工具上限 2 秒，系統處理）。
        return styled(text, ink: isStatic ? pieces.map { $0.sample(at: date) }.joined() : nil)
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var liveTextView: some View {
        let source = FormlessLiveSource(rawValue: layer.value ?? "")

        switch source {
        case .weatherPlace:
            // 圖層自己指定地名時優先採用
            if let name = layer.locationName, !name.isEmpty {
                textView(name)
            } else {
                textView(source?.text(live: live, date: date, dataIndex: layer.dataIndex) ?? "－")
            }

        case .weatherTemp where layer.secondaryColorHex != nil:
            // 度數符號用次要色；與原本一樣不壓縮寬度
            let value = Text(live.weather?.temperatureText ?? "－")
                .foregroundColor(Color(formlessHex: resolvedColorHex, fallback: "#000000"))

            let degree = Text("°")
                .foregroundColor(Color(formlessHex: layer.secondaryColorHex, fallback: "#808495"))

            Text("\(value)\(degree)")
                .font(formlessFont(size: max(1, (layer.fontSize ?? 22) * scale), weight: layer.fontWeight, family: layer.fontFamily))
                .lineLimit(1)
                .fixedSize()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: layer.textAlignment
                )
                .offset(x: inkOffset((live.weather?.temperatureText ?? "－") + "°", fixed: true))

        default:
            textView(source?.text(live: live, date: date, dataIndex: layer.dataIndex) ?? "－")
        }
    }

    /// 去掉字形兩側自帶的空白，讓筆畫貼齊框的邊（`FormlessTextInk`）。計時器、倒數、相對時間的字每秒在變，不處理。
    private func inkOffset(_ content: String?, fixed: Bool = false) -> CGFloat {
        #if canImport(UIKit)
        guard let content, !content.isEmpty, layer.textLineLimit == 1 else { return 0 }
        let size = max(1, (layer.fontSize ?? 22) * scale)
        let font = FormlessTextInk.font(size: size, weight: layer.fontWeight, family: layer.fontFamily)
        return FormlessTextInk.layout(content, font: font, alignment: layer.alignment, boxWidth: boxSize.width,
                                      autoShrink: layer.autoShrink, fixed: fixed).offset
        #else
        return 0
        #endif
    }

    /// 曲線文字：沿框的內切圓排，字型、粗細、字距、顏色和一般文字相同；資料膠囊照樣取值（系統即時走動的時間畫當下的樣子）。
    private func arcText(_ placement: FormlessArcPlacement) -> some View {
        let string = layer.segments.map { live.text($0, at: date) } ?? (layer.value ?? "")
        let size = max(1, CGFloat(layer.fontSize ?? 22) * scale)
        let measure = FormlessTextInk.font(size: size, weight: layer.fontWeight, family: layer.fontFamily)
        return FormlessArcTextView(
            text: string,
            measureFont: measure as CTFont,
            font: formlessFont(size: size, weight: layer.fontWeight, family: layer.fontFamily),
            tracking: CGFloat(layer.tracking ?? 0) * scale,
            placement: placement
        )
        .foregroundStyle(Color(formlessHex: resolvedColorHex, fallback: "#000000"))
    }

    private func styled(_ text: Text, ink content: String? = nil) -> some View {
        text
            .font(formlessFont(size: max(1, (layer.fontSize ?? 22) * scale), weight: layer.fontWeight, family: layer.fontFamily))
            .modifier(FormlessTextDecoration(layer: layer, scale: scale))
            .foregroundStyle(Color(formlessHex: resolvedColorHex, fallback: "#000000"))
            .lineLimit(layer.textLineLimit == 0 ? nil : layer.textLineLimit)
            .truncationMode(.tail)
            .minimumScaleFactor(layer.autoShrink == false ? 1 : 0.4)
            .multilineTextAlignment(layer.multilineAlignment)
            // 以省略號截斷時排滿到框的右緣才出現「…」（系統預設）。
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: layer.textAlignment
            )
            .offset(x: inkOffset(content))
    }

    /// 指針時鐘：時針用主要顏色（可設條件顏色、色階），分針沒設就跟時針一樣；刻度與數字用文字顏色；錶盤沒設是透明。
    private var clockView: some View {
        let spec = layer.clock ?? FormlessClockSpec()
        let hand = Color(formlessHex: resolvedColorHex, fallback: "#000000")
        return FormlessAnalogClockView(
            date: date,
            timeZone: spec.timeZone.flatMap(TimeZone.init(identifier:)),
            marks: spec.marks.flatMap(FormlessClockMarks.init(rawValue:)) ?? .hours,
            numerals: spec.numerals.flatMap(FormlessClockNumerals.init(rawValue:)) ?? FormlessClockNumerals.none,
            numeralFont: nil,
            faceColor: layer.panelColorHex.map { Color(formlessHex: $0) },
            markColor: Color(formlessHex: layer.textColorHex, fallback: "#8E8E93"),
            hourHandColor: hand,
            minuteHandColor: layer.secondaryColorHex.map { Color(formlessHex: $0) } ?? hand,
            centerColor: nil,
            weight: CGFloat(spec.weight ?? 1)
        )
    }

    /// 計時器、倒數、相對時間由系統自己更新，不需要時間軸重載，也不吃更新配額；時鐘與日期樣式顯示的是這一格的時間，
    /// 靠時間軸換畫面（`FormlessDocument.needsMinuteRefresh`）。
    @ViewBuilder
    private var timeView: some View {
        let raw = layer.value ?? FormlessTimeStyle.auto.rawValue

        switch FormlessTimeStyle(rawValue: raw) {
        case .auto:
            styled(Text(date, style: .time),
                   ink: DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))

        case .timer:
            styled(Text(date, style: .timer))

        case .countdown:
            styled(Text(timerInterval: date...max(date.addingTimeInterval(1), targetDate), countsDown: true))

        case .relative:
            styled(Text(date, style: .relative))

        case .day:
            styled(Text(date, style: .date),
                   ink: DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none))

        case .none:
            textView(formlessFormatted(raw, date: date))
        }
    }

    private var targetDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        return calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: date)
        ) ?? date.addingTimeInterval(3600)
    }

    /// 主畫面透明或染色時：照片預設跟系統一起去色，使用者選了保留原色才維持全彩。
    /// 只在那兩種模式指定：照片一加上這個設定（就算是全彩），小型小工具整塊的點擊會被系統當成「打開 App」，
    /// 「重新整理，不跳轉」就失效（使用者 10/04 回報，模擬器實測拿掉後恢復）。
    #if canImport(UIKit)
    @ViewBuilder
    private func photo(_ image: UIImage) -> some View {
        if widgetRenderingMode == .accented {
            Image(uiImage: image).resizable()
                .widgetAccentedRenderingMode(layer.keepsFullColor == true ? .fullColor : .desaturated)
        } else {
            Image(uiImage: image).resizable()
        }
    }
    #endif

    @ViewBuilder
    private var localImage: some View {
        #if canImport(UIKit)
        FormlessLoadedAsset(name: layer.slideshowImage(at: date), drawnSize: boxSize) { image in
            if let image {

            photo(image)
                .scaledToFit()
                .clipShape(
                    FormlessLayerShape(kind: .rectangle, cornerRadius: (layer.cornerRadius ?? 0) * scale,
                                       radii: layer.scaledCornerRadii(scale))
                )
        } else {
            placeholderBox(text: "圖片")
        }
        }
        #else
        placeholderBox(text: "圖片")
        #endif
    }

    @ViewBuilder
    private var networkImage: some View {
        #if canImport(UIKit)
        if
            let remoteData,
            let image = FormlessRemoteImageMemo.image(for: remoteData, drawnIn: boxSize) {

            photo(image)
                .scaledToFit()
                .clipShape(
                    FormlessLayerShape(kind: .rectangle, cornerRadius: (layer.cornerRadius ?? 0) * scale,
                                       radii: layer.scaledCornerRadii(scale))
                )
        } else {
            placeholderBox(text: "網路圖片")
        }
        #else
        placeholderBox(text: "網路圖片")
        #endif
    }

    private func placeholderBox(text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.18))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.gray)
        }
    }
}


struct FormlessPlaceholderView: View {

    let title: String
    let message: String
    let size: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.14))

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: max(10, size.height * 0.10), weight: .semibold))

                Text(message)
                    .font(.system(size: max(9, size.height * 0.07)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}


// MARK: - 完整月曆

struct FormlessCalendarMonth {

    let leadingBlanks: Int
    let numberOfDays: Int
    let today: Int
    let rows: Int
    let weekdaySymbols: [String]
    let monthTitle: String
    let weekdayTitle: String
    /// 顯示的那個月的第一天，與排版用的曆法（月曆格的農曆、週數、熱圖用）。
    let firstOfMonth: Date
    let calendar: Calendar

    /// monthOffset：顯示前後第幾個月（0 是這個月）；不是這個月時沒有「今天」的標示（today 是 0）。
    init(date: Date, mondayFirst: Bool, monthOffset: Int = 0) {

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")
        calendar.firstWeekday = mondayFirst ? 2 : 1

        let shown = monthOffset == 0 ? date : (calendar.date(byAdding: .month, value: monthOffset, to: date) ?? date)
        let components = calendar.dateComponents([.year, .month, .day], from: shown)

        let firstOfMonth = calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: 1
            )
        ) ?? date

        let range = calendar.range(of: .day, in: .month, for: firstOfMonth)

        numberOfDays = range?.count ?? 30
        today = monthOffset == 0 ? (components.day ?? 1) : 0
        self.firstOfMonth = firstOfMonth
        self.calendar = calendar

        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)
        leadingBlanks = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        let total = leadingBlanks + numberOfDays
        rows = max(5, Int(ceil(Double(total) / 7.0)))

        let base = ["日", "一", "二", "三", "四", "五", "六"]
        let offset = calendar.firstWeekday - 1
        weekdaySymbols = (0..<7).map { base[($0 + offset) % 7] }

        monthTitle = formlessFormatted("M月", date: shown)
        weekdayTitle = formlessFormatted("EEEE", date: date)
    }

    /// 第 day 天的日期。
    func date(ofDay day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) ?? firstOfMonth
    }
}


/// Widgy 的座標系：畫布固定 1600×1600，x 與寬度取小工具寬度比例，y 與高度取高度比例。
/// 文字圖層的 e 是行高，實際字級約 0.87 倍（由原始成品圖逐字反推）。
struct FormlessWidgyBox {

    static let canvas: CGFloat = 1600
    static let fontRatio: CGFloat = 0.87

    let width: CGFloat
    let height: CGFloat

    init(_ size: CGSize) {
        width = max(size.width, 1)
        height = max(size.height, 1)
    }

    func x(_ value: CGFloat) -> CGFloat { value / Self.canvas * width }
    func y(_ value: CGFloat) -> CGFloat { value / Self.canvas * height }
    func w(_ value: CGFloat) -> CGFloat { value / Self.canvas * width }
    func h(_ value: CGFloat) -> CGFloat { value / Self.canvas * height }

    func font(_ value: CGFloat) -> CGFloat {
        value / Self.canvas * height * Self.fontRatio
    }

    /// Widgy 的圓角是短邊的百分比
    func radius(_ percent: CGFloat, width wv: CGFloat, height hv: CGFloat) -> CGFloat {
        min(w(wv), h(hv)) * percent / 100
    }
}


extension View {

    /// 依 Widgy 的 x / y / 寬 / 高（或字級行高）定位
    func formlessPlaced(
        _ box: FormlessWidgyBox,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        centered: Bool = false,
        shift: CGPoint = .zero
    ) -> some View {

        let frameWidth = max(box.w(w), 1)
        let frameHeight = max(box.h(h), 1)

        return self
            .frame(
                width: frameWidth,
                height: frameHeight,
                alignment: centered ? .center : .leading
            )
            .position(
                x: box.x(x) + frameWidth / 2 + box.width * shift.x,
                y: box.y(y) + frameHeight / 2 + box.height * shift.y
            )
    }
}


struct FormlessComponentBox {

    let originX: CGFloat
    let originY: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(size: CGSize, aspect: CGFloat) {
        let w = max(size.width, 1)
        let h = max(size.height, 1)

        var boxWidth = w
        var boxHeight = h

        if w / h > aspect {
            boxWidth = h * aspect
        } else {
            boxHeight = w / aspect
        }

        width = boxWidth
        height = boxHeight
        originX = (w - boxWidth) / 2
        originY = (h - boxHeight) / 2
    }

    func x(_ ratio: CGFloat) -> CGFloat { originX + width * ratio }
    func y(_ ratio: CGFloat) -> CGFloat { originY + height * ratio }
    func w(_ ratio: CGFloat) -> CGFloat { width * ratio }
    func h(_ ratio: CGFloat) -> CGFloat { height * ratio }
}


struct FormlessCalendarView: View {

    let layer: FormlessLayer
    let size: CGSize
    let date: Date

    private var month: FormlessCalendarMonth {
        FormlessCalendarMonth(
            date: date,
            mondayFirst: layer.weekStartsOnMonday ?? false
        )
    }

    private var accent: Color {
        Color(formlessHex: layer.colorHex, fallback: "#FF3B30")
    }

    private var secondary: Color {
        Color(formlessHex: layer.secondaryColorHex, fallback: "#808495")
    }

    private var panelColor: Color {
        Color(formlessHex: layer.panelColorHex, fallback: "#E6E6E8")
    }

    private var dayColor: Color {
        Color(formlessHex: layer.textColorHex, fallback: "#000000")
    }

    private var showsPanel: Bool {
        layer.showsPanel ?? true
    }

    /// 完整版直接鋪滿圖層（Widgy 的 1600 畫布就是整個小工具），只有月曆格時才維持比例
    private var designAspect: CGFloat {
        showsPanel
            ? max(size.width, 1) / max(size.height, 1)
            : 1.25
    }

    var body: some View {
        let box = FormlessComponentBox(size: size, aspect: designAspect)

        ZStack(alignment: .topLeading) {

            if showsPanel {
                sidePanel(box)
                panelTexts(box)
            }

            monthTitle(box)
            weekdayHeader(box)
            dayGrid(box)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }


    private func shifted(
        _ box: FormlessComponentBox,
        _ part: String,
        x: CGFloat,
        y: CGFloat
    ) -> CGPoint {
        let offset = layer.offset(part)

        return CGPoint(
            x: x + box.width * offset.x,
            y: y + box.height * offset.y
        )
    }

    // MARK: 左側面板

    // Widgy 原檔：x30 y60 w696 h1480，systemGray4 40%，圓角 11%（短邊 696）
    private func sidePanel(_ box: FormlessComponentBox) -> some View {
        let width = box.w(696 / 1600)
        let height = box.h(1480 / 1600)
        let percent = min(max(layer.cornerRadius ?? 11, 0), 50)
        let radius = min(width, height) * percent / 100

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(panelColor)
            .frame(width: width, height: height)
            .position(
                shifted(
                    box,
                    "panel",
                    x: box.x(30 / 1600) + width / 2,
                    y: box.y(60 / 1600) + height / 2
                )
            )
    }

    private func panelTexts(_ box: FormlessComponentBox) -> some View {
        let panelCenterX = box.x((30 + 345) / 1600)
        let data = month

        return ZStack {
            // Widgy 原檔：x30 y242 w690 字級218 System Bold systemRed 置中
            Text(data.weekdayTitle)
                .font(.system(size: box.h(218 / 1600 * 0.87), weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .fixedSize()
                .position(
                    shifted(box, "weekday", x: panelCenterX, y: box.y((242 + 109) / 1600))
                )

            // Widgy 原檔：x30 y380 w693 字級1160 System Bold 置中 字距-10
            Text("\(data.today)")
                .font(.system(size: box.h(1160 / 1600 * 0.87), weight: .bold))
                .tracking(-box.w(10 / 1600))
                .foregroundStyle(dayColor)
                .lineLimit(1)
                .fixedSize()
                .position(
                    shifted(box, "day", x: panelCenterX, y: box.y((380 + 580) / 1600))
                )
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    // MARK: 右側月曆

    private var gridLeftRatio: CGFloat {
        showsPanel ? 776 / 1600 : 0.05
    }

    private var gridWidthRatio: CGFloat {
        showsPanel ? 746 / 1600 : 0.90
    }

    private func columnCenterX(_ index: Int, box: FormlessComponentBox) -> CGFloat {
        let cell = box.w(gridWidthRatio) / 7
        return box.x(gridLeftRatio) + cell * (CGFloat(index) + 0.5)
    }

    private func monthTitle(_ box: FormlessComponentBox) -> some View {
        // Widgy 原檔：x806 y118 w690 字級150 System Bold #808495 靠左
        let leading = showsPanel ? box.x(806 / 1600) : box.x(0.06)
        let boxWidth = showsPanel
            ? box.w(690 / 1600)
            : max(1, box.originX + box.width - leading)

        return Text(month.monthTitle)
            .font(.system(size: box.h(150 / 1600 * 0.87), weight: .bold))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .frame(width: boxWidth, alignment: .leading)
            .position(
                shifted(box, "month", x: leading + boxWidth / 2, y: box.y((118 + 75) / 1600))
            )
    }

    private func weekdayHeader(_ box: FormlessComponentBox) -> some View {
        let symbols = month.weekdaySymbols

        return ZStack {
            ForEach(0..<7, id: \.self) { index in
                Text(symbols[index])
                    .font(.system(size: box.h(0.0632), weight: .semibold))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .position(
                        shifted(
                            box,
                            "weekdayRow",
                            x: columnCenterX(index, box: box),
                            y: box.y(0.2636)
                        )
                    )
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func dayGrid(_ box: FormlessComponentBox) -> some View {
        let data = month

        let gridTop = box.y(0.32)
        let gridBottom = box.y(0.95)
        let pitch = (gridBottom - gridTop) / CGFloat(max(data.rows, 1))

        let cell = box.w(gridWidthRatio) / 7
        let pillWidth = cell * 0.743
        let pillHeight = min(pitch * 0.67, box.h(0.0826))

        return ZStack {
            ForEach(Array(0..<(data.rows * 7)), id: \.self) { index in
                let day = index - data.leadingBlanks + 1

                if day >= 1 && day <= data.numberOfDays {
                    dayCell(
                        day: day,
                        isToday: day == data.today,
                        fontSize: box.h(0.0644),
                        pillWidth: pillWidth,
                        pillHeight: pillHeight
                    )
                    .position(
                        shifted(
                            box,
                            "grid",
                            x: columnCenterX(index % 7, box: box),
                            y: gridTop + pitch * (CGFloat(index / 7) + 0.5)
                        )
                    )
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func dayCell(
        day: Int,
        isToday: Bool,
        fontSize: CGFloat,
        pillWidth: CGFloat,
        pillHeight: CGFloat
    ) -> some View {

        ZStack {
            if isToday {
                RoundedRectangle(
                    cornerRadius: pillHeight * 0.18,
                    style: .continuous
                )
                .fill(accent)
                .frame(width: pillWidth, height: pillHeight)
            }

            Text("\(day)")
                .font(
                    .system(
                        size: fontSize,
                        weight: isToday ? .semibold : formlessFontWeight(layer.fontWeight)
                    )
                )
                .foregroundStyle(isToday ? Color.white : dayColor)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: pillWidth, height: pillHeight)
    }
}


// MARK: - 年度進度

struct FormlessYearProgressView: View {

    let layer: FormlessLayer
    let size: CGSize
    let date: Date

    private var filledColor: Color {
        Color(formlessHex: layer.colorHex, fallback: "#000000")
    }

    private var emptyColor: Color {
        Color(formlessHex: layer.textColorHex, fallback: "#D8D8DA")
    }

    private var accentColor: Color {
        Color(formlessHex: layer.secondaryColorHex, fallback: "#808495")
    }

    private var progress: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        let year = calendar.component(.year, from: date)

        guard
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
            let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else {
            return 0
        }

        let total = end.timeIntervalSince(start)
        let passed = date.timeIntervalSince(start)

        guard total > 0 else { return 0 }

        return max(0, min(1, passed / total))
    }


    private func shifted(
        _ box: FormlessComponentBox,
        _ part: String,
        x: CGFloat,
        y: CGFloat
    ) -> CGPoint {
        let offset = layer.offset(part)

        return CGPoint(
            x: x + box.width * offset.x,
            y: y + box.height * offset.y
        )
    }

    private var yearText: String {
        formlessFormatted("yyyy", date: date)
    }

    var body: some View {
        let box = FormlessWidgyBox(size)

        let columns = 12
        let rows = 4
        let total = columns * rows
        let filled = Int((progress * Double(total)).rounded())
        let percent = Int((progress * 100).rounded())

        // Widgy 原檔：4 列 12 顆，第一顆左緣 x70、水平間距 124，列中心 y 567/827/1087/1347
        let rowCenter: [CGFloat] = [567, 827, 1087, 1347]

        ZStack(alignment: .topLeading) {

            // 年份：x70 y140 w984 字級220 System Bold 靠左
            Text(yearText)
                .font(.system(size: box.font(220), weight: .bold))
                .foregroundStyle(filledColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 70, y: 140, w: 984, h: 220, shift: partShift("header"))

            // 百分比：x1240 y140 w284 字級220 System Bold 靠左，百分號 #808495
            percentText(percent)
            .font(.system(size: box.font(220), weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .formlessPlaced(box, x: 1240, y: 140, w: 284, h: 220, shift: partShift("percent"))

            ForEach(Array(0..<total), id: \.self) { index in
                FormlessFourPointStar()
                    .fill(index < filled ? filledColor : emptyColor)
                    .frame(width: box.w(68), height: box.h(145))
                    .position(
                        x: box.x(104 + 124 * CGFloat(index % columns))
                            + box.width * partShift("grid").x,
                        y: box.y(rowCenter[index / columns])
                            + box.height * partShift("grid").y
                    )
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func percentText(_ percent: Int) -> Text {
        let value = Text("\(percent)").foregroundColor(filledColor)
        let sign = Text("%").foregroundColor(accentColor)

        return Text("\(value)\(sign)")
    }

    private func partShift(_ part: String) -> CGPoint {
        let offset = layer.offset(part)
        return CGPoint(x: offset.x, y: offset.y)
    }
}


// MARK: - 桌面小工具設定 Intent

struct SmallWidgetIntent: WidgetConfigurationIntent {

    nonisolated static let title: LocalizedStringResource = "選擇小型小工具"

    @Parameter(title: "小工具")
    var selectedWidget: SmallWidgetEntity?
}

struct MediumWidgetIntent: WidgetConfigurationIntent {

    nonisolated static let title: LocalizedStringResource = "選擇中型小工具"

    @Parameter(title: "小工具")
    var selectedWidget: MediumWidgetEntity?
}

struct LargeWidgetIntent: WidgetConfigurationIntent {

    nonisolated static let title: LocalizedStringResource = "選擇大型小工具"

    @Parameter(title: "小工具")
    var selectedWidget: LargeWidgetEntity?
}

struct ExtraLargeWidgetIntent: WidgetConfigurationIntent {

    nonisolated static let title: LocalizedStringResource = "選擇超大型小工具"

    @Parameter(title: "小工具")
    var selectedWidget: ExtraLargeWidgetEntity?
}


// MARK: - 小型

struct SmallWidgetEntity: AppEntity, Identifiable, Hashable {

    nonisolated static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "小型小工具")
    nonisolated static let defaultQuery = SmallWidgetQuery()

    let id: String
    let name: String

    nonisolated var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct SmallWidgetQuery: EntityQuery {

    /// 剛加入小工具、還沒選過時的預設值：第一個可用的設計。沒有預設值時設定表會顯示第一個選項的名稱，
    /// 小工具本身卻是「沒選」而停在提示畫面，兩邊對不上。
    nonisolated func defaultResult() async -> SmallWidgetEntity? {
        return FormlessStorage.loadAll().first { $0.family == .small }
            .map { SmallWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func entities(for identifiers: [String]) async throws -> [SmallWidgetEntity] {
        if identifiers.contains("__none_small__") {
            return [SmallWidgetEntity(id: "__none_small__", name: "沒有可用的小型小工具")]
        }

        return FormlessStorage.loadAll()
            .filter { $0.family == .small && identifiers.contains($0.id.uuidString) }
            .map { SmallWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func suggestedEntities() async throws -> [SmallWidgetEntity] {
        let items = FormlessStorage.loadAll()
            .filter { $0.family == .small }
            .map { SmallWidgetEntity(id: $0.id.uuidString, name: $0.name) }

        if items.isEmpty {
            let reason = FormlessStorage.sharedContainerURL == nil
                ? "讀不到共用資料夾"
                : "沒有可用的小型小工具"

            return [SmallWidgetEntity(id: "__none_small__", name: reason)]
        }

        return items
    }
}


// MARK: - 中型

struct MediumWidgetEntity: AppEntity, Identifiable, Hashable {

    nonisolated static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "中型小工具")
    nonisolated static let defaultQuery = MediumWidgetQuery()

    let id: String
    let name: String

    nonisolated var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MediumWidgetQuery: EntityQuery {

    /// 剛加入小工具、還沒選過時的預設值：第一個可用的設計。沒有預設值時設定表會顯示第一個選項的名稱，
    /// 小工具本身卻是「沒選」而停在提示畫面，兩邊對不上。
    nonisolated func defaultResult() async -> MediumWidgetEntity? {
        return FormlessStorage.loadAll().first { $0.family == .medium }
            .map { MediumWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func entities(for identifiers: [String]) async throws -> [MediumWidgetEntity] {
        if identifiers.contains("__none_medium__") {
            return [MediumWidgetEntity(id: "__none_medium__", name: "沒有可用的中型小工具")]
        }

        return FormlessStorage.loadAll()
            .filter { $0.family == .medium && identifiers.contains($0.id.uuidString) }
            .map { MediumWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func suggestedEntities() async throws -> [MediumWidgetEntity] {
        let items = FormlessStorage.loadAll()
            .filter { $0.family == .medium }
            .map { MediumWidgetEntity(id: $0.id.uuidString, name: $0.name) }

        if items.isEmpty {
            let reason = FormlessStorage.sharedContainerURL == nil
                ? "讀不到共用資料夾"
                : "沒有可用的中型小工具"

            return [MediumWidgetEntity(id: "__none_medium__", name: reason)]
        }

        return items
    }
}


// MARK: - 大型

struct LargeWidgetEntity: AppEntity, Identifiable, Hashable {

    nonisolated static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "大型小工具")
    nonisolated static let defaultQuery = LargeWidgetQuery()

    let id: String
    let name: String

    nonisolated var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct LargeWidgetQuery: EntityQuery {

    /// 剛加入小工具、還沒選過時的預設值：第一個可用的設計。沒有預設值時設定表會顯示第一個選項的名稱，
    /// 小工具本身卻是「沒選」而停在提示畫面，兩邊對不上。
    nonisolated func defaultResult() async -> LargeWidgetEntity? {
        return FormlessStorage.loadAll().first { $0.family == .large }
            .map { LargeWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func entities(for identifiers: [String]) async throws -> [LargeWidgetEntity] {
        if identifiers.contains("__none_large__") {
            return [LargeWidgetEntity(id: "__none_large__", name: "沒有可用的大型小工具")]
        }

        return FormlessStorage.loadAll()
            .filter { $0.family == .large && identifiers.contains($0.id.uuidString) }
            .map { LargeWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func suggestedEntities() async throws -> [LargeWidgetEntity] {
        let items = FormlessStorage.loadAll()
            .filter { $0.family == .large }
            .map { LargeWidgetEntity(id: $0.id.uuidString, name: $0.name) }

        if items.isEmpty {
            let reason = FormlessStorage.sharedContainerURL == nil
                ? "讀不到共用資料夾"
                : "沒有可用的大型小工具"

            return [LargeWidgetEntity(id: "__none_large__", name: reason)]
        }

        return items
    }
}


// MARK: - 超大型

struct ExtraLargeWidgetEntity: AppEntity, Identifiable, Hashable {

    nonisolated static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "超大型小工具")
    nonisolated static let defaultQuery = ExtraLargeWidgetQuery()

    let id: String
    let name: String

    nonisolated var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ExtraLargeWidgetQuery: EntityQuery {

    /// 剛加入小工具、還沒選過時的預設值：第一個可用的設計。沒有預設值時設定表會顯示第一個選項的名稱，
    /// 小工具本身卻是「沒選」而停在提示畫面，兩邊對不上。
    nonisolated func defaultResult() async -> ExtraLargeWidgetEntity? {
        return FormlessStorage.loadAll().first { $0.family == .extraLarge }
            .map { ExtraLargeWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func entities(for identifiers: [String]) async throws -> [ExtraLargeWidgetEntity] {
        if identifiers.contains("__none_extraLarge__") {
            return [ExtraLargeWidgetEntity(id: "__none_extraLarge__", name: "沒有可用的超大型小工具")]
        }

        return FormlessStorage.loadAll()
            .filter { $0.family == .extraLarge && identifiers.contains($0.id.uuidString) }
            .map { ExtraLargeWidgetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    nonisolated func suggestedEntities() async throws -> [ExtraLargeWidgetEntity] {
        let items = FormlessStorage.loadAll()
            .filter { $0.family == .extraLarge }
            .map { ExtraLargeWidgetEntity(id: $0.id.uuidString, name: $0.name) }

        if items.isEmpty {
            let reason = FormlessStorage.sharedContainerURL == nil
                ? "讀不到共用資料夾"
                : "沒有可用的超大型小工具"

            return [ExtraLargeWidgetEntity(id: "__none_extraLarge__", name: reason)]
        }

        return items
    }
}


// MARK: - 圖片庫
/// 共用資料夾圖片的記憶體快取。畫面每次重繪都會取圖，不快取就會一直讀檔與解碼。
final class FormlessAssetCache: @unchecked Sendable {

    static let shared = FormlessAssetCache()

    private let lock = NSLock()
    private var bytes: [String: Data?] = [:]

    #if canImport(UIKit)
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    #endif

    private var index: [FormlessAssetItem]?

    /// 桌面小工具的記憶體上限很低，快取要有數量與大小的界線
    private static let maxEntries = 24
    private static let maxBytes = 4 * 1024 * 1024

    func data(named name: String) -> Data? {
        lock.lock()

        if let slot = bytes.index(forKey: name) {
            let hit = bytes[slot].value
            lock.unlock()
            return hit
        }

        lock.unlock()

        var loaded: Data?

        if let directory = FormlessStorage.assetsDirectoryURL {
            loaded = try? Data(contentsOf: directory.appendingPathComponent(name))
        }

        guard (loaded?.count ?? 0) <= Self.maxBytes else { return loaded }

        lock.lock()

        let totalBytes = bytes.values.reduce(0) { $0 + ($1?.count ?? 0) }
        if bytes.count >= Self.maxEntries || totalBytes + (loaded?.count ?? 0) > Self.maxBytes {
            bytes.removeAll()
        }

        bytes.updateValue(loaded, forKey: name)
        lock.unlock()

        return loaded
    }

    #if canImport(UIKit)
    /// 依畫出來的大小解碼（2026-10）：小工具延伸的記憶體上限約 30 MB，一張 2048 px 的照片原尺寸解碼就要 12 MB 以上，
    /// 解碼當下的高峰還會再翻倍，背景放一張照片就可能讓整個小工具空白。改成只解碼到畫出來的大小 × 3（螢幕倍率），
    /// 用 CGImageSource 的縮圖直接從檔案讀，不先載入原圖。fill 是填滿（背景）、否則是完整放進框裡（圖片圖層）。
    func image(named name: String, drawnIn size: CGSize, fill: Bool, screenScale: CGFloat = 3) -> UIImage? {
        guard size.width > 0, size.height > 0,
              let url = FormlessStorage.assetsDirectoryURL?.appendingPathComponent(name),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let target = Self.decodePixels(source, drawnIn: size, fill: fill, screenScale: screenScale)
        else { return image(named: name) }
        // 原圖本來就不大：照原本的方式解碼（共用同一份快取）。
        guard let maxPixel = target else { return image(named: name) }
        let key = "\(name)@\(maxPixel)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let made = Self.thumbnail(source, maxPixel: maxPixel) else { return image(named: name) }
        images.setObject(made, forKey: key, cost: made.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        return made
    }

    /// 要解碼成多大（長邊的像素，取到 128 的倍數，拖曳改大小時不會每一格都重新解碼）；nil 是原圖已經夠小、照原尺寸。
    /// 外層的 nil 是讀不到圖片的尺寸。
    static func decodePixels(_ source: CGImageSource, drawnIn size: CGSize, fill: Bool, screenScale: CGFloat) -> Int?? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // 直拍的照片寬高對調（EXIF 方向 5～8）。
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let factor = fill ? max(size.width / width, size.height / height) : min(size.width / width, size.height / height)
        let needed = max(width, height) * factor * screenScale
        let bucket = Int((needed / 128).rounded(.up)) * 128
        return Double(bucket) >= max(width, height) ? .some(nil) : .some(max(bucket, 128))
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    func image(named name: String) -> UIImage? {
        if let hit = images.object(forKey: name as NSString) { return hit }
        guard let made = data(named: name).flatMap({ UIImage(data: $0) }) else { return nil }
        let cost = made.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(made.size.width * made.size.height * 4)
        images.setObject(made, forKey: name as NSString, cost: cost)
        return made
    }

    #endif

    func libraryIndex() -> [FormlessAssetItem]? {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func storeLibraryIndex(_ items: [FormlessAssetItem]) {
        lock.lock()
        index = items
        lock.unlock()
    }

    func invalidate(_ name: String? = nil) {
        lock.lock()

        if let name {
            bytes.removeValue(forKey: name)
            #if canImport(UIKit)
            images.removeObject(forKey: name as NSString)
            #endif
        } else {
            bytes.removeAll()
            #if canImport(UIKit)
            images.removeAllObjects()
            #endif
        }

        index = nil
        lock.unlock()
    }
}



struct FormlessAssetItem: Codable, Hashable, Identifiable, Sendable {

    var id: String
    var title: String
    var addedAt: Date
    var digest: String
    var width: Int
    var height: Int

    var thumbName: String { id + ".thumb" }
}


/// 從相簿匯入的圖片會複製一份進 App 群組，之後可以重複選用，也不受相簿刪除影響
enum FormlessAssetLibrary {

    static let indexName = "library.json"
    static let maxSide: CGFloat = 2048
    static let thumbSide: CGFloat = 240

    nonisolated private static var indexURL: URL? {
        FormlessStorage.assetsDirectoryURL?.appendingPathComponent(indexName)
    }

    nonisolated static func all() -> [FormlessAssetItem] {
        if let cached = FormlessAssetCache.shared.libraryIndex() { return cached }

        guard let url = indexURL, let data = try? Data(contentsOf: url) else {
            FormlessAssetCache.shared.storeLibraryIndex([])
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let items = ((try? decoder.decode([FormlessAssetItem].self, from: data)) ?? [])
            .sorted { $0.addedAt > $1.addedAt }

        FormlessAssetCache.shared.storeLibraryIndex(items)

        return items
    }

    nonisolated static func item(named name: String?) -> FormlessAssetItem? {
        guard let name else { return nil }
        return all().first { $0.id == name }
    }

    nonisolated private static func write(_ items: [FormlessAssetItem]) {
        guard let url = indexURL else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(items) else { return }

        try? data.write(to: url, options: .atomic)
        FormlessAssetCache.shared.storeLibraryIndex(items.sorted { $0.addedAt > $1.addedAt })
    }

    nonisolated static func digest(of data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325

        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }

        return String(hash, radix: 16) + "-" + String(data.count, radix: 16)
    }

    /// 匯入一張圖。內容相同就沿用既有的那一張。
    @discardableResult
    nonisolated static func add(data source: Data, title: String? = nil) -> FormlessAssetItem? {
        #if canImport(UIKit)
        guard let image = UIImage(data: source) else { return nil }

        let normalized = resized(image, maxSide: maxSide)

        guard let data = encoded(normalized) else { return nil }

        let key = digest(of: data)

        var items = all()

        if let existing = items.first(where: { $0.digest == key }) {
            return existing
        }

        guard let name = try? FormlessStorage.saveAsset(data: data) else { return nil }

        if
            let thumb = encoded(resized(normalized, maxSide: thumbSide)),
            let directory = FormlessStorage.assetsDirectoryURL {

            try? thumb.write(
                to: directory.appendingPathComponent(name + ".thumb"),
                options: .atomic
            )
        }

        let count = items.count + 1

        let item = FormlessAssetItem(
            id: name,
            title: title ?? "圖片 \(count)",
            addedAt: Date(),
            digest: key,
            width: Int(normalized.size.width),
            height: Int(normalized.size.height)
        )

        items.append(item)
        write(items)

        return item
        #else
        return nil
        #endif
    }

    /// 把還沒登記的舊圖片收進圖片庫，避免清理時被當成沒人用而刪掉
    nonisolated static func adoptExisting() {
        guard let directory = FormlessStorage.assetsDirectoryURL else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        var items = all()
        let known = Set(items.map(\.id))
        var digests = Set(items.map(\.digest))
        let weather = Set(FormlessWeatherStyle.current().images.values)
        var changed = false

        for file in files {
            let name = file.lastPathComponent

            guard name.hasSuffix(".image") else { continue }
            guard !known.contains(name), !weather.contains(name) else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            // 內容和圖片庫既有的一樣就不再登記，避免同一張圖重複出現
            let key = digest(of: data)
            guard !digests.contains(key) else { continue }
            digests.insert(key)

            var size = CGSize.zero

            #if canImport(UIKit)
            guard let image = UIImage(data: data) else { continue }
            size = image.size
            #endif

            let date = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? Date()

            items.append(
                FormlessAssetItem(
                    id: name,
                    title: "圖片 \(items.count + 1)",
                    addedAt: date,
                    digest: key,
                    width: Int(size.width),
                    height: Int(size.height)
                )
            )

            changed = true
        }

        if changed { write(items) }
    }

    nonisolated static func rename(_ id: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty else { return }

        var items = all()

        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        items[index].title = clean
        write(items)
    }

    nonisolated static func remove(_ id: String) {
        var items = all()
        items.removeAll { $0.id == id }
        write(items)

        guard let directory = FormlessStorage.assetsDirectoryURL else { return }

        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(id)
        )

        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(id + ".thumb")
        )

        FormlessAssetCache.shared.invalidate(id)
        FormlessAssetCache.shared.invalidate(id + ".thumb")
    }

    nonisolated static func thumbName(for item: FormlessAssetItem) -> String {
        FormlessAssetCache.shared.data(named: item.thumbName) != nil
            ? item.thumbName
            : item.id
    }

    #if canImport(UIKit)
    nonisolated private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)

        guard longest > maxSide, longest > 0 else { return image }

        let scale = maxSide / longest

        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // 一般色域、每色 8 位元：預設格式遇到廣色域的截圖會存成 16 位元 PNG，解碼後的記憶體多一倍（2026-10）。
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    nonisolated private static func encoded(_ image: UIImage) -> Data? {
        if let data = image.pngData(), data.count < 4_000_000 { return data }
        return image.jpegData(compressionQuality: 0.9) ?? image.pngData()
    }
    #endif
}


// MARK: - 網路

enum FormlessNetwork {

    /// 桌面小工具的時間軸有時間上限，逾時要短
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}


/// 網路圖片快取，預設 6 小時
enum FormlessRemoteImageCache {

    nonisolated static let lifetime: TimeInterval = 6 * 3600

    nonisolated private static func fileName(for urlText: String) -> String {
        var hash: UInt64 = 5381

        for byte in Array(urlText.utf8) {
            hash = hash &* 33 &+ UInt64(byte)
        }

        return "remote-\(hash).img"
    }

    nonisolated private static func fileURL(for urlText: String) -> URL? {
        guard let directory = FormlessStorage.assetsDirectoryURL else { return nil }
        return directory.appendingPathComponent(fileName(for: urlText))
    }

    nonisolated static func load(for urlText: String) -> Data? {
        guard let url = fileURL(for: urlText) else { return nil }

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) < lifetime
        else {
            return nil
        }

        return try? Data(contentsOf: url)
    }

    /// 使用者填的圖片網址。沒寫 http(s):// 的（新增網路圖片時預設的「https://」會先反白，直接打網址就會蓋掉它）
    /// 自動補上 https://，不必要求使用者記得打。只在載入時補，不改使用者填的內容。
    nonisolated static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    nonisolated static func save(_ data: Data, for urlText: String) {
        guard let url = fileURL(for: urlText) else { return }
        // 同一張圖重抓回來：只延長快取時間（壽命看檔案時間），不重寫、不通知首頁重畫縮圖。
        if let existing = try? Data(contentsOf: url), existing == data {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            NotificationCenter.default.post(name: FormlessCache.didUpdate, object: nil)
        } catch { return }
    }
}


// MARK: - 即時資料快取

enum FormlessCache {
    nonisolated static let didUpdate = Notification.Name("FormlessCache.didUpdate")

    private nonisolated static var directoryURL: URL? {
        FormlessStorage.cacheDirectoryURL
    }

    /// 內容和檔案裡的一模一樣時不重寫、不通知（只更新檔案時間）：通知會讓首頁把所有縮圖重畫一次，
    /// 原本每次更新資料（多半沒變）都重畫好幾次。`notify` 為 false 的檔案（例如更新時間戳）不影響畫面，不必通知。
    nonisolated static func save<T: Encodable>(_ value: T, name: String, notify: Bool = true) {
        guard let directory = directoryURL else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(value) else { return }
        let url = directory.appendingPathComponent(name)

        if let existing = try? Data(contentsOf: url), existing == data {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            if notify { NotificationCenter.default.post(name: didUpdate, object: nil) }
        } catch { return }
    }

    nonisolated static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let directory = directoryURL else { return nil }

        guard let data = try? Data(
            contentsOf: directory.appendingPathComponent(name)
        ) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try? decoder.decode(type, from: data)
    }
}


// MARK: - 行事曆事件

struct FormlessEventItem: Codable, Hashable, Identifiable, Sendable {

    var id: String
    var title: String
    var calendarName: String
    var calendarColorHex: String
    var startDate: Date
    var isAllDay: Bool
    var location: String? = nil
    /// 舊快取沒有這個欄位，缺少時視為不明；地點過濾只在有識別碼時生效。
    var calendarIdentifier: String? = nil
    /// 結束時間。舊快取沒有這個欄位（解得開、是 nil），何時消失見 `FormlessLiveTime.visibleUntil`。
    var endDate: Date? = nil

    var dateText: String {
        formlessFormatted("MM/dd", date: startDate)
    }

    var timeText: String {
        if isAllDay { return "整天" }
        return formlessFormatted("a h:mm", date: startDate)
    }
}


/// 要讀哪幾本行事曆。EventKit 沒有提供「行事曆 App 裡有沒有打勾」的資訊，
/// 那是行事曆 App 自己的顯示設定，外部讀不到，所以小工具要有自己的選擇。
struct FormlessCalendarSettings: Codable, Sendable {

    static let cacheName = "calendar-settings.json"

    /// 空集合代表全部都讀
    var excluded: Set<String> = []

    nonisolated static func current() -> FormlessCalendarSettings {
        FormlessCache.load(FormlessCalendarSettings.self, name: cacheName) ?? FormlessCalendarSettings()
    }

    nonisolated static func save(_ settings: FormlessCalendarSettings) {
        FormlessCache.save(settings, name: cacheName)
    }
}


/// 行事曆類別的顯示名稱：使用者在設定頁替行事曆取的名字（以行事曆識別碼對應），
/// 小工具上的「事件分類」與行程清單都顯示這個名字；沒改過的沿用行事曆本身的名稱。
struct FormlessCalendarNameSettings: Codable, Sendable {

    static let cacheName = "calendar-names.json"

    var names: [String: String] = [:]

    nonisolated static func current() -> FormlessCalendarNameSettings {
        FormlessCache.load(FormlessCalendarNameSettings.self, name: cacheName) ?? FormlessCalendarNameSettings()
    }

    nonisolated static func save(_ settings: FormlessCalendarNameSettings) {
        FormlessCache.save(settings, name: cacheName)
    }

    func name(for identifier: String?) -> String? {
        guard let identifier, let name = names[identifier], !name.isEmpty else { return nil }
        return name
    }
}


/// 全域地點擷取；空白或無效規則一律保留原文。
/// `excludedCalendars` 列出不顯示地點的行事曆；空集合代表全部都顯示。
struct FormlessEventLocationSettings: Codable, Hashable, Sendable {
    static let cacheName = "event-location-settings.json"
    var pattern: String = ""
    var excludedCalendars: Set<String> = []

    static func load() -> Self {
        FormlessCache.load(Self.self, name: cacheName) ?? Self()
    }

    /// 這個行程要不要顯示地點。沒有行事曆識別碼的舊快取一律顯示。
    func showsLocation(for event: FormlessEventItem) -> Bool {
        guard let id = event.calendarIdentifier else { return true }
        return !excludedCalendars.contains(id)
    }

    func extract(_ original: String) -> String {
        guard !pattern.isEmpty,
              let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: original) else { return original }
        return String(original[range])
    }
}

extension FormlessEventLocationSettings {
    private enum CodingKeys: String, CodingKey { case pattern, excludedCalendars }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        excludedCalendars = try container.decodeIfPresent(Set<String>.self, forKey: .excludedCalendars) ?? []
    }
}

enum FormlessEventsProvider {

    static let cacheName = "events.json"

    /// 全部可讀的行事曆，依帳號分組時由呼叫端整理
    static func allCalendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return EKEventStore().calendars(for: .event)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static var isAuthorized: Bool {
        return EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    @discardableResult
    @MainActor
    static func requestAccess() async -> Bool {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return isAuthorized }
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func fetch(limit: Int = 12, days: Int = 60) -> [FormlessEventItem]? {
        guard isAuthorized else { return nil }

        let store = EKEventStore()

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        let start = calendar.startOfDay(for: Date())

        guard let end = calendar.date(byAdding: .day, value: days, to: start) else {
            return nil
        }

        let excluded = FormlessCalendarSettings.current().excluded

        let included = store.calendars(for: .event)
            .filter { !excluded.contains($0.calendarIdentifier) }

        guard !included.isEmpty else { return [] }

        // 今天已結束的行程也存（小工具可以設定照常顯示）；要篩掉時，時間軸每一格依自己的時間篩（`FormlessLiveTime`）。
        // 要讓時間軸最後一格仍有 limit 筆可以填，除了前 limit 筆撐過時間軸的行程，排在它們前面的（已結束、會在時間軸內結束的）也一起存。
        let now = Date()
        let horizon = now.addingTimeInterval(FormlessLiveTime.fetchHorizon)
        func picked(_ matched: [EKEvent]) -> (events: [EKEvent], complete: Bool) {
            var result: [EKEvent] = []
            var lasting = 0
            for event in matched.sorted(by: { ($0.startDate ?? start) < ($1.startDate ?? start) }) {
                let until = FormlessLiveTime.visibleUntil(start: event.startDate ?? start, end: event.endDate,
                                                          allDay: event.isAllDay, calendar: calendar)
                result.append(event)
                if until > horizon { lasting += 1 }
                if lasting >= limit { return (result, true) }
            }
            return (result, false)
        }

        // 先查一週：一週內就湊得到 limit 筆撐過時間軸的行程，結果一定和查整段相同（之後的行程開始得更晚，排在它們後面）；
        // 不夠才查整段。原本每次都把 60 天內的重複行程全部展開，只為了取最前面 12 筆。
        func query(until end: Date) -> [EKEvent] {
            store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: included))
        }
        var events: [EKEvent] = []
        if limit < Int.max, days > 7, let week = calendar.date(byAdding: .day, value: 7, to: start) {
            let first = picked(query(until: week))
            events = first.complete ? first.events : picked(query(until: end)).events
        } else {
            events = picked(query(until: end)).events
        }

        return events.map { event in
            FormlessEventItem(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "（無標題）",
                calendarName: event.calendar?.title ?? "",
                calendarColorHex: FormlessEventsProvider.hex(from: event.calendar),
                startDate: event.startDate ?? start,
                isAllDay: event.isAllDay,
                location: event.location,
                calendarIdentifier: event.calendar?.calendarIdentifier,
                endDate: event.endDate
            )
        }
    }

    /// 今日事件數：時間 date 時仍會顯示、而且是那一天開始的行程。
    static func todayCount(in items: [FormlessEventItem], at date: Date = Date()) -> Int {
        let calendar = FormlessLiveTime.calendar
        return items.filter {
            FormlessLiveTime.isVisible($0, at: date) && calendar.isDate($0.startDate, inSameDayAs: date)
        }.count
    }

    private static func hex(from calendar: EKCalendar?) -> String {
        #if canImport(UIKit)
        guard let cgColor = calendar?.cgColor else { return "#4C8BF6" }
        return Color(uiColor: UIColor(cgColor: cgColor)).formlessHex
        #else
        return "#4C8BF6"
        #endif
    }
}


// MARK: - 步數

struct FormlessStepsCache: Codable, Sendable {
    var steps: Int
    var updatedAt: Date

    /// 存今天的步數。今天已經存過同樣的數字就不重寫：畫面只看「是不是今天的」與數字，重寫只會讓首頁重畫縮圖。
    nonisolated static func record(_ steps: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")
        if let old = FormlessCache.load(FormlessStepsCache.self, name: FormlessStepsProvider.cacheName),
           old.steps == steps, calendar.isDateInToday(old.updatedAt) { return }
        FormlessCache.save(FormlessStepsCache(steps: steps, updatedAt: Date()), name: FormlessStepsProvider.cacheName)
    }
}


enum FormlessStepsProvider {

    static let cacheName = "steps.json"

    static var isAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    /// 這台裝置能不能取得步數，計步器或健康資料任一可用即可
    static var stepsAvailable: Bool {
        #if canImport(CoreMotion)
        if CMPedometer.isStepCountingAvailable() { return true }
        #endif
        return isAvailable
    }

    /// 動作與健身權限尚未詢問過。只有主 App 能跳出詢問視窗，小工具行程不行。
    static var motionNeedsPrompt: Bool {
        #if canImport(CoreMotion)
        return CMPedometer.authorizationStatus() == .notDetermined
        #else
        return false
        #endif
    }

    @MainActor private static var authorizationTask: Task<Bool, Never>?
    @MainActor private(set) static var authorizationError: String?

    /// 系統是否還會跳出詢問視窗。已經問過就不會再問，介面要改成開「健康」App。
    @MainActor static func promptWouldAppear() async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable, let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return false }
        let store = HKHealthStore()
        guard let status = try? await store.statusForAuthorizationRequest(toShare: [], read: [type]) else { return false }
        return status != .unnecessary
        #else
        return false
        #endif
    }

    @discardableResult
    @MainActor static func requestAccess() async -> Bool {
        if let pending = authorizationTask { return await pending.value }
        authorizationError = nil
        let task = Task { @MainActor in
            #if canImport(HealthKit)
            guard isAvailable, let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return false }
            let store = HKHealthStore()
            do {
                let status = try await store.statusForAuthorizationRequest(toShare: [], read: [type])
                if status != .unnecessary {
                    try await store.requestAuthorization(toShare: [], read: [type])
                }
                return true // Request completed; this does not reveal read permission.
            } catch {
                authorizationError = error.localizedDescription
                return false
            }
            #else
            return false
            #endif
        }
        authorizationTask = task
        let result = await task.value
        authorizationTask = nil
        return result
    }

    /// 步數優先走計步器：資料直接來自動作處理器，行動中每幾秒就更新，小工具行程也讀得到。
    /// HealthKit 的步數樣本是分批寫入的，會慢上一段時間，只當成備援。
    static func fetchToday() async -> Int? {
        if let steps = await pedometerToday() { return steps }
        return await healthToday()
    }

    static func pedometerToday() async -> Int? {
        #if canImport(CoreMotion)
        guard CMPedometer.isStepCountingAvailable() else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        let start = calendar.startOfDay(for: Date())
        let pedometer = CMPedometer()

        return await withCheckedContinuation { continuation in
            let completion = FormlessOneShot<Int?> { continuation.resume(returning: $0) }

            pedometer.queryPedometerData(from: start, to: Date()) { [pedometer] data, _ in
                _ = pedometer
                completion.resolve(data.map { $0.numberOfSteps.intValue })
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                completion.resolve(nil)
            }
        }
        #else
        return nil
        #endif
    }

    static func healthToday() async -> Int? {
        #if canImport(HealthKit)
        guard isAvailable else { return nil }
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        let start = calendar.startOfDay(for: Date())

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: Date(),
            options: .strictStartDate
        )

        let store = HKHealthStore()

        return await withCheckedContinuation { continuation in
            let completion = FormlessOneShot<Int?> { continuation.resume(returning: $0) }
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in

                guard let sum = statistics?.sumQuantity() else {
                    completion.resolve(nil)
                    return
                }

                let value = sum.doubleValue(for: HKUnit.count())
                completion.resolve(Int(value.rounded()))
            }

            store.execute(query)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                if completion.resolve(nil) { store.stop(query) }
            }
        }
        #else
        return nil
        #endif
    }
}


// MARK: - 天氣

struct FormlessWeatherDay: Codable, Hashable, Sendable {

    var date: Date
    var code: Int
    var high: Double
    var low: Double

    /// 該日與現在同一個鐘點的逐時預報。抓不到才退回當日高溫。
    var sampledTemperature: Double?
    var sampledCode: Int?

    /// 取樣那一刻是白天還是夜晚。現在是半夜，五天的那個鐘點也都是半夜，
    /// 圖示要跟著換成夜間版。
    var sampledIsDay: Bool?

    /// 當日均溫。預報欄位顯示的是「那一天的天氣」，對應 Widgy 的「天氣（每日）」。
    var mean: Double?

    var displayTemperature: Double {
        FormlessWeatherStyle.temperature(mean ?? sampledTemperature ?? high)
    }
    var displayCode: Int { code }
    var displayIsDay: Bool { sampledIsDay ?? true }
}

struct FormlessWeatherData: Codable, Hashable, Sendable {

    var locationName: String
    var temperature: Double
    var code: Int
    var days: [FormlessWeatherDay]
    var updatedAt: Date
    var isDay: Bool?
    var sunrise: Date?
    var sunset: Date?

    /// 白天或夜晚要用畫面當下的時間判斷。抓資料當下的 is_day 會跟著快取一起過期，
    /// 日出日落是絕對時間，時間軸先排好的畫面也算得準。
    func isDaylight(at date: Date) -> Bool {
        if let sunrise, let sunset { return date >= sunrise && date < sunset }
        return isDay ?? true
    }

    var temperatureText: String {
        String(Int(FormlessWeatherStyle.temperature(temperature).rounded()))
    }

    var conditionText: String {
        FormlessWeatherCode.text(for: code)
    }

    var symbolName: String {
        FormlessWeatherCode.symbol(for: code)
    }
}


/// 天氣條件。對應 8 組自訂圖片，每一組都能改用語與圖片。
enum FormlessWeatherCondition: String, CaseIterable, Codable, Sendable {

    case clear
    case fair
    case cloudy
    case lightRain
    case rain
    case thunder
    case snow
    case fog

    /// 設定畫面上固定的分類名稱，不會被自訂用語覆蓋
    var label: String {
        switch self {
        case .clear: return "晴"
        case .fair: return "局部多雲"
        case .cloudy: return "多雲"
        case .lightRain: return "短暫雨"
        case .rain: return "雨"
        case .thunder: return "雷雨"
        case .snow: return "雪"
        case .fog: return "陰、霧"
        }
    }

    var defaultText: String {
        switch self {
        case .clear: return "晴天"
        case .fair: return "局部多雲"
        case .cloudy: return "多雲"
        case .lightRain: return "短暫雨"
        case .rain: return "下雨"
        case .thunder: return "雷雨"
        case .snow: return "下雪"
        case .fog: return "陰天"
        }
    }

    var hasNightVariant: Bool {
        switch self {
        case .clear, .fair, .cloudy, .lightRain: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .fair: return "cloud.sun.fill"
        case .cloudy: return "cloud.sun.fill"
        case .lightRain: return "cloud.sun.rain.fill"
        case .rain: return "cloud.rain.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .fog: return "cloud.fill"
        }
    }

    func assetName(isDay: Bool) -> String {
        let base = "Weather-" + rawValue
        if isDay || !hasNightVariant { return base + "-day" }
        return FormlessAsset.available(base + "-night") ?? (base + "-day")
    }

    /// Open-Meteo（WMO）天氣代碼分類
    nonisolated static func from(code: Int) -> FormlessWeatherCondition {
        switch code {
        case 0: return .clear
        case 1: return .fair
        case 2: return .cloudy
        case 3, 45, 48: return .fog
        case 51, 53, 55, 56, 57, 61, 80: return .lightRain
        case 63, 65, 66, 67, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99: return .thunder
        default: return .fog
        }
    }
}


/// 天氣用語與圖片的自訂設定。存在共用資料夾，App 與桌面小工具共用。
struct FormlessWeatherStyleSettings: Codable, Sendable {

    var words: [String: String] = [:]
    var images: [String: String] = [:]

    /// c 或 f
    var unit: String?

    static func key(_ condition: FormlessWeatherCondition, isDay: Bool) -> String {
        condition.rawValue + (isDay ? "-day" : "-night")
    }
}


/// 設定與圖片的記憶體快取。每張圖示都會查一次，不快取會一直讀檔。
private final class FormlessWeatherStyleCache: @unchecked Sendable {

    static let shared = FormlessWeatherStyleCache()

    private let lock = NSLock()
    private var settings: FormlessWeatherStyleSettings?
    private var loadedAt = Date.distantPast
    private static let lifetime: TimeInterval = 30

    func current() -> FormlessWeatherStyleSettings {
        lock.lock()

        if let settings, Date().timeIntervalSince(loadedAt) < Self.lifetime {
            lock.unlock()
            return settings
        }

        if Thread.isMainThread && !FormlessRenderContext.isExtension {
            let value = settings ?? FormlessWeatherStyleSettings()
            lock.unlock()
            return value
        }

        lock.unlock()

        let fresh = FormlessCache.load(
            FormlessWeatherStyleSettings.self,
            name: FormlessWeatherStyle.cacheName
        ) ?? FormlessWeatherStyleSettings()

        lock.lock()
        settings = fresh
        loadedAt = Date()
        lock.unlock()

        return fresh
    }

    func store(_ value: FormlessWeatherStyleSettings) {
        lock.lock()
        settings = value
        loadedAt = Date()
        lock.unlock()
    }
}


enum FormlessWeatherStyle {

    static let cacheName = "weather-style.json"

    nonisolated static func current() -> FormlessWeatherStyleSettings {
        FormlessWeatherStyleCache.shared.current()
    }

    nonisolated static func save(_ settings: FormlessWeatherStyleSettings) {
        FormlessCache.save(settings, name: cacheName)
        FormlessWeatherStyleCache.shared.store(settings)
    }

    nonisolated static func text(for condition: FormlessWeatherCondition) -> String {
        let custom = current().words[condition.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let custom, !custom.isEmpty { return custom }

        return condition.defaultText
    }

    nonisolated static func text(for code: Int) -> String {
        text(for: FormlessWeatherCondition.from(code: code))
    }

    nonisolated static var usesFahrenheit: Bool {
        current().unit == "f"
    }

    /// 攝氏轉成目前設定的單位
    nonisolated static func temperature(_ celsius: Double) -> Double {
        usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    nonisolated static func customImageName(
        _ condition: FormlessWeatherCondition,
        isDay: Bool
    ) -> String? {

        let settings = current()
        let wanted = FormlessWeatherStyleSettings.key(condition, isDay: isDay)

        if let name = settings.images[wanted] { return name }

        guard !isDay else { return nil }

        return settings.images[FormlessWeatherStyleSettings.key(condition, isDay: true)]
    }
}


enum FormlessWeatherCode {

    nonisolated static func text(for code: Int) -> String {
        FormlessWeatherStyle.text(for: code)
    }

    nonisolated static func asset(for code: Int, isDay: Bool) -> String {
        FormlessWeatherCondition.from(code: code).assetName(isDay: isDay)
    }

    nonisolated static func symbol(for code: Int) -> String {
        FormlessWeatherCondition.from(code: code).symbol
    }
}


/// 依天氣代碼選圖：自訂圖片 → 內建圖片 → 系統圖示
struct FormlessConditionIcon: View {

    let code: Int
    var isDay: Bool = true
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let condition = FormlessWeatherCondition.from(code: code)

        FormlessWeatherIcon(
            name: condition.symbol,
            assetName: condition.assetName(isDay: isDay),
            customName: FormlessWeatherStyle.customImageName(condition, isDay: isDay),
            width: width,
            height: height
        )
    }
}


#if canImport(UIKit)
/// 網路圖片解碼後的圖：同一份資料不要每次重畫都新建 UIImage（每次新建，畫面都要重新解碼一次）。
/// 以資料的長度與頭、中、尾各一小段當指紋，不必每次把整份資料雜湊一遍。
enum FormlessRemoteImageMemo {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()

    static func image(for data: Data) -> UIImage? {
        let key = fingerprint(data) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 只解碼到畫出來的大小 × 3（網路圖片最大 8 MB，原尺寸解碼可能超過小工具的記憶體上限）。
    static func image(for data: Data, drawnIn size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let target = FormlessAssetCache.decodePixels(source, drawnIn: size, fill: false, screenScale: 3)
        else { return image(for: data) }
        guard let maxPixel = target else { return image(for: data) }
        let key = (fingerprint(data) + "@\(maxPixel)") as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let made = FormlessAssetCache.thumbnail(source, maxPixel: maxPixel) else { return image(for: data) }
        cache.setObject(made, forKey: key)
        return made
    }

    private static func fingerprint(_ data: Data) -> String {
        var hasher = Hasher()
        hasher.combine(data.prefix(256))
        let middle = data.count / 2
        hasher.combine(data.dropFirst(max(0, middle - 128)).prefix(256))
        hasher.combine(data.suffix(256))
        return "\(data.count)-\(hasher.finalize())"
    }
}
#endif

/// 步數加千分位（例如 12,345）。格式器只建一次：原本每次重畫都新建一個，建立格式器很慢。
private let formlessStepsFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "zh_Hant_TW")
    return formatter
}()

func formlessStepsText(_ steps: Int) -> String {
    formlessStepsFormatter.string(from: NSNumber(value: steps)) ?? "\(steps)"
}

struct FormlessCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
}


enum FormlessWeatherProvider {

    static let locationCacheName = "location.json"

    static let defaultCoordinate = FormlessCoordinate(
        latitude: 25.0330,
        longitude: 121.5654,
        name: "台北"
    )

    static func cacheName(for coordinate: FormlessCoordinate) -> String {
        let lat = String(format: "%.2f", coordinate.latitude)
        let lon = String(format: "%.2f", coordinate.longitude)
        return "weather-\(lat)-\(lon).json"
    }

    static func coordinate(for layer: FormlessLayer) -> FormlessCoordinate {
        if layer.useCurrentLocation ?? false {
            if let cached = FormlessCache.load(
                FormlessCoordinate.self,
                name: locationCacheName
            ) {
                return cached
            }
        }

        if let latitude = layer.latitude, let longitude = layer.longitude {
            return FormlessCoordinate(
                latitude: latitude,
                longitude: longitude,
                name: layer.locationName ?? ""
            )
        }

        return defaultCoordinate
    }

    static func fetch(for coordinate: FormlessCoordinate) async -> FormlessWeatherData? {

        var components = URLComponents(
            string: "https://api.open-meteo.com/v1/forecast"
        )

        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,temperature_2m_mean,sunrise,sunset"
            ),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]

        guard let url = components?.url else { return nil }

        guard let result = try? await FormlessNetwork.session.data(from: url) else {
            return nil
        }

        guard let payload = try? JSONDecoder().decode(
            OpenMeteoResponse.self,
            from: result.0
        ) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        // 逐時預報：用「YYYY-MM-DDTHH」當索引，之後每一天都取現在這個鐘點
        let hourFormatter = DateFormatter()
        hourFormatter.locale = Locale(identifier: "en_US_POSIX")
        hourFormatter.dateFormat = "yyyy-MM-dd'T'HH"

        var hourlyTemperature: [String: Double] = [:]
        var hourlyCode: [String: Int] = [:]

        if let hourly = payload.hourly {
            let hours = min(
                hourly.time.count,
                min(hourly.temperature_2m.count, hourly.weather_code.count)
            )

            for index in 0..<hours {
                let key = String(hourly.time[index].prefix(13))
                hourlyTemperature[key] = hourly.temperature_2m[index]
                hourlyCode[key] = hourly.weather_code[index]
            }
        }

        let currentHour = String(
            format: "%02d",
            Calendar(identifier: .gregorian).component(.hour, from: Date())
        )

        // 日出日落回傳當地時間字串，配合 utc_offset_seconds 還原成絕對時間
        let offset = TimeInterval(payload.utc_offset_seconds ?? 0)

        let clockFormatter = DateFormatter()
        clockFormatter.locale = Locale(identifier: "en_US_POSIX")
        clockFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        clockFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        func instant(_ text: String?) -> Date? {
            guard let text, let value = clockFormatter.date(from: String(text.prefix(16))) else { return nil }
            return value.addingTimeInterval(-offset)
        }

        let sunrises = payload.daily.sunrise ?? []
        let sunsets = payload.daily.sunset ?? []
        let means = payload.daily.temperature_2m_mean ?? []

        var days: [FormlessWeatherDay] = []

        let count = min(
            payload.daily.time.count,
            min(
                payload.daily.weather_code.count,
                min(
                    payload.daily.temperature_2m_max.count,
                    payload.daily.temperature_2m_min.count
                )
            )
        )

        for index in 0..<count {
            guard let date = formatter.date(from: payload.daily.time[index]) else { continue }

            let key = payload.daily.time[index] + "T" + currentHour

            // 取樣時刻落在那一天的日出與日落之間才算白天
            var sampledIsDay: Bool?

            if
                index < sunrises.count,
                index < sunsets.count,
                let sample = instant(key + ":00"),
                let rise = instant(sunrises[index]),
                let set = instant(sunsets[index])
            {
                sampledIsDay = sample >= rise && sample < set
            }

            days.append(
                FormlessWeatherDay(
                    date: date,
                    code: payload.daily.weather_code[index],
                    high: payload.daily.temperature_2m_max[index],
                    low: payload.daily.temperature_2m_min[index],
                    sampledTemperature: hourlyTemperature[key],
                    sampledCode: hourlyCode[key],
                    sampledIsDay: sampledIsDay,
                    mean: index < means.count ? means[index] : nil
                )
            )
        }

        return FormlessWeatherData(
            locationName: coordinate.name,
            temperature: payload.current.temperature_2m,
            code: payload.current.weather_code,
            days: days,
            updatedAt: Date(),
            isDay: (payload.current.is_day ?? 1) == 1,
            sunrise: instant(payload.daily.sunrise?.first),
            sunset: instant(payload.daily.sunset?.first)
        )
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int?
        }

        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let temperature_2m_mean: [Double]?
            let sunrise: [String]?
            let sunset: [String]?
        }

        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let weather_code: [Int]
        }

        let current: Current
        let daily: Daily
        let hourly: Hourly?
        let utc_offset_seconds: Int?
    }
}


// MARK: - 位置

@MainActor
final class FormlessLocationProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    static let shared = FormlessLocationProvider()
    nonisolated static let didResolveLocation = Notification.Name("FormlessLocationProvider.didResolveLocation")

    private let manager = CLLocationManager()

    override init() {
        super.init()
        authorizationStatus = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func requestAccess() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func refresh() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }

        let coordinate = location.coordinate

        // 還在同一個天氣格（快取以小數兩位分格，約 1 公里）且地名已查好：天氣和現在一樣，不重存、不通知；
        // 只再確認一次地名，跨區時才更新。原本每次定位都存兩次、通知兩次，首頁各做一次完整的資料更新。
        let fresh = FormlessCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude, name: "目前位置")
        if let current = FormlessCache.load(FormlessCoordinate.self, name: FormlessWeatherProvider.locationCacheName),
           current.name != "目前位置",
           FormlessWeatherProvider.cacheName(for: current) == FormlessWeatherProvider.cacheName(for: fresh) {
            resolvePlaceName(for: location,
                             coordinate: CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude))
            return
        }

        // 先把座標存起來，地名之後再補，避免查不到地名就完全沒有天氣
        FormlessCache.save(
            FormlessCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: "目前位置"
            ),
            name: FormlessWeatherProvider.locationCacheName
        )

        NotificationCenter.default.post(name: Self.didResolveLocation, object: nil)
        resolvePlaceName(for: location, coordinate: coordinate)
    }

    /// 反向地理編碼。維持用 CLGeocoder，MapKit 的替代 API 只給到市級，拿不到「中正區」這一層。
    /// iOS 26 起會出現棄用警告，功能不受影響。
    private func resolvePlaceName(
        for location: CLLocation,
        coordinate: CLLocationCoordinate2D
    ) {
        CLGeocoder().reverseGeocodeLocation(location) { places, _ in
            guard let place = places?.first else { return }
            guard let current = FormlessCache.load(FormlessCoordinate.self, name: FormlessWeatherProvider.locationCacheName),
                  current.latitude == coordinate.latitude, current.longitude == coordinate.longitude else { return }

            let name = place.subLocality
                ?? place.locality
                ?? place.subAdministrativeArea
                ?? place.administrativeArea
                ?? "目前位置"
            // 地名沒變就不必存、不必通知（通知會讓首頁重新抓所有資料）。
            guard name != current.name else { return }

            FormlessCache.save(
                FormlessCoordinate(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    name: name
                ),
                name: FormlessWeatherProvider.locationCacheName
            )
            NotificationCenter.default.post(name: Self.didResolveLocation, object: nil)
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // 取不到位置就沿用上一次的快取
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        refresh()
    }
}


// MARK: - 一次備齊的即時資料

struct FormlessLiveData: Hashable, Sendable {

    var events: [FormlessEventItem] = []
    var todayEventCount: Int = 0
    var reminders: [FormlessReminderItem] = []
    var todayReminderCount: Int = 0
    var steps: Int? = nil
    var weather: FormlessWeatherData? = nil
    var remoteImages: [UUID: Data] = [:]
    var eventLocations: [String: String] = [:]

    // 資料系統（2026-10 通用化）：App 畫布、首頁縮圖、小工具都用同一份，看到的值一定相同。
    /// 這份設計用到的資料快照，以來源的快取鍵為鍵（同一份臺北天氣只存一份）。
    var snapshots: [String: FormlessSnapshot] = [:]
    /// 這份設計自己的來源；沒有列出的用 App 預設。
    var sources: [FormlessSource] = []
    /// 我的資料。
    var variables: [FormlessVariable] = []
    /// 小工具按鈕改過的我的資料（切換、加減），以變數 id 為鍵。
    var variableState: [String: FormlessValue] = [:]
    /// 重複排列裡正在畫的那一筆。
    var item: FormlessRecord? = nil
    /// 範例資料預覽：每個欄位用範例值。
    var sampleMode = false
    /// 編輯器預覽「沒有資料」：每個來源都當成沒有內容（我的資料照舊）。
    var emptyMode = false
    /// 編輯器預覽「很長的文字」：文字欄位換成長句，檢查版面。
    var longTextMode = false
    /// 這一刻的顯示環境（深淺色、透明或染色、StandBy）；由畫圖層的地方從 SwiftUI 環境帶入。
    var environment = FormlessRenderEnvironment()

    /// 帶入一份設計的來源與我的資料（快照另外由 `FormlessDataCoordinator` 讀）。
    mutating func adopt(_ document: FormlessDocument) {
        sources = document.sources ?? []
        variables = document.variables ?? []
    }

    static func fromCache() -> FormlessLiveData {
        var data = FormlessLiveData()
        let locationSettings = FormlessEventLocationSettings.load()
        let calendarNames = FormlessCalendarNameSettings.current()

        if var events = FormlessCache.load(
            [FormlessEventItem].self,
            name: FormlessEventsProvider.cacheName
        ) {
            // 使用者改過名稱的行事曆類別，在這裡換成顯示名稱；App 與桌面小工具都從這裡取資料。
            for index in events.indices {
                if let name = calendarNames.name(for: events[index].calendarIdentifier) {
                    events[index].calendarName = name
                }
            }
            data.events = events
            for event in events {
                data.eventLocations[event.id] = locationSettings.showsLocation(for: event)
                    ? locationSettings.extract(event.location ?? "") : ""
            }
        }

        if let reminders = FormlessCache.load(
            [FormlessReminderItem].self,
            name: FormlessRemindersProvider.cacheName
        ) {
            data.reminders = reminders
        }

        if let steps = FormlessCache.load(
            FormlessStepsCache.self,
            name: FormlessStepsProvider.cacheName
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "zh_Hant_TW")

            if calendar.isDateInToday(steps.updatedAt) {
                data.steps = steps.steps
            }
        }

        // 這裡不篩：每個小工具可以選要不要顯示已過的項目，由 `cached(for:)` 依設計檔篩選。
        return data.at(Date(), showsPast: true)
    }

    /// 時間 date 時畫面上該有的行程與提醒事項：已結束的行程、時間已過的提醒拿掉，今日事件數、今日提醒數重算。
    /// 小工具時間軸的每一格用自己的時間呼叫；時間越晚只會拿掉更多項目，對篩過的資料再篩一次結果相同。
    /// showsPast（小工具設定「保留今天已過的行程與提醒」）：不拿掉任何項目，今日數字照原本的算法（今天開始的行程、今天到期或逾期的提醒）。
    func at(_ date: Date, showsPast: Bool = false) -> FormlessLiveData {
        var data = self
        let calendar = FormlessLiveTime.calendar
        if showsPast {
            let endOfDay = FormlessLiveTime.endOfDay(date)
            data.todayEventCount = events.filter { calendar.isDate($0.startDate, inSameDayAs: date) }.count
            data.todayReminderCount = reminders.filter { $0.dueDate.map { $0 < endOfDay } ?? false }.count
            return data
        }
        data.events = events.filter { FormlessLiveTime.isVisible($0, at: date) }
        data.reminders = reminders.filter { FormlessLiveTime.isVisible($0, at: date) }
        data.todayEventCount = FormlessEventsProvider.todayCount(in: data.events, at: date)
        data.todayReminderCount = FormlessRemindersProvider.todayCount(in: data.reminders, at: date)
        return data
    }

    /// 需要哪些即時資料。元件拆解成圖層之後同樣算得出來。
    struct Needs: Sendable {
        var events = false
        var reminders = false
        var steps = false
        var weather = false
    }

    nonisolated static func needs(of document: FormlessDocument) -> Needs {
        var needs = Needs()

        func add(_ source: FormlessLiveSource?) {
            switch source?.need {
            case "events": needs.events = true
            case "reminders": needs.reminders = true
            case "steps": needs.steps = true
            case "weather": needs.weather = true
            default: break
            }
        }

        for layer in document.layers {
            // 條件顏色用到的資料也要抓，條件才判斷得出來。
            for rule in layer.colorRules ?? [] { add(rule.liveSource) }

            switch layer.type {
            case .events, .eventList:
                needs.events = true

            case .reminders, .reminderList:
                needs.reminders = true

            case .steps:
                needs.steps = true

            case .weather, .weatherForecast:
                needs.weather = true

            case .symbol:
                if layer.value == "auto:weather" { needs.weather = true }

            case .liveText:
                add(FormlessLiveSource(rawValue: layer.value ?? ""))

            default:
                break
            }
        }

        return needs
    }

    /// 天氣地點：先找天氣元件，找不到再找拆解後帶著座標的圖層
    nonisolated static func weatherLayer(in document: FormlessDocument) -> FormlessLayer? {
        if let layer = document.layers.first(where: { $0.type == .weather }) {
            return layer
        }

        // 編輯器把地點設定放在天氣預報元件或「跟著天氣」圖示那一層；讀取也先看那一層，
        // 否則拆解後的天氣設計會讀到排在前面、仍是「目前位置」的「地區」文字層（2026-10 修正）。
        if let layer = document.layers.first(where: {
            ($0.type == .weatherForecast || ($0.type == .symbol && ($0.value ?? "") == "auto:weather"))
                && ($0.latitude != nil || $0.longitude != nil || ($0.useCurrentLocation ?? false))
        }) {
            return layer
        }

        return document.layers.first {
            $0.latitude != nil || $0.longitude != nil || ($0.useCurrentLocation ?? false)
        }
    }

    /// 單一設計的快取資料。天氣的快取檔名跟著座標走，fromCache 抓不到，
    /// 所以預覽用的資料要依設計本身再補一次。
    nonisolated static func cached(for document: FormlessDocument, base: FormlessLiveData? = nil) -> FormlessLiveData {
        var data = (base ?? fromCache()).at(Date(), showsPast: document.showsPastItems ?? false)
        data.remoteImages = [:]
        let need = needs(of: document)

        if need.weather, let layer = weatherLayer(in: document) {
            let coordinate = FormlessWeatherProvider.coordinate(for: layer)

            data.weather = FormlessCache.load(
                FormlessWeatherData.self,
                name: FormlessWeatherProvider.cacheName(for: coordinate)
            )
        }

        for layer in document.layers where layer.type == .remoteImage {
            guard let text = layer.value else { continue }
            guard let bytes = FormlessRemoteImageCache.load(for: text) else { continue }

            data.remoteImages[layer.id] = bytes
        }

        data.adopt(document)
        data.snapshots = FormlessDataCoordinator.snapshots(for: document)
        data.variableState = FormlessVariableStore.values(for: document.id)

        return data
    }

    /// 主 App 進前景時先把資料抓進共用快取，桌面小工具才不會等到自己的更新配額
    /// 逾時就放棄，改用既有快取。沒有上限的話，任何一條卡住整批就永遠不會結束。
    nonisolated static func bounded(
        _ seconds: Double,
        _ work: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }

            await group.next()
            group.cancelAll()
        }
    }

    /// 剛抓過就不必再抓一次。點一下小工具時，主 App 的行程會先補齊快取，
    /// 接著系統才重建時間軸；沒有這個記號的話同一批資料會被抓兩次。
    static let warmStampName = "warm.json"

    struct WarmStamp: Codable, Sendable {
        var at: Date
        var documents: [String]
    }

    static func warmCaches(for documents: [FormlessDocument], force: Bool = false) async {
        var wantsEvents = false
        var wantsReminders = false
        var wantsSteps = false
        var weatherLayers: [FormlessLayer] = []

        for document in documents {
            let need = needs(of: document)

            wantsEvents = wantsEvents || need.events
            wantsReminders = wantsReminders || need.reminders
            wantsSteps = wantsSteps || need.steps

            if need.weather, let layer = weatherLayer(in: document) {
                weatherLayers.append(layer)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            // 新資料系統用到的來源：依各自的有效期限抓，同一個快取鍵只抓一次。
            group.addTask {
                await FormlessDataCoordinator.warm(documents, force: force)
            }
            if wantsEvents {
                group.addTask {
                    await bounded(6) {
                        if let events = FormlessEventsProvider.fetch() {
                            FormlessCache.save(events, name: FormlessEventsProvider.cacheName)
                        }
                    }
                }
            }
            if wantsReminders {
                group.addTask {
                    await bounded(6) {
                        if let reminders = await FormlessRemindersProvider.fetch() {
                            FormlessCache.save(reminders, name: FormlessRemindersProvider.cacheName)
                        }
                    }
                }
            }
            if wantsSteps {
                group.addTask {
                    await bounded(6) {
                        if let steps = await FormlessStepsProvider.fetchToday() {
                            FormlessStepsCache.record(steps)
                        }
                    }
                }
            }
            group.addTask {
                var seen = Set<String>()
                for document in documents {
                    for layer in document.layers where layer.type == .remoteImage {
                        guard let text = layer.value, seen.insert(text).inserted,
                              FormlessRemoteImageCache.load(for: text) == nil,
                              let url = FormlessRemoteImageCache.url(from: text) else { continue }
                        if let result = try? await FormlessNetwork.session.data(from: url),
                           let response = result.1 as? HTTPURLResponse,
                           (200..<300).contains(response.statusCode),
                           result.0.count <= 8 * 1024 * 1024,
                           UIImage(data: result.0) != nil {
                            FormlessRemoteImageCache.save(result.0, for: text)
                        }
                    }
                }
            }
            // One weather lane bounds concurrent requests even with many saved cities.
            group.addTask { [weatherLayers] in
                await bounded(12) {
                var done = Set<String>()
                for layer in weatherLayers {
                    let coordinate = FormlessWeatherProvider.coordinate(for: layer)
                    let name = FormlessWeatherProvider.cacheName(for: coordinate)
                    guard done.insert(name).inserted else { continue }
                    if let fresh = await FormlessWeatherProvider.fetch(for: coordinate) {
                        // 天氣內容沒變（只差抓取時間）就不重寫：updatedAt 沒有拿來判斷新舊，重寫只會讓首頁重畫縮圖。
                        if var old = FormlessCache.load(FormlessWeatherData.self, name: name) {
                            old.updatedAt = fresh.updatedAt
                            if old == fresh { continue }
                        }
                        FormlessCache.save(fresh, name: name)
                    }
                }
                }
            }
        }

        // 只用來判斷「剛剛更新過」，不影響畫面：不通知首頁重畫縮圖。
        FormlessCache.save(
            WarmStamp(at: Date(), documents: documents.map { $0.id.uuidString }),
            name: warmStampName,
            notify: false
        )
    }

    static func refreshed(for document: FormlessDocument) async -> FormlessLiveData {

        if let stamp = FormlessCache.load(WarmStamp.self, name: warmStampName),
           stamp.documents.contains(document.id.uuidString),
           Date().timeIntervalSince(stamp.at) < 8 {
            return cached(for: document)
        }

        await warmCaches(for: [document])
        return cached(for: document)
    }
}


// MARK: - 依時間篩選行程與提醒事項

/// 行程與提醒事項在某個時間點還顯不顯示。App（首頁縮圖、編輯器畫布與預覽）與小工具（時間軸每一格）共用這一套。
/// - 行程：結束時間之後不顯示；進行中的保留到結束，全天行程保留到當天結束。舊快取沒有結束時間：全天行程當天結束，其他以開始時間判斷。
/// - 提醒事項：有時間的到期後不顯示，只有日期的保留到當天結束；沒有到期日的一直顯示（範圍在讀取時已經篩過）。
enum FormlessLiveTime {

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")
        return calendar
    }

    /// 讀取時多讀的範圍：時間軸最長一格到下次更新（`effectiveRefreshMinutes` 最多 240 分鐘）。
    static let fetchHorizon: TimeInterval = 240 * 60

    /// 那一天結束的午夜。
    static func endOfDay(_ date: Date, calendar: Calendar = calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// 行程從這個時間起不再顯示。全天行程的結束時間是當天 23:59:59，進位到午夜。
    static func visibleUntil(start: Date, end: Date?, allDay: Bool, calendar: Calendar = calendar) -> Date {
        guard let end else { return allDay ? endOfDay(start, calendar: calendar) : start }
        guard allDay else { return end }
        return calendar.startOfDay(for: end) == end ? end : endOfDay(end, calendar: calendar)
    }

    static func visibleUntil(_ event: FormlessEventItem) -> Date {
        visibleUntil(start: event.startDate, end: event.endDate, allDay: event.isAllDay)
    }

    /// 提醒從這個時間起不再顯示；nil 是沒有到期日（一直顯示）。舊快取不知道有沒有時間：到期時間剛好是 0:00 視為只有日期。
    static func visibleUntil(_ reminder: FormlessReminderItem) -> Date? {
        guard let due = reminder.dueDate else { return nil }
        let timed = reminder.hasDueTime ?? (calendar.startOfDay(for: due) != due)
        return timed ? due : endOfDay(due)
    }

    static func isVisible(_ event: FormlessEventItem, at date: Date) -> Bool {
        visibleUntil(event) > date
    }

    static func isVisible(_ reminder: FormlessReminderItem, at date: Date) -> Bool {
        visibleUntil(reminder).map { $0 > date } ?? true
    }
}

/// 小工具時間軸要排哪些時間：原本的畫面（需要每分鐘更新的設計每 5 分鐘一格），
/// 再加上下次重新整理之前、畫面上的行程或提醒會變的每個時間點（行程結束、有時間的提醒到期、
/// 只有日期的提醒與全天行程的午夜；午夜前後今日數字不同時也排一格），每一格各自用自己的時間篩選資料。
enum FormlessLiveTimeline {

    /// 依資料加排的格數上限，避免行程很多時時間軸過大。
    static let maxDataEntries = 24

    static func dates(now: Date, minutes: Int, minuteRefresh: Bool, live: FormlessLiveData, showsPast: Bool = false,
                      extra: [Date] = []) -> [Date] {
        let end = now.addingTimeInterval(Double(minutes) * 60)
        var dates = minuteRefresh
            ? (0..<max(1, minutes / 5)).map { now.addingTimeInterval(Double($0) * 300) }
            : [now]
        // 新資料系統的變化點（倒數到期、日出日落、逐時預報、時間進度每過 1%…）。
        for date in extra.filter({ $0 > now && $0 < end }).sorted().prefix(maxDataEntries)
        where !dates.contains(where: { abs($0.timeIntervalSince(date)) < 1 }) {
            dates.append(date)
        }
        // 照常顯示已過的項目時，畫面不會隨行程結束改變，和原本一樣。
        guard !showsPast else { return dates.sorted() }

        var changes = Set(live.events.map(FormlessLiveTime.visibleUntil))
        changes.formUnion(live.reminders.compactMap(FormlessLiveTime.visibleUntil))
        let midnight = FormlessLiveTime.endOfDay(now)
        if midnight < end {
            let before = live.at(midnight.addingTimeInterval(-0.001)), after = live.at(midnight)
            if before.todayEventCount != after.todayEventCount || before.todayReminderCount != after.todayReminderCount {
                changes.insert(midnight)
            }
        }

        let added = changes.filter { $0 > now && $0 < end }.sorted().prefix(maxDataEntries)
        for date in added where !dates.contains(where: { abs($0.timeIntervalSince(date)) < 1 }) {
            dates.append(date)
        }
        return dates.sorted()
    }
}


// MARK: - 今日行程

struct FormlessEventsView: View {

    let layer: FormlessLayer
    let size: CGSize
    let date: Date
    let live: FormlessLiveData

    // Widgy 原檔數值
    private static let cardY: [CGFloat] = [391, 660, 931, 1197, 1467]
    private static let cardX: CGFloat = 178
    private static let cardW: CGFloat = 1354
    private static let cardH: CGFloat = 225

    private var titleColor: Color {
        Color(formlessHex: layer.secondaryColorHex, fallback: "#808080")
    }

    private var numberColor: Color {
        Color(formlessHex: layer.colorHex, fallback: "#000000")
    }

    private var cardColor: Color {
        Color(formlessHex: layer.panelColorHex, fallback: "#FFFFFF")
    }

    private var detailColor: Color {
        Color(formlessHex: layer.textColorHex, fallback: "#808080")
    }

    private var backdrop: Color {
        Color(formlessHex: "#F9F8F9")
    }

    private var visibleEvents: [FormlessEventItem] {
        let limit = max(1, min(layer.maxItems ?? 5, Self.cardY.count))
        return Array(live.events.prefix(limit))
    }

    var body: some View {
        let box = FormlessWidgyBox(size)

        ZStack(alignment: .topLeading) {
            cards(box)
            fade(box)
            ticks(box)
            header(box)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .clipped()
    }

    private func shift(_ part: String) -> CGPoint {
        let offset = layer.offset(part)
        return CGPoint(x: offset.x, y: offset.y)
    }

    // MARK: 刻度軸：x-610 y-65 w1400 h2660，圖片等比置中，原檔疊兩層

    @ViewBuilder
    private func ticks(_ box: FormlessWidgyBox) -> some View {
        if let asset = FormlessAsset.available("EventRuler") {
            ZStack {
                Image(asset).resizable().scaledToFit()
                Image(asset).resizable().scaledToFit()
            }
            .formlessPlaced(
                box, x: -610, y: -65, w: 1400, h: 2660,
                centered: true, shift: shift("ruler")
            )
        } else {
            drawnTicks(box)
        }
    }

    private func drawnTicks(_ box: FormlessWidgyBox) -> some View {
        let count = 70
        let pitch = box.height / CGFloat(count)
        let move = shift("ruler")

        return ZStack {
            ForEach(Array(0..<count), id: \.self) { index in
                let isMajor = index % 7 == 0

                Capsule()
                    .fill(Color.black.opacity(isMajor ? 0.20 : 0.10))
                    .frame(
                        width: box.w(isMajor ? 36 : 20),
                        height: max(1, box.h(5))
                    )
                    .position(
                        x: box.x(90) + box.width * move.x,
                        y: pitch * (CGFloat(index) + 0.5) + box.height * move.y
                    )
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    // MARK: 底部漸淡：x0 y500 w1600 h1100

    private func fade(_ box: FormlessWidgyBox) -> some View {
        LinearGradient(
            stops: [
                .init(color: backdrop.opacity(0), location: 0),
                .init(color: backdrop.opacity(0), location: 0.5),
                .init(color: backdrop, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .formlessPlaced(box, x: 0, y: 500, w: 1600, h: 1100)
        .allowsHitTesting(false)
    }

    // MARK: 標題：x176 y103 w1130 字級63；事件數：x175 y190 w557 字級142

    private func header(_ box: FormlessWidgyBox) -> some View {
        ZStack(alignment: .topLeading) {
            Text(layer.value ?? "Today's Events")
                .font(.system(size: box.font(63), weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 176, y: 103, w: 1130, h: 63, shift: shift("title"))

            Text("\(live.todayEventCount)")
                .font(.system(size: box.font(142), weight: .bold))
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 175, y: 190, w: 557, h: 142, shift: shift("count"))
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func cards(_ box: FormlessWidgyBox) -> some View {
        let items = visibleEvents
        let move = shift("cards")

        return ZStack(alignment: .topLeading) {
            if items.isEmpty {
                Text("今天沒有行程")
                    .font(.system(size: box.font(78), weight: .medium))
                    .foregroundStyle(titleColor)
                    .position(x: box.x(800), y: box.y(800))
            }

            ForEach(Array(items.indices), id: \.self) { index in
                if index < Self.cardY.count {
                    eventCard(box, item: items[index], top: Self.cardY[index], shift: move)
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func eventCard(
        _ box: FormlessWidgyBox,
        item: FormlessEventItem,
        top: CGFloat,
        shift move: CGPoint
    ) -> some View {

        let calendarColor = Color(formlessHex: item.calendarColorHex)

        return ZStack(alignment: .topLeading) {

            // 卡片：圓角 15%（短邊 225）、陰影 label 3% 半徑10 位移10
            RoundedRectangle(
                cornerRadius: box.radius(15, width: Self.cardW, height: Self.cardH),
                style: .continuous
            )
            .fill(cardColor)
            .shadow(
                color: Color.primary.opacity(0.03),
                radius: box.w(10) / 2,
                x: 0,
                y: box.h(10) / 2
            )
            .formlessPlaced(
                box, x: Self.cardX, y: top, w: Self.cardW, h: Self.cardH, shift: move
            )

            // 標題：x237 y+42 w1053 字級78 System Medium 靠左
            Text(item.title)
                .font(.system(size: box.font(78), weight: .medium))
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 237, y: top + 42, w: 1053, h: 78, shift: move)

            // 分類色點：x238 y+145 w31 h30
            Circle()
                .fill(calendarColor)
                .formlessPlaced(box, x: 238, y: top + 145, w: 31, h: 30, shift: move)

            // 分類名稱：x287 y+131 w953 字級57 System Medium 靠左
            Text(item.calendarName)
                .font(.system(size: box.font(57), weight: .medium))
                .foregroundStyle(calendarColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 287, y: top + 131, w: 953, h: 57, shift: move)

            // 開始：x1198 y+41 w273 字級48 靠右
            Text(item.dateText)
                .font(.system(size: box.font(48), weight: .medium))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .formlessPlaced(box, x: 1198, y: top + 41, w: 273, h: 48, shift: move)

            // 結束：x1198 y+140 w273 字級48 靠右
            Text(item.timeText)
                .font(.system(size: box.font(48), weight: .medium))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .formlessPlaced(box, x: 1198, y: top + 140, w: 273, h: 48, shift: move)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }
}


// MARK: - 步數

struct FormlessStepsView: View {

    let layer: FormlessLayer
    let size: CGSize
    let live: FormlessLiveData

    private var accent: Color {
        Color(formlessHex: layer.colorHex, fallback: "#9DE14E")
    }

    private var circleColor: Color {
        Color(formlessHex: layer.panelColorHex, fallback: "#EEF8DF")
    }

    private var numberColor: Color {
        Color(formlessHex: layer.textColorHex, fallback: "#000000")
    }

    private var labelColor: Color {
        Color(formlessHex: layer.secondaryColorHex, fallback: "#808495")
    }


    private func shifted(
        _ box: FormlessComponentBox,
        _ part: String,
        x: CGFloat,
        y: CGFloat
    ) -> CGPoint {
        let offset = layer.offset(part)

        return CGPoint(
            x: x + box.width * offset.x,
            y: y + box.height * offset.y
        )
    }

    private var stepsText: String {
        guard let steps = live.steps else { return "－" }

        return formlessStepsText(steps)
    }

    var body: some View {
        let box = FormlessWidgyBox(size)

        ZStack(alignment: .topLeading) {

            // 圓：x500 y184 w600 h600，watch_Green 15%
            Circle()
                .fill(circleColor)
                .formlessPlaced(
                    box, x: 500, y: 184, w: 600, h: 600,
                    centered: true, shift: partShift("icon")
                )

            // 圖示：x508 y340 w588 h300，figure.walk，watch_Green
            Image(systemName: "figure.walk")
                .resizable()
                .scaledToFit()
                .foregroundStyle(accent)
                .formlessPlaced(
                    box, x: 508, y: 340, w: 588, h: 300,
                    centered: true, shift: partShift("icon")
                )

            // 步數：x200 y898 w1200 字級334 System Bold 置中
            Text(stepsText)
                .font(.system(size: box.font(334), weight: .bold))
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .formlessPlaced(
                    box, x: 200, y: 898, w: 1200, h: 334,
                    centered: true, shift: partShift("count")
                )

            // 說明：x200 y1240 w1200 字級162 System Semi Bold #808495 置中
            Text(layer.value ?? "步數")
                .font(.system(size: box.font(162), weight: .semibold))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .formlessPlaced(
                    box, x: 200, y: 1240, w: 1200, h: 162,
                    centered: true, shift: partShift("label")
                )
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func partShift(_ part: String) -> CGPoint {
        let offset = layer.offset(part)
        return CGPoint(x: offset.x, y: offset.y)
    }
}


// MARK: - 天氣

struct FormlessWeatherView: View {

    let layer: FormlessLayer
    let size: CGSize
    let date: Date
    let live: FormlessLiveData

    // Widgy 原檔數值：卡片 x、卡片 y762 寬251 高674、圓角 24%
    private static let cardX: [CGFloat] = [90, 382, 673, 967, 1260]
    private static let cardY: CGFloat = 762
    private static let cardW: CGFloat = 251
    private static let cardH: CGFloat = 674

    private var mainColor: Color {
        Color(formlessHex: layer.colorHex, fallback: "#000000")
    }

    private var secondaryColor: Color {
        Color(formlessHex: layer.secondaryColorHex, fallback: "#808495")
    }

    private var cardColor: Color {
        Color(formlessHex: layer.panelColorHex, fallback: "#FFFFFF")
    }

    private var placeName: String {
        if let name = layer.locationName, !name.isEmpty { return name }
        if let name = live.weather?.locationName, !name.isEmpty { return name }
        return "－"
    }

    var body: some View {
        let box = FormlessWidgyBox(size)

        ZStack(alignment: .topLeading) {
            head(box)
            forecast(box)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func shift(_ part: String) -> CGPoint {
        let offset = layer.offset(part)
        return CGPoint(x: offset.x, y: offset.y)
    }

    private var temperatureText: Text {
        let value = Text(live.weather?.temperatureText ?? "－")
            .foregroundColor(mainColor)

        let degree = Text("°").foregroundColor(secondaryColor)

        return Text("\(value)\(degree)")
    }

    private func head(_ box: FormlessWidgyBox) -> some View {
        ZStack(alignment: .topLeading) {

            // 地區：x96 y160 w1284 字級182 System Semi Bold #808495 靠左
            Text(placeName)
                .font(.system(size: box.font(182), weight: .semibold))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 96, y: 160, w: 1284, h: 182, shift: shift("place"))

            // 狀態：x96 y364 w1284 字級216 System Semi Bold label 靠左
            Text(live.weather?.conditionText ?? "－")
                .font(.system(size: box.font(216), weight: .semibold))
                .foregroundStyle(mainColor)
                .lineLimit(1)
                .formlessPlaced(box, x: 96, y: 364, w: 1284, h: 216, shift: shift("condition"))

            // 溫度：x1226 y168 w345 字級436 System Bold，度數符號 #808495
            temperatureText
            .font(.system(size: box.font(436), weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .formlessPlaced(box, x: 1226, y: 168, w: 345, h: 436, shift: shift("now"))

            // 天氣圖示：x997 y90 w230 h560
            FormlessConditionIcon(
                code: live.weather?.code ?? 3,
                isDay: live.weather?.isDaylight(at: date) ?? true,
                width: box.w(230),
                height: box.h(560)
            )
            .formlessPlaced(box, x: 997, y: 90, w: 230, h: 560, centered: true, shift: shift("icon"))
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func forecast(_ box: FormlessWidgyBox) -> some View {
        let days = Array((live.weather?.days ?? []).dropFirst().prefix(5))
        let move = shift("forecast")

        return ZStack(alignment: .topLeading) {
            ForEach(Array(Self.cardX.indices), id: \.self) { index in
                if index < days.count {
                    card(box, index: index, day: days[index], shift: move)
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func card(
        _ box: FormlessWidgyBox,
        index: Int,
        day: FormlessWeatherDay,
        shift move: CGPoint
    ) -> some View {

        let left = Self.cardX[index]

        return ZStack(alignment: .topLeading) {

            // 卡片：圓角 24%、外框 label 6% 1、陰影 label 5% 半徑25 位移15
            RoundedRectangle(
                cornerRadius: box.radius(24, width: Self.cardW, height: Self.cardH),
                style: .continuous
            )
            .fill(cardColor)
            .overlay(
                RoundedRectangle(
                    cornerRadius: box.radius(24, width: Self.cardW, height: Self.cardH),
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.06), lineWidth: max(box.w(1), 0.5))
            )
            .shadow(
                color: Color.primary.opacity(0.05),
                radius: box.w(25) / 2,
                x: 0,
                y: box.h(15) / 2
            )
            .formlessPlaced(
                box, x: left, y: Self.cardY, w: Self.cardW, h: Self.cardH, shift: move
            )

            // 星期：x+10 y822 w230 字級140 System Medium #808495 置中
            Text(formlessFormatted("EEE", date: day.date))
                .font(.system(size: box.font(140), weight: .medium))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .formlessPlaced(
                    box, x: left + 10, y: 822, w: 230, h: 140,
                    centered: true, shift: move
                )

            // 圖示：x+63 y806 w126 h580
            FormlessConditionIcon(
                code: day.displayCode,
                isDay: day.displayIsDay,
                width: box.w(126),
                height: box.h(580)
            )
            .formlessPlaced(
                box, x: left + 63, y: 806, w: 126, h: 580,
                centered: true, shift: move
            )

            // 溫度：x+10 y1244 w230 字級140 System Medium #808495 置中
            Text("\(Int(day.displayTemperature.rounded()))")
                .font(.system(size: box.font(140), weight: .medium))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
                .formlessPlaced(
                    box, x: left + 10, y: 1244, w: 230, h: 140,
                    centered: true, shift: move
                )
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }
}


/// 天氣圖示：用尺寸框控制大小，並加上柔和陰影，白色雲朵在白底上才看得見
struct FormlessWeatherIcon: View {

    @State private var availableAsset: String?

    let name: String
    var assetName: String? = nil
    var customName: String? = nil
    let width: CGFloat
    let height: CGFloat

    /// 需要當下就畫好的時候（桌面小工具、編輯器量選取框、首頁縮圖）直接查；原本只看是不是小工具，
    /// 量選取框與縮圖時查不到圖片，畫成備用的系統圖示加一圈陰影，選取框比畫布上的圖大一大圈（使用者回報）。
    private var customImage: String? {
        FormlessRenderContext.loadsAssetsNow ? FormlessAsset.available(assetName) : availableAsset
    }

    var body: some View {
        FormlessLoadedAsset(name: customName) { pickedImage in
            #if canImport(UIKit)
            if let pickedImage {
                Image(uiImage: pickedImage)
                    .resizable()
                    .scaledToFit()
            } else if let customImage {
                Image(customImage)
                    .resizable()
                    .scaledToFit()
            } else {
                symbolImage
            }
            #else
            if let customImage {
                Image(customImage)
                    .resizable()
                    .scaledToFit()
            } else {
                symbolImage
            }
            #endif
        }
        .frame(width: width, height: height)
        .task(id: assetName) {
            guard !FormlessRenderContext.loadsAssetsNow else { return }
            let name = assetName
            availableAsset = await Task.detached { FormlessAsset.available(name) }.value
        }
    }

    private var symbolImage: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.multicolor)
            .shadow(
                color: Color.black.opacity(0.22),
                radius: height * 0.10,
                x: 0,
                y: height * 0.04
            )
    }
}


// MARK: - 提醒事項

struct FormlessReminderItem: Codable, Hashable, Identifiable, Sendable {

    var id: String
    var title: String
    var listName: String
    var colorHex: String
    var dueDate: Date?
    var isDueTodayOrOverdue: Bool
    /// 到期日有沒有具體時間（`dueDateComponents` 有 hour）；false 是只有日期。舊快取沒有這個欄位（nil）。
    var hasDueTime: Bool? = nil
}


// MARK: - 提醒事項讀取範圍

/// 全域設定，App 與桌面小工具共用。預設只讀今天。
enum FormlessReminderRange: String, CaseIterable, Identifiable, Codable, Sendable {
    case today
    case threeDays
    case week
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "今天"
        case .threeDays: return "三天內"
        case .week: return "一週內"
        case .all: return "全部未完成"
        }
    }

    /// 從今天 0 點起算的天數；nil 表示不限日期，含沒有到期日的提醒
    var days: Int? {
        switch self {
        case .today: return 1
        case .threeDays: return 3
        case .week: return 7
        case .all: return nil
        }
    }
}

struct FormlessReminderSettings: Codable, Sendable {

    static let cacheName = "reminder-settings.json"

    var range: FormlessReminderRange = .today

    nonisolated static func current() -> FormlessReminderSettings {
        FormlessCache.load(FormlessReminderSettings.self, name: cacheName) ?? FormlessReminderSettings()
    }

    nonisolated static func save(_ settings: FormlessReminderSettings) {
        FormlessCache.save(settings, name: cacheName)
    }
}


enum FormlessRemindersProvider {

    static let cacheName = "reminders.json"

    nonisolated static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    @discardableResult
    @MainActor
    static func requestAccess() async -> Bool {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else { return isAuthorized }
        let store = EKEventStore()
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// 依「設定 → 提醒事項範圍」取未完成提醒。範圍從今天 0 點起算，
    /// 到期日已過的不算。沒有到期日的只在「全部未完成」出現。
    nonisolated static func fetch(limit: Int = 8) async -> [FormlessReminderItem]? {
        guard isAuthorized else { return nil }

        let store = EKEventStore()

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()

        let range = FormlessReminderSettings.current().range
        let ending: Date? = range.days.flatMap { calendar.date(byAdding: .day, value: $0, to: startOfToday) }

        // 一律抓全部未完成，範圍自己篩。EventKit 的起訖參數對「只有日期沒有時間」
        // 或帶不同時區的提醒行為不一致，交給它過濾會漏掉當天的項目。
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )

        let reminders: [EKReminder]? = await withCheckedContinuation { continuation in
            let completion = FormlessOneShot<[EKReminder]?> { continuation.resume(returning: $0) }
            let token = store.fetchReminders(matching: predicate) { result in
                completion.resolve(result)
            }
            let cancellation = FormlessOneShot<Void> { _ in store.cancelFetchRequest(token) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                if completion.resolve(nil) { cancellation.resolve(()) }
            }
        }
        guard let reminders else { return nil }

        let items: [FormlessReminderItem] = reminders.map { reminder in
            let due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }

            return FormlessReminderItem(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "（無標題）",
                listName: reminder.calendar?.title ?? "",
                colorHex: FormlessRemindersProvider.hex(from: reminder.calendar),
                dueDate: due,
                isDueTodayOrOverdue: due.map { $0 < endOfToday } ?? false,
                hasDueTime: due == nil ? nil : reminder.dueDateComponents?.hour != nil
            )
        }

        let inRange = items.filter { item in
            guard range != .all else { return true }
            guard let due = item.dueDate else { return false }
            guard let ending else { return true }
            return due >= startOfToday && due < ending
        }

        let sorted = inRange.sorted { left, right in
            switch (left.dueDate, right.dueDate) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.title < right.title
            }
        }

        // 和行程相同：除了前 limit 筆撐過時間軸的，排在前面的（時間已過、會在時間軸內到期的）也一起存，
        // 照常顯示時和原本相同，篩掉時時間軸最後一格也仍有 limit 筆。
        let now = Date()
        let horizon = now.addingTimeInterval(FormlessLiveTime.fetchHorizon)
        var result: [FormlessReminderItem] = []
        var lasting = 0
        for item in sorted {
            let until = FormlessLiveTime.visibleUntil(item)
            result.append(item)
            if until.map({ $0 > horizon }) ?? true { lasting += 1 }
            if lasting >= limit { break }
        }
        return result
    }

    /// 今日提醒數：時間 date 時仍會顯示、而且是那一天到期的提醒。
    nonisolated static func todayCount(in items: [FormlessReminderItem], at date: Date = Date()) -> Int {
        let calendar = FormlessLiveTime.calendar
        return items.filter { item in
            guard let due = item.dueDate else { return false }
            return FormlessLiveTime.isVisible(item, at: date) && calendar.isDate(due, inSameDayAs: date)
        }.count
    }

    nonisolated private static func hex(from calendar: EKCalendar?) -> String {
        #if canImport(UIKit)
        guard let cgColor = calendar?.cgColor else { return "#EB5545" }
        return Color(uiColor: UIColor(cgColor: cgColor)).formlessHex
        #else
        return "#EB5545"
        #endif
    }
}


struct FormlessRemindersView: View {

    let layer: FormlessLayer
    let size: CGSize
    let live: FormlessLiveData

    private var titleColor: Color {
        Color(formlessHex: layer.secondaryColorHex, fallback: "#757575")
    }

    private var itemColor: Color {
        Color(formlessHex: layer.textColorHex, fallback: "#424242")
    }

    /// 最多三筆，與桌面上的版本一致
    private var items: [FormlessReminderItem] {
        let limit = min(max(1, layer.maxItems ?? 3), 3)
        return Array(live.reminders.prefix(limit))
    }

    private func partShift(_ part: String) -> CGPoint {
        let offset = layer.offset(part)
        return CGPoint(x: offset.x, y: offset.y)
    }

    var body: some View {
        let box = FormlessWidgyBox(size)

        ZStack(alignment: .topLeading) {
            background(box)
            icon(box)
            title(box)
            rows(box)
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .clipped()
    }

    // 外框：Widgy 原檔為整幅 1600×1600 的圖片
    @ViewBuilder
    private func background(_ box: FormlessWidgyBox) -> some View {
        if layer.showsPanel ?? true {
            Image("ReminderBackground")
                .resizable()
                .scaledToFill()
                .formlessPlaced(box, x: 0, y: 0, w: 1600, h: 1600, centered: true)
        }
    }

    private func icon(_ box: FormlessWidgyBox) -> some View {
        Image("ReminderIcon")
            .resizable()
            .scaledToFit()
            .formlessPlaced(
                box, x: 144, y: 140, w: 432, h: 432,
                centered: true, shift: partShift("icon")
            )
    }

    // 標題：依截圖量測
    private func title(_ box: FormlessWidgyBox) -> some View {
        Text(layer.value ?? "Reminders")
            .font(.system(size: box.font(132), weight: .semibold))
            .foregroundStyle(titleColor)
            .lineLimit(1)
            .formlessPlaced(box, x: 604, y: 301, w: 854, h: 132, shift: partShift("title"))
    }

    // 清單：Widgy 原檔 圓點 x226 w62 h63、文字 x360 w1034 字級141、每列間距 280
    private func rows(_ box: FormlessWidgyBox) -> some View {
        let list = items
        let move = partShift("list")

        return ZStack(alignment: .topLeading) {
            ForEach(Array(list.indices), id: \.self) { index in
                let top = 666 + 280 * CGFloat(index)

                Circle()
                    .fill(Color(formlessHex: list[index].colorHex))
                    .formlessPlaced(
                        box, x: 226, y: top + 40, w: 62, h: 63,
                        centered: true, shift: move
                    )

                Text(list[index].title)
                    .font(.system(size: box.font(141), weight: .medium))
                    .foregroundStyle(itemColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .formlessPlaced(box, x: 360, y: top, w: 1034, h: 141, shift: move)
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }
}



// MARK: - 即時文字來源

enum FormlessLiveSource: String, CaseIterable, Identifiable, Sendable {
    case eventCount
    case reminderCount
    case steps
    case yearPercent
    case weatherTemp
    case weatherPlace
    case weatherCondition

    // 以下需要搭配圖層的 dataIndex 指定第幾筆
    case eventTitle
    case eventSource
    case eventDate
    case eventTime
    case eventLocation
    case reminderTitle
    case forecastName
    case forecastTemp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eventCount: return "今日事件數"
        case .reminderCount: return "今日提醒數"
        case .steps: return "步數"
        case .yearPercent: return "年度百分比"
        case .weatherTemp: return "目前溫度"
        case .weatherPlace: return "地區"
        case .weatherCondition: return "天氣狀態"
        case .eventTitle: return "事件標題"
        case .eventSource: return "事件分類"
        case .eventDate: return "事件日期"
        case .eventTime: return "事件時間"
        case .eventLocation: return "行程地點"
        case .reminderTitle: return "提醒標題"
        case .forecastName: return "預報星期"
        case .forecastTemp: return "預報溫度"
        }
    }

    /// 需要哪一種即時資料
    var need: String {
        switch self {
        case .eventCount, .eventTitle, .eventSource, .eventDate, .eventTime, .eventLocation:
            return "events"

        case .reminderCount, .reminderTitle:
            return "reminders"

        case .steps:
            return "steps"

        case .weatherTemp, .weatherPlace, .weatherCondition, .forecastName, .forecastTemp:
            return "weather"

        case .yearPercent:
            return ""
        }
    }

    func text(live: FormlessLiveData, date: Date, dataIndex: String? = nil) -> String {
        switch self {
        case .eventCount:
            return "\(live.todayEventCount)"

        case .reminderCount:
            return "\(live.todayReminderCount)"

        case .steps:
            guard let steps = live.steps else { return "－" }

            return formlessStepsText(steps)

        case .yearPercent:
            return "\(FormlessYearMath.percent(for: date))"

        case .weatherTemp:
            return live.weather?.temperatureText ?? "－"

        case .weatherPlace:
            return live.weather?.locationName ?? "－"

        case .weatherCondition:
            return live.weather?.conditionText ?? "－"

        case .eventTitle:
            return FormlessDataBinding.event(dataIndex, live: live)?.title ?? ""

        case .eventSource:
            return FormlessDataBinding.event(dataIndex, live: live)?.calendarName ?? ""

        case .eventDate:
            return FormlessDataBinding.event(dataIndex, live: live)?.dateText ?? ""

        case .eventTime:
            return FormlessDataBinding.event(dataIndex, live: live)?.timeText ?? ""

        case .eventLocation:
            guard let event = FormlessDataBinding.event(dataIndex, live: live) else { return "" }
            return live.eventLocations[event.id] ?? event.location ?? ""

        case .reminderTitle:
            return FormlessDataBinding.reminder(dataIndex, live: live)?.title ?? ""

        case .forecastName:
            guard let day = FormlessDataBinding.day(dataIndex, live: live) else { return "" }
            return formlessFormatted("EEE", date: day.date)

        case .forecastTemp:
            guard let day = FormlessDataBinding.day(dataIndex, live: live) else { return "" }
            return "\(Int(day.displayTemperature.rounded()))"
        }
    }
}


enum FormlessYearMath {

    static func progress(for date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")

        let year = calendar.component(.year, from: date)

        guard
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
            let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else {
            return 0
        }

        let total = end.timeIntervalSince(start)

        guard total > 0 else { return 0 }

        return max(0, min(1, date.timeIntervalSince(start) / total))
    }

    static func percent(for date: Date) -> Int {
        Int((progress(for: date) * 100).rounded())
    }
}


// MARK: - 圖示

/// 圖示的上色方式（SF Symbols 的渲染模式）。沒設定時和原本一樣是單色。
struct FormlessSymbolStyle: ViewModifier {
    let mode: String?
    let primary: Color
    let secondary: Color

    func body(content: Content) -> some View {
        switch mode {
        case "hierarchical"?: content.symbolRenderingMode(.hierarchical).foregroundStyle(primary)
        case "palette"?: content.symbolRenderingMode(.palette).foregroundStyle(primary, secondary)
        case "multicolor"?: content.symbolRenderingMode(.multicolor).foregroundStyle(primary)
        default: content.foregroundStyle(primary)
        }
    }

    static let options: [(value: String?, name: String)] = [
        (nil, "單色"), ("hierarchical", "階層"), ("palette", "調色盤"), ("multicolor", "多色")
    ]
}

struct FormlessSymbolView: View {

    let layer: FormlessLayer
    let size: CGSize
    let live: FormlessLiveData
    var date: Date = Date()

    private var name: String {
        let raw = layer.value ?? "star.fill"

        if raw == "auto:weather" {
            return live.weather?.symbolName ?? "cloud.fill"
        }

        return raw
    }

    private var isAuto: Bool {
        (layer.value ?? "") == "auto:weather"
    }

    var body: some View {
        Group {
            if isAuto, let day = FormlessDataBinding.day(layer.dataIndex, live: live) {
                FormlessConditionIcon(
                    code: day.displayCode,
                    isDay: day.displayIsDay,
                    width: size.width,
                    height: size.height
                )
            } else if isAuto {
                FormlessConditionIcon(
                    code: live.weather?.code ?? 3,
                    isDay: live.weather?.isDaylight(at: date) ?? true,
                    width: size.width,
                    height: size.height
                )
            } else {
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .modifier(FormlessSymbolStyle(mode: layer.symbolMode,
                                                  primary: Color(formlessHex: layer.resolvedColorHex(date: date, live: live), fallback: "#000000"),
                                                  secondary: Color(formlessHex: layer.secondaryColorHex, fallback: "#8E8E93")))
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}


// MARK: - 資源圖片輔助

enum FormlessAsset {

    /// 資源檔裡有這張圖才回傳名稱
    nonisolated static func available(_ name: String?) -> String? {
        #if canImport(UIKit)
        guard let name, !name.isEmpty else { return nil }
        return UIImage(named: name) == nil ? nil : name
        #else
        return nil
        #endif
    }
}


// MARK: - 刻度軸

struct FormlessRulerView: View {

    let layer: FormlessLayer
    let size: CGSize

    var body: some View {
        if let asset = FormlessAsset.available(layer.value ?? "EventRuler") {
            ZStack {
                Image(asset).resizable().scaledToFit()
                Image(asset).resizable().scaledToFit()
            }
            .frame(width: size.width, height: size.height)
        } else {
            drawnTicks
        }
    }

    private var drawnTicks: some View {
        let count = max(2, layer.maxItems ?? 70)
        let pitch = size.height / CGFloat(count)
        let color = Color(formlessHex: layer.colorHex, fallback: "#000000")
        let thickness = max(1, size.height * 0.0027 * 70 / CGFloat(count))

        return ZStack {
            ForEach(Array(0..<count), id: \.self) { index in
                let isMajor = index % 7 == 0

                Capsule()
                    .fill(color.opacity(isMajor ? 0.20 : 0.10))
                    .frame(
                        width: isMajor ? size.width : size.width * 0.56,
                        height: thickness
                    )
                    .position(
                        x: size.width / 2,
                        y: pitch * (CGFloat(index) + 0.5)
                    )
            }
        }
        .frame(width: size.width, height: size.height)
    }
}


// MARK: - 月曆格

struct FormlessCalendarGridView: View {

    let layer: FormlessLayer
    let size: CGSize
    let date: Date
    let scale: CGFloat
    var live: FormlessLiveData = FormlessLiveData()

    private var options: FormlessCalendarOptions { layer.calendarOptions ?? FormlessCalendarOptions() }

    private var month: FormlessCalendarMonth {
        FormlessCalendarMonth(
            date: date,
            mondayFirst: layer.weekStartsOnMonday ?? false,
            monthOffset: options.monthOffset ?? 0
        )
    }

    // 延伸設定（2026-10）都關閉時，排法和原本完全相同：週數欄寬度 0、日期不位移、沒有熱圖與週末顏色。
    var body: some View {
        let data = month
        let options = self.options
        let w = max(size.width, 1)
        let h = max(size.height, 1)

        let weekColumn = options.showsWeekNumbers == true
        let cell = w / (weekColumn ? 8 : 7)
        let lead: CGFloat = weekColumn ? cell : 0
        let headerCenter = h * 0.08
        let gridTop = h * 0.16
        let pitch = (h - gridTop) / CGFloat(max(data.rows, 1))

        let dayFont = max(1, (layer.fontSize ?? 10.2) * scale)
        let headFont = dayFont * 0.98

        let pillWidth = cell * 0.743
        let pillHeight = min(pitch * 0.67, dayFont * 1.28)

        let accent = Color(formlessHex: layer.colorHex, fallback: "#FF3B30")
        let secondary = Color(formlessHex: layer.secondaryColorHex, fallback: "#808495")
        let dayColor = Color(formlessHex: layer.textColorHex, fallback: "#000000")
        let weekendColor = options.weekendColorHex.map { Color(formlessHex: $0) }
        let lunar = options.showsLunar == true
        // 有農曆時日期往上移、農曆放在下面，兩行一起置中在那一格。
        let lunarFont = dayFont * 0.52
        let dayShift: CGFloat = lunar ? -lunarFont * 0.62 : 0
        let heat = heatValues(data)
        let mondayFirst = layer.weekStartsOnMonday ?? false

        ZStack {
            if layer.value != "days" {
            ForEach(0..<7, id: \.self) { index in
                Text(data.weekdaySymbols[index])
                    .font(.system(size: headFont, weight: .semibold))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .position(x: lead + cell * (CGFloat(index) + 0.5), y: headerCenter)
            }
            if weekColumn {
                Text("週")
                    .font(.system(size: headFont, weight: .semibold))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .position(x: cell * 0.5, y: headerCenter)
            }

            }
            if layer.value != "weekdays" {
            if weekColumn {
                ForEach(0..<data.rows, id: \.self) { row in
                    Text("\(weekNumber(data, row: row, mondayFirst: mondayFirst))")
                        .font(.system(size: dayFont * 0.8, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: cell * 0.5, y: gridTop + pitch * (CGFloat(row) + 0.5))
                }
            }
            ForEach(Array(0..<(data.rows * 7)), id: \.self) { index in
                let day = index - data.leadingBlanks + 1

                if day >= 1 && day <= data.numberOfDays {
                    let column = index % 7
                    let weekend = mondayFirst ? column >= 5 : (column == 0 || column == 6)
                    let center = CGPoint(x: lead + cell * (CGFloat(column) + 0.5),
                                         y: gridTop + pitch * (CGFloat(index / 7) + 0.5))
                    ZStack {
                        if day == data.today {
                            RoundedRectangle(
                                cornerRadius: pillHeight * 0.18,
                                style: .continuous
                            )
                            .fill(accent)
                            .frame(width: pillWidth, height: pillHeight)
                        } else if let level = heat[day] {
                            // 依資料上色：數量或數值越大越深。
                            RoundedRectangle(cornerRadius: pillHeight * 0.18, style: .continuous)
                                .fill(accent.opacity(0.14 + 0.66 * level))
                                .frame(width: pillWidth, height: pillHeight)
                        }

                        Text("\(day)")
                            .font(
                                .system(
                                    size: dayFont,
                                    weight: day == data.today
                                        ? .semibold
                                        : formlessFontWeight(layer.fontWeight)
                                )
                            )
                            // 今天與底色夠深（熱圖一半以上）的日子用白字，週末顏色疊在同色底上才看得清楚。
                            .foregroundStyle(day == data.today || (heat[day] ?? 0) >= 0.5
                                             ? Color.white : (weekend ? weekendColor ?? dayColor : dayColor))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(width: pillWidth, height: pillHeight)
                    .position(x: center.x, y: center.y + dayShift)

                    if lunar {
                        Text(lunarText(data, day: day))
                            .font(.system(size: lunarFont, weight: .medium))
                            .foregroundStyle(day == data.today ? accent : secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: center.x, y: center.y + dayShift + pillHeight / 2 + lunarFont * 0.62)
                    }
                }
            }
            }
        }
        .frame(width: w, height: h)
    }

    /// 那一列的週數（ISO 8601）：取那一列的星期一（週日開始時是第二格）。
    private func weekNumber(_ data: FormlessCalendarMonth, row: Int, mondayFirst: Bool) -> Int {
        let day = row * 7 + (mondayFirst ? 0 : 1) - data.leadingBlanks + 1
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = data.calendar.timeZone
        return iso.component(.weekOfYear, from: data.date(ofDay: day))
    }

    /// 農曆日：初一顯示月份（八月），節氣那天顯示節氣（寒露）。
    private func lunarText(_ data: FormlessCalendarMonth, day: Int) -> String {
        let when = data.date(ofDay: day)
        if let term = FormlessChineseCalendar.solarTerm(on: when, timeZone: data.calendar.timeZone) { return term }
        let parts = FormlessChineseCalendar.lunar(for: when, timeZone: data.calendar.timeZone)
        return parts.day == 1 ? FormlessChineseCalendar.monthName(parts.month, leap: parts.isLeapMonth)
            : FormlessChineseCalendar.dayName(parts.day)
    }

    /// 依資料上色：清單每一筆的日期（日期、開始、到期…）落在這個月的哪一天，那天加上筆數或欄位的數值；
    /// 回傳每一天佔最大值的比例（0～1）。
    private func heatValues(_ data: FormlessCalendarMonth) -> [Int: Double] {
        guard let binding = options.heatmap, case .list(let items) = live.value(binding, at: date) else { return [:] }
        var sums: [Int: Double] = [:]
        for item in items {
            guard let record = item.recordValue else { continue }
            let when = ["date", "start", "due", "time"].lazy.compactMap { record[$0].dateValue }.first
                ?? record.fields.keys.sorted().lazy.compactMap { record[$0].dateValue }.first
            guard let when, data.calendar.isDate(when, equalTo: data.firstOfMonth, toGranularity: .month) else { continue }
            let amount = options.heatmapField.map { record[$0].numberValue ?? 0 } ?? 1
            sums[data.calendar.component(.day, from: when), default: 0] += amount
        }
        guard let largest = sums.values.max(), largest > 0 else { return [:] }
        return sums.compactMapValues { $0 > 0 ? $0 / largest : nil }
    }
}


// MARK: - 事件清單

struct FormlessEventListView: View {

    let layer: FormlessLayer
    let size: CGSize
    let live: FormlessLiveData
    let scale: CGFloat

    var body: some View {
        let w = max(size.width, 1)
        let h = max(size.height, 1)

        let limit = min(max(1, layer.maxItems ?? 5), 5)
        let items = Array(live.events.prefix(limit))

        // Widgy 原檔：整框 1354×1301，卡片相對 y 0/269/540/806/1076、高 225
        let tops: [CGFloat] = [0, 269, 540, 806, 1076]
        let cardHeight = h * 225 / 1301

        let cardColor = Color(formlessHex: layer.panelColorHex, fallback: "#FFFFFF")
        let titleColor = Color(formlessHex: layer.colorHex, fallback: "#000000")
        let detailColor = Color(formlessHex: layer.textColorHex, fallback: "#808080")

        ZStack {
            ForEach(Array(items.indices), id: \.self) { index in
                FormlessEventCard(
                    item: items[index],
                    width: w,
                    height: cardHeight,
                    cardColor: cardColor,
                    titleColor: titleColor,
                    detailColor: detailColor
                )
                .position(
                    x: w / 2,
                    y: h * tops[min(index, tops.count - 1)] / 1301 + cardHeight / 2
                )
            }
        }
        .frame(width: w, height: h)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.80),
                    .init(color: .black.opacity(0.15), location: 0.96),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}


struct FormlessEventCard: View {

    let item: FormlessEventItem
    let width: CGFloat
    let height: CGFloat
    let cardColor: Color
    let titleColor: Color
    let detailColor: Color

    var body: some View {
        // Widgy 原檔（卡片 1354×225）
        let titleFont = height * 78 / 225 * 0.87
        let sourceFont = height * 57 / 225 * 0.87
        let timeFont = height * 48 / 225 * 0.87
        let dotSize = height * 30 / 225

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: height * 0.15, style: .continuous)
                .fill(cardColor)
                .frame(width: width, height: height)

            Text(item.title)
                .font(.system(size: titleFont, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(width: width * 1053 / 1354, height: height * 78 / 225, alignment: .leading)
                .position(
                    x: width * (59 + 1053 / 2) / 1354,
                    y: height * (42 + 78 / 2) / 225
                )

            Circle()
                .fill(Color(formlessHex: item.calendarColorHex))
                .frame(width: dotSize, height: dotSize)
                .position(
                    x: width * (60 + 15.5) / 1354,
                    y: height * (145 + 15) / 225
                )

            Text(item.calendarName)
                .font(.system(size: sourceFont, weight: .medium))
                .foregroundStyle(Color(formlessHex: item.calendarColorHex))
                .lineLimit(1)
                .frame(width: width * 953 / 1354, height: height * 57 / 225, alignment: .leading)
                .position(
                    x: width * (109 + 953 / 2) / 1354,
                    y: height * (131 + 57 / 2) / 225
                )

            Text(item.dateText)
                .font(.system(size: timeFont, weight: .medium))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .frame(width: width * 273 / 1354, height: height * 48 / 225, alignment: .trailing)
                .position(
                    x: width * (1020 + 273 / 2) / 1354,
                    y: height * (41 + 48 / 2) / 225
                )

            Text(item.timeText)
                .font(.system(size: timeFont, weight: .medium))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .frame(width: width * 273 / 1354, height: height * 48 / 225, alignment: .trailing)
                .position(
                    x: width * (1020 + 273 / 2) / 1354,
                    y: height * (140 + 48 / 2) / 225
                )
        }
        .frame(width: width, height: height)
    }
}


// MARK: - 提醒清單

struct FormlessReminderListView: View {

    let layer: FormlessLayer
    let size: CGSize
    let live: FormlessLiveData
    let scale: CGFloat

    var body: some View {
        let w = max(size.width, 1)
        let h = max(size.height, 1)

        let limit = min(max(1, layer.maxItems ?? 3), 3)
        let items = Array(live.reminders.prefix(limit))

        // Widgy 原檔：整框 1168×701，每列相對 y 0/280/560
        let pitch = h * 280 / 701
        let dot = w * 62 / 1168
        let textLeading = w * 134 / 1168
        let textWidth = w * 1034 / 1168
        let font = max(1, (layer.fontSize ?? 34) * scale)

        let titleColor = Color(formlessHex: layer.textColorHex, fallback: "#424242")

        ZStack {
            ForEach(Array(items.indices), id: \.self) { index in
                let centerY = pitch * CGFloat(index) + h * 70.5 / 701

                Circle()
                    .fill(Color(formlessHex: items[index].colorHex))
                    .frame(width: dot, height: dot)
                    .position(x: w * 31 / 1168, y: pitch * CGFloat(index) + h * 71.5 / 701)

                Text(items[index].title)
                    .font(.system(size: font, weight: .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth, alignment: .leading)
                    .position(x: textLeading + textWidth / 2, y: centerY)
            }
        }
        .frame(width: w, height: h)
    }
}


// MARK: - 天氣預報列

struct FormlessWeatherForecastView: View {

    let layer: FormlessLayer
    let size: CGSize
    let live: FormlessLiveData
    let scale: CGFloat

    var body: some View {
        let w = max(size.width, 1)
        let h = max(size.height, 1)

        let count = min(max(1, layer.maxItems ?? 5), 5)
        let days = Array((live.weather?.days ?? []).dropFirst().prefix(count))

        // Widgy 原檔：整框寬 1421，卡片相對 x 0/292/583/877/1170、寬 251
        let offsets: [CGFloat] = [0, 292, 583, 877, 1170]
        let cardWidth = w * 251 / 1421

        let cardColor = Color(formlessHex: layer.panelColorHex, fallback: "#FFFFFF")
        let textColor = Color(formlessHex: layer.secondaryColorHex, fallback: "#808495")
        let font = max(1, (layer.fontSize ?? 11.5) * scale)

        ZStack {
            ForEach(Array(days.indices), id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: cardWidth * 0.24, style: .continuous)
                        .fill(cardColor)

                    Text(formlessFormatted("EEE", date: days[index].date))
                        .font(.system(size: font, weight: .medium))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .position(x: cardWidth / 2, y: h * 130 / 674)

                    FormlessConditionIcon(
                        code: days[index].displayCode,
                        isDay: days[index].displayIsDay,
                        width: cardWidth * 126 / 251,
                        height: h * 580 / 674
                    )
                    .position(x: cardWidth / 2, y: h * 334 / 674)

                    Text("\(Int(days[index].displayTemperature.rounded()))")
                        .font(.system(size: font, weight: .medium))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .position(x: cardWidth / 2, y: h * 552 / 674)
                }
                .frame(width: cardWidth, height: h)
                .position(
                    x: w * offsets[min(index, offsets.count - 1)] / 1421 + cardWidth / 2,
                    y: h / 2
                )
            }
        }
        .frame(width: w, height: h)
    }
}


/// Widgy 原檔用的 ✦ 四角星
struct FormlessFourPointStar: Shape {

    var waist: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let centerY = rect.midY
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let handleX = radiusX * waist
        let handleY = radiusY * waist

        var path = Path()
        path.move(to: CGPoint(x: centerX, y: centerY - radiusY))
        path.addQuadCurve(
            to: CGPoint(x: centerX + radiusX, y: centerY),
            control: CGPoint(x: centerX + handleX, y: centerY - handleY)
        )
        path.addQuadCurve(
            to: CGPoint(x: centerX, y: centerY + radiusY),
            control: CGPoint(x: centerX + handleX, y: centerY + handleY)
        )
        path.addQuadCurve(
            to: CGPoint(x: centerX - radiusX, y: centerY),
            control: CGPoint(x: centerX - handleX, y: centerY + handleY)
        )
        path.addQuadCurve(
            to: CGPoint(x: centerX, y: centerY - radiusY),
            control: CGPoint(x: centerX - handleX, y: centerY - handleY)
        )
        path.closeSubpath()
        return path
    }
}


// MARK: - 拆解成圖層

extension FormlessTemplate {

    /// 進階元件是否可以拆解
    static func canExplode(_ type: FormlessLayerType) -> Bool {
        switch type {
        case .calendar, .events, .reminders, .weather, .steps, .yearProgress:
            return true
        default:
            return false
        }
    }

    /// 把一個進階元件拆成可以各自搬動的獨立圖層
    private static func rawParts(
        _ layer: FormlessLayer,
        family: FormlessWidgetFamily
    ) -> [FormlessLayer] {

        var base = layer.frame
        if layer.type == .calendar && !(layer.showsPanel ?? true) {
            let aspect = Double(family.aspectRatio)
            let height = min(base.height, base.width * aspect / 1.25)
            let width = height * 1.25 / aspect
            base.x += (base.width - width) / 2
            base.y += (base.height - height) / 2
            base.width = width
            base.height = height
        }
        let refHeight = Double(family.referenceHeight)

        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> FormlessFrame {
            FormlessFrame(
                x: base.x + x * base.width,
                y: base.y + y * base.height,
                width: w * base.width,
                height: h * base.height
            )
        }

        func size(_ ratio: Double) -> Double {
            (ratio * refHeight * base.height).rounded()
        }

        let refWidth = Double(family.referenceWidth)

        /// Widgy 1600 座標 → 文件上的 0–1 比例
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> FormlessFrame {
            FormlessFrame(
                x: base.x + x / 1600 * base.width,
                y: base.y + y / 1600 * base.height,
                width: w / 1600 * base.width,
                height: h / 1600 * base.height
            )
        }

        /// Widgy 的 e 是行高，實際字級為 0.87 倍
        func font(_ lineHeight: Double) -> Double {
            lineHeight * 0.87 / 1600 * refHeight * base.height
        }

        /// 1600 單位換成參考尺寸下的點數
        func lenW(_ units: Double) -> Double { units / 1600 * refWidth * base.width }
        func lenH(_ units: Double) -> Double { units / 1600 * refHeight * base.height }

        /// Widgy 的圓角是短邊的百分比
        func corner(_ percent: Double, _ w: Double, _ h: Double) -> Double {
            min(lenW(w), lenH(h)) * percent / 100
        }

        switch layer.type {

        case .calendar:
            var parts: [FormlessLayer] = []

            if layer.showsPanel ?? true {
                parts.append(
                    FormlessLayer(
                        name: "左側面板",
                        type: .shape,
                        frame: frame(0.01875, 0.0375, 0.435, 0.925),
                        colorHex: layer.panelColorHex ?? "#E6E6E8",
                        cornerRadius: min(base.width * Double(family.aspectRatio) * refHeight * 0.435, base.height * refHeight * 0.925) * min(max(layer.cornerRadius ?? 11, 0), 50) / 100
                    )
                )

                parts.append(
                    FormlessLayer(
                        name: "星期",
                        type: .date,
                        frame: frame(0.01875, 0.15125, 0.43125, 0.13625),
                        value: "EEEE",
                        colorHex: layer.colorHex ?? "#FF3B30",
                        fontSize: size(0.11854),
                        fontWeight: "bold",
                        alignment: "center"
                    )
                )

                parts.append(
                    FormlessLayer(
                        name: "大日期",
                        type: .date,
                        frame: frame(0.01875, 0.2375, 0.43312, 0.725),
                        value: "d",
                        colorHex: layer.textColorHex ?? "#000000",
                        fontSize: size(0.63075),
                        fontWeight: "bold",
                        alignment: "center"
                    )
                )
            }

            parts.append(
                FormlessLayer(
                    name: "月份標題",
                    type: .date,
                    frame: frame((layer.showsPanel ?? true) ? 0.50375 : 0.06, 0.07375, (layer.showsPanel ?? true) ? 0.43125 : 0.94, 0.09375),
                    value: "M月",
                    colorHex: layer.secondaryColorHex ?? "#808495",
                    fontSize: size(0.08156),
                    fontWeight: "bold",
                    alignment: "leading"
                )
            )

            parts.append(
                FormlessLayer(
                    name: "月曆格",
                    type: .calendarGrid,
                    frame: frame((layer.showsPanel ?? true) ? 0.485 : 0.05, 0.2025, (layer.showsPanel ?? true) ? 0.46625 : 0.9, 0.7425),
                    colorHex: layer.colorHex ?? "#FF3B30",
                    fontSize: size(0.0644),
                    fontWeight: layer.fontWeight ?? "medium",
                    secondaryColorHex: layer.secondaryColorHex ?? "#808495",
                    textColorHex: layer.textColorHex ?? "#000000",
                    weekStartsOnMonday: layer.weekStartsOnMonday
                )
            )

            return parts

        case .events:
            var parts: [FormlessLayer] = []

            let cardTops: [Double] = [391, 660, 931, 1197, 1467]
            let cardLimit = min(max(1, layer.maxItems ?? 5), 5)
            let cardFill = layer.panelColorHex ?? "#FFFFFF"
            let eventTitleColor = layer.colorHex ?? "#000000"
            let eventDetailColor = layer.textColorHex ?? "#808080"
            let headerColor = layer.secondaryColorHex ?? "#808080"

            // 沒有行程時才出現，位置與原本置中於 800, 800 相同
            parts.append(
                FormlessLayer(
                    name: "無行程提示",
                    type: .text,
                    frame: box(0, 761, 1600, 78),
                    value: "今天沒有行程",
                    colorHex: headerColor,
                    fontSize: font(78),
                    fontWeight: "medium",
                    alignment: "center",
                    dataIndex: "event0"
                )
            )

            for number in 1...cardLimit {
                let top = cardTops[number - 1]
                let tag = "event\(number)"

                // 卡片：圓角 15%（短邊 225）、陰影 label 3% 半徑10 位移10
                parts.append(
                    FormlessLayer(
                        name: "事件 \(number) 卡片",
                        type: .shape,
                        frame: box(178, top, 1354, 225),
                        colorHex: cardFill,
                        cornerRadius: corner(15, 1354, 225),
                        dataIndex: tag,
                        shadowColorHex: "#00000008",
                        shadowRadius: lenW(10) / 2,
                        shadowOffsetY: lenH(10) / 2
                    )
                )

                // 標題：x237 y+42 w1053 字級78 System Medium 靠左
                parts.append(
                    FormlessLayer(
                        name: "事件 \(number) 標題",
                        type: .liveText,
                        frame: box(237, top + 42, 1053, 78),
                        value: FormlessLiveSource.eventTitle.rawValue,
                        colorHex: eventTitleColor,
                        fontSize: font(78),
                        fontWeight: "medium",
                        alignment: "leading",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )

                // 分類色點：x238 y+145 w31 h30
                parts.append(
                    FormlessLayer(
                        name: "事件 \(number) 色點",
                        type: .shape,
                        frame: box(238, top + 145, 31, 30),
                        colorHex: "auto",
                        cornerRadius: corner(50, 31, 30),
                        dataIndex: tag
                    )
                )

                // 分類名稱：x287 y+131 w953 字級57 System Medium 靠左
                parts.append(
                    FormlessLayer(
                        name: "事件 \(number) 分類",
                        type: .liveText,
                        frame: box(287, top + 131, 953, 57),
                        value: FormlessLiveSource.eventSource.rawValue,
                        colorHex: "auto",
                        fontSize: font(57),
                        fontWeight: "medium",
                        alignment: "leading",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )

                // 開始：x1198 y+41 w273 字級48 靠右
                parts.append(
                    FormlessLayer(
                        name: "事件 \(number) 日期",
                        type: .liveText,
                        frame: box(1198, top + 41, 273, 48),
                        value: FormlessLiveSource.eventDate.rawValue,
                        colorHex: eventDetailColor,
                        fontSize: font(48),
                        fontWeight: "medium",
                        alignment: "trailing",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )

                // 結束：x1198 y+140 w273 字級48 靠右
                parts.append(
                    FormlessLayer(
                        name: "事件 \(number) 時間",
                        type: .liveText,
                        frame: box(1198, top + 140, 273, 48),
                        value: FormlessLiveSource.eventTime.rawValue,
                        colorHex: eventDetailColor,
                        fontSize: font(48),
                        fontWeight: "medium",
                        alignment: "trailing",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )
            }

            // 底部漸淡：x0 y500 w1600 h1100，蓋在卡片之上
            parts.append(FormlessLayer.fade(name: "底部漸淡", frame: box(0, 500, 1600, 1100), colorHex: "#F9F8F9"))

            // 刻度軸：x-610 y-65 w1400 h2660，原檔疊兩層
            for number in 1...2 {
                parts.append(
                    FormlessLayer(
                        name: "刻度軸 \(number)",
                        type: .bundleImage,
                        frame: box(-610, -65, 1400, 2660),
                        value: "EventRuler"
                    )
                )
            }

            // 標題：x176 y103 w1130 字級63
            parts.append(
                FormlessLayer(
                    name: "標題",
                    type: .text,
                    frame: box(176, 103, 1130, 63),
                    value: layer.value ?? "Today's Events",
                    colorHex: headerColor,
                    fontSize: font(63),
                    fontWeight: "semibold",
                    alignment: "leading",
                    autoShrink: false
                )
            )

            // 事件數：x175 y190 w557 字級142
            parts.append(
                FormlessLayer(
                    name: "事件數",
                    type: .liveText,
                    frame: box(175, 190, 557, 142),
                    value: FormlessLiveSource.eventCount.rawValue,
                    colorHex: layer.colorHex ?? "#000000",
                    fontSize: font(142),
                    fontWeight: "bold",
                    alignment: "leading",
                    autoShrink: false
                )
            )

            return parts

        case .reminders:
            var parts: [FormlessLayer] = []

            let reminderLimit = min(max(1, layer.maxItems ?? 3), 3)

            // 外框：Widgy 原檔為整幅 1600×1600 的圖片
            if layer.showsPanel ?? true {
                parts.append(
                    FormlessLayer(
                        name: "外框背景",
                        type: .bundleImage,
                        frame: box(0, 0, 1600, 1600),
                        value: "ReminderBackground"
                    )
                )
            }

            // 圖示：x144 y140 w432 h432（依截圖量測）
            parts.append(
                FormlessLayer(
                    name: "圖示",
                    type: .bundleImage,
                    frame: box(144, 140, 432, 432),
                    value: "ReminderIcon"
                )
            )

            // 標題：x604 y301 w854 字級132（依截圖量測）
            parts.append(
                FormlessLayer(
                    name: "標題",
                    type: .text,
                    frame: box(604, 301, 854, 132),
                    value: layer.value ?? "Reminders",
                    colorHex: layer.secondaryColorHex ?? "#757575",
                    fontSize: font(132),
                    fontWeight: "semibold",
                    alignment: "leading",
                    autoShrink: false
                )
            )

            // 清單：圓點 x226 w62 h63、文字 x360 w1034 字級141、每列間距 280
            for number in 1...reminderLimit {
                let top = 666 + 280 * Double(number - 1)
                let tag = "reminder\(number)"

                parts.append(
                    FormlessLayer(
                        name: "提醒 \(number) 色點",
                        type: .shape,
                        frame: box(226, top + 40, 62, 63),
                        colorHex: "auto",
                        cornerRadius: corner(50, 62, 63),
                        dataIndex: tag
                    )
                )

                parts.append(
                    FormlessLayer(
                        name: "提醒 \(number) 標題",
                        type: .liveText,
                        frame: box(360, top, 1034, 141),
                        value: FormlessLiveSource.reminderTitle.rawValue,
                        colorHex: layer.textColorHex ?? "#424242",
                        fontSize: font(141),
                        fontWeight: "medium",
                        alignment: "leading",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )
            }

            return parts

        case .weather:
            var parts: [FormlessLayer] = []

            let mainColor = layer.colorHex ?? "#000000"
            let subColor = layer.secondaryColorHex ?? "#808495"
            let forecastX: [Double] = [90, 382, 673, 967, 1260]
            let forecastLimit = min(max(1, layer.maxItems ?? 5), 5)

            // 地區：x96 y160 w1284 字級182 靠左
            parts.append(
                FormlessLayer(
                    name: "地區",
                    type: .liveText,
                    frame: box(96, 160, 1284, 182),
                    value: FormlessLiveSource.weatherPlace.rawValue,
                    colorHex: subColor,
                    fontSize: font(182),
                    fontWeight: "semibold",
                    latitude: layer.latitude,
                    longitude: layer.longitude,
                    locationName: layer.locationName,
                    useCurrentLocation: layer.useCurrentLocation,
                    alignment: "leading",
                    autoShrink: false
                )
            )

            // 狀態：x96 y364 w1284 字級216 靠左
            parts.append(
                FormlessLayer(
                    name: "天氣狀態",
                    type: .liveText,
                    frame: box(96, 364, 1284, 216),
                    value: FormlessLiveSource.weatherCondition.rawValue,
                    colorHex: mainColor,
                    fontSize: font(216),
                    fontWeight: "semibold",
                    alignment: "leading",
                    autoShrink: false
                )
            )

            // 溫度：x1226 y168 w345 字級436，度數符號用次要色
            parts.append(
                FormlessLayer(
                    name: "溫度",
                    type: .liveText,
                    frame: box(1226, 168, 345, 436),
                    value: FormlessLiveSource.weatherTemp.rawValue,
                    colorHex: mainColor,
                    fontSize: font(436),
                    fontWeight: "bold",
                    secondaryColorHex: subColor,
                    alignment: "leading",
                    autoShrink: false
                )
            )

            // 天氣圖示：x997 y90 w230 h560
            parts.append(
                FormlessLayer(
                    name: "天氣圖示",
                    type: .symbol,
                    frame: box(997, 90, 230, 560),
                    value: "auto:weather"
                )
            )

            // 預報卡：y762 w251 h674，圓角 24%、外框 label 6%、陰影 label 5%
            for number in 1...forecastLimit {
                let left = forecastX[number - 1]
                let tag = "forecast\(number)"

                parts.append(
                    FormlessLayer(
                        name: "預報 \(number) 卡片",
                        type: .shape,
                        frame: box(left, 762, 251, 674),
                        colorHex: layer.panelColorHex ?? "#FFFFFF",
                        cornerRadius: corner(24, 251, 674),
                        dataIndex: tag,
                        strokeColorHex: "#0000000F",
                        strokeWidth: lenW(1),
                        shadowColorHex: "#0000000D",
                        shadowRadius: lenW(25) / 2,
                        shadowOffsetY: lenH(15) / 2
                    )
                )

                parts.append(
                    FormlessLayer(
                        name: "預報 \(number) 星期",
                        type: .liveText,
                        frame: box(left + 10, 822, 230, 140),
                        value: FormlessLiveSource.forecastName.rawValue,
                        colorHex: subColor,
                        fontSize: font(140),
                        fontWeight: "medium",
                        alignment: "center",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )

                parts.append(
                    FormlessLayer(
                        name: "預報 \(number) 圖示",
                        type: .symbol,
                        frame: box(left + 63, 806, 126, 580),
                        value: "auto:weather",
                        dataIndex: tag
                    )
                )

                parts.append(
                    FormlessLayer(
                        name: "預報 \(number) 溫度",
                        type: .liveText,
                        frame: box(left + 10, 1244, 230, 140),
                        value: FormlessLiveSource.forecastTemp.rawValue,
                        colorHex: subColor,
                        fontSize: font(140),
                        fontWeight: "medium",
                        alignment: "center",
                        dataIndex: tag,
                        autoShrink: false
                    )
                )
            }

            return parts

        case .steps:
            return [
                FormlessLayer(
                    name: "圓形底",
                    type: .shape,
                    frame: frame(0.3125, 0.115, 0.375, 0.375),
                    colorHex: layer.panelColorHex ?? "#EEF8DF",
                    cornerRadius: size(0.1875)
                ),
                FormlessLayer(
                    name: "步行圖示",
                    type: .symbol,
                    frame: frame(0.3175, 0.2125, 0.3675, 0.1875),
                    value: "figure.walk",
                    colorHex: layer.colorHex ?? "#9DE14E"
                ),
                FormlessLayer(
                    name: "步數",
                    type: .liveText,
                    frame: frame(0.125, 0.5613, 0.75, 0.2087),
                    value: FormlessLiveSource.steps.rawValue,
                    colorHex: layer.textColorHex ?? "#000000",
                    fontSize: size(0.18161),
                    fontWeight: "bold",
                    alignment: "center"
                ),
                FormlessLayer(
                    name: "下方文字",
                    type: .text,
                    frame: frame(0.125, 0.775, 0.75, 0.1013),
                    value: layer.value ?? "步數",
                    colorHex: layer.secondaryColorHex ?? "#808495",
                    fontSize: size(0.08809),
                    fontWeight: "semibold",
                    alignment: "center"
                )
            ]

        case .yearProgress:
            return [
                FormlessLayer(
                    name: "年份",
                    type: .date,
                    frame: frame(0.0437, 0.0875, 0.615, 0.1375),
                    value: "yyyy",
                    colorHex: layer.colorHex ?? "#000000",
                    fontSize: size(0.11963),
                    fontWeight: "bold",
                    alignment: "leading"
                ),
                FormlessLayer(
                    name: "百分比",
                    type: .liveText,
                    frame: frame(0.775, 0.0875, 0.1187, 0.1375),
                    value: FormlessLiveSource.yearPercent.rawValue,
                    colorHex: layer.colorHex ?? "#000000",
                    fontSize: size(0.11963),
                    fontWeight: "bold",
                    alignment: "leading"
                ),
                FormlessLayer(
                    name: "百分號",
                    type: .text,
                    frame: frame(0.8938, 0.0875, 0.1062, 0.1375),
                    value: "%",
                    colorHex: layer.secondaryColorHex ?? "#808495",
                    fontSize: size(0.11963),
                    fontWeight: "bold",
                    alignment: "leading"
                )
            ] + yearGridStars(
                in: frame(0.0437, 0.3088, 0.9125, 0.5787),
                filledHex: layer.colorHex ?? "#000000",
                emptyHex: layer.textColorHex ?? "#D8D8DA",
                family: family
            )

        default:
            return []
        }
    }
}


extension FormlessTemplate {
    /// A template is an editable stack, with a group for moving its pieces together.
    static func editableDocument(_ source: FormlessDocument) -> FormlessDocument {
        var result = source
        result.layers = source.layers.flatMap { layer -> [FormlessLayer] in
            guard canExplode(layer.type), layer.parentID == nil else { return [layer] }
            let parts = explode(layer, family: source.family)
            guard !parts.isEmpty else { return [layer] }
            var group = FormlessLayer(id: layer.id, name: layer.name, type: .shape, isGroup: true)
            group.isHidden = layer.isHidden
            group.isLocked = layer.isLocked
            return [group] + parts.map { part in
                var child = part
                child.parentID = group.id
                child.isHidden = nil
                child.isLocked = nil
                return child
            }
        }
        for index in result.layers.indices { result.layers[index].zIndex = index }
        return result
    }

    // MARK: 年度進度格（一般圖層）

    /// 年度進度格的 48 顆四角星（使用者規則：進度格只是一種設計，由一般圖層組成，每顆各自依條件變色）。
    /// 12 欄 × 4 列，每顆在自己那格的正中央，是邊長等於格高 × 0.56 的正方形；平常是未完成的顏色，
    /// 第 k 顆在「年度百分比 ≥ (k − 0.5) ÷ 48」時換成已完成的顏色，和原本的四捨五入一樣，同一天亮的顆數不變。
    static func yearGridStars(in box: FormlessFrame, filledHex: String, emptyHex: String,
                              family: FormlessWidgetFamily) -> [FormlessLayer] {
        let columns = 12, rows = 4
        let height = box.height * 0.14
        let width = height / Double(family.aspectRatio)
        /// 座標取到小數第六位（畫布上不到 0.001 pt），匯出的檔案才好讀。
        func tidy(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
        return (0..<columns * rows).map { index in
            let k = index + 1
            let centerX = box.x + box.width * (Double(index % columns) + 0.5) / Double(columns)
            let centerY = box.y + box.height * (Double(index / columns) + 0.5) / Double(rows)
            var star = FormlessLayer(
                name: "格 \(k)",
                type: .shape,
                frame: FormlessFrame(x: tidy(centerX - width / 2), y: tidy(centerY - height / 2),
                                     width: tidy(width), height: tidy(height)),
                colorHex: emptyHex,
                shape: FormlessShapeKind.fourPointStar.rawValue
            )
            // 門檻取到小數第二位：(k − 0.5) ÷ 48 × 100。
            star.colorRules = [FormlessColorRule(source: .yearPercent, comparison: .atLeast,
                                                 value: (Double(2 * k - 1) * 2500 / 24).rounded() / 100,
                                                 colorHex: filledHex)]
            return star
        }
    }

    /// 舊檔裡沒拆解的年度進度元件換成一般圖層（使用者規則，2026-09-27）：拆成年份、百分比、百分號和 48 顆星，
    /// 包成同名群組。開檔、匯入、貼上都經過這裡。新圖層的 id 由原本的 id 推算，同一份舊檔每次讀出來都一樣
    /// （小工具和 App 各自讀也對得上）。舊版的年度進度格不再轉換（使用者已刪掉舊檔）。
    static func expandLegacyLayers(_ layers: [FormlessLayer], family: FormlessWidgetFamily) -> [FormlessLayer] {
        guard layers.contains(where: { $0.type == .yearProgress }) else { return layers }
        var result = layers.flatMap { layer -> [FormlessLayer] in
            layer.type == .yearProgress ? legacyYearProgress(layer, family: family) : [layer]
        }
        for index in result.indices { result[index].zIndex = index }
        return result
    }

    /// 沒拆解的年度進度元件：和建立範本時一樣拆成一般圖層，包成同名群組；原本在群組裡就直接放進那個群組。
    private static func legacyYearProgress(_ layer: FormlessLayer, family: FormlessWidgetFamily) -> [FormlessLayer] {
        let parts = explode(layer, family: family).map { original -> FormlessLayer in
            var part = original
            let key = part.name.hasPrefix("格 ") ? "star-" + String(part.name.dropFirst(2)) : part.name
            part.id = UUID(formlessName: key, in: layer.id)
            return part
        }
        if let parent = layer.parentID {
            return parts.map { original in
                var part = original
                part.parentID = parent
                return part
            }
        }
        var group = FormlessLayer(id: layer.id, name: layer.name, type: .shape, isGroup: true)
        group.isHidden = layer.isHidden
        group.isLocked = layer.isLocked
        group.isCollapsed = true
        return [group] + parts.map { original in
            var part = original
            part.parentID = group.id
            part.isHidden = nil
            part.isLocked = nil
            return part
        }
    }

    static func explode(_ layer: FormlessLayer, family: FormlessWidgetFamily) -> [FormlessLayer] {
        /// 拆出來的圖層對應到哪個可微調部位。名稱帶序號，所以用前綴判斷。
        func partKey(_ name: String) -> String? {
            switch layer.type {
            case .calendar:
                return ["左側面板": "panel", "星期": "weekday", "大日期": "day", "月份標題": "month", "星期列": "weekdayRow", "日期格": "grid"][name]

            case .events:
                if name.hasPrefix("刻度軸") { return "ruler" }
                if name == "標題" { return "title" }
                if name == "事件數" { return "count" }
                if name.hasPrefix("事件 ") || name == "底部漸淡" || name == "無行程提示" { return "cards" }
                return nil

            case .reminders:
                if name == "圖示" { return "icon" }
                if name == "標題" { return "title" }
                if name.hasPrefix("提醒 ") { return "list" }
                return nil

            case .weather:
                if name == "地區" { return "place" }
                if name == "天氣狀態" { return "condition" }
                if name == "天氣圖示" { return "icon" }
                if name == "溫度" { return "now" }
                if name.hasPrefix("預報 ") { return "forecast" }
                return nil

            case .steps:
                return ["圓形底": "icon", "步行圖示": "icon", "步數": "count", "下方文字": "label"][name]

            case .yearProgress:
                if name.hasPrefix("格 ") { return "grid" }
                return ["年份": "header", "百分比": "percent", "百分號": "percent"][name]

            default:
                return nil
            }
        }
        return rawParts(layer, family: family).flatMap { part -> [FormlessLayer] in
            guard part.type == .calendarGrid else { return [part] }
            var weekdays = part
            weekdays.id = UUID()
            weekdays.name = "星期列"
            weekdays.value = "weekdays"
            var days = part
            days.name = "日期格"
            days.value = "days"
            return [weekdays, days]
        }.filter {
            !(layer.type == .reminders && layer.showsPanel == false && $0.name == "外框背景")
        }.map { original in
            var part = original
            if let key = partKey(part.name) {
                let offset = layer.offset(key)
                part.frame.x += offset.x * layer.frame.width
                part.frame.y += offset.y * layer.frame.height
            }
            let aspect = Double(family.aspectRatio)
            let angle = layer.rotation * .pi / 180
            let cx = layer.frame.x + layer.frame.width / 2
            let cy = layer.frame.y + layer.frame.height / 2
            let dx = (part.frame.x + part.frame.width / 2 - cx) * aspect
            let dy = part.frame.y + part.frame.height / 2 - cy
            part.frame.x = cx + (dx * cos(angle) - dy * sin(angle)) / aspect - part.frame.width / 2
            part.frame.y = cy + dx * sin(angle) + dy * cos(angle) - part.frame.height / 2
            part.rotation = layer.rotation
            part.opacity *= layer.opacity
            part.isHidden = layer.isHidden
            part.isLocked = layer.isLocked
            part.actionURL = layer.actionURL
            part.tapAction = layer.tapAction
            part.fontFamily = layer.fontFamily
            return part
        }
    }
}



final class FormlessOneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        guard let callback else { return false }
        callback(value)
        return true
    }
}
