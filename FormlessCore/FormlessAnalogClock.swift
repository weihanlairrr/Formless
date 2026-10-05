import Foundation
import SwiftUI

// MARK: - 指針時鐘
//
// 小工具上的類比時鐘：時針、分針，沒有秒針（小工具不能每秒更新，時間軸每分鐘一格）。
// 錶盤是框的內切圓、置中；刻度、數字、指針的長短粗細都是半徑的比例，20 點到 400 點的錶盤看起來一樣協調。
// 用 Canvas 畫（小工具可用），只用 SwiftUI，App、小工具延伸、macOS 測試都能編譯。

enum FormlessClockMarks: String, Codable, CaseIterable, Sendable {
    /// 無刻度、12 個小時刻度、60 個分鐘刻度（小時刻度較粗較長）。
    case none, hours, minutes

    var displayName: String {
        switch self {
        case .none: return "無"
        case .hours: return "小時"
        case .minutes: return "分鐘"
        }
    }
}

enum FormlessClockNumerals: String, Codable, CaseIterable, Sendable {
    /// 無數字、只有 12 3 6 9、1 到 12。
    case none, quarters, all

    var displayName: String {
        switch self {
        case .none: return "無"
        case .quarters: return "四個"
        case .all: return "全部"
        }
    }
}

struct FormlessAnalogClockView: View {
    let date: Date
    var timeZone: TimeZone? = nil      // nil 用目前時區
    var marks: FormlessClockMarks = .hours
    var numerals: FormlessClockNumerals = .none
    var numeralFont: Font? = nil        // nil 時依錶盤大小自動算系統字型大小
    var faceColor: Color? = nil         // nil 是透明錶盤
    var markColor: Color = .primary
    var hourHandColor: Color = .primary
    var minuteHandColor: Color = .primary
    var centerColor: Color? = nil       // 中心圓點；nil 用分針顏色
    /// 指針與刻度的粗細倍率，1 是預設。
    var weight: CGFloat = 1

    var body: some View {
        let dial = FormlessClockDial(
            date: date, timeZone: timeZone ?? .current, marks: marks, numerals: numerals,
            numeralFont: numeralFont, faceColor: faceColor, markColor: markColor,
            hourHandColor: hourHandColor, minuteHandColor: minuteHandColor,
            centerColor: centerColor ?? minuteHandColor, weight: weight
        )
        Canvas { context, size in
            dial.draw(in: &context, size: size)
        }
        // Canvas 沒有文字可唸，旁白改唸時間。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(date, format: Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone ?? .current)))
    }
}

// MARK: - 繪製

/// 畫錶盤需要的值。和 View 分開，Canvas 的繪製不綁在主執行緒。
private struct FormlessClockDial {
    let date: Date
    let timeZone: TimeZone
    let marks: FormlessClockMarks
    let numerals: FormlessClockNumerals
    let numeralFont: Font?
    let faceColor: Color?
    let markColor: Color
    let hourHandColor: Color
    let minuteHandColor: Color
    let centerColor: Color
    let weight: CGFloat

    /// 以半徑為 1 的比例。參考蘋果時鐘 App 與 Apple Watch 簡約錶面：刻度貼近外緣、小時刻度粗長、
    /// 時針到數字內側、分針到刻度，指針從圓心先是一段細頸再接粗的本體，兩端圓角。
    private enum Ratio {
        /// 刻度外緣離圓心的距離。
        static let markOuter: CGFloat = 0.95
        static let hourMarkLength: CGFloat = 0.12
        static let hourMarkWidth: CGFloat = 0.032
        static let minuteMarkLength: CGFloat = 0.06
        static let minuteMarkWidth: CGFloat = 0.012
        /// 數字外緣和刻度內緣（沒有刻度時是錶盤外緣）的距離。
        static let numeralGap: CGFloat = 0.06
        /// 自動字型大小：1 到 12 較小，只有四個時較大。
        static let numeralSizeAll: CGFloat = 0.18
        static let numeralSizeQuarters: CGFloat = 0.24
        static let hourHandLength: CGFloat = 0.5
        static let minuteHandLength: CGFloat = 0.86
        static let handWidth: CGFloat = 0.06
        /// 細頸長度與粗細（粗細是本體的比例）。
        static let stemLength: CGFloat = 0.14
        static let stemWidth: CGFloat = 0.4
        /// 中心圓點半徑（指針本體粗細的比例）。
        static let centerRadius: CGFloat = 0.9
        /// 指針四周挖空的間隙：指針蓋過刻度、數字時看得出是兩樣東西，不會黏成一條。
        static let handClearance: CGFloat = 0.02
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let radius = min(size.width, size.height) / 2
        guard radius > 0, radius.isFinite else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // 再細的線至少一個實體像素，小錶盤的分鐘刻度才不會消失。
        let pixel = 1 / max(1, context.environment.displayScale)
        let weight = weight.isFinite ? max(0, weight) : 1

        // 指針：時、分在指定時區取；不含秒，同一分鐘畫出來都一樣。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        let hourAngle = (Double(hour % 12) + Double(minute) / 60) * 30
        let minuteAngle = Double(minute) * 6
        let handWidth = max(pixel * 2, Ratio.handWidth * radius * weight)
        let stemWidth = min(handWidth, max(pixel * 2, handWidth * Ratio.stemWidth))
        let stemLength = Ratio.stemLength * radius
        let hourHand = Self.hand(center: center, degrees: hourAngle, length: Ratio.hourHandLength * radius,
                                 width: handWidth, stemLength: stemLength, stemWidth: stemWidth)
        let minuteHand = Self.hand(center: center, degrees: minuteAngle, length: Ratio.minuteHandLength * radius,
                                   width: handWidth, stemLength: stemLength, stemWidth: stemWidth)

