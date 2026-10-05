import WidgetKit
import SwiftUI
import AppIntents


// MARK: - 顯示資料

struct FormlessEntry: TimelineEntry {
    let date: Date
    let document: FormlessDocument?
    let noAvailableWidget: Bool
    let live: FormlessLiveData
}


// MARK: - 共用讀取

enum FormlessWidgetLoader {

    /// 依設計檔設定的間隔安排下一次更新。含時間的設計會先排好每分鐘的畫面（Apple 規定時間軸項目至少相隔約 5 分鐘），
    /// 這樣時鐘不必消耗系統的更新配額也會走。行程結束、提醒到期的時間點另外各排一格（`FormlessLiveTimeline`），
    /// 每一格都用自己的時間篩選行程與提醒事項，不必等下次重新整理。
    static func timeline(for entry: FormlessEntry) -> Timeline<FormlessEntry> {
        let now = entry.date

        guard let document = entry.document else {
            return Timeline(
                entries: [entry],
                policy: .after(now.addingTimeInterval(900))
            )
        }

        let minutes = document.effectiveRefreshMinutes

        let horizon = now.addingTimeInterval(Double(minutes) * 60)
        let entries = FormlessLiveTimeline.dates(
            now: now,
            minutes: minutes,
            minuteRefresh: document.needsMinuteRefresh,
            live: entry.live,
            showsPast: document.showsPastItems ?? false,
            extra: FormlessDataCoordinator.changes(for: document, live: entry.live, from: now, to: horizon)
        ).map { date in
            FormlessEntry(
                date: date,
                document: document,
                noAvailableWidget: entry.noAvailableWidget,
                live: entry.live.at(date, showsPast: document.showsPastItems ?? false)
            )
        }

        return Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(Double(minutes) * 60))
        )
    }

    /// preview 為 true 時只讀快取。設定畫面的預覽不該去等網路與行事曆，
    /// 否則整張設定表會卡在載入中。
    static func entry(
        selectedID: String?,
        noneToken: String,
        preview: Bool = false
    ) async -> FormlessEntry {
        // 匯入的字型：小工具延伸是另一個行程，要自己註冊一次（只在字型清單改變時重讀）。
        FormlessFontLibrary.registerAll()

        guard let selectedID else {
            return FormlessEntry(
                date: Date(),
                document: nil,
                noAvailableWidget: false,
                live: FormlessLiveData()
            )
        }

        if selectedID == noneToken {
            return FormlessEntry(
                date: Date(),
                document: nil,
                noAvailableWidget: true,
                live: FormlessLiveData()
            )
        }

        guard let document = FormlessStorage.load(idString: selectedID) else {
            return FormlessEntry(
                date: Date(),
                document: nil,
                noAvailableWidget: false,
                live: FormlessLiveData()
            )
        }

        let live = preview
            ? FormlessLiveData.cached(for: document)
            : await FormlessLiveData.refreshed(for: document)

        return FormlessEntry(
            date: Date(),
            document: document,
            noAvailableWidget: false,
            live: live
        )
    }
}


// MARK: - 小型

struct SmallProvider: AppIntentTimelineProvider {

    typealias Entry = FormlessEntry
    typealias Intent = SmallWidgetIntent

    func placeholder(in context: Context) -> FormlessEntry {
        FormlessEntry(
            date: Date(),
            document: nil,
            noAvailableWidget: false,
            live: FormlessLiveData()
        )
    }

    func snapshot(
        for configuration: SmallWidgetIntent,
        in context: Context
    ) async -> FormlessEntry {

        await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_small__",
            preview: true
        )
    }

    func timeline(
        for configuration: SmallWidgetIntent,
        in context: Context
    ) async -> Timeline<FormlessEntry> {

        let entry = await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_small__"
        )

        return FormlessWidgetLoader.timeline(for: entry)
    }
}


// MARK: - 中型

struct MediumProvider: AppIntentTimelineProvider {

    typealias Entry = FormlessEntry
    typealias Intent = MediumWidgetIntent

    func placeholder(in context: Context) -> FormlessEntry {
        FormlessEntry(
            date: Date(),
            document: nil,
            noAvailableWidget: false,
            live: FormlessLiveData()
        )
    }

