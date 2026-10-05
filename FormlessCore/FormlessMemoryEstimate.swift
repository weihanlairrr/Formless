import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 小工具記憶體估算
//
// 小工具延伸的記憶體上限，社群回報與 Apple 論壇的當機紀錄都是 30 MB（EXC_RESOURCE RESOURCE_TYPE_MEMORY，
// limit=30 MB，看的是最高用量）；超過時系統直接結束延伸，整個小工具空白。官方文件沒有寫數字。
//
// 小工具怎麼畫圖（2026-10-04 讀 FormlessShared.swift）：
// - 背景與圖片圖層：FormlessLoadedAsset → FormlessAssetCache.image(named:) → UIImage(data:)，原尺寸解碼，沒有縮圖。
//   圖片庫匯入時最長邊縮到 2048（FormlessAssetLibrary.maxSide），一張最大 2048 × 2048。
// - 網路圖片：下載的原始資料（最多 8 MB，像素不限）放在 FormlessLiveData.remoteImages，
//   2026-10 起 FormlessRemoteImageMemo 也依畫出來的大小解碼，但原始資料仍留在記憶體。
// - 天氣自訂圖示：WeatherStyleView.shrink 縮到 512 pt，但用預設格式（3 倍）畫，實際是 1536 px；
//   iPhone 相機的照片（Display P3）縮完存成 16 位元 PNG（模擬器實測 1536×1152、解碼後 13.5 MB 一張），
//   sRGB 的圖是 8 位元（同尺寸 6.8 MB）。
// - 內建素材（提醒事項、行程刻度、bundleImage 圖層）：資源目錄裡的小圖，原尺寸解碼。
//
// 估算方式（`decodesAtDisplaySize` 為 false，也就是目前的畫法）：
// - 每張圖：寬 × 高 × 每像素 bytes（8 位元 4、16 位元 8），加上檔案本身的大小——UIImage(data:) 會一直留著
//   原始資料，以便需要時重新解碼。同一張圖用在好幾個地方只算一次（同一個 UIImage）。
// - 解碼當下的暫存：模擬器實測完整解碼時最高用量約是點陣圖的兩倍（2048×1536 JPEG +25 MB、2048² PNG +33 MB、
//   1024² PNG +9 MB），所以最大的那張圖再多算一份點陣圖。
// - 基本用量 12 MB：小工具延伸本身（系統框架、Formless 的程式、設計檔、行事曆與天氣資料、時間軸）。
//   實機沒有量過。模擬器上的命令列程式載入 Formless 的程式、用 ImageRenderer 畫一份只有文字與色塊的中型設計
//   （3 倍），用量從 5.2 MB 到 13 MB，其中畫出來的點陣圖 2.2 MB 小工具不會留著；延伸另外還有 WidgetKit 的封存、
//   EventKit 與資料，取 12 MB。
// - 字型：CoreText 用記憶體對映讀字型檔，檔案本身不算進用量；實際占用的是讀進來的字形與表格。
//   模擬器實測 64 MB 的宋體畫 300～3000 個字多 1.5～1.7 MB、22 MB 的字型多 0.1～2.1 MB，
//   估成 0.5 MB 加檔案大小的 2.5%（不超過檔案大小）。
//
// 門檻：22 MB 以上「偏高」、27 MB 以上「過高」。上限 30 MB，「過高」留 3 MB（一成）給估不準的部分
// （基本用量是估的，時間軸的筆數與資料多寡會變）；「偏高」是基本用量之外的圖片與字型已經用到 10 MB
// （例如兩張 1024 × 1024 的圖），提早提醒。

struct FormlessMemoryEstimate: Sendable {

    /// 占用較多的一項。圖片與字型掛在用到它的圖層上（第一個），背景圖片的 id 是設計本身的 id。
    struct Item: Sendable, Identifiable {
        let id: UUID
        let name: String
        let bytes: Int
    }

    enum Level: Sendable { case ok, high, tooHigh }

    /// 估計的最高用量（含基本用量）。
    let totalBytes: Int
    /// 由大到小；只列 256 KB 以上的項目，其餘仍算在總量裡。
    let items: [Item]

    var level: Level { Self.level(for: totalBytes) }

    static let megabyte = 1024 * 1024
    /// 小工具延伸的記憶體上限（社群回報）。
    static let limitBytes = 30 * megabyte
    static let baseBytes = 12 * megabyte
    static let highBytes = 22 * megabyte
    static let tooHighBytes = 27 * megabyte
    static let minimumListedBytes = 256 * 1024

