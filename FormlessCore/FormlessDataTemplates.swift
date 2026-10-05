import Foundation

// MARK: - 網路資料範本
//
// 選了就能用的公開資料：不需要帳號、不需要金鑰。每一個都在 2026-10-04 用 curl 實際抓過，
// 建議欄位是當天回應裡確定有的欄位 id（對應各供應者 fields(for:snapshot:) 的 id）。

/// 一個網路資料範本。
struct FormlessDataTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    /// 一行說明。
    let detail: String
    /// 資料出處（面板顯示「資料來自 …」）。
    let attribution: String
    /// 供應者 id：json、rss、csv。
    let provider: String
    let url: String
    /// 建議的欄位 id。
    let suggestedFields: [String]
    /// 更新頻率（秒，對應來源設定「更新頻率」的選項）。
    var refresh: String = "3600"
}

enum FormlessDataTemplates {
    static let all: [FormlessDataTemplate] = [
        FormlessDataTemplate(
            id: "exchange-usd", name: "匯率（美元兌各國）", symbol: "dollarsign.circle",
            detail: "1 美元換多少新臺幣、日圓、歐元，每天更新", attribution: "ExchangeRate-API",
            provider: "json", url: "https://open.er-api.com/v6/latest/USD",
            suggestedFields: ["rates.TWD", "rates.JPY", "rates.EUR", "rates.CNY", "time_last_update_utc"], refresh: "21600"),
        FormlessDataTemplate(
            id: "bank-of-taiwan", name: "臺灣銀行牌告匯率", symbol: "building.columns",
            detail: "各幣別的現金與即期匯率；「即期」是買入，「即期 2」是賣出", attribution: "臺灣銀行",
            provider: "csv", url: "https://rate.bot.com.tw/xrt/flcsv/0/day",
            suggestedFields: ["rows", "column.即期 2", "column.現金 2"], refresh: "3600"),
        FormlessDataTemplate(
            id: "crypto", name: "加密貨幣價格", symbol: "bitcoinsign.circle",
            detail: "比特幣、以太幣的新臺幣與美元價格，含 24 小時漲跌（%）", attribution: "CoinGecko",
            provider: "json",
            url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd,twd&include_24hr_change=true",
            suggestedFields: ["bitcoin.twd", "bitcoin.usd", "bitcoin.twd_24h_change", "ethereum.twd", "ethereum.usd"], refresh: "900"),
        FormlessDataTemplate(
            id: "taiex", name: "台股指數", symbol: "chart.line.uptrend.xyaxis",
            detail: "證交所各項指數收盤，第 2 筆是加權指數", attribution: "臺灣證券交易所",
            provider: "json", url: "https://openapi.twse.com.tw/v1/exchangeReport/MI_INDEX",
            suggestedFields: ["[]"], refresh: "3600"),
        FormlessDataTemplate(
            id: "nasa-iotd", name: "NASA 每日一圖", symbol: "photo",
            detail: "NASA 每天精選的太空照片", attribution: "NASA",
            provider: "rss", url: "https://www.nasa.gov/feeds/iotd-feed/",
            suggestedFields: ["latestImage", "latestTitle", "latestDate", "items"], refresh: "21600"),
        FormlessDataTemplate(
            id: "cwa-taipei", name: "臺北市天氣預報", symbol: "cloud.sun",
            detail: "中央氣象署臺北市今明天氣預報", attribution: "中央氣象署",
            provider: "rss", url: "https://www.cwa.gov.tw/rss/forecast/36_01.xml",
            suggestedFields: ["latestTitle", "items"], refresh: "3600"),
        FormlessDataTemplate(
            id: "cna-finance", name: "中央社財經新聞", symbol: "newspaper",
            detail: "中央社即時新聞的財經類", attribution: "中央社",
            provider: "rss", url: "https://feeds.feedburner.com/rsscna/finance",
            suggestedFields: ["latestTitle", "latestDate", "items"], refresh: "1800"),
        FormlessDataTemplate(
            id: "ltn-breaking", name: "自由時報即時新聞", symbol: "newspaper",
            detail: "自由時報各類即時新聞", attribution: "自由時報",
            provider: "rss", url: "https://news.ltn.com.tw/rss/all.xml",
            suggestedFields: ["latestTitle", "latestDate", "items"], refresh: "900"),
        FormlessDataTemplate(
            id: "yahoo-tw", name: "Yahoo奇摩新聞", symbol: "newspaper",
            detail: "Yahoo奇摩新聞最新消息，多數附圖片", attribution: "Yahoo奇摩新聞",
            provider: "rss", url: "https://tw.news.yahoo.com/rss/",
            suggestedFields: ["latestTitle", "latestImage", "items"], refresh: "900"),
        FormlessDataTemplate(
            id: "bbc-chinese", name: "BBC 中文", symbol: "globe.asia.australia",
            detail: "BBC 中文網繁體版的新聞", attribution: "BBC News 中文",
            provider: "rss", url: "https://feeds.bbci.co.uk/zhongwen/trad/rss.xml",
            suggestedFields: ["latestTitle", "latestImage", "items"], refresh: "1800"),
        FormlessDataTemplate(
            id: "ithome", name: "iThome 新聞", symbol: "desktopcomputer",
            detail: "iThome 的科技與資安新聞", attribution: "iThome",
            provider: "rss", url: "https://www.ithome.com.tw/rss",
            suggestedFields: ["latestTitle", "items"], refresh: "1800"),
        FormlessDataTemplate(
            id: "hacker-news", name: "Hacker News 熱門", symbol: "flame",
            detail: "Hacker News 首頁的熱門文章（英文）", attribution: "Hacker News",
            provider: "json", url: "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=10",
            suggestedFields: ["hits"], refresh: "1800"),
        FormlessDataTemplate(
            id: "usgs-quakes", name: "全球地震", symbol: "waveform.path.ecg",
            detail: "過去一天全球規模 4.5 以上的地震（英文地名）", attribution: "美國地質調查局（USGS）",
            provider: "json", url: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson",
            suggestedFields: ["features", "metadata.count"], refresh: "1800"),
        FormlessDataTemplate(
            id: "swift-releases", name: "GitHub 新版本", symbol: "shippingbox",
            detail: "專案的新版本（範例是 Swift）；網址換成其他專案的 /releases.atom 即可", attribution: "GitHub",
            provider: "rss", url: "https://github.com/swiftlang/swift/releases.atom",
            suggestedFields: ["latestTitle", "latestDate", "items"], refresh: "21600")
    ]

    static func template(_ id: String) -> FormlessDataTemplate? { all.first { $0.id == id } }

    /// 用範本建立這份設計自己的來源：新的 UUID、名稱是範本名稱，設定是網址與更新頻率；
    /// 另外帶著出處（不在設定頁顯示），面板的「資料來自 …」用它（部分資料的使用條款要求標明出處）。
    static func source(for template: FormlessDataTemplate) -> FormlessSource {
        FormlessSource(id: UUID().uuidString, provider: template.provider, name: template.name,
                       settings: ["url": .text(template.url), "refresh": .text(template.refresh), "attribution": .text(template.attribution)])
    }
}
