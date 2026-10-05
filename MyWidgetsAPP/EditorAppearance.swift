import SwiftUI

// MARK: - 外觀分頁（使用者核准的設計，2026-09-27）
//
// 一張卡片、三層：上面是大方塊（形狀、填色、顏色、文字、圓角……，直接看得到目前的樣子），中間是透明度與旋轉，
// 下面是外框與陰影。細項（漸層的顏色點與角度、字級字重字型對齊、外框寬度與顏色……）只有點了方塊才從下方滑出
// 工具面板（和「位置與大小」「顏色」同一種面板，畫布不擋）。每個控制項各自有點擊範圍，整列不會被當成一個按鈕
// （原本選單和按鈕擠在同一列，點填色選單常觸發到下方的 ＋）。進階樣式的系統展開列會把內容內縮，這裡不再用它。

extension FormlessShapeKind {
    /// 方塊裡形狀輪廓的大小：比較扁的形狀用 wide，半圓是 wide 寬度的 2:1，其他是 square 的正方形。
    func editorGlyphSize(wide: CGSize, square: CGFloat) -> CGSize {
        switch self {
        case .rectangle, .capsule, .parallelogram, .trapezoid, .arrow, .speechBubble:
            return wide
        case .semicircle:
            return CGSize(width: wide.width, height: wide.width / 2)
        default:
            return CGSize(width: square, height: square)
        }
    }
}

extension FormlessLayer {
    /// 可以「跟隨資料顏色」（行程、提醒事項的顏色）：文字類與色塊綁了第幾筆行程或提醒事項時，或已經是自動。
    var editorSupportsAutomaticColor: Bool {
        guard [.shape, .text, .date, .time, .liveText].contains(type) else { return false }
        if editorUsesAutomaticColor { return true }
        guard let binding = FormlessDataBinding.parse(dataIndex), binding.index > 0 else { return false }
        return binding.kind == "event" || binding.kind == "reminder"
    }

    var editorUsesAutomaticColor: Bool { colorHex?.lowercased() == "auto" }

    /// 天氣地點放在主天氣圖示那一層（拆解後）或天氣元件本身。
    var editorHoldsWeatherLocation: Bool {
        if type == .weather || type == .weatherForecast { return true }
        return type == .symbol && (value ?? "") == "auto:weather"
    }

    /// 換填色方式：切到漸層時沒有顏色點的話，從目前的顏色開始，預設三個顏色點：左右兩端各一個、中間一個
    /// （使用者指定）。左端是目前的顏色、右端是同色的完全透明，中間是兩者的中間值，看起來和只有兩點時一樣。
    /// 切回單色時保留顏色點，再切回漸層還是原本的樣子。
    mutating func editorSetFill(_ style: FormlessFillStyle) {
        fill = style == .solid ? nil : style.rawValue
        if style != .solid, (gradientStops ?? []).count < 2 {
            let current = editorUsesAutomaticColor ? "#E6E6E8" : (colorHex ?? "#E6E6E8")
            let base = FormlessGradientStop.opaqueHex(current)
            gradientStops = [FormlessGradientStop(colorHex: base, location: 0),
                             FormlessGradientStop(colorHex: base + "80", location: 0.5),
                             FormlessGradientStop(colorHex: base + "00", location: 1)]
        }
    }
}

/// 「跟隨資料顏色」開關：關掉時回到色塊的預設灰或文字的黑色。
func editorAutomaticColorBinding(_ layer: Binding<FormlessLayer>) -> Binding<Bool> {
    Binding(
        get: { layer.wrappedValue.editorUsesAutomaticColor },
        set: { enabled in
            layer.wrappedValue.colorHex = enabled ? "auto" : (layer.wrappedValue.type == .shape ? "#E6E6E8" : "#000000")
        }
    )
}

// MARK: - 細項面板的種類

enum EditorStylePanelKind: Hashable {
    case fill, shape, text, corner, stroke, shadow, progress, chart, effects

    var title: String {
        switch self {
        case .fill: return "填色"
        case .shape: return "形狀"
        case .text: return "文字"
        case .corner: return "圓角"
        case .stroke: return "外框"
        case .shadow: return "陰影"
        case .progress, .chart: return "樣式"
        case .effects: return "效果"
        }
    }
}

struct EditorStylePanelRequest: Identifiable {
    let id = UUID()
    let layerID: UUID
    let kind: EditorStylePanelKind
}

extension EnvironmentValues {
    /// 外觀方塊用來打開細項面板（由屬性面板提供）。
    @Entry var editorStylePanelOpener: ((EditorStylePanelKind) -> Void)? = nil
}

// MARK: - 方塊

/// 顏色方塊：一個顏色欄位（名稱、欄位、預設值）。
struct EditorColorTile: Hashable {
    let title: String
    let keyPath: WritableKeyPath<FormlessLayer, String?>
    let fallback: String
}

enum EditorAppearanceTile: Hashable {
    case shape, fill, text, corner, progressStyle, chartStyle
    case color(EditorColorTile)

    var caption: String {
        switch self {
        case .shape: return "形狀"
        case .fill: return "填色"
        case .text: return "文字"
        case .corner: return "圓角"
        case .progressStyle, .chartStyle: return "樣式"
        case .color(let tile): return tile.title
        }
    }

    /// 這個圖層的方塊：色塊是形狀與填色（先形狀再填色，使用者規則）；其他是各部位的顏色，接著文字或圓角。
    /// 圖片沒有顏色可調（畫的時候不用顏色），不放顏色方塊。
    static func tiles(for layer: FormlessLayer) -> [EditorAppearanceTile] {
        if layer.type == .shape { return [.shape, .fill] }
        if layer.type == .progress {
            return [.progressStyle,
                    .color(EditorColorTile(title: "進度色", keyPath: \.colorHex, fallback: "#007AFF")),
                    .color(EditorColorTile(title: "軌道色", keyPath: \.progressTrackColorHex, fallback: FormlessProgressView.defaultTrackHex))]
        }
        if layer.type == .chart {
            return [.chartStyle,
                    .color(EditorColorTile(title: "顏色", keyPath: \.colorHex, fallback: "#007AFF")),
                    .color(EditorColorTile(title: "次要色", keyPath: \.chartSecondaryColorHex, fallback: "#8E8E93"))]
        }
        return colorTiles(for: layer).map { .color($0) } + styleTiles(for: layer)
    }

    private static func colorTiles(for layer: FormlessLayer) -> [EditorColorTile] {
        guard ![.image, .remoteImage, .bundleImage].contains(layer.type) else { return [] }
        // 「跟著天氣」的圖示畫的是天氣圖片，不用顏色：原本顯示的顏色、預報卡底色都改了沒有作用。
        guard !(layer.type == .symbol && (layer.value ?? "") == formlessAutoWeatherSymbol) else { return [] }
        // 沒設定顏色時方塊顯示的顏色要和畫出來的一樣：月曆格的強調色預設是 #FF3B30。
        let accentFallback = layer.type == .calendarGrid ? "#FF3B30" : "#000000"
        var list = [EditorColorTile(title: layer.type.isComponent ? "強調色" : (layer.type == .clock ? "時針" : "顏色"),
                                    keyPath: \.colorHex, fallback: accentFallback)]
        if layer.type == .symbol && layer.symbolMode == "palette" {
            // 調色盤的第二個顏色（圖示的次要部分）。
            list.append(EditorColorTile(title: "第二顏色", keyPath: \.secondaryColorHex, fallback: "#8E8E93"))
        }
        if layer.type == .clock {
            // 指針時鐘：分針（沒設跟時針一樣）、刻度與數字、錶盤（沒設是透明）。
            list.append(EditorColorTile(title: "分針", keyPath: \.secondaryColorHex, fallback: layer.colorHex ?? "#000000"))
            list.append(EditorColorTile(title: "刻度", keyPath: \.textColorHex, fallback: "#8E8E93"))
            list.append(EditorColorTile(title: "錶盤", keyPath: \.panelColorHex, fallback: "#00000000"))
        }
        if layer.type.isComponent {
            list.append(EditorColorTile(title: "次要色", keyPath: \.secondaryColorHex, fallback: "#808495"))
            switch layer.type {
            case .calendar:
                list.append(EditorColorTile(title: "左側面板底色", keyPath: \.panelColorHex, fallback: "#E6E6E8"))
                list.append(EditorColorTile(title: "日期文字色", keyPath: \.textColorHex, fallback: "#000000"))
            case .events:
                list.append(EditorColorTile(title: "事件卡底色", keyPath: \.panelColorHex, fallback: "#FFFFFF"))
                list.append(EditorColorTile(title: "日期時間顏色", keyPath: \.textColorHex, fallback: "#666666"))
            case .reminders, .reminderList:
                list.append(EditorColorTile(title: "項目文字色", keyPath: \.textColorHex, fallback: "#424242"))
            case .steps:
                list.append(EditorColorTile(title: "圓形底色", keyPath: \.panelColorHex, fallback: "#EEF8DF"))
                list.append(EditorColorTile(title: "數字顏色", keyPath: \.textColorHex, fallback: "#000000"))
            case .yearProgress:
                list.append(EditorColorTile(title: "未完成顏色", keyPath: \.textColorHex, fallback: "#D8D8DA"))
            case .calendarGrid:
                list.append(EditorColorTile(title: "日期文字色", keyPath: \.textColorHex, fallback: "#000000"))
                list.append(EditorColorTile(title: "週末", keyPath: \.calendarWeekendColorHex, fallback: layer.textColorHex ?? "#000000"))
            case .eventList:
                list.append(EditorColorTile(title: "卡片底色", keyPath: \.panelColorHex, fallback: "#FFFFFF"))
                list.append(EditorColorTile(title: "日期時間顏色", keyPath: \.textColorHex, fallback: "#666666"))
            default:
                break
            }
        }
        // 預報卡底色只有天氣元件會畫（圖示放的是天氣地點，沒有卡片）。
        if layer.editorHoldsWeatherLocation && layer.type != .symbol {
            list.append(EditorColorTile(title: "預報卡底色", keyPath: \.panelColorHex, fallback: "#FFFFFF"))
        }
        return list
    }