    func snapshot(
        for configuration: MediumWidgetIntent,
        in context: Context
    ) async -> FormlessEntry {

        await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_medium__",
            preview: true
        )
    }

    func timeline(
        for configuration: MediumWidgetIntent,
        in context: Context
    ) async -> Timeline<FormlessEntry> {

        let entry = await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_medium__"
        )

        return FormlessWidgetLoader.timeline(for: entry)
    }
}


// MARK: - 大型

struct LargeProvider: AppIntentTimelineProvider {

    typealias Entry = FormlessEntry
    typealias Intent = LargeWidgetIntent

    func placeholder(in context: Context) -> FormlessEntry {
        FormlessEntry(
            date: Date(),
            document: nil,
            noAvailableWidget: false,
            live: FormlessLiveData()
        )
    }

    func snapshot(
        for configuration: LargeWidgetIntent,
        in context: Context
    ) async -> FormlessEntry {

        await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_large__",
            preview: true
        )
    }

    func timeline(
        for configuration: LargeWidgetIntent,
        in context: Context
    ) async -> Timeline<FormlessEntry> {

        let entry = await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_large__"
        )

        return FormlessWidgetLoader.timeline(for: entry)
    }
}


// MARK: - 超大型

struct ExtraLargeProvider: AppIntentTimelineProvider {

    typealias Entry = FormlessEntry
    typealias Intent = ExtraLargeWidgetIntent

    func placeholder(in context: Context) -> FormlessEntry {
        FormlessEntry(
            date: Date(),
            document: nil,
            noAvailableWidget: false,
            live: FormlessLiveData()
        )
    }

    func snapshot(
        for configuration: ExtraLargeWidgetIntent,
        in context: Context
    ) async -> FormlessEntry {

        await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_extraLarge__",
            preview: true
        )
    }

    func timeline(
        for configuration: ExtraLargeWidgetIntent,
        in context: Context
    ) async -> Timeline<FormlessEntry> {

        let entry = await FormlessWidgetLoader.entry(
            selectedID: configuration.selectedWidget?.id,
            noneToken: "__none_extraLarge__"
        )

        return FormlessWidgetLoader.timeline(for: entry)
    }
}


/// 點擊只重新整理資料，畫面上不能有任何反應。
/// .plain 仍會套用系統的按壓效果，所以自己實作一個完全忽略 isPressed 的樣式。
struct FormlessSilentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}


// MARK: - 小工具畫面

struct FormlessWidgetView: View {

    let entry: FormlessEntry
    var kind: String = ""

    private var backgroundColor: Color {
        Color(
            formlessHex: entry.document?.backgroundColorHex,
            fallback: "#F4F4F4"
        )
    }

    var body: some View {
        tappable
            // 圖層自己的點擊動作蓋在最上面：點到那個圖層用它的，其他地方照小工具的設定。
            .overlay { layerTapAreas }
            .containerBackground(for: .widget) {
                containerBackground
            }
    }

    /// 底色與背景圖交給系統：StandBy 會拿掉、透明與染色會換成玻璃。
    @ViewBuilder
    private var containerBackground: some View {
        if let document = entry.document, !entry.noAvailableWidget {
            FormlessDocumentBackground(document: document)
        } else {
            backgroundColor
        }
    }

