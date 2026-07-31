import AppKit
import ServiceManagement

// Bu dosya, "ekrana ne çizeceğiz" işini yapıyor: menü çubuğu simgesi,
// açılan menü, renkler, tıklama davranışları. Hesaplama mantığı yok,
// o UsageData.swift ve UsageAPI.swift'te.
//
// NOT: Kod yorumları Türkçe (öğrenme amaçlı), ama kullanıcıya GÖRÜNEN
// her metin İngilizce — uygulama GitHub'da yayınlanacağı için arayüz
// dilinin İngilizce olması gerekiyor.

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

    // Oturum süresi dolduğunda true olur ve kullanıcı yeniden giriş yapana
    // kadar öyle kalır. Ayrı bir bayrak tutmamızın sebebi: süresi dolan
    // anahtarı hemen siliyoruz, o yüzden apiError bir sonraki döngüde
    // temizleniyor — bayrak olmasaydı "yeniden giriş yapın" uyarısı 20
    // saniye sonra kaybolur, kullanıcı neden veri gelmediğini anlamazdı.
    private var needsReauth = false

    // Hesaba bağlı organizasyonlar. Çoğu kişide tek tane olur; Team/Enterprise
    // hesaplarında birden fazla olabiliyor ve o zaman kullanıcının hangisine
    // baktığını seçebilmesi gerekiyor (bkz. appendOrganizationMenu).
    private var organizations: [UsageAPI.Organization] = []
    // Organizasyon listesini en son ne zaman çektik? Hiç yenilemezsek yeni
    // bir takıma katılan kullanıcı onu menüde göremez; her turda denersek de
    // hesapta tek organizasyon varken 20 saniyede bir boşuna istek atarız.
    // Yarım saatte bir tazelemek ikisinin arasında makul bir denge.
    private var organizationsLoadedAt: Date?

    // Sunucu "çok sık istek atıyorsun" (429) derse bu tarihe kadar hiç
    // istek atmıyoruz. Aynı hızda devam etmek engeli uzatabilir; geri
    // çekilmek hem bize hem sunucuya doğru olan davranış.
    private var pauseUntil: Date?

    // Aynı anda birden fazla istek uçuşmasın. Bir istek 15 saniyeye kadar
    // sürebiliyor; zamanlayıcı 20 saniyede bir, menü her kapandığında da
    // bir kez tetikliyor. Bu koruma olmazsa üst üste binen istekler hem
    // gereksiz trafik yaratır hem de sonuçlar ters sırada gelip ekranda
    // eski veriyi gösterebilir.
    private var isFetching = false
    private var lastFetchAt: Date?

    // Üst üste kaç kez kimlik hatası aldık? Tek bir hatada kullanıcıyı
    // çıkış yaptırmak riskli: yanlış karar verirsek insanın çalışan
    // oturumunu yok etmiş oluruz. Üç kez üst üste (yani ~1 dakika boyunca)
    // reddedilirse oturumun gerçekten bittiğine hükmediyoruz.
    private var consecutiveAuthFailures = 0

    // "Start at Login" kaydı başarısız olduysa sebebini menüde göstermek
    // için saklıyoruz. Sadece log'a yazmak yetmiyor: paketlenmiş uygulamada
    // stdout hiçbir yere gitmediği için kullanıcı tikin neden açılmadığını
    // hiç öğrenemezdi.
    private var startAtLoginError: String?

    // En son çizdiğimiz veri. Menüyü ağdan bir şey çekmeden yeniden
    // kurabilmek için saklıyoruz (ör. "Start at Login" tikini güncellemek
    // gerektiğinde sunucuya gitmenin anlamı yok).
    private var lastSnapshot: UsageSnapshot?

    // NSApplication açıldığında AppKit bu fonksiyonu otomatik çağırır
    // (JS'teki "DOMContentLoaded" event'ine benzer bir "artık hazırım" anı).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = "Dock'ta simge gösterme, sadece menü çubuğunda yaşa".
        NSApp.setActivationPolicy(.accessory)

        // SF Symbols, Apple'ın hazır ikon setinin adı; "bolt.fill" bizim
        // şimşek ikonumuz.
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.fill", accessibilityDescription: "Claude Usage"
        )
        statusItem.button?.imagePosition = .imageLeading  // ikon solda, yüzde metni sağda

        // Açılışta tek satırlık durum kaydı. Kullanıcı bir sorun bildirdiğinde
        // ilk sorulacak şeyler bunlar: hangi sürüm, paketlenmiş mi çalışıyor,
        // giriş yapılmış mı. (Oturum anahtarının kendisi asla loglanmaz.)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        log(
            "started — v\(version ?? "dev"), "
                + "\(isBundledApp ? "bundled" : "bare binary"), "
                + "signed in: \(SessionStore.sessionKey != nil)"
        )

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
    // force: kullanıcının kendi tıklamasıyla tetiklenen yenilemeler için.
    // Aşağıdaki hız sınırlamaları arka plandaki zamanlayıcı içindir; kullanıcı
    // giriş yaptığında ya da organizasyon değiştirdiğinde sonucu HEMEN
    // görmeli, "5 saniye geçmedi" diye beklememeli.
    private func refresh(force: Bool = false) {
        if SessionStore.sessionKey == nil {
            apiError = nil
            organizations = []  // çıkış yapıldıysa eski listeyi taşıma
            renderFromFile()
            return
        }

        // Zaten uçuşan bir istek varsa ikincisini başlatma. Bu koruma
        // kullanıcı tetiklese bile geçerli — iki eşzamanlı istek sonuçları
        // ters sırada döndürüp ekranda eski veriyi bırakabilir.
        guard !isFetching else { return }

        if !force {
            // Oran sınırına takıldıysak süre dolana kadar hiç istek atmıyoruz.
            if let pauseUntil, pauseUntil > Date() {
                renderFromFile()
                return
            }

            // Menü her kapandığında da yeniliyoruz; kullanıcı menüyü arka
            // arkaya açıp kapatırsa bu saniyede birkaç isteğe dönüşebilir.
            // Ardışık iki istek arasına en az 5 saniye koyuyoruz.
            if let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < 5 { return }
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
        isFetching = true
        lastFetchAt = Date()
        defer { isFetching = false }  // defer = fonksiyondan nasıl çıkarsak çıkalım çalışır

        do {
            let snapshot = try await UsageAPI.fetchSnapshot()
            apiError = nil
            pauseUntil = nil
            consecutiveAuthFailures = 0
            render(snapshot)
            await loadOrganizationsIfNeeded()

        } catch APIError.rateLimited(let retryAfter) {
            // Sunucunun önerdiği süreyi kullan; vermemişse 5 dakika bekle.
            let wait = retryAfter ?? 300
            pauseUntil = Date().addingTimeInterval(wait)
            log("rate limited — pausing for \(Int(wait))s")
            apiError = APIError.rateLimited(retryAfter: retryAfter)
            renderFromFile()

        } catch APIError.unauthorized where consecutiveAuthFailures < 2 {
            // Henüz emin değiliz — anahtara dokunmadan yerel dosyaya düş.
            consecutiveAuthFailures += 1
            apiError = APIError.unauthorized
            renderFromFile()

        } catch APIError.unauthorized {
            // Anahtar artık ölü (oturum süresi doldu ya da başka bir yerden
            // iptal edildi). Onu Keychain'de tutmanın hiçbir faydası yok:
            // her 20 saniyede bir çalışmayacağı bilinen bir istek atardık ve
            // menüde "Sign In" yerine "Sign Out" yazmaya devam ederdi —
            // kullanıcı önce çıkış yapmayı akıl etmek zorunda kalırdı.
            // Silince menü kendiliğinden girişe dönüyor.
            log("session expired — key cleared, sign-in required")
            SessionStore.clear()
            SessionStore.orgId = nil
            organizations = []
            organizationsLoadedAt = nil
            needsReauth = true
            apiError = nil
            // Eski API anlık görüntüsünü de bırakmıyoruz: redraw() onu
            // yeniden çizip, oturum kapalıyken "Source: claude.ai (live)"
            // diyerek eski kullanım verisini gösterebilirdi.
            lastSnapshot = nil
            renderFromFile()

        } catch {
            // Geçici bir sorun (internet yok, zaman aşımı, sunucu hatası).
            // Uygulamayı kırmak yerine sessizce yerel dosyaya düşüyoruz —
            // kullanıcı yine bir şeyler görsün, sebebi de menüde yazsın.
            // Anahtara DOKUNMUYORUZ: geçici bir kesinti yüzünden kullanıcıyı
            // yeniden giriş yapmaya zorlamak yanlış olurdu.
            apiError = error
            renderFromFile()
        }
    }

    // Organizasyon listesini yalnızca bir kez çekiyoruz; her 20 saniyede bir
    // tekrar sormanın anlamı yok, bu liste neredeyse hiç değişmiyor.
    @MainActor
    private func loadOrganizationsIfNeeded() async {
        if let loadedAt = organizationsLoadedAt, Date().timeIntervalSince(loadedAt) < 1800 {
            return
        }
        organizationsLoadedAt = Date()

        // Başarısız olursa elimizdeki listeyi KORUYORUZ. "?? []" deseydik
        // geçici bir hata, menüdeki organizasyon seçimini kullanıcının
        // gözü önünde yok ederdi.
        if let fetched = try? await UsageAPI.organizations() {
            organizations = fetched
        }
    }

    // Menüyü, elimizdeki son veriyle yeniden kurar — sunucuya gitmeden.
    private func redraw() {
        if let lastSnapshot {
            render(lastSnapshot)
        } else {
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
        // Hiç pencere yoksa gösterecek bir şey de yok. Bunu "%0" diye
        // göstermek YANLIŞ olur — kullanıcı hiç kullanmadığını sanır.
        // (Sunucu bazı hesap türleri için her iki pencereyi de boş
        // dönebiliyor; o zaman elimizde veri yok demektir, sıfır değil.)
        guard !snapshot.windows.isEmpty else {
            renderNoData()
            return
        }

        lastSnapshot = snapshot
        let now = Date()
        let age = now.timeIntervalSince(snapshot.capturedAt) * 1000
        // Canlı API verisi tanımı gereği taze; bayatlık sadece yerel dosya
        // için anlamlı bir kavram.
        let stale = snapshot.source == .localFile && age > staleMs
        let headline = snapshot.windows.first?.percent ?? 0

        // Menü çubuğundaki "⚡ 14%" yazısı — bu menü açıkken bile
        // güncellenebilir, çünkü menünün bir parçası değil.
        statusItem.button?.attributedTitle = attributed(
            " \(headline)%", color: stale ? .disabledControlTextColor : colorFor(headline)
        )

        // Kullanıcı tam o an menüyü açmışsa, altından değiştirmiyoruz.
        guard !menuIsOpen else { return }

        // NSMenu = tıklayınca açılan dropdown'ın kendisi. Her satır bir
        // NSMenuItem.
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Claude Usage Limits", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // "for window in snapshot.windows" = JS'teki "for (const w of ...)" ile aynı
        for window in snapshot.windows {
            let reset = resetLabel(
                percent: window.percent, resetAt: window.resetAt,
                isEstimate: window.resetIsEstimate, now: now
            )

            addRow(to: menu, "\(window.label): \(window.percent)%", color: colorFor(window.percent))
            addRow(to: menu, "   Resets: \(reset)", color: grayText, small: true)
        }

        menu.addItem(.separator())
        addRow(to: menu, sourceLine(snapshot: snapshot, age: age), color: grayText, small: true)

        if stale {
            addRow(
                to: menu, "⚠️ Data is stale — Claude may not be running",
                color: warningColor, small: true
            )
        }
        if needsReauth {
            addRow(to: menu, "⚠️ Session expired — please sign in again", color: warningColor, small: true)
        }
        if let apiError {
            addRow(
                to: menu, "⚠️ Live data unavailable: \(apiError.localizedDescription)",
                color: warningColor, small: true
            )
        }

        appendFooter(to: menu)
        // Bu satır menüyü fiilen simgeye bağlıyor — kullanıcı tıklayınca
        // AppKit bu menu nesnesini otomatik açar.
        statusItem.menu = menu
    }

    // Sunucuya ulaştık ama hiçbir limit bilgisi gelmedi.
    private func renderNoData() {
        statusItem.button?.attributedTitle = attributed(" –", color: .disabledControlTextColor)
        guard !menuIsOpen else { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "No usage limits reported", action: nil, keyEquivalent: "")
        addRow(
            to: menu, "This account doesn't report session or weekly limits",
            color: grayText, small: true
        )
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // Verinin nereden geldiğini kullanıcıya açıkça söylüyoruz; "kesin mi
    // tahmin mi" ayrımını görebilmesi önemli.
    private func sourceLine(snapshot: UsageSnapshot, age: Double) -> String {
        switch snapshot.source {
        case .api:
            return "Source: claude.ai (live)"
        case .localFile:
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            let clockStr = clock.string(from: snapshot.capturedAt)
            return "Source: local file · \(clockStr) (\(formatDuration(age)) ago)"
        }
    }

    // JSON okunamadığında/bozuk olduğunda ve giriş YAPILMIŞKEN gösterilen menü.
    private func renderError(_ error: Error) {
        // Giriş yapılmamışsa ortada bir ARIZA yok — kullanıcı henüz
        // bağlanmamış demektir. Bunu hata ekranı gibi göstermek, uygulamayı
        // ilk kez açan birini boşuna telaşlandırıyor. Üstelik bu, Claude
        // masaüstü uygulaması kurulu olmayan bir kullanıcının göreceği ilk
        // ekran — yani "bozuk indirdim" izlenimi tam da ilk temasta oluşuyor.
        guard SessionStore.sessionKey != nil else {
            renderSignedOut()
            return
        }

        statusItem.button?.attributedTitle = attributed(" N/A", color: .disabledControlTextColor)
        guard !menuIsOpen else { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Couldn't read Claude usage data", action: nil, keyEquivalent: "")
        // error.localizedDescription = Swift'in hatayı otomatik olarak
        // okunabilir bir cümleye çevirmesi (JS'teki err.message gibi)
        addRow(to: menu, "Error: \(error.localizedDescription)", color: grayText, small: true)
        if let apiError {
            addRow(to: menu, "Live data: \(apiError.localizedDescription)", color: grayText, small: true)
        }
        appendFooter(to: menu)
        statusItem.menu = menu
    }

    // Henüz giriş yapılmamış (ya da oturumu düşmüş) ve gösterilecek yerel
    // veri de yok. Bu bir hata durumu değil, sadece "başlamaya hazır"
    // durumu — o yüzden ayrı ve sakin bir ekran gösteriyoruz.
    private func renderSignedOut() {
        statusItem.button?.attributedTitle = attributed(" –", color: .disabledControlTextColor)
        guard !menuIsOpen else { return }

        let menu = NSMenu()
        menu.delegate = self

        if needsReauth {
            menu.addItem(withTitle: "Session expired", action: nil, keyEquivalent: "")
            addRow(to: menu, "Sign in again to see your usage", color: grayText, small: true)
        } else {
            menu.addItem(withTitle: "Not signed in", action: nil, keyEquivalent: "")
            addRow(to: menu, "Sign in with Claude to see your usage limits", color: grayText, small: true)
        }

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

    // Her menünün altına eklenen ortak kısım.
    private func appendFooter(to menu: NSMenu) {
        menu.addItem(.separator())

        appendOrganizationMenu(to: menu)

        // Giriş durumuna göre tek bir satır: ya giriş teklif ediyoruz ya da
        // mevcut oturumu kapatma seçeneği sunuyoruz.
        //
        // action: #selector(...) demek "bu satıra tıklanınca aşağıdaki
        // fonksiyonu çalıştır" demek. "target = self" ise "bu fonksiyonu
        // BENDE (bu AppDelegate nesnesinde) ara" demek — AppKit'in eski ama
        // hâlâ kullanılan "target-action" tıklama deseni.
        let signedIn = SessionStore.sessionKey != nil
        let authItem = NSMenuItem(
            title: signedIn ? "Sign Out" : "Sign In with Claude…",
            action: signedIn ? #selector(signOut) : #selector(signIn),
            keyEquivalent: ""
        )
        authItem.target = self
        menu.addItem(authItem)

        appendStartAtLoginItem(to: menu)

        // "Open Claude" yalnızca Claude masaüstü uygulaması KURULUYSA
        // gösteriliyor. Kurulu değilken bu satır tıklanınca hiçbir şey
        // olmuyordu — ve bu, uygulamayı GitHub'dan indiren birinin çok
        // muhtemel durumu (Claude masaüstü şart değil, giriş yeterli).
        if claudeAppURL != nil {
            let openItem = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
        }

        // NSApplication.terminate zaten AppKit'in hazır "uygulamayı kapat"
        // fonksiyonu, kendimiz yazmamıza gerek yok. keyEquivalent: "q" ise
        // ⌘Q kısayolunu bu menü öğesine bağlıyor.
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Birden fazla organizasyon varsa hangisine baktığımızı seçilebilir
    // yapıyoruz. Tek organizasyon varsa (kullanıcıların çoğu) bu menüyü hiç
    // göstermiyoruz — gereksiz kalabalık olurdu.
    private func appendOrganizationMenu(to menu: NSMenu) {
        guard organizations.count > 1 else { return }

        let parent = NSMenuItem(title: "Organization", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for org in organizations {
            let item = NSMenuItem(title: org.name, action: #selector(selectOrganization(_:)), keyEquivalent: "")
            item.target = self
            // representedObject = menü öğesine iliştirilen serbest veri;
            // tıklanınca hangi organizasyonun seçildiğini buradan okuyoruz.
            item.representedObject = org.uuid
            item.state = (org.uuid == SessionStore.orgId) ? .on : .off  // seçili olana tik
            submenu.addItem(item)
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    // "Girişte başlat" anahtarı. SMAppService (macOS 13+), kullanıcının
    // Sistem Ayarları > Genel > Giriş Öğeleri listesine uygulamayı ekler —
    // yani kullanıcının oraya elle gidip uğraşmasına gerek kalmıyor.
    private func appendStartAtLoginItem(to menu: NSMenu) {
        // SMAppService yalnızca gerçek bir .app paketinde çalışır; kaynaktan
        // doğrudan çalıştırılan çıplak ikilide bu seçeneği hiç göstermiyoruz,
        // yoksa tıklayınca sessizce hata verirdi.
        guard isBundledApp else { return }

        let item = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        item.target = self
        item.state = startsAtLogin ? .on : .off
        menu.addItem(item)

        if let startAtLoginError {
            addRow(to: menu, "   \(startAtLoginError)", color: warningColor, small: true)
        }
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var startsAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
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
            // Farklı bir hesapla girilmiş olabilir; eski hesabın sıfırlanma
            // zamanlarını taşımayalım.
            SessionStore.clearResetCache()
            // Farklı bir hesapla girilmiş olabilir; önbellekteki org
            // kimliği ve listesi artık geçersiz sayılmalı.
            SessionStore.orgId = nil
            self?.organizations = []
            self?.organizationsLoadedAt = nil
            self?.needsReauth = false
            self?.pauseUntil = nil
            self?.refresh(force: true)
        }
    }

    @objc private func signOut() {
        SessionStore.clear()
        SessionStore.orgId = nil
        SessionStore.preferredOrgId = nil
        organizations = []
        organizationsLoadedAt = nil
        pauseUntil = nil
        apiError = nil
        needsReauth = false  // kullanıcı kendi isteğiyle çıktı, uyarıya gerek yok
        lastSnapshot = nil   // eski canlı veri bir daha çizilmesin

        // Keychain'i silmek yetmiyor: WebKit'in kalıcı deposundaki claude.ai
        // oturum çerezi de gitmeli, yoksa "çıkış yaptım" demek gerçekte
        // doğru olmaz (bkz. LoginWindowController.clearStoredWebSession).
        LoginWindowController.clearStoredWebSession { [weak self] in
            self?.refresh(force: true)
        }
        refresh(force: true)  // temizlik bitmeden de arayüz hemen güncellensin
    }

    @objc private func selectOrganization(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        SessionStore.orgId = uuid
        // Tercihi ayrıca kaydediyoruz: orgId hata kurtarmasında
        // temizlenebiliyor, ama kullanıcının seçimi kalıcı olmalı.
        SessionStore.preferredOrgId = uuid
        lastSnapshot = nil  // artık başka bir organizasyona bakıyoruz
        // Önbellekteki sıfırlanma zamanları ÖNCEKİ organizasyona ait.
        SessionStore.clearResetCache()
        refresh(force: true)
    }

    @objc private func toggleStartAtLogin() {
        do {
            if startsAtLogin {
                try SMAppService.mainApp.unregister()
                log("start at login disabled")
            } else {
                try SMAppService.mainApp.register()
                log("start at login enabled")
            }
            startAtLoginError = nil
        } catch {
            // Uygulamayı kırmıyoruz ama sessizce de geçmiyoruz — kullanıcı
            // tikin neden değişmediğini görmeli ve elle ekleyebileceğini
            // bilmeli.
            log("start at login failed: \(error.localizedDescription)")
            startAtLoginError = "Could not change — add it in System Settings › General › Login Items"
        }
        redraw()  // sadece menüdeki tik işaretini güncelle — ağa gitmeye gerek yok
    }

    // Claude masaüstü uygulamasının yeri — kurulu değilse nil.
    // "bundle identifier" ile arıyoruz, böylece /Applications dışına
    // kurulmuş olsa bile bulunur.
    private var claudeAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
    }

    @objc private func openClaude() {
        guard let url = claudeAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