    /// 小工具目前用原尺寸解碼圖片（見檔案開頭）。改成依顯示尺寸縮圖、並改用 CGImageSourceCreateWithURL 讀檔
    /// （不留原始資料）之後改成 true：圖片改用「顯示尺寸 × 3 倍」計算，也不再加檔案大小。
    /// 2026-10 起小工具依畫出來的大小解碼（`FormlessAssetCache.image(named:drawnIn:fill:)`），從檔案讀、不留原始資料。
    static let decodesAtDisplaySize = true
    /// 使用者的手機（iPhone Air）是 3 倍螢幕。
    static let deviceScale: CGFloat = 3

    static func level(for bytes: Int) -> Level {
        if bytes >= tooHighBytes { return .tooHigh }
        if bytes >= highBytes { return .high }
        return .ok
    }

    /// 估算一份設計在小工具上的最高用量。會讀圖片檔頭（快取）與網路圖片的快取資料，請在背景執行緒呼叫。
    static func estimate(_ document: FormlessDocument) -> FormlessMemoryEstimate {
        estimate(document, sources: .shared)
    }

    /// 估算時去哪裡找圖片與字型。App 用共用資料夾；測試用暫存資料夾，不碰使用者的資料。
    struct Sources {
        var assetsDirectory: URL?
        var fonts: [FormlessImportedFont]
        var weatherImageNames: [String]
        var remoteImage: (String) -> Data?
        /// 資源目錄裡的圖片的像素尺寸。
        var bundleImagePixels: (String) -> CGSize?

        static var shared: Sources {
            Sources(
                assetsDirectory: FormlessStorage.assetsDirectoryURL,
                fonts: FormlessFontLibrary.installed(),
                weatherImageNames: Array(FormlessWeatherStyle.current().images.values),
                remoteImage: { FormlessRemoteImageCache.load(for: $0) },
                bundleImagePixels: { name in
                    #if canImport(UIKit)
                    guard let image = UIImage(named: name) else { return nil }
                    return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
                    #else
                    return nil
                    #endif
                }
            )
        }
    }

    static func estimate(_ document: FormlessDocument, sources: Sources) -> FormlessMemoryEstimate {
        let canvas = CGSize(width: document.family.referenceWidth, height: document.family.referenceHeight)
        let layers = document.visibleSortedLayers
        var images: [ImageCost] = []
        var seen = Set<String>()

        // 背景：填滿畫布。和圖層用同一張圖時只算一次。
        if let name = document.activeBackgroundImageName, seen.insert("asset:" + name).inserted,
           let metrics = assetMetrics(name, sources) {
            images.append(ImageCost(id: document.id, name: "背景圖片", metrics: metrics, box: canvas, fills: true))
        }

        for layer in layers {
            let box = FormlessLayerLayout.rect(for: layer, canvasSize: canvas).size
            let name = layer.name.isEmpty ? layer.type.displayName : layer.name

            if layer.type == .image, let asset = layer.value, seen.insert("asset:" + asset).inserted,
               let metrics = assetMetrics(asset, sources) {
                images.append(ImageCost(id: layer.id, name: name, metrics: metrics, box: box, fills: false))
            } else if layer.type == .remoteImage, let text = layer.value, seen.insert("remote:" + text).inserted,
                      let metrics = remoteMetrics(text, sources) {
                images.append(ImageCost(id: layer.id, name: name, metrics: metrics, box: box, fills: false, keepsData: true))
            } else {
                // 內建素材：資源目錄裡的小圖，沒有原始資料要留（資源目錄自己管）。
                var pixels = 0, largest = 0
                for asset in bundleAssets(of: layer) where seen.insert("bundle:" + asset).inserted {
                    if let size = sources.bundleImagePixels(asset) {
                        let count = Int(size.width) * Int(size.height)
                        pixels += count
                        largest = max(largest, count)
                    }
                }
                if pixels > 0 {
                    let metrics = FormlessImageMetrics(width: pixels, height: 1, bytesPerPixel: 4, fileBytes: 0)
                    var cost = ImageCost(id: layer.id, name: name, metrics: metrics, box: nil, fills: false)
                    cost.largestSingleOverride = largest * 4
                    images.append(cost)
                }
            }
        }

        if let weather = weatherCost(layers: layers, sources: sources) {
            images.append(weather)
        }

        // 解碼當下的暫存：一次解一張，最大的那張圖多一份點陣圖（實測完整解碼的最高用量約是點陣圖的兩倍）。
        if let largest = images.indices.max(by: { images[$0].largestSingleBytes < images[$1].largestSingleBytes }) {
            images[largest].transientBytes = images[largest].largestSingleBytes
        }

        var items = images.map { Item(id: $0.id, name: $0.name, bytes: $0.totalBytes) }
        items.append(contentsOf: fontItems(layers: layers, fonts: sources.fonts))

        let total = baseBytes + items.reduce(0) { $0 + $1.bytes }
        let listed = items.filter { $0.bytes >= minimumListedBytes }.sorted { $0.bytes > $1.bytes }
        return FormlessMemoryEstimate(totalBytes: total, items: listed)
    }