        if let faceColor {
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(faceColor))
        }

        // 刻度與數字畫在同一層，再把指針四周挖空：透明錶盤也一樣，挖空處露出底下的東西。
        if marks != .none || numerals != .none {
            context.drawLayer { layer in
                let numeralLimit = drawMarks(in: &layer, center: center, radius: radius, pixel: pixel, weight: weight)
                drawNumerals(in: &layer, center: center, radius: radius, limit: numeralLimit)
                let clearance = max(pixel, Ratio.handClearance * radius)
                let outline = StrokeStyle(lineWidth: clearance * 2, lineCap: .round, lineJoin: .round)
                layer.blendMode = .destinationOut
                layer.fill(hourHand.union(hourHand.strokedPath(outline)), with: .color(.black))
                layer.fill(minuteHand.union(minuteHand.strokedPath(outline)), with: .color(.black))
            }
        }

        // 時針在下、分針在上，中心圓點蓋住兩支指針的根部。
        context.fill(hourHand, with: .color(hourHandColor))
        context.fill(minuteHand, with: .color(minuteHandColor))
        let dot = handWidth * Ratio.centerRadius
        context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)),
                     with: .color(centerColor))
    }

    /// 畫刻度，回傳數字可以用到的最外圈半徑（刻度內緣；沒有刻度是刻度外緣）。
    private func drawMarks(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                           pixel: CGFloat, weight: CGFloat) -> CGFloat {
        let outer = Ratio.markOuter * radius
        guard marks != .none else { return outer }
        let count = marks == .minutes ? 60 : 12
        var hourPath = Path(), minutePath = Path()
        for index in 0..<count {
            let isHour = marks == .hours || index % 5 == 0
            let length = (isHour ? Ratio.hourMarkLength : Ratio.minuteMarkLength) * radius
            let direction = Self.direction(degrees: Double(index) * 360 / Double(count))
            if isHour {
                hourPath.move(to: Self.point(center, direction, outer))
                hourPath.addLine(to: Self.point(center, direction, outer - length))
            } else {
                minutePath.move(to: Self.point(center, direction, outer))
                minutePath.addLine(to: Self.point(center, direction, outer - length))
            }
        }
        context.stroke(minutePath, with: .color(markColor),
                       style: StrokeStyle(lineWidth: max(pixel, Ratio.minuteMarkWidth * radius * weight), lineCap: .butt))
        context.stroke(hourPath, with: .color(markColor),
                       style: StrokeStyle(lineWidth: max(pixel, Ratio.hourMarkWidth * radius * weight), lineCap: .butt))
        return outer - Ratio.hourMarkLength * radius
    }

    /// 數字：正立；每個數字沿半徑方向和刻度保持同樣的距離（10、11、12 較寬，會往內一點）。
    private func drawNumerals(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, limit: CGFloat) {
        guard numerals != .none else { return }
        let values = numerals == .all ? Array(1...12) : [12, 3, 6, 9]
        let size = (numerals == .all ? Ratio.numeralSizeAll : Ratio.numeralSizeQuarters) * radius
        let font = numeralFont ?? .system(size: max(1, size), weight: .medium)
        let gap = Ratio.numeralGap * radius
        for value in values {
            var text = context.resolve(Text(verbatim: "\(value)").font(font))
            text.shading = .color(markColor)
            let box = text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            guard box.width > 0, box.height > 0 else { continue }
            // 數字本身約佔行高的六成（基線到數字頂），以數字筆畫的中心對位，而不是整個行框的中心。
            let halfHeight = box.height * 0.3
            let direction = Self.direction(degrees: Double(value % 12) * 30)
            let extent = abs(direction.dx) * box.width / 2 + abs(direction.dy) * halfHeight
            let distance = max(0, limit - gap - extent)
            let baseline = text.firstBaseline(in: box)
            context.draw(text, at: Self.point(center, direction, distance),
                         anchor: UnitPoint(x: 0.5, y: (baseline - halfHeight) / box.height))
        }
    }

    /// 一支指針的外形：圓心到細頸末端的細線，接著圓頭的粗本體到指針尖端。合成一個外形，半透明的顏色才不會在接縫疊深。
    private static func hand(center: CGPoint, degrees: Double, length: CGFloat, width: CGFloat,
                             stemLength: CGFloat, stemWidth: CGFloat) -> Path {
        let direction = direction(degrees: degrees)
        var stem = Path()
        stem.move(to: center)
        stem.addLine(to: point(center, direction, stemLength))
        // 本體的圓頭從細頸末端開始、到 length 結束。
        let start = stemLength + width / 2
        var body = Path()
        body.move(to: point(center, direction, start))
        body.addLine(to: point(center, direction, max(start, length - width / 2)))
        return stem.strokedPath(StrokeStyle(lineWidth: stemWidth, lineCap: .round))
            .union(body.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)))
    }

    /// 從 12 點方向順時針轉 degrees 度的單位向量（y 往下）。
    private static func direction(degrees: Double) -> CGVector {
        let radians = degrees * .pi / 180
        return CGVector(dx: sin(radians), dy: -cos(radians))
    }

    private static func point(_ center: CGPoint, _ direction: CGVector, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: center.x + direction.dx * distance, y: center.y + direction.dy * distance)
    }
}