    private static func styleTiles(for layer: FormlessLayer) -> [EditorAppearanceTile] {
        switch layer.type {
        case .text, .date, .time, .liveText, .calendarGrid, .reminderList, .weatherForecast: return [.text]
        case .image, .remoteImage: return [.corner]
        case .calendar: return [.text, .corner]
        default: return []
        }
    }
}

enum EditorAppearanceMetrics {
    /// 方塊的圓角與內距：預覽和四邊的距離一樣（上、左、右 12；說明文字到底邊也是 12）。
    static let tileRadius = FormlessDesign.Radius.medium
    static let tilePadding: CGFloat = 12
    static let previewHeight: CGFloat = 36
    /// 方塊列上下左右和卡片邊緣的距離，和「版面」的方向鍵列相同。
    static let rowInset = FormlessDesign.Space.panel
}

/// 方塊本身：玻璃圓角方塊（和「版面」的方向鍵同一種質感），上面是目前樣子的預覽、下面一行小字說明。
struct EditorAppearanceTileLabel<Preview: View>: View {
    /// nil 表示只有預覽、沒有下面那行字（形狀面板一列五個，圖示本身就說明了是什麼）。
    let caption: String?
    var selected = false
    /// 預覽區的高度。形狀面板的圖示最高 32，用 32：四列加上矩形的圓角列才放得進面板，不用捲。
    var previewHeight = EditorAppearanceMetrics.previewHeight
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: EditorAppearanceMetrics.tileRadius, style: .continuous)
        VStack(spacing: 8) {
            preview()
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(EditorAppearanceMetrics.tilePadding)
        .frame(maxWidth: .infinity)
        .contentShape(shape)
        .formlessGlass(.regular, in: shape)
        .overlay {
            if selected { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
    }
}

/// 方塊按下去的樣子：稍微縮小、變暗一點（和玻璃方向鍵的按下樣子相同，數值見 `FormlessDesign.Press`）。
struct EditorTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: EditorAppearanceMetrics.tileRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? FormlessDesign.Press.overlay : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? FormlessDesign.Press.scale : 1)
            .animation(FormlessDesign.Motion.press, value: configuration.isPressed)
    }
}

/// 方塊裡的預覽：色塊是實際的填色（含漸層），形狀與圓角畫出輪廓，文字用目前的字重與字型寫「Aa」。
struct EditorAppearanceTilePreview: View {
    let tile: EditorAppearanceTile
    let layer: FormlessLayer

    var body: some View {
        switch tile {
        case .fill:
            swatch { size in
                if layer.fillStyle == .solid {
                    mainColor(fallback: "#E6E6E8")
                } else {
                    Rectangle().fill(layer.shapeFill(size: size, solidHex: layer.colorHex))
                }
            }
        case .color(let color):
            swatch { _ in
                if color.keyPath == \FormlessLayer.colorHex {
                    mainColor(fallback: color.fallback)
                } else {
                    Color(formlessHex: layer[keyPath: color.keyPath], fallback: color.fallback)
                }
            }
        case .shape:
            let size = layer.shapeKind.editorGlyphSize(wide: CGSize(width: 58, height: 36), square: 36)
            FormlessLayerShape(kind: layer.shapeKind, cornerRadius: glyphRadius(layer.cornerRadius ?? 0))
                .stroke(Color.primary, lineWidth: 2)
                .padding(1)
                .frame(width: size.width, height: size.height)
        case .corner:
            RoundedRectangle(cornerRadius: cornerGlyphRadius, style: .continuous)
                .strokeBorder(Color.primary, lineWidth: 2)
                .frame(width: 58, height: 36)
        case .text:
            Text("Aa")
                .font(formlessFont(size: 26, weight: layer.fontWeight ?? EditorTextPanelSpec(layer: layer).weightFallback,
                                   family: layer.fontFamily))
                .foregroundStyle(.primary)
        case .progressStyle:
            EditorProgressGlyph(style: layer.progress?.style ?? .linear)
        case .chartStyle:
            Image(systemName: (layer.chart?.kind ?? .bar).symbol).font(.system(size: 24)).foregroundStyle(.primary)
        }
    }

    /// 主要顏色的預覽：有條件顏色時，平常的顏色和每條條件的顏色並排。
    private func mainColor(fallback: String) -> some View {
        HStack(spacing: 0) {
            if layer.editorUsesAutomaticColor {
                automaticMark
            } else if let scale = layer.colorScale, scale.stops.count >= 2 {
                // 依數值漸變：畫成色階本身，一眼看得出顏色會隨資料改變。
                LinearGradient(colors: scale.stops.sorted { $0.value < $1.value }.map { Color(formlessHex: $0.colorHex, fallback: fallback) },
                               startPoint: .leading, endPoint: .trailing)
            } else {
                Color(formlessHex: layer.colorHex, fallback: fallback)
            }
            ForEach(Array((layer.colorRules ?? []).enumerated()), id: \.offset) { _, rule in
                Color(formlessHex: rule.colorHex, fallback: fallback)
            }
        }
    }

    /// 圓角在預覽裡的大小：畫布上的 pt 縮成預覽的比例，最多到半高（再大就是膠囊）。
    private func glyphRadius(_ radius: Double) -> CGFloat { min(18, CGFloat(radius) * 0.45) }

    private var cornerGlyphRadius: CGFloat {
        // 月曆的面板圓角是百分比（相對短邊），圖片是 pt。
        if layer.type == .calendar { return 36 * CGFloat(layer.cornerRadius ?? 11) / 100 }
        return glyphRadius(layer.cornerRadius ?? 0)
    }