    // MARK: 字型

    /// 一個用到的字面：0.5 MB 加檔案大小的 2.5%，不超過檔案大小（見檔案開頭的實測）。
    static func fontBytes(fileSize: Int) -> Int {
        guard fileSize > 0 else { return 512 * 1024 }
        return min(fileSize, 512 * 1024 + fileSize / 40)
    }

    /// 文字圖層用到的匯入字型，每個字面算一次，掛在第一個用到它的圖層上。
    private static func fontItems(layers: [FormlessLayer], fonts: [FormlessImportedFont]) -> [Item] {
        let textTypes: Set<FormlessLayerType> = [.text, .date, .time, .liveText]
        var seen = Set<String>()
        var items: [Item] = []
        for layer in layers where textTypes.contains(layer.type) {
            guard let name = FormlessFontLibrary.postScriptName(fromFamily: layer.fontFamily),
                  seen.insert(name).inserted,
                  let font = fonts.first(where: { $0.postScriptName == name }) else { continue }
            items.append(Item(id: layer.id, name: "字型「\(font.displayName)」", bytes: fontBytes(fileSize: font.fileSize)))
        }
        return items
    }

    // MARK: 天氣自訂圖示

    /// 每個天氣圖示的位置都可能是不同天氣的自訂圖：位置數（目前天氣 1 個、預報每天 1 個）以內，
    /// 取最大的幾張自訂圖。沒有自訂圖時用內建的小圖示（每張約 0.1 MB），算在基本用量裡。
    private static func weatherCost(layers: [FormlessLayer], sources: Sources) -> ImageCost? {
        var slots = 0
        var owner: FormlessLayer?
        for layer in layers {
            let count: Int
            switch layer.type {
            case .weather: count = 6                                         // 目前天氣 + 5 天預報
            case .weatherForecast: count = min(max(1, layer.maxItems ?? 5), 5)
            case .symbol where layer.value == "auto:weather": count = 1
            default: count = 0
            }
            if count > 0, owner == nil { owner = layer }
            slots += count
        }
        guard slots > 0, let owner else { return nil }

        let custom = Set(sources.weatherImageNames).compactMap { assetMetrics($0, sources) }
            .sorted { $0.decodedBytes > $1.decodedBytes }
            .prefix(slots)
        guard !custom.isEmpty else { return nil }

        let combined = FormlessImageMetrics(
            width: custom.reduce(0) { $0 + $1.width * $1.height * $1.bytesPerPixel / 4 },
            height: 1,
            bytesPerPixel: 4,
            fileBytes: custom.reduce(0) { $0 + $1.fileBytes }
        )
        // 圖示畫得很小，但目前原尺寸解碼，整張算。解碼暫存一次只有一張：取最大的那張。
        var cost = ImageCost(id: owner.id, name: "天氣自訂圖示", metrics: combined, box: nil, fills: false)
        cost.largestSingleOverride = custom.first?.decodedBytes
        return cost
    }

    /// 元件與 bundleImage 圖層用到的資源目錄圖片。
    private static func bundleAssets(of layer: FormlessLayer) -> [String] {
        switch layer.type {
        case .bundleImage: return layer.value.map { [$0] } ?? []
        case .reminders: return ["ReminderBackground", "ReminderIcon"]
        case .events: return ["EventRuler"]
        case .ruler: return [layer.value ?? "EventRuler"]
        default: return []
        }
    }

    // MARK: 讀圖片尺寸

    /// 圖片庫的檔案：只讀檔頭（CGImageSourceCopyPropertiesAtIndex），不解碼。依路徑、修改時間與大小快取。
    private static func assetMetrics(_ name: String, _ sources: Sources) -> FormlessImageMetrics? {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
              let directory = sources.assetsDirectory else { return nil }
        return imageMetrics(at: directory.appendingPathComponent(name))
    }

