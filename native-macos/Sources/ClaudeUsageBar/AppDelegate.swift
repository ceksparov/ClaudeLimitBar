import AppKit

// Bu dosya, "ekrana ne çizeceğiz" işini yapıyor: menü çubuğu simgesi,
// açılan menü, renkler, tıklama davranışları. Hesaplama mantığı yok,
// o UsageData.swift ve UsageAPI.swift'te.

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
// "NSMenuDelegate" ise menünün açılıp kapandığını bize haber verir —
// açık bir menüyü altından değiştirmemek için buna ihtiyacımız var.
// "final" = bu sınıftan başka bir sınıf türetilemez demek, sadece bir
// güvenlik/performans notu, davranışı etkilemiyor.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // statusItem = menü çubuğundaki simgemizin kendisi. ".variableLength"
    // = genişliği içindeki metne göre otomatik ayarlansın (sabit piksel değil).
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Timer? — "?" yine Optional: uygulama henüz başlamadan bu nil (boş),
    // applicationDidFinishLaunching çalışınca gerçek bir Timer'la doluyor.
    private var timer: Timer?
    private let loginWindow = LoginWindowController()

    // Menü açıkken menüyü yeniden kurarsak kullanıcının elinin altında
    // titreşir/kapanır. Bu bayrak sayesinde açıkken çizimi erteliyoruz.
    private var menuIsOpen = false
    // API çağrısı başarısız olup yerel dosyaya düştüysek, sebebini menüde
    // göstermek için saklıyoruz.
    private var apiError: Error?

    // NSApplication açıldığında AppKit bu fonksiyonu otomatik çağırır
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

        // Canlı API'den 20 saniyede bir çekiyoruz. Daha sık sorgulamak
        // teoride mümkün ama sunucu tarafında hız sınırına (rate limit)
        // takılma riski var; 20 saniye, yerel dosyanın 5 dakikalık yazma
        // aralığına kıyasla zaten çok daha güncel bir veri demek.
        //
        // "{ [weak self] _ in ... }" bir closure (JS'teki () => {} gibi
        // anonim fonksiyon). "[weak self]" ise hafıza sızıntısını önleyen
        // bir güvenlik notu: Timer, AppDelegate'i "zayıf" (weak) referansla
        // tutuyor, yani AppDelegate bir gün yok edilirse Timer onu
        // sonsuza dek hayatta tutmaya zorlamıyor.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()  // "?" burada da Optional: self hâlâ varsa çağır
        }
    }

    // MARK: - Veri çekme

    // Giriş yapılmışsa canlı API'yi, yapılmamışsa doğrudan yerel dosyayı
    // kullanıyoruz. Bu, uygulamanın iki kaynağı yönettiği merkez nokta.
    private func refresh() {
        if SessionStore.sessionKey == nil {
            apiError = nil
            renderFromFile()
            return
        }

        // "Task { ... }" = "şu işi arka planda başlat, bitince devam et".
        // Ağ isteği saniyeler sürebilir; bunu doğrudan burada beklersek
        // menü çubuğu donardı. Task sayesinde arayüz akıcı kalıyor.
        Task { await refreshFromAPI() }
    }

    // "@MainActor" = bu fonksiyonun gövdesi her zaman ana iş parçacığında
    // (UI thread) çalışsın demek. AppKit'e dokunan her şey ana thread'de
    // olmak ZORUNDA; bu işaret olmadan çökme/bozulma riski var.
    @MainActor
    private func refreshFromAPI() async {
        do {
            let snapshot = try await UsageAPI.fetchSnapshot()
            apiError = nil
            render(snapshot)
        } catch {
            // API'ye ulaşamadık (internet yok, oturum düştü, sunucu değişti…).
            // Uygulamayı kırmak yerine sessizce yerel dosyaya düşüyoruz —
            // kullanıcı yine bir şeyler görsün, sebebi de menüde yazsın.
            apiError = error
            renderFromFile()
        }
    }

    private func renderFromFile() {
        let now = Date().timeIntervalSince1970 * 1000  // "şu an", milisaniye cinsinden
        do {
            let samples = try loadHistory()
            render(fileSnapshot(samples: samples, now: now))
        } catch {
            renderError(error)
        }
    }

    // MARK: - Çizim

    // Asıl "menü çubuğunda ne yazsın, dropdown'da neler olsun" mantığı burada.
    private func render(_ snapshot: UsageSnapshot) {
        let now = Date()
        let age = now.timeIntervalSince(snapshot.capturedAt) * 1000
        // Canlı API verisi tanımı gereği taze; bayatlık sadece yerel dosya
        // için anlamlı bir kavram.
        let stale = snapshot.source == .localFile && age > staleMs
        let headline = snapshot.windows.first?.percent ?? 0

        // Menü çubuğundaki "⚡ %14" yazısı — bu menü açıkken bile
        // güncellenebilir, çünkü menünün bir parçası değil.
        statusItem.button?.attributedTitle = attributed(
            " %\(headline)", color: stale ? .disabledControlTextColor : colorFor(headline)
        )

        // Kullanıcı tam o an menüyü açmışsa, altından değiştirmiyoruz.
        guard !menuIsOpen else { return }

        // NSMenu = tıklayınca açılan dropdown'ın kendisi. Her satır bir
        // NSMenuItem. SwiftBar'da bunu satır satır metin yazarak yapıyorduk
        // (line("...", "color=...")), burada aynı şeyi doğrudan AppKit
        // nesneleri oluşturarak yapıyoruz.
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Claude Kullanım Limitleri", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // "for window in snapshot.windows" = JS'teki "for (const w of ...)" ile aynı
        for window in snapshot.windows {
            let reset = resetLabel(
                percent: window.percent, resetAt: window.resetAt,
                isEstimate: window.resetIsEstimate, now: now
            )

            // action: nil, keyEquivalent: "" = "bu satıra tıklanınca hiçbir
            // şey olmasın, klavye kısayolu da yok" — sadece bilgi göstermek için
            addRow(to: menu, "\(window.label): %\(window.percent)", color: colorFor(window.percent))
            addRow(to: menu, "   Sıfırlanma: \(reset)", color: grayText, small: true)
        }

        menu.addItem(.separator())
        addRow(to: menu, sourceLine(snapshot: snapshot, age: age), color: grayText, small: true)

        if stale {
            addRow(
                to: menu, "⚠️ Veri bayat — Claude uygulaması kapalı olabilir",
                color: warningColor, small: true
            )
        }
        if let apiError {
            addRow(
                to: menu, "⚠️ Canlı veri alınamadı: \(apiError.localizedDescription)",
                color: warningColor, small: true
            )
        }

        appendFooter(to: menu)
        // Bu satır menüyü fiilen simgeye bağlıyor — kullanıcı tıklayınca
        // AppKit bu menu nesnesini otomatik açar, bizim ayrıca "tıklandı"
        // kodu yazmamıza gerek yok.
        statusItem.menu = menu
    }

    // Verinin nereden geldiğini kullanıcıya açıkça söylüyoruz; "kesin mi
    // tahmin mi" ayrımını görebilmesi önemli.
    private func sourceLine(snapshot: UsageSnapshot, age: Double) -> String {
        switch snapshot.source {
        case .api:
            return "Kaynak: claude.ai (canlı)"
        case .localFile:
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            let clockStr = clock.string(from: snapshot.capturedAt)
            return "Kaynak: yerel dosya · \(clockStr) (\(formatDuration(age)) önce)"
        }
    }

    // JSON okunamadığında/bozuk olduğunda ve giriş de yapılmamışken
    // gösterilen menü.
    private func renderError(_ error: Error) {
        statusItem.button?.attributedTitle = attributed(" N/A", color: .disabledControlTextColor)
        guard !menuIsOpen else { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Claude kullanım verisi okunamadı", action: nil, keyEquivalent: "")
        // error.localizedDescription = Swift'in hatayı otomatik olarak
        // okunabilir bir cümleye çevirmesi (JS'teki err.message gibi)
        addRow(to: menu, "Hata: \(error.localizedDescription)", color: grayText, small: true)
        if let apiError {
            addRow(to: menu, "Canlı veri: \(apiError.localizedDescription)", color: grayText, small: true)
        }
        addRow(
            to: menu,
            "Canlı veri için \"Claude ile Giriş Yap\"ı kullanın ya da Claude masaüstü uygulamasını açın",
            color: grayText, small: true
        )
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // Aynı üç satırı (başlık oluştur, rengini ayarla, menüye ekle) her
    // yerde tekrar yazmamak için küçük bir yardımcı.
    private func addRow(to menu: NSMenu, _ text: String, color: NSColor, small: Bool = false) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = attributed(text, color: color, small: small)
        menu.addItem(item)
    }

    // Her menünün altına eklenen ortak kısım: giriş/çıkış, "Claude'u Aç"
    // ve "Çıkış" butonları.
    private func appendFooter(to menu: NSMenu) {
        menu.addItem(.separator())

        // Giriş durumuna göre tek bir satır: ya giriş teklif ediyoruz ya da
        // mevcut oturumu kapatma seçeneği sunuyoruz.
        //
        // action: #selector(...) demek "bu satıra tıklanınca aşağıdaki
        // fonksiyonu çalıştır" demek. "target = self" ise "bu fonksiyonu
        // BENDE (bu AppDelegate nesnesinde) ara" demek — AppKit'in eski ama
        // hâlâ kullanılan "target-action" tıklama deseni.
        let signedIn = SessionStore.sessionKey != nil
        let authItem = NSMenuItem(
            title: signedIn ? "Oturumu Kapat" : "Claude ile Giriş Yap…",
            action: signedIn ? #selector(signOut) : #selector(signIn),
            keyEquivalent: ""
        )
        authItem.target = self
        menu.addItem(authItem)

        let openItem = NSMenuItem(title: "Claude'u Aç", action: #selector(openClaude), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // NSApplication.terminate zaten AppKit'in hazır "uygulamayı kapat"
        // fonksiyonu, kendimiz yazmamıza gerek yok. keyEquivalent: "q" ise
        // ⌘Q kısayolunu bu menü öğesine bağlıyor.
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Menü açık/kapalı takibi (NSMenuDelegate)

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Menü kapanınca, açıkken ertelediğimiz güncellemeyi hemen uygula.
        refresh()
    }

    // MARK: - Tıklama davranışları

    // "@objc" = bu fonksiyonu Objective-C çalışma zamanına (AppKit'in
    // altyapısına) görünür kıl demek. #selector(...) ile bir fonksiyona
    // "isimle" referans verebilmek için Swift'te bu işaretin olması şart
    // — yoksa derleyici "böyle bir fonksiyon bulamıyorum" hatası verir.
    @objc private func signIn() {
        loginWindow.present { [weak self] sessionKey in
            SessionStore.save(sessionKey: sessionKey)
            // Farklı bir hesapla girilmiş olabilir; önbellekteki org
            // kimliği artık geçersiz sayılmalı.
            SessionStore.orgId = nil
            self?.refresh()
        }
    }

    @objc private func signOut() {
        SessionStore.clear()
        SessionStore.orgId = nil
        apiError = nil

        // Keychain'i silmek yetmiyor: WebKit'in kalici deposundaki claude.ai
        // oturum cerezi de gitmeli, yoksa "cikis yaptim" demek gercekte
        // dogru olmaz (bkz. LoginWindowController.clearStoredWebSession).
        LoginWindowController.clearStoredWebSession { [weak self] in
            self?.refresh()
        }
        refresh()  // temizlik bitmeden de arayuz hemen guncellensin
    }

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
