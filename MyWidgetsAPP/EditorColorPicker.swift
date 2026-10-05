import SwiftUI
import UIKit

/// 顏色工具面板的調色盤（取代系統的 UIColorPickerViewController）。系統的內容約 570 pt 高，60% 的面板放不下，
/// 要捲動才看得到下半部；而在格線上下滑是「拖著選色」不是捲動，手指經過的格子都被選上（標題被改成 #38571A 就是這樣）。
/// 這裡排成剛好放進面板、不需要捲動，功能比照系統：格線／光譜／滑桿三種選法、滴管、不透明度、
/// 目前顏色與收藏顏色（＋ 加入、長按刪除）、sRGB／Display P3 的色彩空間與十六進位色碼。
struct EditorColorPicker: View {
    let title: String
    let supportsOpacity: Bool
    let selection: Binding<Color>
    /// 面板的總高度（含標題列與螢幕底部安全區）。
    let height: CGFloat
    /// 滴管：由面板負責（面板要先滑下去），取到的顏色交回這裡套用。
    let onEyedropper: (@escaping (UIColor) -> Void) -> Void
    /// 調色盤上方這一項的其他設定（填色方式與漸層、外框寬度、陰影半徑……）；格線或光譜會讓出高度，面板仍不捲動。
    var header: AnyView? = nil
    /// 調的對象換了（例如漸層選了另一個顏色點）：面板裡記著的顏色要重新讀。
    var selectionKey: AnyHashable? = nil
    /// 標題列中間換成別的內容（例如填色方式選單）；nil 就顯示標題文字。
    var titleContent: AnyView? = nil
    /// 不是調色的時候（例如底色選了「圖片」）：調色盤的位置換成這個內容，標題列與上方的方塊位置完全不變，
    /// 滴管與選法按鈕藏起來（位置保留，標題不會移動）。
    var replacement: AnyView? = nil

    static let titleBar = FormlessDesign.Size.titleBar
    static let margin = FormlessDesign.Space.panel
    /// 系統調色盤格線的 120 色（12 欄 × 10 列，從系統調色盤逐格取樣）。
    static let grid: [[UInt32]] = [
        [0xFFFFFF, 0xEBEBEB, 0xD6D6D6, 0xC2C2C2, 0xADADAD, 0x999999, 0x858585, 0x707070, 0x5C5C5C, 0x474747, 0x333333, 0x000000],
        [0x00374A, 0x011D57, 0x11053B, 0x2E063D, 0x3C071B, 0x5C0701, 0x5A1C00, 0x583300, 0x563D00, 0x666100, 0x4F5504, 0x263E0F],
        [0x004D65, 0x012F7B, 0x1A0A52, 0x450D59, 0x551029, 0x831100, 0x7B2900, 0x7A4A00, 0x785800, 0x8D8602, 0x6F760A, 0x38571A],
        [0x016E8F, 0x0042A9, 0x2C0977, 0x61187C, 0x791A3D, 0xB51A00, 0xAD3E00, 0xA96800, 0xA67B01, 0xC4BC00, 0x9BA50E, 0x4E7A27],
        [0x008CB4, 0x0056D6, 0x371A94, 0x7A219E, 0x99244F, 0xE22400, 0xDA5100, 0xD38301, 0xD19D01, 0xF5EC00, 0xC3D117, 0x669D34],
        [0x00A1D8, 0x0061FE, 0x4D22B2, 0x982ABC, 0xB92D5D, 0xFF4015, 0xFF6A00, 0xFFAB01, 0xFDC700, 0xFEFB41, 0xD9EC37, 0x76BB40],
        [0x01C7FC, 0x3A87FE, 0x5E30EB, 0xBE38F3, 0xE63B7A, 0xFF6250, 0xFF8648, 0xFEB43F, 0xFECB3E, 0xFFF76B, 0xE4EF65, 0x96D35F],
        [0x52D6FC, 0x74A7FF, 0x864FFE, 0xD357FE, 0xEE719E, 0xFF8C82, 0xFFA57D, 0xFFC777, 0xFFD977, 0xFFF994, 0xEAF28F, 0xB1DD8B],
        [0x93E3FD, 0xA7C6FF, 0xB18CFE, 0xE292FE, 0xF4A4C0, 0xFFB5AF, 0xFFC5AB, 0xFFD9A8, 0xFEE4A8, 0xFFFBB9, 0xF2F7B7, 0xCDE8B5],
        [0xCBF0FF, 0xD3E2FF, 0xD9C9FE, 0xEFCAFF, 0xF9D3E0, 0xFFDBD8, 0xFFE2D6, 0xFFECD4, 0xFFF2D5, 0xFEFCDD, 0xF7FADB, 0xDFEED4],
    ]