    static func imageMetrics(at url: URL) -> FormlessImageMetrics? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let stamp = FormlessImageStamp(
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0
        )
        if let hit = metricsCache.lookup(url.path, stamp: stamp) { return hit }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let metrics = imageMetrics(from: source, fileBytes: stamp.size) else { return nil }
        metricsCache.store(url.path, stamp: stamp, metrics: metrics)
        return metrics
    }

    /// 網路圖片：快取檔的位置不公開，只能整份讀進來看檔頭。網路圖片 6 小時才換一次，十分鐘內不重讀。
    private static func remoteMetrics(_ text: String, _ sources: Sources) -> FormlessImageMetrics? {
        if let hit = metricsCache.recentRemote(text) { return hit }
        guard let data = sources.remoteImage(text),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metrics = imageMetrics(from: source, fileBytes: data.count) else { return nil }
        metricsCache.storeRemote(text, metrics: metrics)
        return metrics
    }

    private static func imageMetrics(from source: CGImageSource, fileBytes: Int) -> FormlessImageMetrics? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // 每個色彩分量超過 8 位元（16 位元 PNG、10 位元 HEIF）解碼後每像素 8 bytes。
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        return FormlessImageMetrics(width: width, height: height, bytesPerPixel: depth > 8 ? 8 : 4, fileBytes: fileBytes)
    }

    private static let metricsCache = FormlessImageMetricsCache()
}


/// 一張圖的像素尺寸與檔案大小。
struct FormlessImageMetrics: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytesPerPixel: Int
    let fileBytes: Int

    /// 原尺寸解碼後的點陣圖大小。
    var decodedBytes: Int { width * height * bytesPerPixel }
}

/// 估算中的一張圖（或一組天氣圖示）。
private struct ImageCost {
    let id: UUID
    let name: String
    let metrics: FormlessImageMetrics
    /// 顯示的框（點）；nil 表示不縮圖（內建素材、天氣圖示）。
    let box: CGSize?
    /// 背景填滿畫布（scaledToFill）；圖層是 scaledToFit。
    let fills: Bool
    var transientBytes = 0
    /// 一組圖（天氣圖示）裡最大的一張；單張圖是 nil。
    var largestSingleOverride: Int?
    /// 原始資料一直留在記憶體（網路圖片下載的資料放在 FormlessLiveData.remoteImages）。
    var keepsData = false

    init(id: UUID, name: String, metrics: FormlessImageMetrics, box: CGSize?, fills: Bool, keepsData: Bool = false) {
        self.id = id
        self.name = name
        self.metrics = metrics
        self.box = box
        self.fills = fills
        self.keepsData = keepsData
    }

    /// 解碼後的點陣圖：目前原尺寸；改成縮圖後是顯示尺寸 × 3 倍（不放大）。
    var decodedBytes: Int {
        guard FormlessMemoryEstimate.decodesAtDisplaySize, let box, metrics.width > 0, metrics.height > 0 else {
            return metrics.decodedBytes
        }
        let scale = FormlessMemoryEstimate.deviceScale
        let width = CGFloat(metrics.width), height = CGFloat(metrics.height)
        let ratio = fills
            ? max(box.width * scale / width, box.height * scale / height)
            : min(box.width * scale / width, box.height * scale / height)
        guard ratio < 1 else { return metrics.decodedBytes }
        return Int((width * ratio).rounded(.up)) * Int((height * ratio).rounded(.up)) * metrics.bytesPerPixel
    }

    /// 解碼時一次解一張：這一項裡最大的一張點陣圖。
    var largestSingleBytes: Int { largestSingleOverride ?? decodedBytes }

    /// 圖片庫的圖改從檔案讀縮圖之後不再留原始資料；網路圖片下載的資料仍在記憶體裡。
    var keptFileBytes: Int {
        FormlessMemoryEstimate.decodesAtDisplaySize && box != nil && !keepsData ? 0 : metrics.fileBytes
    }

    var totalBytes: Int { decodedBytes + keptFileBytes + transientBytes }
}

private struct FormlessImageStamp: Equatable {
    let modified: Date
    let size: Int
}

private final class FormlessImageMetricsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (stamp: FormlessImageStamp, metrics: FormlessImageMetrics)] = [:]
    private var remote: [String: (at: Date, metrics: FormlessImageMetrics)] = [:]
    private static let remoteLifetime: TimeInterval = 600

    func lookup(_ path: String, stamp: FormlessImageStamp) -> FormlessImageMetrics? {
        lock.withLock {
            guard let hit = files[path], hit.stamp == stamp else { return nil }
            return hit.metrics
        }
    }

    func store(_ path: String, stamp: FormlessImageStamp, metrics: FormlessImageMetrics) {
        lock.withLock {
            if files.count > 500 { files.removeAll() }
            files[path] = (stamp, metrics)
        }
    }

    func recentRemote(_ text: String) -> FormlessImageMetrics? {
        lock.withLock {
            guard let hit = remote[text], Date().timeIntervalSince(hit.at) < Self.remoteLifetime else { return nil }
            return hit.metrics
        }
    }

    func storeRemote(_ text: String, metrics: FormlessImageMetrics) {
        lock.withLock {
            if remote.count > 100 { remote.removeAll() }
            remote[text] = (Date(), metrics)
        }
    }
}