    private func swatch<Fill: View>(@ViewBuilder _ fill: @escaping (CGSize) -> Fill) -> some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        return GeometryReader { geometry in
            ZStack {
                EditorCheckerboard()
                fill(geometry.size)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline))
        }
    }

    /// 跟隨資料顏色：顏色由行程或提醒事項決定，用連結符號表示。
    private var automaticMark: some View {
        // 不透明的淡灰底：半透明的話會透出下面的棋盤格，看起來像透明色。
        ZStack {
            Color(uiColor: .systemGray6)
            Image(systemName: "link").font(FormlessDesign.Symbol.smallCircle).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 外觀卡片

/// 外觀分頁的卡片：大方塊（一列兩個，單數時最後一個佔滿）→ 透明度 → 旋轉 → 外框與陰影。
struct EditorAppearanceSection: View {
    @Binding var layer: FormlessLayer
    let family: FormlessWidgetFamily
    @Environment(\.editorStylePanelOpener) private var openStyle
    @Environment(\.editorColorPanelOpener) private var openColor
    @AppStorage("formless.nudgeStep") private var nudgeStep: Double = 10

    var body: some View {
        let tiles = EditorAppearanceTile.tiles(for: layer)
        Section {
            if !tiles.isEmpty {
                tileGrid(tiles)
                    .listRowInsets(EdgeInsets(top: EditorAppearanceMetrics.rowInset, leading: EditorAppearanceMetrics.rowInset,
                                              bottom: EditorAppearanceMetrics.rowInset, trailing: EditorAppearanceMetrics.rowInset))
                    // 分隔線從卡片內容的左緣開始（列內沒有文字可以對齊時，系統會把線縮到一半）。
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            EditorNumberRow(title: "透明度", value: Binding(get: { (layer.opacity * 100).rounded() },
                                                         set: { layer.opacity = min(max($0, 0), 100) / 100 }),
                            range: 0...100, step: 1, suffix: "%")
            EditorNumberRow(title: "旋轉", value: $layer.rotation, range: -180...180, step: 1)
            // 文字排到多寬開始縮小或截斷（框寬）。單位和位置欄相同，步進跟著位置的「移動步進」。
            if [.text, .date, .time, .liveText].contains(layer.type) {
                EditorStepperRow(title: "可用寬度", value: availableWidth, range: Self.availableWidthRange, step: nudgeStep)
            }
            effects
        }
    }

    private func tileGrid(_ tiles: [EditorAppearanceTile]) -> some View {
        let rows = stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
        return VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    ForEach(rows[index], id: \.self) { tile in
                        Button { open(tile) } label: {
                            EditorAppearanceTileLabel(caption: tile.caption) {
                                EditorAppearanceTilePreview(tile: tile, layer: layer)
                            }
                        }
                        .buttonStyle(EditorTileButtonStyle())
                        .accessibilityLabel(tile.caption)
                    }
                }
            }
        }
    }

    private func open(_ tile: EditorAppearanceTile) {
        switch tile {
        case .shape: openStyle?(.shape)
        case .fill: openStyle?(.fill)
        case .text: openStyle?(.text)
        case .corner: openStyle?(.corner)
        case .progressStyle: openStyle?(.progress)
        case .chartStyle: openStyle?(.chart)
        case .color(let color):
            let main = color.keyPath == \FormlessLayer.colorHex
            let automatic = main && layer.editorSupportsAutomaticColor
            // 文字類與圖示的主要顏色可以設條件顏色（色塊在填色面板設）。
            let rules = main && layer.editorSupportsColorRules && layer.type != .shape
            openColor?(EditorColorPanelRequest(
                title: color.title, supportsOpacity: true,
                layerID: layer.id, keyPath: color.keyPath, fallback: color.fallback,
                automatic: automatic,
                rulesLayerID: rules ? layer.id : nil, rulesFallback: color.fallback))
        }
    }

    /// 外框與陰影：和「版面」的對齊按鈕同一種灰色按鈕，右邊小字是目前的寬度／半徑（沒有就是「無」）。
    private var effects: some View {
        HStack(spacing: 8) {
            effectButton("外框", value: Self.effectValue(layer.strokeWidth)) { openStyle?(.stroke) }
            effectButton("陰影", value: Self.effectValue(layer.shadowRadius)) { openStyle?(.shadow) }
            effectButton("效果", value: Self.otherEffects(layer)) { openStyle?(.effects) }
        }
        .padding(.vertical, 4)
    }

    /// 效果按鈕右邊的小字：有設定幾項就寫幾項，沒有是「無」。
    static func otherEffects(_ layer: FormlessLayer) -> String {
        let count = [(layer.blur ?? 0) > 0, layer.blendMode.map { $0 != "normal" } ?? false,
                     layer.flipHorizontal == true || layer.flipVertical == true].filter { $0 }.count
        return count == 0 ? "無" : "\(count)"
    }

    private func effectButton(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.primary)
                Text(value).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    /// 可用寬度的範圍：和「大小」一樣至少 1 格；上限是畫布寬的 10 倍。
    private static let availableWidthRange: ClosedRange<Double> = 1...16000

    /// 可用寬度：只改框寬，字級不變（不走「大小」的等比縮放）。依對齊固定一邊，已經放得下的文字不會移動：
    /// 靠左固定左緣、靠右固定右緣、置中固定中心。有旋轉時沿著文字的方向固定，同樣不動。
    private var availableWidth: Binding<Double> {
        Binding(
            get: { (layer.frame.width * 1600).rounded() },
            set: { value in
                var next = layer
                let old = next.frame
                let width = min(max(EditorNumbers.integer(value), Self.availableWidthRange.lowerBound),
                                Self.availableWidthRange.upperBound) / 1600
                guard width != old.width else { return }
                // 以畫布高為 1 的座標算（畫布寬 = 寬高比），旋轉後的方向才正確。
                let aspect = Double(family.aspectRatio)
                let shift: Double
                switch next.alignment {
                case "trailing": shift = -(width - old.width) * aspect / 2
                case "center": shift = 0
                default: shift = (width - old.width) * aspect / 2
                }
                let angle = next.rotation * .pi / 180
                let centerX = (old.x + old.width / 2) * aspect + shift * cos(angle)
                let centerY = old.y + old.height / 2 + shift * sin(angle)
                next.frame = FormlessFrame(x: centerX / aspect - width / 2, y: centerY - old.height / 2,
                                           width: width, height: old.height)
                layer = next
            }
        )
    }

    static func effectValue(_ value: Double?) -> String {
        guard let value, value > 0 else { return "無" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 共用的小控制項

/// 二選一、三選一的按鈕：和對齊按鈕同一種灰色；選中的是淡藍底、藍字。
struct EditorChoiceButton<Label: View>: View {
    let selected: Bool
    var height: CGFloat = FormlessDesign.Size.control
    let action: () -> Void
    let label: Label

    init(selected: Bool, height: CGFloat = FormlessDesign.Size.control, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.selected = selected
        self.height = height
        self.action = action
        self.label = label()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        Button(action: action) {
            label
                .font(.subheadline)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(selected ? AnyShapeStyle(FormlessDesign.Palette.selectionFill) : AnyShapeStyle(.quaternary), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension EditorChoiceButton where Label == Text {
    init(_ title: String, selected: Bool, height: CGFloat = 36, action: @escaping () -> Void) {
        self.init(selected: selected, height: height, action: action) { Text(title) }
    }
}

/// 橫向的方向鍵盤，和「版面」的位置／大小方塊同一種樣子：左右兩顆玻璃鍵加減（按住連續），
/// 中間的玻璃方塊寫著名稱與數字，點一下直接輸入。寬度和「版面」的方塊一樣（兩個並排剛好是一張卡片寬）。
struct EditorStepPad: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var suffix = ""
    var decrease = "minus"
    var increase = "plus"
    @State private var focusTrigger = 0

    static let satellite: CGFloat = 38
    static let hubWidth: CGFloat = 80
    static let gap: CGFloat = 4
    static var width: CGFloat { satellite * 2 + hubWidth + gap * 2 }

    var body: some View {
        HStack(spacing: Self.gap) {
            RepeatingPadButton(symbol: decrease, diameter: Self.satellite) { change(-1) }
                .accessibilityLabel(title + "減少")
            hub
            RepeatingPadButton(symbol: increase, diameter: Self.satellite) { change(1) }
                .accessibilityLabel(title + "增加")
        }
        .frame(width: Self.width, height: Self.satellite)
    }

    private var hub: some View {
        let shape = RoundedRectangle(cornerRadius: (Self.satellite * 0.3).rounded(), style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            FormlessNumberField(value: value, format: { format($0) }, allowsDecimal: step < 1,
                                allowsNegative: range.lowerBound < 0, focusTrigger: focusTrigger) { entered in
                value = clamp(entered)
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .fixedSize()
        }
        .frame(width: Self.hubWidth, height: Self.satellite)
        .contentShape(shape)
        .formlessGlass(.regular, in: shape)
        // 整顆方塊都是輸入範圍：點名稱或空白處一樣開始輸入；鍵盤開著時點它不收鍵盤。
        .background(FormlessInputArea())
        .onTapGesture { focusTrigger += 1 }
        .accessibilityElement(children: .contain)
    }

    private func format(_ number: Double) -> String {
        (step < 1 ? String(format: "%.1f", number) : String(Int(number.rounded()))) + suffix
    }

    private func clamp(_ number: Double) -> Double { min(max(number, range.lowerBound), range.upperBound) }

    /// 對齊步進的倍數（和 −/＋ 數字框相同）：2.37 按 ＋（步進 0.5）得到 2.5。每次都讀目前的值，按住連續才會累加。
    private func change(_ direction: Double) {
        let current = value
        let snapped = (current / step).rounded(direction > 0 ? .down : .up) * step
        let next = abs(snapped - current) < step * 0.001 ? current + direction * step : snapped + direction * step
        value = clamp((next / step).rounded() * step)
    }
}

// MARK: - 文字細項的規格

/// 各種圖層的文字細項：文字類有字級、字重、字型、對齊、過長時；元件只有字級與（日期）字重。
struct EditorTextPanelSpec {
    let sizeRange: ClosedRange<Double>?
    let sizeStep: Double
    let sizeFallback: Double
    let hasWeight: Bool
    let weightFallback: String
    let isText: Bool

    init(layer: FormlessLayer) {
        switch layer.type {
        case .text, .date, .time, .liveText:
            sizeRange = 6...120; sizeStep = 1; sizeFallback = 22; hasWeight = true; weightFallback = "regular"; isText = true
        case .calendarGrid:
            sizeRange = 5...60; sizeStep = 0.5; sizeFallback = 12; hasWeight = true; weightFallback = "medium"; isText = false
        case .reminderList, .weatherForecast:
            sizeRange = 5...60; sizeStep = 0.5; sizeFallback = 12; hasWeight = false; weightFallback = "regular"; isText = false
        case .calendar:
            sizeRange = nil; sizeStep = 1; sizeFallback = 12; hasWeight = true; weightFallback = "medium"; isText = false
        default:
            sizeRange = nil; sizeStep = 1; sizeFallback = 12; hasWeight = false; weightFallback = "regular"; isText = false
        }
    }
}

extension FormlessFillStyle {
    /// 填色面板的選項順序：單色、直線漸層、放射漸層。
    static var panelOrder: [FormlessFillStyle] { [.solid, .linear, .radial] }
}

// MARK: - 細項面板

/// 點外觀方塊後從下方滑出的面板（和「位置與大小」「顏色」同一種：螢幕 60% 高、畫布不擋、點外面關閉）。
/// 有顏色的細項（填色、外框、陰影）下半部就是調色盤，上面放這一項的其他設定；其他細項是一張卡片。
struct EditorStylePanel: View {
    @ObservedObject var model: EditorModel
    let request: EditorStylePanelRequest
    let height: CGFloat
    var shown = true
    let onEyedropper: (@escaping (UIColor) -> Void) -> Void
    let onClose: () -> Void
    @State private var selectedStop = 0
    /// 單色時調色盤改哪個顏色：nil 是平常的顏色，數字是第幾條條件顏色。
    @State private var selectedRule: Int?
    /// 字型選單的「管理字型…」。
    @State private var showFonts = false

    private var layer: Binding<FormlessLayer> { model.layerBinding(request.layerID) }
    private var current: FormlessLayer { layer.wrappedValue }

    var body: some View {
        content
            .editorToolPanel(height: height, active: shown, onClose: onClose)
            .sheet(isPresented: $showFonts) {
                NavigationStack {
                    FormlessFontLibraryView()
                }
                .formlessSheetBackground()
            }
            // 填色面板開著時，畫布上的這個圖層顯示選中的那個顏色（條件現在不成立也一樣），看得到自己在調什麼。
            .onAppear { previewSelectedColor() }
            .onChange(of: selectedRule) { _, _ in previewSelectedColor() }
            .onDisappear { if model.colorPreview?.layerID == request.layerID { model.colorPreview = nil } }
    }

    /// 只在圖層有條件顏色時才預覽，而且值變了才寫：改 model 會讓整個編輯器重畫，打開面板的那一格不能多這一次。
    private func previewSelectedColor() {
        guard request.kind == .fill else { return }
        let next = (current.colorRules ?? []).isEmpty ? nil
            : EditorColorPreview(layerID: request.layerID, rule: EditorColorRuleRows.valid(selectedRule, in: current))
        if model.colorPreview != next { model.colorPreview = next }
    }

    @ViewBuilder private var content: some View {
        switch request.kind {
        case .fill: fillPanel
        case .stroke: strokePanel
        case .shadow: shadowPanel
        case .shape, .text, .corner, .progress, .chart, .effects: formPanel
        }
    }

    // MARK: 填色

    /// 填色：標題列中間是填色方式選單；下面一條填色條（單色是那個顏色；漸層是角度或半徑、漸層條與新增鈕），
    /// 再下面是調色盤。單色和漸層同一個版面，換填色方式時高度不變（使用者：原本三個按鈕佔空間、換一下整個面板就跳）。
    /// 單色的填色條右邊有 ＋ 可加條件顏色，每條條件在填色條下面多一列；條件只用在單色，切到漸層時收起來但會保留。
    private var fillPanel: some View {
        let gradient = current.fillStyle != .solid
        let stops = current.gradientStops ?? []
        let index = min(max(selectedStop, 0), max(stops.count - 1, 0))
        let rule = EditorColorRuleRows.valid(selectedRule, in: current)
        return EditorColorPicker(
            title: request.kind.title,
            supportsOpacity: true,
            selection: gradient ? stopColor(index)
                : (rule.map { EditorColorRuleRows.colorBinding(layer, $0) } ?? hexColorBinding(layer.colorHex, fallback: "#E6E6E8")),
            height: height,
            onEyedropper: onEyedropper,
            header: gradient
                ? AnyView(EditorFillBarRow(layer: layer, selected: $selectedStop))
                : AnyView(EditorColorRuleRows(layer: layer, selected: $selectedRule, fallback: "#E6E6E8",
                                              linkable: current.editorSupportsAutomaticColor,
                                              dataSources: EditorRuleSource.all(model), live: model.live)),
            selectionKey: gradient ? AnyHashable(index) : AnyHashable(rule.map { "rule\($0)" } ?? "solid"),
            titleContent: AnyView(EditorFillStyleMenu(layer: layer))
        )
    }

    private func stopColor(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let stops = layer.wrappedValue.gradientStops ?? []
                return Color(formlessHex: stops.indices.contains(index) ? stops[index].colorHex : "#000000", fallback: "#000000")
            },
            set: { color in
                var stops = layer.wrappedValue.gradientStops ?? []
                guard stops.indices.contains(index) else { return }
                stops[index].colorHex = color.formlessHex
                layer.wrappedValue.gradientStops = stops
            }
        )
    }

    // MARK: 外框、陰影

    private var strokePanel: some View {
        EditorColorPicker(
            title: request.kind.title,
            supportsOpacity: true,
            selection: hexColorBinding(layer.strokeColorHex, fallback: "#00000033"),
            height: height,
            onEyedropper: onEyedropper,
            header: AnyView(
                VStack(spacing: 12) {
                    EditorStepPad(title: "寬度", value: strokeWidth, range: 0...12, step: 0.5)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        EditorChoiceButton("實線", selected: current.strokeDash != true) { layer.wrappedValue.strokeDash = nil }
                        EditorChoiceButton("虛線", selected: current.strokeDash == true) { layer.wrappedValue.strokeDash = true }
                    }
                }
            )
        )
    }

    private var shadowPanel: some View {
        EditorColorPicker(
            title: request.kind.title,
            supportsOpacity: true,
            selection: hexColorBinding(layer.shadowColorHex, fallback: "#00000033"),
            height: height,
            onEyedropper: onEyedropper,
            header: AnyView(
                HStack(spacing: 12) {
                    EditorStepPad(title: "半徑", value: shadowRadius, range: 0...20, step: 0.5)
                    EditorStepPad(title: "位移", value: doubleBinding(layer.shadowOffsetY, fallback: 0), range: -20...20, step: 0.5)
                }
                .frame(maxWidth: .infinity)
            )
        )
    }

    /// 外框寬度：第一次加上外框時給預設的淡黑色（和原本相同）。
    private var strokeWidth: Binding<Double> {
        Binding(
            get: { layer.wrappedValue.strokeWidth ?? 0 },
            set: { width in
                var next = layer.wrappedValue
                next.strokeWidth = width
                if width > 0 && next.strokeColorHex == nil { next.strokeColorHex = "#00000033" }
                layer.wrappedValue = next
            }
        )
    }

    private var shadowRadius: Binding<Double> {
        Binding(
            get: { layer.wrappedValue.shadowRadius ?? 0 },
            set: { radius in
                var next = layer.wrappedValue
                next.shadowRadius = radius
                if radius > 0 && next.shadowColorHex == nil { next.shadowColorHex = "#00000033" }
                layer.wrappedValue = next
            }
        )
    }

    // MARK: 形狀、文字、圓角（一張卡片）

    private var formPanel: some View {
        Form {
            Section { formRows }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(FormlessDesign.Space.cardGap)
        .contentMargins(.horizontal, BatchPositionPanel.margin, for: .scrollContent)
        // 和「位置與大小」面板相同：卡片直接接在標題列下面，底部留一個邊距加螢幕底部安全區。
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, BatchPositionPanel.margin + FormlessSafeArea.bottom, for: .scrollContent)
        .scrollIndicators(.hidden)
        .background(FormlessFixedPanelScroll())
        .safeAreaBar(edge: .top, spacing: 0) {
            Text(request.kind.title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: BatchPositionPanel.titleBar)
        }
    }

    private var padInsets: EdgeInsets {
        EdgeInsets(top: EditorAppearanceMetrics.rowInset, leading: EditorAppearanceMetrics.rowInset,
                   bottom: EditorAppearanceMetrics.rowInset, trailing: EditorAppearanceMetrics.rowInset)
    }

    @ViewBuilder private var formRows: some View {
        switch request.kind {
        case .shape: shapeRows
        case .text: textRows
        case .progress: EditorProgressStyleRows(layer: layer, padInsets: padInsets)
        case .chart: EditorChartStyleRows(layer: layer, padInsets: padInsets)
        case .effects: effectRows
        default: cornerRows
        }
    }

    @ViewBuilder private var shapeRows: some View {
        // 20 種形狀一列五個、排四列，不放文字（使用者選的排法），面板不用捲就看得完。
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(FormlessShapeKind.allCases) { kind in
                Button { setShape(kind) } label: {
                    EditorAppearanceTileLabel(caption: nil, selected: current.shapeKind == kind, previewHeight: 32) {
                        let size = kind.editorGlyphSize(wide: CGSize(width: 34, height: 26), square: 32)
                        FormlessLayerShape(kind: kind, cornerRadius: 6)
                            .stroke(Color.primary, lineWidth: 2)
                            .padding(1)
                            .frame(width: size.width, height: size.height)
                    }
                }
                .buttonStyle(EditorTileButtonStyle())
                .accessibilityLabel(kind.displayName)
                .accessibilityAddTraits(current.shapeKind == kind ? .isSelected : [])
            }
        }
        .listRowInsets(padInsets)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        // 圓角只對矩形有意義；圓形與膠囊本身就是圓的，四角星沒有圓角。
        if current.shapeKind == .rectangle {
            EditorStepPad(title: "圓角", value: doubleBinding(layer.cornerRadius, fallback: 0), range: 0...80, step: 1)
                .frame(maxWidth: .infinity)
                .listRowInsets(padInsets)
                // 列裡的文字在方塊中間，系統會把分隔線對齊到那裡（只畫半條）；改成從卡片內容的左緣開始。
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }

    /// 切成圓形的當下就把框修成正圓（以短邊為直徑），畫面立刻是圓、大小方塊立刻只剩直徑；矩形存 nil。
    private func setShape(_ kind: FormlessShapeKind) {
        var next = layer.wrappedValue
        next.shape = kind == .rectangle ? nil : kind.rawValue
        if kind == .circle { next.frame = model.circleFrame(next.frame) }
        layer.wrappedValue = next
    }

    @ViewBuilder private var textRows: some View {
        let spec = EditorTextPanelSpec(layer: current)
        if let range = spec.sizeRange {
            EditorStepPad(title: "字級", value: doubleBinding(layer.fontSize, fallback: spec.sizeFallback), range: range,
                          step: spec.sizeStep)
                .frame(maxWidth: .infinity)
                .listRowInsets(padInsets)
                // 列裡的文字在方塊中間，系統會把分隔線對齊到那裡（只畫半條）；改成從卡片內容的左緣開始。
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        if spec.hasWeight || spec.isText {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    // 匯入的字型粗細由字型檔決定，不顯示粗細選單。
                    let customFont = FormlessFontLibrary.postScriptName(fromFamily: current.fontFamily) != nil
                    if spec.hasWeight && !customFont {
                        menuButton(icon: "bold", value: optionName(formlessFontWeightOptions, current.fontWeight ?? spec.weightFallback),
                                   options: formlessFontWeightOptions,
                                   selection: optionalString(layer.fontWeight, fallback: spec.weightFallback))
                    }
                    if spec.isText {
                        let family = optionalString(layer.fontFamily, fallback: "system")
                        menuButton(icon: "textformat",
                                   value: FormlessFontLibrary.displayName(forFamily: current.fontFamily)
                                       ?? optionName(formlessFontFamilyOptions, current.fontFamily ?? "system"),
                                   options: formlessFontFamilyOptions,
                                   selection: family,
                                   extra: {
                                       // 匯入的字型與「管理字型…」（2026-10）。
                                       FormlessFontMenuItems.menuElements(current: family.wrappedValue,
                                                                          select: { family.wrappedValue = $0 },
                                                                          manage: { showFonts = true })
                                   })
                    }
                }
                if spec.isText {
                    let alignment = current.alignment ?? "leading"
                    HStack(spacing: 8) {
                        ForEach(Self.alignments, id: \.value) { option in
                            EditorChoiceButton(selected: alignment == option.value, action: { layer.wrappedValue.alignment = option.value }) {
                                Image(systemName: option.symbol).font(.system(size: 16, weight: .medium))
                            }
                            .accessibilityLabel(option.name)
                        }
                    }
                    let shrinks = current.autoShrink ?? true
                    HStack(spacing: 8) {
                        EditorChoiceButton("縮小文字", selected: shrinks) { layer.wrappedValue.autoShrink = true }
                        EditorChoiceButton("以省略號截斷", selected: !shrinks) { layer.wrappedValue.autoShrink = false }
                    }
                    // 行數：一行（原本的樣子）、兩行、三行、不限；多行時框的高度決定能放幾行。
                    let lines = current.textLineLimit
                    HStack(spacing: 8) {
                        ForEach([(1, "1 行"), (2, "2 行"), (3, "3 行"), (0, "不限")], id: \.0) { option in
                            EditorChoiceButton(option.1, selected: lines == option.0) {
                                layer.wrappedValue.lineLimit = option.0 == 1 ? nil : option.0
                            }
                        }
                    }
                    // 曲線文字（2026-10）：沿框的內切圓排，上弧或下弧。
                    if current.type == .text { EditorTextArcRow(layer: layer) }
                    HStack(spacing: 8) {
                        EditorChoiceButton(selected: current.italic == true, action: { layer.wrappedValue.italic = current.italic == true ? nil : true }) {
                            Image(systemName: "italic").font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("斜體")
                        EditorChoiceButton(selected: current.underline == true, action: { layer.wrappedValue.underline = current.underline == true ? nil : true }) {
                            Image(systemName: "underline").font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("底線")
                        EditorChoiceButton(selected: current.strikethrough == true, action: { layer.wrappedValue.strikethrough = current.strikethrough == true ? nil : true }) {
                            Image(systemName: "strikethrough").font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("刪除線")
                    }
                }
            }
            .padding(.vertical, 4)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        if spec.isText {
            HStack(spacing: 12) {
                EditorStepPad(title: "字距", value: optionalDouble(layer.tracking), range: -5...30, step: 0.5)
                EditorStepPad(title: "行距", value: optionalDouble(layer.lineSpacing), range: 0...40, step: 1)
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(padInsets)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }

    /// 沒設定（nil）顯示 0，改回 0 時存 nil：舊設計不會多出任何設定。
    private func optionalDouble(_ binding: Binding<Double?>) -> Binding<Double> {
        Binding(get: { binding.wrappedValue ?? 0 }, set: { binding.wrappedValue = $0 == 0 ? nil : $0 })
    }

    /// 效果：模糊、混合模式、翻轉。
    @ViewBuilder private var effectRows: some View {
        EditorStepPad(title: "模糊", value: optionalDouble(layer.blur), range: 0...30, step: 0.5)
            .frame(maxWidth: .infinity)
            .listRowInsets(padInsets)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        let blend = FormlessBlendOption(rawValue: current.blendMode ?? "") ?? .normal
        menuButton(icon: "square.2.layers.3d", value: blend.displayName,
                   options: FormlessBlendOption.allCases.map { FormlessNamedOption(id: $0.rawValue, displayName: $0.displayName) },
                   selection: Binding(get: { blend.rawValue },
                                      set: { layer.wrappedValue.blendMode = $0 == FormlessBlendOption.normal.rawValue ? nil : $0 }))
            .padding(.vertical, 4)
        HStack(spacing: 8) {
            EditorChoiceButton(selected: current.flipHorizontal == true,
                               action: { layer.wrappedValue.flipHorizontal = current.flipHorizontal == true ? nil : true }) {
                Label("水平翻轉", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.subheadline)
            }
            EditorChoiceButton(selected: current.flipVertical == true,
                               action: { layer.wrappedValue.flipVertical = current.flipVertical == true ? nil : true }) {
                Label("垂直翻轉", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private static let alignments: [(value: String, symbol: String, name: String)] = [
        ("leading", "text.alignleft", "靠左"), ("center", "text.aligncenter", "置中"), ("trailing", "text.alignright", "靠右")
    ]

    @ViewBuilder private var cornerRows: some View {
        if current.type == .calendar {
            EditorStepPad(title: "圓角", value: doubleBinding(layer.cornerRadius, fallback: 11), range: 0...50, step: 1, suffix: "%")
                .frame(maxWidth: .infinity)
                .listRowInsets(padInsets)
                // 列裡的文字在方塊中間，系統會把分隔線對齊到那裡（只畫半條）；改成從卡片內容的左緣開始。
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } else {
            if let radii = current.cornerRadii, radii.count == 4 {
                // 四個角分開（2026-10）：左上、右上、左下、右下兩兩一列，和角的位置一樣。
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        EditorStepPad(title: "左上", value: cornerBinding(0), range: 0...80, step: 1)
                        EditorStepPad(title: "右上", value: cornerBinding(1), range: 0...80, step: 1)
                    }
                    HStack(spacing: 12) {
                        EditorStepPad(title: "左下", value: cornerBinding(3), range: 0...80, step: 1)
                        EditorStepPad(title: "右下", value: cornerBinding(2), range: 0...80, step: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(padInsets)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            } else {
                EditorStepPad(title: "圓角", value: doubleBinding(layer.cornerRadius, fallback: 0), range: 0...80, step: 1)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(padInsets)
                    // 列裡的文字在方塊中間，系統會把分隔線對齊到那裡（只畫半條）；改成從卡片內容的左緣開始。
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            // 只有矩形與圖片有四個角。
            if current.type == .image || current.type == .remoteImage || (current.type == .shape && current.shapeKind == .rectangle) {
                Toggle("四個角分開", isOn: Binding(
                    get: { current.cornerRadii != nil },
                    set: { on in
                        // 打開時四個角先等於原本的圓角；關掉時留下左上角的值當作統一的圓角。
                        let base = current.cornerRadius ?? 0
                        let first = current.cornerRadii?.first
                        var next = current
                        next.cornerRadii = on ? [base, base, base, base] : nil
                        if !on, let first { next.cornerRadius = first }
                        layer.wrappedValue = next
                    }))
            }
        }
    }

    /// 四個角分開時第 index 個角（左上、右上、右下、左下）。
    private func cornerBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let radii = current.cornerRadii ?? [0, 0, 0, 0]
                return radii.indices.contains(index) ? radii[index] : 0
            },
            set: { value in
                var radii = current.cornerRadii ?? [0, 0, 0, 0]
                guard radii.indices.contains(index) else { return }
                radii[index] = value
                layer.wrappedValue.cornerRadii = radii
            })
    }

    private func optionName(_ options: [FormlessNamedOption], _ id: String) -> String {
        options.first { $0.id == id }?.displayName ?? id
    }

    /// 選單鈕：和對齊按鈕同一種灰色，左邊小圖示、中間目前的值、右邊上下箭頭。自己畫的彈出清單（不用系統 Menu，見 `FormlessOptionMenu`）。
    private func menuButton(icon: String, value: String, options: [FormlessNamedOption], selection: Binding<String>,
                            extra: (() -> [UIMenuElement])? = nil) -> some View {
        FormlessOptionMenu(options: options.map { FormlessMenuOption(id: AnyHashable($0.id), title: $0.displayName) },
                           selection: AnyHashable(selection.wrappedValue),
                           onSelect: { id in if let next = id.base as? String { selection.wrappedValue = next } },
                           extra: extra) {
            HStack(spacing: 6) {
                // 圖示和旁邊的文字同字級（subheadline）。textformat 這類圖示會依語系換字（繁中是「格式」），固定用英文字形。
                Image(systemName: icon)
                    .environment(\.locale, Locale(identifier: "en_US"))
                Text(value)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: FormlessDesign.Size.control)
            .formlessGrayBox()
            .contentShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous))
        }
    }
}

/// 填色面板標題列中間的選單：單色、直線漸層、放射漸層。
struct EditorFillStyleMenu: View {
    let layer: Binding<FormlessLayer>

    var body: some View {
        let style = layer.wrappedValue.fillStyle
        Menu {
            Picker("填色方式", selection: Binding(
                get: { style },
                set: { option in
                    guard layer.wrappedValue.fillStyle != option else { return }
                    layer.wrappedValue.editorSetFill(option)
                }
            )) {
                ForEach(FormlessFillStyle.panelOrder) { Text($0.displayName).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(style.displayName).font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // 選單預設用強調色（藍）畫標籤；標題維持一般文字色，和其他面板的標題一樣。
        .tint(.primary)
        .accessibilityLabel("填色方式")
        .accessibilityValue(style.displayName)
    }
}

/// 填色條：單色是一條那個顏色的條；漸層是漸層條（圓鈕在條上，點選、橫拖改位置、往下拖離刪除）與新增鈕。
/// 兩種都一樣高，換填色方式時下面的調色盤不會跳。選中那一點的顏色由下面的調色盤調。
struct EditorFillBarRow: View {
    let layer: Binding<FormlessLayer>
    @Binding var selected: Int
    static let height: CGFloat = 32

    private var stops: Binding<[FormlessGradientStop]> {
        Binding(get: { layer.wrappedValue.gradientStops ?? [] }, set: { layer.wrappedValue.gradientStops = $0 })
    }

    var body: some View {
        let value = layer.wrappedValue
        HStack(spacing: 8) {
            switch value.fillStyle {
            case .solid:
                EditorSolidFillBar(hex: value.colorHex, automatic: value.editorUsesAutomaticColor)
                if value.editorSupportsAutomaticColor { EditorAutomaticColorLink(layer: layer) }
            case .linear, .radial:
                // 角度（放射是半徑）是這個漸層的設定，放在漸層條同一列的最前面（使用者：放在標題列不合邏輯）。
                if value.fillStyle == .linear { angleControl(value) } else { radiusControl(value) }
                EditorGradientBar(stops: stops, selected: $selected)
                Button(action: addStop) {
                    Image(systemName: "plus")
                        .font(FormlessDesign.Symbol.smallCircle)
                        .foregroundStyle(FormlessDesign.Palette.accent)
                        .frame(width: Self.height, height: Self.height)
                        .background(FormlessDesign.Palette.tintFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新增顏色點")
            }
        }
        .frame(height: Self.height)
    }

    /// 直線漸層的角度：圓盤（拖著轉、點一下指向那個方向）與角度數字，放在一顆膠囊裡。
    private func angleControl(_ value: FormlessLayer) -> some View {
        capsule {
            EditorAngleDial(angle: doubleBinding(layer.gradientAngle, fallback: 180), size: 24)
            FormlessNumberField(value: (value.gradientAngle ?? 180).rounded(), format: { "\(Int($0))°" },
                                allowsDecimal: false, allowsNegative: false) { entered in
                layer.wrappedValue.gradientAngle = (entered.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            }
            .font(.subheadline.monospacedDigit())
            .fixedSize()
            .frame(minWidth: 38)
            .accessibilityLabel("角度")
        }
    }

    /// 放射漸層的半徑（10–200%）。
    private func radiusControl(_ value: FormlessLayer) -> some View {
        capsule {
            Image(systemName: "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            FormlessNumberField(value: ((value.gradientRadius ?? 1) * 100).rounded(), format: { "\(Int($0))%" },
                                allowsDecimal: false, allowsNegative: false) { entered in
                layer.wrappedValue.gradientRadius = min(max(entered, 10), 200) / 100
            }
            .font(.subheadline.monospacedDigit())
            .fixedSize()
            .frame(minWidth: 42)
            .accessibilityLabel("半徑")
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: Self.height)
            // 輸入欄一律灰底、無框（和面板裡其他數字欄同一種底）；在 32 高的條列裡用膠囊。
            .background(.quaternary, in: Capsule())
            // 整顆膠囊都算輸入範圍：鍵盤開著時點它不收鍵盤。
            .background(FormlessInputArea())
            .fixedSize()
    }

    /// 新顏色點放在最大空隙的中間，顏色取那個位置原本的顏色（畫面不變），並選取它。
    private func addStop() {
        var list = layer.wrappedValue.gradientStops ?? []
        let sorted = list.sorted { $0.location < $1.location }
        var best = (start: 0.0, gap: -1.0)
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.location - a.location > best.gap {
            best = (a.location, b.location - a.location)
        }
        let location = best.gap > 0 ? ((best.start + best.gap / 2) * 100).rounded() / 100 : 0.5
        list.append(FormlessGradientStop(colorHex: EditorGradientBar.color(at: location, in: list), location: location))
        layer.wrappedValue.gradientStops = list
        selected = list.count - 1
    }
}

/// 單色的填色條：棋盤格上畫那個顏色（看得出不透明度）；跟隨資料顏色時畫連結符號。
struct EditorSolidFillBar: View {
    let hex: String?
    let automatic: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        ZStack {
            if automatic {
                Color(uiColor: .systemGray6)
                Image(systemName: "link")
                    .font(FormlessDesign.Symbol.smallCircle)
                    .foregroundStyle(.secondary)
            } else {
                EditorCheckerboard()
                Color(formlessHex: hex, fallback: "#E6E6E8")
            }
        }
        .frame(height: 28)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FormlessDesign.Palette.hairline, lineWidth: FormlessDesign.Stroke.hairline))
        .accessibilityHidden(true)
    }
}

/// 「跟隨資料顏色」連結鈕（單色且綁了行程或提醒事項）：放在填色條右邊，位置和漸層的新增鈕相同。
struct EditorAutomaticColorLink: View {
    let layer: Binding<FormlessLayer>

    var body: some View {
        let on = layer.wrappedValue.editorUsesAutomaticColor
        Button {
            editorAutomaticColorBinding(layer).wrappedValue = !on
        } label: {
            Image(systemName: "link")
                .font(FormlessDesign.Symbol.smallCircle)
                .foregroundStyle(on ? Color.white : Color.accentColor)
                .frame(width: EditorFillBarRow.height, height: EditorFillBarRow.height)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(FormlessDesign.Palette.tintFill), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跟隨資料顏色")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - 條件顏色

extension FormlessLayer {
    /// 主要顏色可以設條件：文字類與圖示在「顏色」面板，色塊在「填色」面板（單色時）。
    var editorSupportsColorRules: Bool {
        [.shape, .text, .date, .time, .liveText, .symbol, .progress, .chart].contains(type) && !group
    }
}

/// 條件顏色可以比的資料（舊的五項以外）。
struct EditorRuleSource: Identifiable {
    let id: String
    let title: String
    let binding: FormlessBinding

    /// 我的資料裡的數字，與這份設計用到的來源裡的數字欄位。
    @MainActor static func all(_ model: EditorModel) -> [EditorRuleSource] {
        var result: [EditorRuleSource] = []
        for variable in model.document.variables ?? [] where variable.kind == .number {
            result.append(EditorRuleSource(id: "var:" + variable.id.uuidString, title: variable.name, binding: .variable(variable.id)))
        }
        for source in FormlessDataCoordinator.sources(usedBy: model.document) {
            guard let provider = FormlessProviders.provider(source.provider) else { continue }
            let name = EditorDataLabels.name(of: source)
            for field in provider.fields(for: source, snapshot: model.live.snapshot(for: source)) where field.kind == .number {
                result.append(EditorRuleSource(id: "src:" + source.id + "." + field.id, title: name + "・" + field.name,
                                               binding: FormlessBinding(source: source.id, field: field.id)))
            }
        }
        return result
    }
}

/// 條件顏色的編輯列，放在填色、顏色面板的調色盤上方（使用者核准的設計，2026-09-27）：
/// 第一列是平常的顏色條與 ＋（新增條件）；每條條件一列〔資料〕〔比較〕〔數值〕〔這條的顏色〕〔−〕。
/// 點哪一條顏色條，下面的調色盤就改那個顏色，選中的有藍框（和漸層選中的顏色點一樣）。
/// 最多兩條（面板不捲動，每多一條調色盤就矮一列）；滿了 ＋ 變淡、按不下去，位置不動。
struct EditorColorRuleRows: View {
    let layer: Binding<FormlessLayer>
    /// 調色盤改哪個顏色：nil 是平常的顏色，數字是第幾條條件。
    @Binding var selected: Int?
    /// 新增條件時先用平常的顏色；平常的顏色沒設定或跟隨資料顏色時用這個。
    let fallback: String
    /// 色塊綁了行程或提醒事項時，平常的顏色條右邊有「跟隨資料顏色」連結鈕。
    var linkable = false
    /// 條件可以比的其他資料：我的資料、這份設計用到的數字（2026-10 起）。
    var dataSources: [EditorRuleSource] = []
    var live = FormlessLiveData()
    /// 打開選擇資料面板：色階的數字、取用資料的顏色（2026-10）。
    var openData: ((EditorDataPanelRequest) -> Void)? = nil

    private static let height = EditorFillBarRow.height
    /// 色階兩端的顏色點在 selected 裡的編號（條件是 0、1；色階是 1000 起）。
    private static let scaleBase = 1000

    static func scaleStop(_ index: Int?) -> Int? {
        guard let index, index >= scaleBase else { return nil }
        return index - scaleBase
    }

    var body: some View {
        let value = layer.wrappedValue
        let rules = value.colorRules ?? []
        let current = Self.valid(selected, in: value)
        let dataColor = value.bindings?[FormlessBindableProperty.color.rawValue]
        let hasExtras = !rules.isEmpty || value.colorScale != nil
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                EditorColorChoiceBar(hex: value.colorHex, automatic: value.editorUsesAutomaticColor,
                                     selected: hasExtras && current == nil) { selected = nil }
                if linkable { EditorAutomaticColorLink(layer: layer) }
                addMenu(rules: rules, value: value, dataColor: dataColor)
            }
            .frame(height: Self.height)
            if let dataColor {
                // 取用資料的顏色（行程的行事曆顏色…）：拿得到就用它，拿不到用上面平常的顏色。
                HStack(spacing: 8) {
                    dataChip(EditorDataLabels.label(for: dataColor, live: live).title, prefix: "資料顏色") {
                        open(.color, kinds: [.color])
                    }
                    Spacer(minLength: 0)
                    circleButton("minus", enabled: true) { setDataColor(nil) }
                        .accessibilityLabel("不取用資料的顏色")
                }
                .frame(height: Self.height)
            }
            if let scale = value.colorScale {
                scaleRows(scale, current: current)
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack(spacing: 8) {
                    sourceMenu(index, rule)
                    comparisonMenu(index, rule)
                    valueField(index, rule)
                    EditorColorChoiceBar(hex: rule.colorHex, selected: current == index) { selected = index }
                    circleButton("minus", enabled: true) { removeRule(index) }
                        .accessibilityLabel("刪除條件")
                }
                .frame(height: Self.height)
            }
        }
    }

    /// 選取的條件（或色階的顏色點）還在就回傳它，否則是 nil（例如復原把條件拿掉了）。
    static func valid(_ selected: Int?, in layer: FormlessLayer) -> Int? {
        if let stop = scaleStop(selected) {
            return (layer.colorScale?.stops ?? []).indices.contains(stop) ? selected : nil
        }
        guard let selected, (layer.colorRules ?? []).indices.contains(selected) else { return nil }
        return selected
    }

    /// 第幾條條件的顏色（給調色盤用）；色階的顏色點也是。
    static func colorBinding(_ layer: Binding<FormlessLayer>, _ index: Int) -> Binding<Color> {
        if let stop = scaleStop(index) {
            return Binding(
                get: {
                    let stops = layer.wrappedValue.colorScale?.stops ?? []
                    return Color(formlessHex: stops.indices.contains(stop) ? stops[stop].colorHex : nil, fallback: "#000000")
                },
                set: { color in
                    guard var scale = layer.wrappedValue.colorScale, scale.stops.indices.contains(stop) else { return }
                    scale.stops[stop].colorHex = color.formlessHex
                    layer.wrappedValue.colorScale = scale
                }
            )
        }
        return Binding(
            get: {
                let rules = layer.wrappedValue.colorRules ?? []
                return Color(formlessHex: rules.indices.contains(index) ? rules[index].colorHex : nil, fallback: "#000000")
            },
            set: { color in
                var rules = layer.wrappedValue.colorRules ?? []
                guard rules.indices.contains(index) else { return }
                rules[index].colorHex = color.formlessHex
                layer.wrappedValue.colorRules = rules
            }
        )
    }

    /// 數值最多兩位小數，去掉尾巴的 0：1.04、3.1、50。
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e12 { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private func update(_ index: Int, _ change: (inout FormlessColorRule) -> Void) {
        var rules = layer.wrappedValue.colorRules ?? []
        guard rules.indices.contains(index) else { return }
        change(&rules[index])
        layer.wrappedValue.colorRules = rules
    }

    /// 新條件：年度百分比 ≥ 50%，顏色先和平常一樣；新增後選它，下面的調色盤直接改它的顏色。
    private func addRule() {
        let value = layer.wrappedValue
        var rules = value.colorRules ?? []
        guard rules.count < FormlessColorRule.maxCount else { return }
        let base = value.editorUsesAutomaticColor ? fallback : (value.colorHex ?? fallback)
        rules.append(FormlessColorRule(source: .yearPercent, comparison: .atLeast, value: 50, colorHex: base))
        layer.wrappedValue.colorRules = rules
        selected = rules.count - 1
    }

    // MARK: 色階與資料顏色（2026-10）

    /// ＋：新增條件、依數值漸變（色階）、取用資料的顏色。
    private func addMenu(rules: [FormlessColorRule], value: FormlessLayer, dataColor: FormlessBinding?) -> some View {
        let canAddRule = rules.count < FormlessColorRule.maxCount
        let canScale = value.colorScale == nil && openData != nil
        let canData = dataColor == nil && openData != nil
        return Menu {
            Button("新增條件", systemImage: "line.3.horizontal.decrease", action: addRule)
                .disabled(!canAddRule)
            if openData != nil {
                Button("依數值漸變", systemImage: "slider.horizontal.below.rectangle") {
                    open(.colorScale, kinds: [.number])
                }
                .disabled(!canScale)
                Button("取用資料的顏色", systemImage: "eyedropper.halffull") {
                    open(.color, kinds: [.color])
                }
                .disabled(!canData)
            }
        } label: {
            Image(systemName: "plus")
                .font(FormlessDesign.Symbol.smallCircle)
                .foregroundStyle(canAddRule || canScale || canData ? AnyShapeStyle(FormlessDesign.Palette.accent) : AnyShapeStyle(.tertiary))
                .frame(width: Self.height, height: Self.height)
                .background(canAddRule || canScale || canData ? AnyShapeStyle(FormlessDesign.Palette.tintFill) : AnyShapeStyle(.quaternary),
                            in: Circle())
                .contentShape(Circle())
        }
        .disabled(!(canAddRule || canScale || canData))
        .accessibilityLabel("新增")
    }

    private func open(_ slot: EditorBindingSlot, kinds: Set<FormlessValueKind>) {
        openData?(EditorDataPanelRequest(layerID: layer.wrappedValue.id, target: .slot(slot), kinds: kinds))
    }

    private func setDataColor(_ binding: FormlessBinding?) {
        var bindings = layer.wrappedValue.bindings ?? [:]
        bindings[FormlessBindableProperty.color.rawValue] = binding
        layer.wrappedValue.bindings = bindings.isEmpty ? nil : bindings
    }

    /// 色階兩列：依據的數字；兩端的數值與顏色（點顏色條，下面的調色盤改它）。
    @ViewBuilder
    private func scaleRows(_ scale: FormlessColorScale, current: Int?) -> some View {
        HStack(spacing: 8) {
            dataChip(EditorDataLabels.label(for: scale.subject, live: live).title, prefix: "漸變") {
                open(.colorScale, kinds: [.number])
            }
            Spacer(minLength: 0)
            circleButton("minus", enabled: true) {
                layer.wrappedValue.colorScale = nil
                selected = nil
            }
            .accessibilityLabel("刪除漸變")
        }
        .frame(height: Self.height)
        HStack(spacing: 8) {
            ForEach(Array(scale.stops.enumerated()), id: \.offset) { index, stop in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                scaleValueField(index, stop)
                EditorColorChoiceBar(hex: stop.colorHex, selected: current == Self.scaleBase + index) {
                    selected = Self.scaleBase + index
                }
            }
        }
        .frame(height: Self.height)
    }

    private func scaleValueField(_ index: Int, _ stop: FormlessColorScaleStop) -> some View {
        FormlessNumberField(value: stop.value, format: { Self.number($0) }, allowsDecimal: true, allowsNegative: true) { entered in
            guard var scale = layer.wrappedValue.colorScale, scale.stops.indices.contains(index) else { return }
            scale.stops[index].value = (entered * 100).rounded() / 100
            layer.wrappedValue.colorScale = scale
        }
        .font(.subheadline.monospacedDigit())
        .fixedSize()
        .frame(minWidth: 36)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(.quaternary, in: Capsule())
        .background(FormlessInputArea())
        .accessibilityLabel(index == 0 ? "最小值" : "最大值")
    }

    /// 資料膠囊：「漸變・溫度」「資料顏色・行事曆顏色」；點了重新選資料。
    private func dataChip(_ title: String, prefix: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(prefix).foregroundStyle(.secondary)
                Text(title).foregroundStyle(.primary)
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func removeRule(_ index: Int) {
        var rules = layer.wrappedValue.colorRules ?? []
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        layer.wrappedValue.colorRules = rules.isEmpty ? nil : rules
        selected = nil
    }

    private func sourceMenu(_ index: Int, _ rule: FormlessColorRule) -> some View {
        let legacy = FormlessLiveSource.conditionSources.map { FormlessMenuOption(id: AnyHashable($0.rawValue), title: $0.displayName) }
        let extra = dataSources.map { FormlessMenuOption(id: AnyHashable($0.id), title: $0.title) }
        let selectedID = rule.subject.flatMap { subject in dataSources.first { $0.binding.target == subject.target }?.id } ?? rule.source
        let title = rule.subject.map { EditorDataLabels.label(for: $0, live: live).title } ?? rule.liveSource?.displayName ?? "資料"
        return FormlessOptionMenu(options: legacy + extra, selection: AnyHashable(selectedID),
                                  onSelect: { id in
                                      guard let next = id.base as? String else { return }
                                      if let source = dataSources.first(where: { $0.id == next }) {
                                          update(index) { $0.subject = source.binding; $0.source = "" }
                                      } else {
                                          update(index) { $0.subject = nil; $0.source = next }
                                      }
                                  }) {
            menuLabel(title)
        }
        .accessibilityLabel("資料")
        .accessibilityValue(title)
    }

    private func comparisonMenu(_ index: Int, _ rule: FormlessColorRule) -> some View {
        FormlessOptionMenu(options: FormlessColorComparison.allCases.map { FormlessMenuOption(id: AnyHashable($0), title: $0.symbol) },
                           selection: AnyHashable(rule.comparison),
                           onSelect: { id in if let next = id.base as? FormlessColorComparison { update(index) { $0.comparison = next } } }) {
            menuLabel(rule.comparison.symbol)
        }
        .accessibilityLabel("比較")
        .accessibilityValue(rule.comparison.symbol)
    }

    private func valueField(_ index: Int, _ rule: FormlessColorRule) -> some View {
        let unit = rule.liveSource?.conditionUnit ?? ""
        return FormlessNumberField(value: rule.value, format: { Self.number($0) + unit },
                                   allowsDecimal: true, allowsNegative: false) { entered in
            update(index) { $0.value = (entered * 100).rounded() / 100 }
        }
        .font(.subheadline.monospacedDigit())
        .fixedSize()
        .frame(minWidth: 36)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(.quaternary, in: Capsule())
        // 整顆膠囊都算輸入範圍：鍵盤開著時點它不收鍵盤。
        .background(FormlessInputArea())
        .accessibilityLabel("數值")
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.subheadline).lineLimit(1)
            // 選值的選單一律用上下箭頭（和 App 其他選值選單相同）。
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
        .fixedSize()
    }

    /// ＋ 和 − 和漸層的新增鈕同一種圓鈕；按不下去時圖示變淺灰、底色不再是主色（和其他停用的按鈕相同）。
    private func circleButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(FormlessDesign.Symbol.smallCircle)
                .foregroundStyle(enabled ? AnyShapeStyle(FormlessDesign.Palette.accent) : AnyShapeStyle(.tertiary))
                .frame(width: Self.height, height: Self.height)
                .background(enabled ? AnyShapeStyle(FormlessDesign.Palette.tintFill) : AnyShapeStyle(.quaternary), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 可以點選的顏色條（條件顏色的平常色與每條條件的顏色）：點了下面的調色盤就改這個顏色；選中的有藍框。
struct EditorColorChoiceBar: View {
    let hex: String?
    var automatic = false
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        EditorSolidFillBar(hex: hex, automatic: automatic)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
                        .strokeBorder(FormlessDesign.Palette.accent, lineWidth: FormlessDesign.Stroke.selection)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityElement()
            .accessibilityLabel("顏色")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