    /// 上次用的選法（格線／光譜／滑桿），和系統一樣下次打開沿用。
    @AppStorage("formless.colorPicker.mode") private var mode = 0
    @AppStorage("formless.colorPicker.displayP3") private var displayP3 = false
    /// 收藏的顏色（#RRGGBBAA，逗號分隔）；預設和系統相同：黑、藍、綠、黃、紅。
    @AppStorage("formless.colorPicker.saved") private var savedRaw = "#000000FF,#0161FDFF,#32C759FF,#FFCC02FF,#FF3A30FF"

    /// 面板裡顯示的顏色：綁定讀的是圖層資料，這個畫面不會因為資料改變而重畫，所以自己記一份，每次設定時同步更新。
    @State private var picked: Color?
    /// 記著的那份只在和圖層資料一致時才用（拖曳中維持精確值）；資料在面板外被改了（上一步、下一步）就改讀綁定，
    /// 滑桿、色碼才會跟著變（使用者回報：顏色還原了、滑桿沒變）。
    private var currentColor: Color {
        if let picked, EditorRGBA(picked, displayP3: false).hex8 == boundHex { return picked }
        return selection.wrappedValue
    }
    private var boundHex: String { EditorRGBA(selection.wrappedValue, displayP3: false).hex8 }
    private var rgba: EditorRGBA { EditorRGBA(currentColor, displayP3: displayP3) }
    private var saved: [EditorRGBA] {
        savedRaw.split(separator: ",").compactMap { EditorRGBA(hex: String($0)) }
    }

    private func set(_ value: EditorRGBA) {
        var value = value
        if !supportsOpacity { value.a = 1 }
        apply(value.color(displayP3: false))
    }
    /// 格線、光譜、收藏給的是 sRGB 顏色；不透明度維持目前的值（和系統一樣，選顏色不改不透明度）。
    private func setSRGB(_ value: EditorRGBA) {
        var value = value
        value.a = EditorRGBA(currentColor, displayP3: false).a
        if !supportsOpacity { value.a = 1 }
        apply(value.color(displayP3: false))
    }
    private func apply(_ color: Color) {
        picked = color
        selection.wrappedValue = color
    }

    /// 鍵盤出現時內容往上捲的距離：輸入欄停在鍵盤上方 36 pt，面板本身不動（和全 App 的鍵盤距離相同）。
    @State private var keyboardShift: CGFloat = 0
    /// 鍵盤期間內容底部多出的空間，才捲得上去。
    @State private var keyboardRoom: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private func keyboardShown(_ delta: CGFloat) {
        let next = max(0, keyboardShift + delta)
        keyboardRoom = max(keyboardRoom, next)
        keyboardShift = next
        DispatchQueue.main.async {
            withAnimation(FormlessMotion.push) { scrollPosition.scrollTo(y: next) }
        }
    }
    private func keyboardHidden() {
        keyboardShift = 0
        withAnimation(FormlessMotion.push) { scrollPosition.scrollTo(y: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + FormlessMotion.pushDuration + 0.05) {
            if keyboardShift == 0 { keyboardRoom = 0 }
        }
    }

    var body: some View {
        let contentHeight = height - Self.titleBar
        ScrollView {
            VStack(spacing: 16) {
                if let header { header }
                if let replacement {
                    replacement.frame(maxHeight: .infinity)
                } else {
                    // 所有顏色面板同一個排法（使用者要求精簡、統一）：光譜、色號、透明度。
                    // 滑桿和輸入框各自成列，不在滑桿之間夾一個輸入框。
                    EditorColorSpectrum(current: EditorRGBA(currentColor, displayP3: false)) { setSRGB($0) }
                        .frame(maxHeight: .infinity)
                    EditorHexField(hex: EditorRGBA(currentColor, displayP3: false).hex6) { hex in
                        guard var next = EditorRGBA(hex: hex) else { return }
                        next.a = EditorRGBA(currentColor, displayP3: false).a
                        apply(next.color(displayP3: false))
                    }
                    EditorOpacityRow(rgba: EditorRGBA(currentColor, displayP3: false), displayP3: false) { set($0) }
                }
            }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, Self.margin + FormlessSafeArea.bottom)
            .frame(height: contentHeight)
            .padding(.bottom, keyboardRoom)
        }
        // 內容剛好放進面板，但仍然可以上下滑、會回彈（使用者要求）：不確定下面還有沒有內容時會不自覺上下滑，
        // 原本不能捲，那一滑就變成拖格線、光譜或滑桿而改到參數。現在上下滑一律當捲動；格線、光譜、滑桿只在點一下
        // 或從色點橫向開始拖時才改值（見 `FormlessScrollSafeDrag`）。鍵盤出現時的捲動仍由這裡自己捲。
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .scrollPosition($scrollPosition)
        .background(FormlessSelfManagedKeyboardScroll(onShow: keyboardShown, onHide: keyboardHidden))
        .ignoresSafeArea(.keyboard)
        .safeAreaBar(edge: .top, spacing: 0) { titleBarView }
        // 拖曳漸層顏色點時的位置標籤：畫在標題列與所有內容之上。
        .editorDragLabels()
        .onChange(of: selectionKey) { _, _ in picked = nil }

    }

