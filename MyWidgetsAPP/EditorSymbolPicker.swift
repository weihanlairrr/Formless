import SwiftUI
import UIKit

// MARK: - 圖示面板（使用者核准的設計，2026-09-27）
//
// 圖示圖層不再要使用者自己打系統圖示的名稱（例如 star.fill）：「內容」只有一列顯示目前的圖示，點了從下方滑出圖示面板
// （和「位置與大小」「顏色」同一種面板：螢幕 60%、畫布不擋、點外面關閉）。面板是一張卡片，依分類排好常用的圖示，
// 往下捲就看得到其他分類；點一個畫布立刻換，面板不關，可以一直試。天氣分類的第一格是「跟著天氣」（依目前天氣自動換圖）。

/// 「跟著天氣」存在圖層裡的值（和原本的「改成跟著天氣自動變化」相同）。
let formlessAutoWeatherSymbol = "auto:weather"

struct EditorSymbolCategory: Identifiable {
    let id: String
    let symbols: [String]
    /// 這一類的第一格是「跟著天氣」。
    var includesAutoWeather = false
}

enum EditorSymbolCatalog {
    /// 分類與圖示。名稱都是系統圖示；這台裝置的系統沒有的名稱會自動略過，不會出現空白格。
    static let categories: [EditorSymbolCategory] = {
        let raw: [EditorSymbolCategory] = [
            EditorSymbolCategory(id: "常用", symbols: [
                "star.fill", "heart.fill", "bell.fill", "bookmark.fill", "flag.fill", "bolt.fill",
                "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.circle.fill", "info.circle.fill",
                "questionmark.circle.fill", "sparkles"]),
            EditorSymbolCategory(id: "天氣", symbols: [
                "sun.max.fill", "cloud.sun.fill", "cloud.fill", "cloud.rain.fill", "cloud.heavyrain.fill",
                "cloud.bolt.rain.fill", "cloud.snow.fill", "cloud.fog.fill", "wind", "snowflake", "moon.fill",
                "moon.stars.fill", "sunrise.fill", "sunset.fill", "thermometer.medium", "umbrella.fill", "drop.fill",
                "rainbow"], includesAutoWeather: true),
            EditorSymbolCategory(id: "時間", symbols: [
                "clock.fill", "alarm.fill", "timer", "stopwatch.fill", "hourglass", "calendar",
                "calendar.badge.clock", "deskclock.fill", "watch.analog", "calendar.circle.fill"]),
            EditorSymbolCategory(id: "生活", symbols: [
                "house.fill", "cup.and.saucer.fill", "fork.knife", "cart.fill", "bag.fill", "gift.fill",
                "book.fill", "music.note", "headphones", "tv.fill", "gamecontroller.fill", "camera.fill",
                "photo.fill", "paintbrush.fill", "leaf.fill", "pawprint.fill", "bed.double.fill", "lightbulb.fill"]),
            EditorSymbolCategory(id: "健康", symbols: [
                "figure.walk", "figure.run", "bicycle", "dumbbell.fill", "flame.fill", "bolt.heart.fill",
                "heart.text.square.fill", "lungs.fill", "cross.case.fill", "pills.fill", "waterbottle.fill", "moon.zzz.fill"]),
            EditorSymbolCategory(id: "交通", symbols: [
                "car.fill", "bus.fill", "tram.fill", "train.side.front.car", "airplane", "ferry.fill",
                "scooter", "fuelpump.fill", "map.fill", "mappin.and.ellipse", "location.fill", "signpost.right.fill"]),
            EditorSymbolCategory(id: "通訊", symbols: [
                "phone.fill", "message.fill", "envelope.fill", "bubble.left.fill", "video.fill", "person.fill",
                "person.2.fill", "at", "paperplane.fill", "link", "wifi", "antenna.radiowaves.left.and.right"]),
            EditorSymbolCategory(id: "箭頭", symbols: [
                "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.up.right", "arrow.down.right",
                "arrow.clockwise", "arrow.counterclockwise", "arrow.triangle.2.circlepath", "chevron.up", "chevron.down",
                "chevron.right"]),
            EditorSymbolCategory(id: "形狀", symbols: [
                "circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill",
                "capsule.fill", "oval.fill", "rhombus.fill", "star.circle.fill", "heart.circle.fill", "app.fill"])
        ]
        return raw.map { category in
            EditorSymbolCategory(id: category.id,
                                 symbols: category.symbols.filter { UIImage(systemName: $0) != nil },
                                 includesAutoWeather: category.includesAutoWeather)
        }
    }()
}

