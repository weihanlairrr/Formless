import Foundation
import CoreText
import SwiftUI

// MARK: - 曲線文字
//
// 文字沿圖層框的內切圓排：半徑是框短邊的一半、圓心在框中心，使用者改框的大小就改了彎曲程度。
// 逐字（Character，也就是字素叢集：中文、emoji、組合字都算一個字）畫一個 Text：
// 每個字先正立擺在圓的頂端（或底端），用文字基線對準算好的半徑，再整個繞圓心轉到該字在弧上的角度，字就沿著切線方向。
// 字寬用 CoreText 量「單獨一個字」的寬度，再加上相鄰兩字的字距調整（kerning），和逐字畫出來的結果一致。
// 只用 SwiftUI 與 CoreText，App、小工具延伸、macOS 測試都能編譯。

enum FormlessArcPlacement: String, Codable, CaseIterable, Sendable {
    /// 文字置中在圓的頂端，順時針排，字頭朝外。
    case top
    /// 文字置中在圓的底端，從左讀到右，字頭朝圓心（字是正的，不是倒的）。
    case bottom

    var displayName: String {
        switch self {
        case .top: return "上方"
        case .bottom: return "下方"
        }
    }
}

struct FormlessArcTextView: View {
    let text: String
    /// 用來量每個字的寬度與上升、下降高度。iOS 上主對話會傳 UIFont（UIFont 與 CTFont 可直接橋接）。
    let measureFont: CTFont
    /// 實際畫字用的字型（與 measureFont 同一個字型與大小）。
    let font: Font
    /// 額外字距（點），可以是負的。
    var tracking: CGFloat = 0
    var placement: FormlessArcPlacement = .top

    var body: some View {
        GeometryReader { proxy in
            let layout = FormlessArcTextLayout(
                metrics: FormlessArcTextMetrics.measure(text, font: measureFont),
                size: proxy.size, tracking: tracking, placement: placement
            )
            if !layout.letters.isEmpty {
                letters(layout, size: proxy.size)
            }
        }
        // 拆成一個個字之後，旁白仍要整句唸。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }

    private func letters(_ layout: FormlessArcTextLayout, size: CGSize) -> some View {
        let plain = layout.letters.filter { !$0.isColor }
        let color = layout.letters.filter(\.isColor)
        return ZStack {
            if !plain.isEmpty {
                // 一般的字當遮罩，挖出一塊填滿前景樣式的框：漸層以整個框為範圍，不會每個字各自從頭漸一次。
                Rectangle()
                    .fill(.foreground)
                    .mask {
                        ZStack {
                            ForEach(plain) { letterView($0, layout: layout, size: size) }
                        }
                        // 遮罩只看不透明度；外面的前景色若是半透明或漸層，不能在遮罩裡再套一次。
                        .foregroundStyle(Color.black)
                    }
            }
            // 彩色字（emoji）本來就不吃前景色，照原樣畫在上面。
            ForEach(color) { letterView($0, layout: layout, size: size) }
        }
        .frame(width: size.width, height: size.height)
    }

    private func letterView(_ letter: FormlessArcTextLayout.Letter, layout: FormlessArcTextLayout, size: CGSize) -> some View {
        Text(verbatim: letter.string)
            .font(font)
            // 字距已由 tracking 參數排進角度；外面若再套 .tracking，每個字的框會變寬、位置跑掉，這裡擋掉。
            .tracking(0)
            .fixedSize()
            // 字左右置中、基線落在 baselineY：emoji、中文、英文的行高各不相同，用基線對齊才準。
            .alignmentGuide(.top) { $0[.firstTextBaseline] - layout.baselineY }
            .frame(width: size.width, height: size.height, alignment: .top)
            // 文字太長要縮小時，以基線中點為準縮放，字頂（或字底）仍貼著圓。
            .scaleEffect(layout.scale, anchor: UnitPoint(x: 0.5, y: layout.baselineY / size.height))
            // 框的中心就是圓心，整個框繞中心轉，字就移到弧上並沿切線方向。
            .rotationEffect(.radians(letter.angle))
    }
}

// MARK: - 排版

/// 依框的大小算出每個字的角度、基線位置與縮小比例。
struct FormlessArcTextLayout {
    struct Letter: Identifiable {
        /// 在原文字裡的第幾個字，當作 ForEach 的 id。
        let id: Int
        let string: String
        /// 繞圓心轉的角度（弧度，順時針為正）。
        let angle: Double
        let isColor: Bool
    }