    private var titleBarView: some View {
        ZStack {
            if let titleContent { titleContent } else { Text(title).font(.headline) }
            HStack {
                Button {
                    onEyedropper { color in setSRGB(EditorRGBA(Color(uiColor: color), displayP3: false)) }
                } label: {
                    Image(systemName: "eyedropper")
                        .font(FormlessDesign.Symbol.glassButton)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .formlessGlass(.regular.interactive(), in: .circle)
                .accessibilityLabel("滴管")
                .opacity(replacement == nil ? 1 : 0)
                .allowsHitTesting(replacement == nil)
                Spacer()
            }
            .padding(.horizontal, Self.margin)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.titleBar)
    }

    private static let modes: [(name: String, symbol: String)] = [
        // 圖示要一看就是那種選法：矩形裡分成很多格、彩虹、方框裡的滑桿（使用者指定）。原本的格線和「設計」分頁的圖示、
        // 滑桿和右上角「小工具設定」的圖示長得一樣，會誤會（使用者回報）。
        ("格線", "rectangle.split.3x3"), ("光譜", "rainbow"), ("滑桿", "slider.horizontal.2.square")
    ]

    /// 右上角的選法選單：和左上角的滴管同一種玻璃圓鈕，圖示是目前的選法；標題因此在兩顆圓鈕正中間。
    private var modeMenu: some View {
        let current = Self.modes[min(max(mode, 0), Self.modes.count - 1)]
        return Menu {
            Picker("選法", selection: $mode) {
                ForEach(Self.modes.indices, id: \.self) { index in
                    Label(Self.modes[index].name, systemImage: Self.modes[index].symbol).tag(index)
                }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        // 選單預設用強調色（藍）畫標籤；和左上角的滴管一樣用一般文字色。
        .tint(.primary)
        .formlessGlass(.regular.interactive(), in: .circle)
        .accessibilityLabel("選法")
        .accessibilityValue(current.name)
    }

    /// 目前顏色（左）與收藏顏色：點一下套用，長按刪除，最後的 ＋ 把目前顏色加進收藏。
    /// 一排排開、不左右捲動（使用者：所有彈出的面板都不應該能左右滑動）：收藏最多放到這一排放得下的數量，
    /// 滿了再加入時擠掉最舊的一個。
    private var swatches: some View {
        let current = EditorRGBA(currentColor, displayP3: false)
        return HStack(spacing: Self.swatchSpacing) {
            EditorCheckerboard()
                .overlay(currentColor)
                .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.control, style: .continuous))
                .frame(width: Self.swatch, height: Self.swatch)
                .accessibilityLabel("目前顏色")
            ForEach(Array(visibleSaved.enumerated()), id: \.offset) { index, color in
                Button { setSRGB(color) } label: {
                    EditorCheckerboard()
                        .overlay(color.color(displayP3: false))
                        .clipShape(Circle())
                        .padding(color.hex8 == current.hex8 ? 4 : 0)
                        .overlay {
                            // 選中的收藏色：主色 2 pt 內框（和其他選取狀態相同），色塊內縮一圈讓框不壓到顏色。
                            if color.hex8 == current.hex8 {
                                Circle().strokeBorder(FormlessDesign.Palette.accent, lineWidth: FormlessDesign.Stroke.selection)
                            }
                        }
                        .frame(width: Self.swatch, height: Self.swatch)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("刪除", systemImage: "trash", role: .destructive) { removeSaved(color) }
                }
            }
            Button { addSaved(current) } label: {
                Image(systemName: "plus")
                    .font(FormlessDesign.Symbol.circle)
                    .foregroundStyle(FormlessDesign.Palette.accent)
                    .frame(width: Self.swatch, height: Self.swatch)
                    .background(FormlessDesign.Palette.tintFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("加入收藏")
            Spacer(minLength: 0)
        }
        .frame(height: Self.swatch)
    }
    static let swatch: CGFloat = 36
    static let swatchSpacing = FormlessDesign.Space.loose
    /// 這一排放得下的收藏色數量：扣掉左邊的目前顏色與右邊的 ＋。
    @MainActor static var savedCapacity: Int {
        let width = FormlessSafeArea.windowWidth - 2 * margin
        return max(1, Int((width - 2 * swatch - swatchSpacing) / (swatch + swatchSpacing)))
    }
    /// 資料裡比放得下的還多時（舊版存的），只顯示最新的那幾個。
    private var visibleSaved: [EditorRGBA] { Array(saved.suffix(Self.savedCapacity)) }

    private func addSaved(_ color: EditorRGBA) {
        var list = saved.map(\.hex8)
        guard !list.contains(color.hex8) else { return }
        list.append(color.hex8)
        if list.count > Self.savedCapacity { list.removeFirst(list.count - Self.savedCapacity) }
        savedRaw = list.joined(separator: ",")
    }
    private func removeSaved(_ color: EditorRGBA) {
        var list = saved.map(\.hex8)
        list.removeAll { $0 == color.hex8 }
        savedRaw = list.joined(separator: ",")
    }
}

/// 調色盤內部用的顏色值（0–1），可以是 sRGB 或 Display P3。
struct EditorRGBA: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    init(rgb: UInt32) {
        self.init(r: Double((rgb >> 16) & 0xFF) / 255, g: Double((rgb >> 8) & 0xFF) / 255, b: Double(rgb & 0xFF) / 255)
    }
    init?(hex: String) {
        let clean = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6 || clean.count == 8, let value = UInt64(clean, radix: 16) else { return nil }
        if clean.count == 8 {
            self.init(r: Double((value >> 24) & 0xFF) / 255, g: Double((value >> 16) & 0xFF) / 255,
                      b: Double((value >> 8) & 0xFF) / 255, a: Double(value & 0xFF) / 255)
        } else {
            self.init(rgb: UInt32(value))
        }
    }
    init(_ color: Color, displayP3: Bool) {
        let native = UIColor(color).cgColor
        let space = CGColorSpace(name: displayP3 ? CGColorSpace.displayP3 : CGColorSpace.extendedSRGB)!
        let converted = native.converted(to: space, intent: .defaultIntent, options: nil) ?? native
        let c = converted.components ?? [0, 0, 0, 1]
        if c.count >= 4 {
            self.init(r: Self.clamp(c[0]), g: Self.clamp(c[1]), b: Self.clamp(c[2]), a: Self.clamp(c[3]))
        } else if c.count == 2 {
            self.init(r: Self.clamp(c[0]), g: Self.clamp(c[0]), b: Self.clamp(c[0]), a: Self.clamp(c[1]))
        } else {
            self.init(r: 0, g: 0, b: 0)
        }
    }
    private static func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }

    func color(displayP3: Bool) -> Color {
        Color(displayP3 ? .displayP3 : .sRGB, red: r, green: g, blue: b, opacity: a)
    }
    private static func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    var rgbHex: UInt32 { UInt32(Self.byte(r) << 16 | Self.byte(g) << 8 | Self.byte(b)) }
    var hex6: String { String(format: "%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b)) }
    var hex8: String { "#" + hex6 + String(format: "%02X", Self.byte(a)) }
}

/// 格線：12 × 10 的系統色，點或拖著選（手指經過的格子依序套用，和系統一樣）。目前顏色正好是某一格時框起來。
struct EditorColorGrid: View {
    let current: UInt32
    let onPick: (UInt32) -> Void
    @State private var lastIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            let cellWidth = geometry.size.width / 12
            let cellHeight = geometry.size.height / 10
            Canvas { context, _ in
                for (row, colors) in EditorColorPicker.grid.enumerated() {
                    for (column, rgb) in colors.enumerated() {
                        // 往外多畫半點，格子之間不會露出底色的細縫。
                        let rect = CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight,
                                          width: cellWidth + 0.5, height: cellHeight + 0.5)
                        context.fill(Path(rect), with: .color(EditorRGBA(rgb: rgb).color(displayP3: false)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let index = selectedIndex {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .frame(width: cellWidth + 2, height: cellHeight + 2)
                        .offset(x: CGFloat(index % 12) * cellWidth - 1, y: CGFloat(index / 12) * cellHeight - 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // 點一下選格子；橫向開始拖可以掃過去換格子；上下滑是捲動面板（不選色），滑動也不會被當成點擊。
            .overlay {
                FormlessScrollSafeDrag(
                    canBegin: { _ in true },
                    onTap: { point in pick(at: point, cellWidth: cellWidth, cellHeight: cellHeight) },
                    onBegan: { _ in lastIndex = nil },
                    onChanged: { location, _ in pick(at: location, cellWidth: cellWidth, cellHeight: cellHeight) },
                    onEnded: { lastIndex = nil }
                )
            }
        }
        .accessibilityLabel("格線")
    }

    private var selectedIndex: Int? {
        for (row, colors) in EditorColorPicker.grid.enumerated() {
            if let column = colors.firstIndex(of: current) { return row * 12 + column }
        }
        return nil
    }

    private func pick(at point: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat) {
        let column = min(11, max(0, Int(point.x / cellWidth)))
        let row = min(9, max(0, Int(point.y / cellHeight)))
        let index = row * 12 + column
        guard index != lastIndex else { return }
        lastIndex = index
        onPick(EditorColorPicker.grid[row][column])
    }
}

/// 光譜：色相由上到下（紅、黃、綠、青、藍、洋紅、紅），左半往白、右半往黑；和系統的光譜同一種排法。
struct EditorColorSpectrum: View {
    let current: EditorRGBA
    let onPick: (EditorRGBA) -> Void
    /// 拖曳中直接用手指的位置畫圈（換成 8 位元顏色再換回位置會有一點跳動）。
    @State private var dragPoint: CGPoint?

    /// 光譜圖用選色的同一條公式逐點算出來：手指下看到的顏色就是選到的顏色（用漸層疊出來的最多差 24/255）。
    private static let image: UIImage = {
        let width = 128, height = 256
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(atX: Double(x) / Double(width - 1), y: Double(y) / Double(height - 1))
                let i = (y * width + x) * 4
                data[i] = UInt8((c.r * 255).rounded()); data[i + 1] = UInt8((c.g * 255).rounded()); data[i + 2] = UInt8((c.b * 255).rounded())
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }()

    static func color(atX x: Double, y: Double) -> EditorRGBA {
        let hue = min(max(y, 0), 1)
        let x = min(max(x, 0), 1)
        let saturation = x <= 0.5 ? x / 0.5 : 1
        let brightness = x <= 0.5 ? 1 : 1 - (x - 0.5) / 0.5
        let native = UIColor(hue: hue >= 1 ? 0 : hue, saturation: saturation, brightness: brightness, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
        return EditorRGBA(r: Double(r), g: Double(g), b: Double(b))
    }

    /// 目前顏色在光譜上的位置；不在光譜上的顏色（例如灰色：既不是最亮也不是最飽和）不畫圈。
    private var currentPoint: CGPoint? {
        let native = UIColor(red: current.r, green: current.g, blue: current.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        native.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if v >= 0.995 { return CGPoint(x: s * 0.5, y: h) }
        if s >= 0.995 { return CGPoint(x: 0.5 + (1 - v) * 0.5, y: h) }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Image(uiImage: Self.image)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: FormlessDesign.Radius.medium, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let point = dragPoint ?? currentPoint.map({ CGPoint(x: $0.x * size.width, y: $0.y * size.height) }) {
                    Circle()
                        .fill(current.color(displayP3: false))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .frame(width: 28, height: 28)
                        .offset(x: point.x - 14, y: point.y - 14)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // 點一下選那個位置；橫向開始拖之後可以任意方向移動；上下滑是捲動面板（不選色）。
            .overlay {
                FormlessScrollSafeDrag(
                    canBegin: { _ in true },
                    onTap: { point in pick(point, in: size) },
                    onBegan: { _ in },
                    onChanged: { location, _ in pick(location, in: size) },
                    onEnded: { dragPoint = nil }
                )
            }
        }
        .accessibilityLabel("光譜")
    }

    private func pick(_ location: CGPoint, in size: CGSize) {
        let point = CGPoint(x: min(max(location.x, 0), size.width), y: min(max(location.y, 0), size.height))
        dragPoint = point
        onPick(Self.color(atX: point.x / size.width, y: point.y / size.height))
    }
}

/// 滑桿：紅、綠、藍三條（軌道是只改這一色時的漸層），右邊是 0–255 的數字；最下面是色彩空間與十六進位色碼。
struct EditorColorSliders: View {
    let rgba: EditorRGBA
    @Binding var displayP3: Bool
    let onChange: (EditorRGBA) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 間距可以縮到 6：填色面板上方多了漸層的兩行時，滑桿模式也要剛好放得下（面板不捲動）。
            channel(\.r)
            Spacer(minLength: 6)
            channel(\.g)
            Spacer(minLength: 6)
            channel(\.b)
            Spacer(minLength: 6)
            hexRow
        }
    }

    private func channel(_ key: WritableKeyPath<EditorRGBA, Double>) -> some View {
        var low = rgba; low[keyPath: key] = 0; low.a = 1
        var high = rgba; high[keyPath: key] = 1; high.a = 1
        return HStack(spacing: 10) {
            EditorGradientSlider(value: rgba[keyPath: key],
                                 track: LinearGradient(colors: [low.color(displayP3: displayP3), high.color(displayP3: displayP3)],
                                                       startPoint: .leading, endPoint: .trailing)) { value in
                var next = rgba; next[keyPath: key] = value
                onChange(next)
            }
            EditorColorNumberField(value: (rgba[keyPath: key] * 255).rounded(), format: { String(Int($0)) }) { entered in
                var next = rgba; next[keyPath: key] = min(max(entered, 0), 255) / 255
                onChange(next)
            }
        }
    }

    private var hexRow: some View {
        HStack(spacing: 10) {
            FormlessOptionMenu(options: [FormlessMenuOption(id: AnyHashable(false), title: "sRGB"),
                                         FormlessMenuOption(id: AnyHashable(true), title: "Display P3")],
                               selection: AnyHashable(displayP3),
                               onSelect: { id in if let value = id.base as? Bool { displayP3 = value } }) {
                // 選值的選單：文字用一般文字色、箭頭灰色（不用主色）。
                HStack(spacing: 4) {
                    Text(displayP3 ? "Display P3" : "sRGB")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(minHeight: FormlessDesign.Size.control)
                .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            EditorHexField(hex: rgba.hex6) { hex in
                guard var next = EditorRGBA(hex: hex) else { return }
                next.a = rgba.a
                onChange(next)
            }
        }
    }
}

/// 不透明度：棋盤格上從透明到目前顏色的漸層，右邊是百分比。
struct EditorOpacityRow: View {
    let rgba: EditorRGBA
    let displayP3: Bool
    let onChange: (EditorRGBA) -> Void

    var body: some View {
        var opaque = rgba; opaque.a = 1
        var clear = rgba; clear.a = 0
        return HStack(spacing: 10) {
            EditorGradientSlider(value: rgba.a,
                                 track: LinearGradient(colors: [clear.color(displayP3: displayP3), opaque.color(displayP3: displayP3)],
                                                       startPoint: .leading, endPoint: .trailing),
                                 checkerboard: true) { value in
                var next = rgba; next.a = value
                onChange(next)
            }
            EditorColorNumberField(value: (rgba.a * 100).rounded(), format: { "\(Int($0))%" }) { entered in
                var next = rgba; next.a = min(max(entered, 0), 100) / 100
                onChange(next)
            }
        }
        .accessibilityLabel("不透明度")
    }
}

/// 漸層軌道的滑桿：膠囊軌道、白色圓環滑塊；點軌道任何位置直接跳過去，拖著連續調整。
struct EditorGradientSlider: View {
    let value: Double
    let track: LinearGradient
    var checkerboard = false
    let onChange: (Double) -> Void
    static let height: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let knob = Self.height
            let travel = max(1, geometry.size.width - knob)
            ZStack(alignment: .leading) {
                ZStack {
                    if checkerboard { EditorCheckerboard() }
                    Capsule().fill(track)
                }
                .clipShape(Capsule())
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .frame(width: knob, height: knob)
                    .offset(x: CGFloat(min(max(value, 0), 1)) * travel)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // 和 App 的其他滑桿一樣：從圓鈕附近橫向開始拖才動；點一下跳到那個位置；上下滑是捲動面板。
            .overlay {
                FormlessScrollSafeDrag(
                    canBegin: { start in abs(start.x - (knob / 2 + CGFloat(min(max(value, 0), 1)) * travel)) <= knob / 2 + 12 },
                    onTap: { point in onChange(Double(min(max((point.x - knob / 2) / travel, 0), 1))) },
                    onBegan: { _ in },
                    onChanged: { location, _ in onChange(Double(min(max((location.x - knob / 2) / travel, 0), 1))) },
                    onEnded: {}
                )
            }
        }
        .frame(height: Self.height)
    }
}

/// 調色盤裡的數字欄：和屬性面板滑桿列的數字欄同一種（點了先清空、輸入後套用）。
struct EditorColorNumberField: View {
    let value: Double
    let format: (Double) -> String
    let onCommit: (Double) -> Void

    var body: some View {
        FormlessNumberField(value: value, format: format, allowsDecimal: false, allowsNegative: false, onCommit: onCommit)
            .font(.body.monospacedDigit())
            .padding(.horizontal, 10)
            .frame(width: 72)
            .frame(minHeight: 36)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 十六進位色碼欄：外觀同數字欄，點了先清空（提示字是目前的色碼），輸入 6 碼即套用。
struct EditorHexField: View {
    let hex: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text("#").foregroundStyle(.secondary)
            TextField(hex, text: $text)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                // 只在打進不是 0–9、A–F 的字或超過 6 碼時才改寫欄位；大小寫送出時才轉。
                // 每打一個字就把小寫改成大寫會重設欄位內容，打得快時後面的字會被吃掉。
                .onChange(of: text) { _, next in
                    let filtered = String(next.filter { $0.isHexDigit }.prefix(6))
                    if filtered != next { text = filtered }
                }
                .onChange(of: focused) { _, isFocused in
                    if isFocused { editing = true; text = "" } else { commit() }
                }
                .onSubmit { focused = false }
                .onAppear { text = hex }
                .onChange(of: hex) { _, next in if !editing { text = next } }
        }
        .font(.body.monospacedDigit())
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: FormlessDesign.Size.control)
        .formlessGrayBox()
        .background(FormlessInputArea())
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if text.count == 6 { onCommit(text.uppercased()) }
        text = hex
    }
}

/// 透明度的棋盤格底。
struct EditorCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(white: 0.85)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}

// MARK: - 滴管

/// 滴管：面板先滑下去讓整個畫面露出來，拍下目前的畫面；放大鏡從畫布中間開始，手指在任何地方拖動都會移動它，
/// 放開時取放大鏡中心那一點的顏色（和系統滴管相同：拖著看、放手選）。
@MainActor enum FormlessEyedropper {
    private static var window: FormlessEyedropperWindow?

    static func present(start: CGPoint, completion: @escaping (UIColor?) -> Void) {
        guard window == nil,
              let appWindow = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow),
              let scene = appWindow.windowScene else { completion(nil); return }
        let format = UIGraphicsImageRendererFormat(for: appWindow.traitCollection)
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: appWindow.bounds, format: format).image { _ in
            appWindow.drawHierarchy(in: appWindow.bounds, afterScreenUpdates: false)
        }
        guard let pixels = FormlessPixelBuffer(image: image) else { completion(nil); return }
        let overlay = FormlessEyedropperWindow(windowScene: scene, pixels: pixels, start: start) { color in
            window?.isHidden = true
            window = nil
            completion(color)
        }
        overlay.frame = appWindow.frame
        overlay.windowLevel = UIWindow.Level(appWindow.windowLevel.rawValue + 2)
        overlay.isHidden = false
        window = overlay
    }
}

/// 畫面快照的像素（sRGB、每點 4 位元組），滴管與放大鏡直接讀。
final class FormlessPixelBuffer {
    let width: Int
    let height: Int
    let scale: CGFloat
    private var data: [UInt8]

    init?(image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        width = cg.width
        height = cg.height
        scale = image.scale
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
    }

    /// 畫面座標（pt）換成像素。
    func pixel(at point: CGPoint) -> (x: Int, y: Int) {
        (min(max(Int(point.x * scale), 0), width - 1), min(max(Int(point.y * scale), 0), height - 1))
    }

    func color(x: Int, y: Int) -> UIColor {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        let i = (y * width + x) * 4
        return UIColor(red: CGFloat(data[i]) / 255, green: CGFloat(data[i + 1]) / 255, blue: CGFloat(data[i + 2]) / 255, alpha: 1)
    }
}

final class FormlessEyedropperWindow: UIWindow {
    private let loupe: FormlessLoupeView
    private let onFinish: (UIColor?) -> Void
    private var lastTouch: CGPoint?

    init(windowScene: UIWindowScene, pixels: FormlessPixelBuffer, start: CGPoint, onFinish: @escaping (UIColor?) -> Void) {
        loupe = FormlessLoupeView(pixels: pixels)
        self.onFinish = onFinish
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        addSubview(loupe)
        loupe.target = start
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouch = touches.first?.location(in: self)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), let last = lastTouch else { return }
        lastTouch = point
        var target = loupe.target
        target.x = min(max(target.x + point.x - last.x, 0), bounds.width - 1)
        target.y = min(max(target.y + point.y - last.y, 0), bounds.height - 1)
        loupe.target = target
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouch = nil
        onFinish(loupe.pickedColor)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouch = nil
        onFinish(nil)
    }
}

/// 放大鏡：中心附近 11 × 11 個像素放大顯示，中心那一格加框；外圈是目前取到的顏色。
final class FormlessLoupeView: UIView {
    private let pixels: FormlessPixelBuffer
    static let diameter: CGFloat = 120
    private static let cells = 11
    var target: CGPoint = .zero {
        didSet {
            center = target
            setNeedsDisplay()
        }
    }
    var pickedColor: UIColor {
        let p = pixels.pixel(at: target)
        return pixels.color(x: p.x, y: p.y)
    }

    init(pixels: FormlessPixelBuffer) {
        self.pixels = pixels
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isOpaque = false
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ring: CGFloat = 8
        let outer = bounds.insetBy(dx: 1, dy: 1)
        let inner = outer.insetBy(dx: ring, dy: ring)
        context.saveGState()
        context.addEllipse(in: inner)
        context.clip()
        let count = Self.cells
        let cell = inner.width / CGFloat(count)
        let p = pixels.pixel(at: target)
        for row in 0..<count {
            for column in 0..<count {
                pixels.color(x: p.x + column - count / 2, y: p.y + row - count / 2).setFill()
                context.fill(CGRect(x: inner.minX + CGFloat(column) * cell, y: inner.minY + CGFloat(row) * cell,
                                    width: cell + 0.5, height: cell + 0.5))
            }
        }
        let middle = CGRect(x: inner.minX + CGFloat(count / 2) * cell, y: inner.minY + CGFloat(count / 2) * cell,
                            width: cell, height: cell)
        UIColor.black.withAlphaComponent(0.6).setStroke()
        context.setLineWidth(2)
        context.stroke(middle.insetBy(dx: -1, dy: -1))
        UIColor.white.setStroke()
        context.setLineWidth(1)
        context.stroke(middle)
        context.restoreGState()
        // 外圈：取到的顏色
        pickedColor.setStroke()
        context.setLineWidth(ring)
        context.strokeEllipse(in: outer.insetBy(dx: ring / 2, dy: ring / 2))
        UIColor.white.withAlphaComponent(0.9).setStroke()
        context.setLineWidth(1)
        context.strokeEllipse(in: outer)
        context.strokeEllipse(in: inner)
    }
}