    /// 有自己點擊動作的圖層，在它的位置放一塊透明連結；順序跟圖層疊放相同，上面的圖層先接到。
    @ViewBuilder
    private var layerTapAreas: some View {
        if !entry.noAvailableWidget, let document = entry.document {
            let layers = document.renderedLayers(document.visibleSortedLayers, live: entry.live, date: entry.date).filter {
                ($0.layer.tapDestination(live: $0.live, date: entry.date) != nil
                    || $0.layer.widgetIntent(document: document, live: $0.live) != nil)
                    && FormlessDataBinding.satisfied($0.layer.dataIndex, live: $0.live)
                    && $0.live.matches($0.layer.visibility, at: entry.date)
            }
            if !layers.isEmpty {
                GeometryReader { geometry in
                    ForEach(layers) { item in
                        let layer = item.layer
                        // 切換、加減、完成提醒、重新整理：小工具上直接執行的按鈕，不打開 App。
                        if let intent = layer.widgetIntent(document: document, live: item.live) {
                            let rect = FormlessLayerLayout.rect(for: layer, canvasSize: geometry.size)
                            intentArea(intent)
                                .frame(width: rect.width, height: rect.height)
                                .rotationEffect(.degrees(layer.rotation))
                                .position(x: rect.midX, y: rect.midY)
                        } else if let destination = layer.tapDestination(live: item.live, date: entry.date) {
                            let rect = FormlessLayerLayout.rect(for: layer, canvasSize: geometry.size)
                            Link(destination: destination) {
                                Color.clear.contentShape(Rectangle())
                            }
                            .frame(width: rect.width, height: rect.height)
                            .rotationEffect(.degrees(layer.rotation))
                            .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
            }
        }
    }

    /// 透明的按鈕：按了執行動作，畫面上沒有任何按壓效果。
    private func intentArea(_ intent: some AppIntent) -> AnyView {
        AnyView(
            Button(intent: intent) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(FormlessSilentButtonStyle())
        )
    }

    @ViewBuilder
    private var tappable: some View {
        switch entry.document?.effectiveTapAction ?? .refresh {

        case .refresh:
            Button(
                intent: FormlessRefreshIntent(
                    kind: kind,
                    documentID: entry.document?.id.uuidString ?? ""
                )
            ) {
                // 整塊都是按鈕：底色移到 containerBackground 之後，沒有圖層的地方是透明的，點到那裡會落到系統預設的「打開 App」。
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(FormlessSilentButtonStyle())

        case .openApp:
            content

        case .openURL:
            content
                .widgetURL(URL(string: entry.document?.tapURL ?? ""))

        case .createEvent:
            content
                .widgetURL(FormlessDeepLink.createEvent)
        }
    }

    @ViewBuilder
    private var content: some View {
        if entry.noAvailableWidget {
            messageView(
                title: "沒有可用的小工具",
                detail: ""
            )
        } else if let document = entry.document {
            FormlessDocumentView(
                document: document,
                date: entry.date,
                live: entry.live,
                drawsBackground: false
            )
        } else {
            messageView(
                title: "Formless",
                detail: "長按 → 編輯小工具"
            )
        }
    }

    private func messageView(title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - 四種尺寸

struct FormlessSmallWidget: Widget {

    let kind = "FormlessSmallWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SmallWidgetIntent.self,
            provider: SmallProvider()
        ) { entry in
            FormlessWidgetView(entry: entry, kind: kind)
        }
        .configurationDisplayName("Formless 小型")
        .supportedFamilies([.systemSmall])
        // 背景可以移除：StandBy 與 iPad 鎖定畫面的小工具圖庫才會列出 Formless。
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
    }
}

struct FormlessMediumWidget: Widget {

    let kind = "FormlessMediumWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: MediumWidgetIntent.self,
            provider: MediumProvider()
        ) { entry in
            FormlessWidgetView(entry: entry, kind: kind)
        }
        .configurationDisplayName("Formless 中型")
        .supportedFamilies([.systemMedium])
        // 背景可以移除：StandBy 與 iPad 鎖定畫面的小工具圖庫才會列出 Formless。
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
    }
}

struct FormlessLargeWidget: Widget {

    let kind = "FormlessLargeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: LargeWidgetIntent.self,
            provider: LargeProvider()
        ) { entry in
            FormlessWidgetView(entry: entry, kind: kind)
        }
        .configurationDisplayName("Formless 大型")
        .supportedFamilies([.systemLarge])
        // 背景可以移除：StandBy 與 iPad 鎖定畫面的小工具圖庫才會列出 Formless。
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
    }
}

struct FormlessExtraLargeWidget: Widget {

    let kind = "FormlessExtraLargeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ExtraLargeWidgetIntent.self,
            provider: ExtraLargeProvider()
        ) { entry in
            FormlessWidgetView(entry: entry, kind: kind)
        }
        .configurationDisplayName("Formless 超大型")
        .supportedFamilies([.systemExtraLargePortrait])
        // 背景可以移除：StandBy 與 iPad 鎖定畫面的小工具圖庫才會列出 Formless。
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
    }
}