    /// 要畫的字；空白只佔位置，不畫。
    private(set) var letters: [Letter] = []
    /// 字正立擺在頂端（或底端）時，基線在框裡的 y。
    private(set) var baselineY: CGFloat = 0
    /// 文字太長時整體縮小的比例；放得下是 1。
    private(set) var scale: CGFloat = 1

    /// 太長時最多排到整圈的 95%，頭尾留一點空隙，不會接在一起。
    static let maximumSweep: CGFloat = 0.95 * 2 * .pi
    /// 字身高度（上升＋下降）最多佔半徑的比例。
    static let maximumBand: CGFloat = 2.0 / 3.0

    init(metrics: FormlessArcTextMetrics, size: CGSize, tracking: CGFloat, placement: FormlessArcPlacement) {
        let items = metrics.letters
        let radius = min(size.width, size.height) / 2
        guard !items.isEmpty, radius > 0, radius.isFinite, size.width.isFinite, size.height.isFinite else { return }
        let tracking = tracking.isFinite ? tracking : 0

        // 每個字的中心在一直線上的位置（原尺寸，第一個字的左緣是 0）。字距太負時字疊在一起，但不會倒退。
        var centers: [CGFloat] = []
        centers.reserveCapacity(items.count)
        var x = items[0].width / 2
        for index in items.indices {
            if index > 0 {
                let previous = items[index - 1]
                x += max(0, previous.width / 2 + previous.kern + tracking + items[index].width / 2)
            }
            centers.append(x)
        }
        let length = max(0, x + items[items.count - 1].width / 2)

        // 弧長量在字身中線上（離圓 lineHeight / 2）：上方、下方同一個半徑，字的間距看起來和平常排成一行時一樣。
        // 中線半徑會跟著縮小比例變，解 scale × length = 最大角度 × (R − scale × lineHeight / 2)。
        let lineHeight = max(0, metrics.ascent + metrics.descent)
        let sweep = Self.maximumSweep
        var fit = sweep * radius / (length + sweep * lineHeight / 2)
        // 字比圓還大時（字身超過半徑的 2/3），字的內側會擠到圓心互相交疊，也一起縮小。
        if lineHeight > 0 { fit = min(fit, Self.maximumBand * radius / lineHeight) }
        scale = fit.isFinite && fit > 0 ? min(1, fit) : 1
        let midRadius = radius - scale * lineHeight / 2

        switch placement {
        case .top:
            // 字頂（上升高度）碰到內切圓。
            baselineY = size.height / 2 - (radius - scale * metrics.ascent)
        case .bottom:
            // 字底（下降高度）碰到內切圓，字頭朝圓心。
            baselineY = size.height / 2 + (radius - scale * metrics.descent)
        }

        // 上方：右邊的字順時針轉。下方：字正立在底端，左邊的字要順時針轉才會跑到左下。
        let direction: CGFloat = placement == .top ? 1 : -1
        letters = items.indices.compactMap { index in
            let item = items[index]
            guard !item.isBlank else { return nil }
            let arc = (centers[index] - length / 2) * scale
            let angle = midRadius > 0.001 ? arc / midRadius * direction : 0
            return Letter(id: index, string: item.string, angle: Double(angle.isFinite ? angle : 0), isColor: item.isColor)
        }
    }
}

// MARK: - 量字

/// 一段文字用某個字型量出來的結果（字型原尺寸，還沒套字距與縮小）。量一次就快取，重畫不重量。
final class FormlessArcTextMetrics: Sendable {
    struct Letter: Sendable {
        let string: String
        /// 單獨一個字的排版寬度。
        let width: CGFloat
        /// 和下一個字之間的字距調整（字型內建的 kerning）；最後一個字是 0。
        let kern: CGFloat
        /// 空白：只佔位置。
        let isBlank: Bool
        /// 彩色字（emoji）：不吃前景色。
        let isColor: Bool
    }

