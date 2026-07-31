import AppKit

// Bu dosya, "ekrana ne çizeceğiz" işini yapıyor: menü çubuğu simgesi,
// açılan menü, renkler, tıklama davranışları. Hesaplama mantığı yok,
// o UsageData.swift'te.

// Yüzdeye göre renk seçiyor. NSColor'ı "red/green/blue" 0-1 arası ondalık
// sayılarla kuruyoruz (JS'teki #ff3b30 hex kodunun aynısı, sadece
// 0-255 yerine 0-1 arasına bölünmüş hâli — 255/255=1.00, 59/255=0.231 gibi).
func colorFor(_ pct: Int) -> NSColor {
    if pct >= 80 { return NSColor(red: 1.00, green: 0.231, blue: 0.188, alpha: 1) } // #ff3b30 kırmızı
    if pct >= 50 { return NSColor(red: 1.00, green: 0.624, blue: 0.039, alpha: 1) } // #ff9f0a turuncu
    return NSColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1) // #30d158 yeşil
}

// .secondaryLabelColor = sistemin kendi "soluk gri" rengi; açık/koyu temaya
// göre otomatik uyum sağlıyor, bizim hex girmemize gerek yok.
let grayText = NSColor.secondaryLabelColor
let warningColor = NSColor(red: 1.00, green: 0.624, blue: 0.039, alpha: 1) // #ff9f0a

// Menüdeki her satır düz metin değil, "renkli ve belirli boyutta" metin
// olduğu için NSAttributedString kullanıyoruz — normal String'e "şu renk,
// şu font" gibi ek bilgiler (attribute) yapıştırılmış hâli.
func attributed(_ text: String, color: NSColor, small: Bool = false) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .foregroundColor: color,
        .font: NSFont.menuFont(ofSize: small ? 11 : NSFont.systemFontSize),
    ])
}