/// 「內容」分頁的圖示列：左邊「圖示」，右邊目前的圖示；點了打開圖示面板。
struct EditorSymbolRow: View {
    let value: String?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack {
                Text("圖示").foregroundStyle(.primary)
                Spacer(minLength: 12)
                if (value ?? "") == formlessAutoWeatherSymbol {
                    Text("跟著天氣").foregroundStyle(.secondary)
                } else {
                    Image(systemName: value.flatMap { UIImage(systemName: $0) != nil ? $0 : nil } ?? "questionmark")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                }
                FormlessDisclosureIndicator()
            }
            // 整列都能點（放在按鈕外面只有文字點得到）。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("圖示")
    }
}

/// 圖示面板。
struct EditorSymbolPanel: View {
    @ObservedObject var model: EditorModel
    let layerID: UUID
    let height: CGFloat
    var shown = true
    let onClose: () -> Void

    private static let columnCount = 6

    private enum Item: Hashable {
        case autoWeather
        case symbol(String)
        var span: Int { self == .autoWeather ? 2 : 1 }
    }

    /// 一類排成好幾列，每列 6 格；「跟著天氣」佔兩格。
    private static func rows(for category: EditorSymbolCategory) -> [[Item]] {
        var items: [Item] = category.includesAutoWeather ? [.autoWeather] : []
        items += category.symbols.map { .symbol($0) }
        var rows: [[Item]] = [], row: [Item] = [], used = 0
        for item in items {
            if used + item.span > columnCount { rows.append(row); row = []; used = 0 }
            row.append(item); used += item.span
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// 卡片內容的寬度（量到之前用視窗寬扣掉面板與卡片的邊距估計）：格子是正方形，6 格加 5 個間距剛好填滿。
    @State private var rowWidth: CGFloat = FormlessSafeArea.windowWidth - 4 * BatchPositionPanel.margin
    private static let spacing: CGFloat = 8
    private var cellSize: CGFloat { max(30, ((rowWidth - Self.spacing * CGFloat(Self.columnCount - 1)) / CGFloat(Self.columnCount)).rounded(.down)) }

    private var layer: Binding<FormlessLayer> { model.layerBinding(layerID) }
    private var current: String { layer.wrappedValue.value ?? "" }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(EditorSymbolCatalog.categories) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: Self.spacing) {
                                ForEach(Array(Self.rows(for: category).enumerated()), id: \.offset) { _, row in
                                    HStack(spacing: Self.spacing) {
                                        ForEach(row, id: \.self) { item in
                                            switch item {
                                            case .autoWeather: autoWeatherCell
                                            case .symbol(let name): cell(name)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(FormlessDesign.Space.cardGap)
        .contentMargins(.horizontal, BatchPositionPanel.margin, for: .scrollContent)
        // 和其他面板相同：卡片直接接在標題列下面，底部留一個邊距加螢幕底部安全區。
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, BatchPositionPanel.margin + FormlessSafeArea.bottom, for: .scrollContent)
        .scrollIndicators(.hidden)
        .safeAreaBar(edge: .top, spacing: 0) {
            Text("圖示")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: BatchPositionPanel.titleBar)
        }
        .editorToolPanel(height: height, active: shown, onClose: onClose)
    }

    private func cell(_ name: String) -> some View {
        let selected = current == name
        return Button { choose(name) } label: {
            Image(systemName: name)
                .font(.system(size: 20))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: cellSize, height: cellSize)
                .background(background(selected))
                .contentShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 「跟著天氣」佔兩格寬。
    private var autoWeatherCell: some View {
        let selected = current == formlessAutoWeatherSymbol
        return Button { choose(formlessAutoWeatherSymbol) } label: {
            HStack(spacing: 4) {
                Image(systemName: "cloud.sun.fill").font(.system(size: 15))
                Text("跟著天氣").font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(width: cellSize * 2 + Self.spacing, height: cellSize)
            .background(background(selected))
            .contentShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func background(_ selected: Bool) -> some View {
        // 選擇格：灰底圓角 8；選中是主色 12% 底加 2 pt 內框（和其他選取狀態相同）。
        let shape = RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous)
        return shape
            .fill(selected ? AnyShapeStyle(FormlessDesign.Palette.selectionFill) : AnyShapeStyle(FormlessDesign.Palette.fill))
            .overlay { if selected { shape.strokeBorder(FormlessDesign.Palette.accent, lineWidth: FormlessDesign.Stroke.selection) } }
    }

    private func choose(_ name: String) {
        guard layer.wrappedValue.value != name else { return }
        layer.wrappedValue.value = name
    }
}