    let letters: [Letter]
    /// 有筆畫的字裡最高的上升高度、最深的下降高度（中文會換成蘋方等後備字型，某些字級的高度和英文字型不同）。
    let ascent: CGFloat
    let descent: CGFloat

    private init(letters: [Letter], ascent: CGFloat, descent: CGFloat) {
        self.letters = letters
        self.ascent = ascent
        self.descent = descent
    }

    /// 小工具可能在背景執行緒畫；NSCache 本身是執行緒安全的（只是 SDK 沒標 Sendable），CoreText 也可以跨執行緒用。
    /// 鍵是文字加字型（CFEqual 比字型名稱、大小、粗細等所有屬性）；字距是排版時才加，不必放進鍵。
    nonisolated(unsafe) private static let cache: NSCache<CacheKey, FormlessArcTextMetrics> = {
        let cache = NSCache<CacheKey, FormlessArcTextMetrics>()
        cache.countLimit = 200
        return cache
    }()

    static func measure(_ text: String, font: CTFont) -> FormlessArcTextMetrics {
        let key = CacheKey(text: text, font: font)
        if let hit = cache.object(forKey: key) { return hit }
        let result = make(text, font: font)
        cache.setObject(result, forKey: key)
        return result
    }

    private static func make(_ text: String, font: CTFont) -> FormlessArcTextMetrics {
        // 曲線文字只有一行：換行、定位字元當空白。
        let strings = text.map { $0.isNewline || $0 == "\t" ? " " : String($0) }
        guard !strings.isEmpty else {
            return FormlessArcTextMetrics(letters: [], ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font))
        }
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        func line(_ string: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        }

        var widths: [CGFloat] = [], glyphCounts: [Int] = [], blanks: [Bool] = [], colors: [Bool] = []
        var ascent: CGFloat = 0, descent: CGFloat = 0, hasInk = false
        for string in strings {
            let single = line(string)
            var lineAscent: CGFloat = 0, lineDescent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(single, &lineAscent, &lineDescent, nil))
            let blank = string.allSatisfy(\.isWhitespace)
            widths.append(width.isFinite ? max(0, width) : 0)
            glyphCounts.append(CTLineGetGlyphCount(single))
            blanks.append(blank)
            colors.append(!blank && usesColorGlyphs(single))
            // 空白用的是英文字型，不能讓它把全中文的行高撐高。
            if !blank {
                ascent = max(ascent, lineAscent)
                descent = max(descent, lineDescent)
                hasInk = true
            }
        }
        if !hasInk {
            ascent = CTFontGetAscent(font)
            descent = CTFontGetDescent(font)
        }

        var letters: [Letter] = []
        letters.reserveCapacity(strings.count)
        for index in strings.indices {
            var kern: CGFloat = 0
            if index + 1 < strings.count {
                // 兩個字一起排的寬度減掉各自的寬度就是字距調整。若兩字合成連字（字形數變少），逐字畫不出連字，就不調。
                let pair = line(strings[index] + strings[index + 1])
                if CTLineGetGlyphCount(pair) == glyphCounts[index] + glyphCounts[index + 1] {
                    let value = CGFloat(CTLineGetTypographicBounds(pair, nil, nil, nil)) - widths[index] - widths[index + 1]
                    if value.isFinite { kern = value }
                }
            }
            letters.append(Letter(string: strings[index], width: widths[index], kern: kern,
                                  isBlank: blanks[index], isColor: colors[index]))
        }
        return FormlessArcTextMetrics(letters: letters, ascent: ascent, descent: descent)
    }

    /// 這個字是否用到彩色字型（Apple Color Emoji 之類）。
    private static func usesColorGlyphs(_ line: CTLine) -> Bool {
        // CoreText 的字形段一定是 CTRun、字型屬性一定是 CTFont，直接轉型。
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            if CTFontGetSymbolicTraits(value as! CTFont).contains(.traitColorGlyphs) { return true }
        }
        return false
    }

    /// NSCache 的鍵：文字與字型都相同才算同一個。
    private final class CacheKey: NSObject {
        let text: String
        let font: CTFont

        init(text: String, font: CTFont) {
            self.text = text
            self.font = font
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(text)
            hasher.combine(CFHash(font))
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else { return false }
            return text == other.text && CFEqual(font, other.font)
        }
    }
}