// "class" = değiştirilebilir, referansla taşınan nesne türü (struct'ın
// aksine). "NSApplicationDelegate" = "NSApplication'ın önemli anlarda
// çağıracağı fonksiyonları barındırıyorum" demek (bkz. main.swift).
// "final" = bu sınıftan başka bir sınıf türetilemez demek, sadece bir
// güvenlik/performans notu, davranışı etkilemiyor.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // statusItem = menü çubuğundaki simgemizin kendisi. ".variableLength"
    // = genişliği içindeki metne göre otomatik ayarlansın (sabit piksel değil).
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Timer? — "?" yine Optional: uygulama henüz başlamadan bu nil (boş),
    // applicationDidFinishLaunching çalışınca gerçek bir Timer'la doluyor.
    private var timer: Timer?

    // NSApplication açıldığında SwiftAppKit bu fonksiyonu otomatik çağırır
    // (JS'teki "DOMContentLoaded" event'ine benzer bir "artık hazırım" anı).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = "Dock'ta simge gösterme, sadece menü çubuğunda yaşa".
        // SwiftBar'ın kendisinin yaptığı şeyin aynısı.
        NSApp.setActivationPolicy(.accessory)

        // SF Symbols, Apple'ın hazır ikon setinin adı; "bolt.fill" bizim
        // şimşek ikonumuz (SwiftBar'daki sfimage=bolt.fill ile aynı ikon).
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.fill", accessibilityDescription: "Claude Kullanım"
        )
        statusItem.button?.imagePosition = .imageLeading  // ikon solda, yüzde metni sağda

        refresh()  // uygulama açılır açılmaz bir kere hemen göster

        // Timer.scheduledTimer: "her 10 saniyede bir şu kapalı fonksiyonu
        // (closure) çalıştır" demek — SwiftBar'ın dosya adındaki ".10s."
        // ile yaptığı periyodik yenilemenin native karşılığı, ama artık
        // dış bir uygulamaya (SwiftBar'a) ihtiyaç duymadan biz yönetiyoruz.
        //
        // "{ [weak self] _ in ... }" bir closure (JS'teki () => {} gibi
        // anonim fonksiyon). "[weak self]" ise hafıza sızıntısını önleyen
        // bir güvenlik notu: Timer, AppDelegate'i "zayıf" (weak) referansla
        // tutuyor, yani AppDelegate bir gün yok edilirse Timer onu
        // sonsuza dek hayatta tutmaya zorlamıyor.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()  // "?" burada da Optional: self hâlâ varsa çağır, yoksa hiçbir şey yapma
        }
    }

    // Dosyayı okumayı dener; başarılıysa menüyü günceller, hata varsa
    // hata menüsünü gösterir. UsageData.swift'teki loadHistory() throws
    // olduğu için burada do/try/catch (JS'teki try/catch ile birebir aynı
    // mantık) kullanmak zorundayız.
    private func refresh() {
        let now = Date().timeIntervalSince1970 * 1000  // "şu an", milisaniye cinsinden
        do {
            let samples = try loadHistory()
            renderUsage(samples: samples, now: now)
        } catch {
            renderError(error)
        }
    }

    // Asıl "menü çubuğunda ne yazsın, dropdown'da neler olsun" mantığı burada.
    private func renderUsage(samples: [RawSample], now: Double) {
        let last = samples[samples.count - 1]  // dizinin son elemanı = en güncel örnek
        let age = now - last.t
        let stale = age > staleMs
        let headline = last.u[keyPath: limits[0].key]  // limits[0] = 5 saatlik pencere (fh)

        // Menü çubuğundaki "⚡ %14" yazısı
        statusItem.button?.attributedTitle = attributed(
            " %\(headline)", color: stale ? .disabledControlTextColor : colorFor(headline)
        )

        // NSMenu = tıklayınca açılan dropdown'ın kendisi. Her satır bir
        // NSMenuItem. SwiftBar'da bunu satır satır metin yazarak yapıyorduk
        // (line("...", "color=...")), burada aynı şeyi doğrudan AppKit
        // nesneleri oluşturarak yapıyoruz.
        let menu = NSMenu()
        menu.addItem(withTitle: "Claude Kullanım Limitleri", action: nil, keyEquivalent: "")
        menu.addItem(.separator())  // ince ayırıcı çizgi (SwiftBar'daki "---")

        // "for limit in limits" = JS'teki "for (const limit of limits)" ile aynı
        for limit in limits {
            let pct = last.u[keyPath: limit.key]
            let resetAt = estimateReset(samples: samples, key: limit.key, windowMs: limit.windowMs, now: now)
            let reset = resetLabel(pct: pct, resetAt: resetAt, now: now)

            // action: nil, keyEquivalent: "" = "bu satıra tıklanınca hiçbir
            // şey olmasın, klavye kısayolu da yok" — sadece bilgi göstermek için
            let pctItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            pctItem.attributedTitle = attributed("\(limit.label): %\(pct)", color: colorFor(pct))
            menu.addItem(pctItem)

            let resetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            resetItem.attributedTitle = attributed("   Sıfırlanma (tahmini): \(reset)", color: grayText, small: true)
            menu.addItem(resetItem)
        }

        menu.addItem(.separator())
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let clockStr = clock.string(from: Date(timeIntervalSince1970: last.t / 1000))
        let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updatedItem.attributedTitle = attributed(
            "Veri: \(clockStr) (\(formatDuration(age)) önce)", color: grayText, small: true
        )
        menu.addItem(updatedItem)

        if stale {
            let warnItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            warnItem.attributedTitle = attributed(
                "⚠️ Veri bayat — Claude uygulaması kapalı olabilir", color: warningColor, small: true
            )
            menu.addItem(warnItem)
        }

        appendFooter(to: menu)
        // Bu satır menüyü fiilen simgeye bağlıyor — kullanıcı tıklayınca
        // AppKit bu menu nesnesini otomatik açar, bizim ayrıca "tıklandı"
        // kodu yazmamıza gerek yok.
        statusItem.menu = menu
    }

    // JSON okunamadığında/bozuk olduğunda gösterilen menü (JS'teki
    // errorMenu fonksiyonunun karşılığı).
    private func renderError(_ error: Error) {
        statusItem.button?.attributedTitle = attributed(" N/A", color: .disabledControlTextColor)

        let menu = NSMenu()
        menu.addItem(withTitle: "Claude kullanım verisi okunamadı", action: nil, keyEquivalent: "")
        let errItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        // error.localizedDescription = Swift'in hatayı otomatik olarak
        // okunabilir bir cümleye çevirmesi (JS'teki err.message gibi)
        errItem.attributedTitle = attributed("Hata: \(error.localizedDescription)", color: grayText, small: true)
        menu.addItem(errItem)
        menu.addItem(withTitle: "Claude masaüstü uygulamasının kurulu ve en az bir kez açılmış olması gerekir",
                     action: nil, keyEquivalent: "")
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // Her iki menünün de (normal ve hata) altına eklenen ortak kısım:
    // "Claude'u Aç" ve "Çıkış" butonları.
    private func appendFooter(to menu: NSMenu) {
        menu.addItem(.separator())

        // Bu sefer action: nil DEĞİL — #selector(openClaude) demek "bu
        // satıra tıklanınca aşağıdaki openClaude() fonksiyonunu çalıştır"
        // demek. "target = self" ise "bu fonksiyonu BENDE (bu AppDelegate
        // nesnesinde) ara" demek — AppKit'in eski ama hâlâ kullanılan
        // "target-action" tıklama deseni.
        let openItem = NSMenuItem(title: "Claude'u Aç", action: #selector(openClaude), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // NSApplication.terminate zaten AppKit'in hazır "uygulamayı kapat"
        // fonksiyonu, kendimiz yazmamıza gerek yok. keyEquivalent: "q" ise
        // ⌘Q kısayolunu bu menü öğesine bağlıyor.
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // "@objc" = bu fonksiyonu Objective-C çalışma zamanına (AppKit'in
    // altyapısına) görünür kıl demek. #selector(...) ile bir fonksiyona
    // "isimle" referans verebilmek için Swift'te bu işaretin olması şart
    // — yoksa derleyici "böyle bir fonksiyon bulamıyorum" hatası verir.
    @objc private func openClaude() {
        // Önce Claude'u "bundle identifier" (uygulamanın benzersiz kimliği,
        // com.anthropic.claudefordesktop) ile bulmayı dene — bu, uygulama
        // /Applications dışında bir yere kurulmuş olsa bile çalışır.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            // Bulunamazsa (ör. Claude kurulu değilse farklı bir yoldaysa),
            // standart /Applications yoluna dönüş yap
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
        }
    }
}
