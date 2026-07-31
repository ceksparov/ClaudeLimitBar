import AppKit
import OSLog
import WebKit

// Giris akisi birden fazla pencere ve yonlendirmeden gectigi icin, bir sey
// ters gittiginde nerede takildigini gormek zor. Bu yuzden akisin her
// adimini kaydediyoruz.
//
// Neden os_log: paketlenmis bir uygulamada print() ciktisi HICBIR YERE
// gitmez — stdout'u okuyan kimse yoktur. Yani bir kullanici "giris
// yapamiyorum" dediginde elimizde hicbir veri olmazdi. os_log ise sistemin
// log deposuna yazar; kullanici Console.app'ten ya da su komutla gorebilir:
//
//   log show --predicate 'subsystem == "io.github.claudeusagebar"' --last 1h
//
// privacy: .public — log satirlarinda gizli deger YOK (URL'lerin yalnizca
// host+path kismi yaziliyor, oturum anahtari hicbir zaman loglanmiyor).
// Bunu belirtmezsek sistem metni <private> diye maskeler ve log ise yaramaz.
private let appLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ClaudeUsageBar", category: "app"
)

func log(_ message: String) {
    // .notice seviyesi bilerek secildi: .info ve .debug yalnizca bellekte
    // tutulur, diske yazilmaz — yani olay gectikten SONRA "log show" ile
    // bakildiginda hicbir sey bulunamaz (olculdu). Kullanicinin bize sonradan
    // log gonderebilmesi icin kaydin kalici olmasi sart.
    appLog.notice("\(message, privacy: .public)")

    // Terminalden calistirildiginda (gelistirme sirasinda) dogrudan da gorunsun.
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    print("[\(clock.string(from: Date()))] \(message)")
    // Terminale aninda dussun; yoksa cikti tamponda bekleyebilir.
    fflush(stdout)
}

// URL'leri loglarken sorgu parametrelerini (?code=... gibi) YAZMIYORUZ —
// OAuth kodlari ve benzeri gizli degerler oralarda tasinir.
private func safeURL(_ url: URL?) -> String {
    guard let url else { return "?" }
    return "\(url.host ?? "?")\(url.path)"
}

// "Claude ile Giris Yap" penceresi.
//
// Neden boyle yapiyoruz: Windows tarafinda, Claude masaustu uygulamasinin
// sifreli cerez veritabanini disaridan cozmeye calisiyorduk — bu, baska
// bir uygulamanin ic depolama bicimine bagimli oldugu icin kirilgan bir
// yontem. Burada bunun yerine kendi penceremizde claude.ai'nin GERCEK
// giris sayfasini aciyoruz; kullanici her zamanki gibi giris yapiyor ve
// olusan oturum cerezini kendi WebView'imizin cerez deposundan okuyoruz.
// Boylece hicbir uygulamanin ic yapisina bagimli kalmiyoruz.
//
// WKWebView = macOS'un gomulu WebKit (Safari) motoru. Yani bu pencere
// gercek bir tarayici sekmesi.
//
// "WKUIDelegate" = sayfanin yeni pencere acma (window.open), uyari
// gosterme gibi ARAYUZ taleplerini bize yonlendiren protokol. Google ile
// giris tam olarak boyle calistigi icin (OAuth akisi ayri bir pencerede
// acilir) bunu uygulamak zorundayiz — yoksa WKWebView popup talebini
// sessizce yok sayar ve giris "sebepsizce" basarisiz olur.
final class LoginWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?

    // Google/SSO akisinin actigi ikinci pencere.
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?

    // Cerezi periyodik yoklayan zamanlayici (asagida neden gerektigi anlatiliyor).
    private var pollTimer: Timer?

    // Su an dogrulanmakta olan anahtar ve daha once gecersiz cikmis
    // anahtarlar — ayni degeri saniyede bir tekrar tekrar sunucuya
    // sormamak icin.
    private var validatingKey: String?
    private var rejectedKeys: Set<String> = []

    // Giris basarili oldugunda cagrilacak fonksiyon. Optional cunku
    // pencere kapaliyken elimizde boyle bir fonksiyon olmuyor.
    private var onFinish: ((String) -> Void)?

    // Cikis yaparken cagriliyor. Keychain'deki anahtari silmek TEK BASINA
    // yeterli DEGIL: WKWebView'in kalici cerez deposu, claude.ai oturum
    // cerezini diskte tutmaya devam eder. Bu temizlik olmadan
    // "Oturumu Kapat" aldatici bir islem olurdu — kullanici cikis yaptigini
    // sanirken hesabina erisim veren gecerli bir cerez diskte kalir, ve
    // tekrar "Giris Yap" dendiginde hicbir sey sorulmadan ayni oturuma
    // geri donulurdu.
    //
    // Neden SADECE claude.ai: ilk surumde tum site verisini siliyorduk, ama
    // bu Google oturumunu da goturuyordu. Sonucu su oldu — tekrar giriste
    // Google sifirdan kimlik dogrulamasi istedi, passkey'e dustu ve passkey
    // gomulu bir WKWebView'da CALISMAZ (Touch ID erisimi, yalnizca imzali
    // uygulamalara verilen bir yetki gerektirir). Yani asiri temizlik,
    // kullaniciyi girisi mumkun olmayan bir yola sokuyordu.
    //
    // Sadece claude.ai verisini silmek guvenlik amacini zaten karsiliyor:
    // Claude oturum cerezi tamamen gider. Taraiycilarin davranisi da budur —
    // bir siteden cikmak, Google hesabindan cikmak anlamina gelmez.
    static func clearStoredWebSession(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        // Once "hangi siteler icin veri tutuluyor" listesini aliyoruz, sonra
        // sadece claude.ai'ye ait olanlari secip siliyoruz.
        store.fetchDataRecords(ofTypes: types) { records in
            let claudeRecords = records.filter { $0.displayName.contains("claude.ai") }

            store.removeData(ofTypes: types, for: claudeRecords) {
                log("cleared claude.ai web data (\(claudeRecords.count) records)")
                completion()
            }
        }
    }

    func present(onFinish: @escaping (String) -> Void) {
        self.onFinish = onFinish

        // Pencere zaten aciksa yenisini acma, var olani one getir.
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        // .default() = KALICI cerez deposu (diske yazilir). .nonPersistent()
        // secseydik uygulama her kapandiginda oturum silinir, kullanici
        // surekli yeniden giris yapmak zorunda kalirdi.
        configuration.websiteDataStore = .default()

        let webView = makeWebView(configuration: configuration)
        self.webView = webView

        let window = makeWindow(for: webView, title: "Sign In with Claude")
        self.window = window

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        window.makeKeyAndOrderFront(nil)
        // .accessory uygulamalari kendiliginden one gelmez; bu satir
        // pencereyi kullanicinin onune getirip klavye odagini veriyor.
        NSApp.activate(ignoringOtherApps: true)

        startPolling()
    }

    // WebView ve pencere kurulumunu iki yerde (ana pencere + popup)
    // kullandigimiz icin ayri fonksiyonlara ayirdik.
    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration
        )
        // Bu iki satir, sayfanin olaylarini bize baglar: navigationDelegate
        // sayfa yuklemelerini, uiDelegate ise pencere acma taleplerini.
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    // Pencerenin ustunde duran yonlendirme bandi.
    //
    // Sirasi bilerek boyle: once CALISTIGINI BILDIGIMIZ yol, sonra uyari.
    // Onceki surumde Google varsayilan yol gibi duruyor, e-posta ise bir
    // kacis secenegi gibi sunuluyordu — oysa gercek deneyim tam tersini
    // gosterdi: Google yolu passkey duvarina carpiyor, sonra sifre adimina
    // dusuluyor, ust uste denemede de giris oran sinirina takiliyor.
    //
    // Passkey uyarisi neden sart: passkey gomulu bir WKWebView icinde
    // CALISAMAZ (Apple, WKWebView'da WebAuthn icin uygulamanin ilgili alan
    // adiyla "Associated Domains" iliskisi kurmus olmasini sart kosuyor —
    // google.com bizim alan adimiz olmadigi icin bu mumkun degil). Onceden
    // soylemezsek kullanici passkey ekranina kadar gidip orada anlamsiz bir
    // hatayla karsilasiyor.
    private static let hintText =
        "Easiest way: sign in with your email — Claude sends you a code. "
        + "If you'd rather use Google, note that passkeys don't work in this "
        + "window: when the passkey prompt appears, choose \"Try another way\" "
        + "and use your password."

    private func makeHintLabel() -> NSTextField {
        // wrappingLabelWithString = secilemeyen, satir kaydiran bir etiket
        // uretir (duzenlenebilir bir metin kutusu degil).
        let label = NSTextField(wrappingLabelWithString: Self.hintText)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeWindow(for webView: WKWebView, title: String) -> NSWindow {
        // Pencerenin icerigi artik sadece WebView degil: ustte uyari bandi,
        // altta WebView olacak sekilde bir kapsayici kuruyoruz.
        let hint = makeHintLabel()
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 760))
        container.addSubview(hint)
        container.addSubview(webView)

        // Auto Layout: pencere yeniden boyutlandirildiginda bandin ustte
        // sabit kalmasini, WebView'in ise kalan alani doldurmasini saglar.
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            webView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = container
        window.center()
        // Uygulamamiz .accessory modunda (Dock'ta yok) oldugu icin pencere
        // kapatildiginda bellekten silinmesin istiyoruz.
        window.isReleasedWhenClosed = false
        // Kullanici pencereyi kendisi kapatirsa haberimiz olsun ki
        // zamanlayiciyi durduralim (bkz. windowWillClose).
        window.delegate = self
        return window
    }

    // MARK: - Cerezi yakalama
    //
    // Cerez kontrolunu neden zamanlayiciya bagladik: giris akisi tek bir
    // sayfa yuklemesi degil. E-posta/kod adimlari, Google popup'i ve
    // giris sonrasi SPA yonlendirmeleri sirasinda "sayfa yuklendi"
    // (didFinish) olayi hic tetiklenmeyebilir. Duzenli araliklarla
    // yoklamak, akisin hangi yoldan tamamlandigindan bagimsiz olarak
    // calisir — cok daha dayanikli.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.captureSessionKey()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // Her sayfa yuklemesi bittiginde WebKit bunu cagirir — zamanlayiciya
    // ek olarak, girisin hemen ardindan aninda tepki verebilmek icin.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let which = webView === popupWebView ? "popup" : "main"
        log("\(which) window loaded: \(safeURL(webView.url))")
        updateTitle(for: webView)
        captureSessionKey()
    }

    // Sayfa fiilen degismeye basladiginda (icerik gelmeden once) tetiklenir;
    // basligi burada guncellemek, adresin yonlendirme sirasinda da dogru
    // gorunmesini saglar.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateTitle(for: webView)
    }

    // Bu pencerede kullanicidan sifre isteniyor (Google girisi gibi), ama
    // gomulu bir WebView'in adres cubugu yoktur — yani kullanici normalde
    // sifresini HANGI siteye yazdigini goremez. Bu, kimlik avi icin klasik
    // bir zemin. Cozum olarak pencere basliginda o anki alan adini ve
    // baglantinin sifreli olup olmadigini gosteriyoruz.
    private func updateTitle(for webView: WKWebView) {
        let host = webView.url?.host ?? "?"
        // http (sifresiz) bir adrese duserse bu acikca belli olmali.
        let mark = webView.url?.scheme == "https" ? "🔒" : "⚠️ NOT SECURE —"
        let title = "\(mark) \(host)"

        if webView === popupWebView {
            popupWindow?.title = title
        } else {
            window?.title = title
        }
    }

    // Sayfa yuklenemezse sebebini gorelim.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("load failed: \(safeURL(webView.url)) — \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        log("connection failed: \(safeURL(webView.url)) — \(error.localizedDescription)")
    }

    private func captureSessionKey() {
        // Giris zaten tamamlandiysa (onFinish tuketildi) bos yere calisma.
        guard onFinish != nil, let webView else { return }

        // getAllCookies bir "completion handler" alir: cerezler hazir
        // oldugunda bu closure cagrilir (disk islemi oldugu icin anlik degil).
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            guard
                let cookie = cookies.first(where: {
                    $0.name == "sessionKey" && $0.domain.contains("claude.ai")
                }),
                !cookie.value.isEmpty
            else { return }

            let key = cookie.value
            // Ayni anahtari tekrar tekrar dogrulamaya calismayalim:
            // zamanlayici 1.5 saniyede bir calisiyor.
            guard key != self.validatingKey, !self.rejectedKeys.contains(key) else { return }

            self.validatingKey = key
            log("sessionKey cookie found, validating…")
            Task { await self.validate(key) }
        }
    }

    // Cerezin varligi tek basina "giris basarili" demek DEGIL: claude.ai
    // giris akisi sirasinda henuz gecerli olmayan ya da eski bir oturumdan
    // kalma bir sessionKey birakmis olabilir. Bu yuzden anahtari kabul
    // etmeden once onunla gercek bir API istegi atip sonucuna bakiyoruz.
    //
    // Onceki surumde bunun yerine "ana pencerenin URL'i /login degilse
    // kabul et" gibi bir kestirme kural vardi; Google girisi ayri bir
    // pencerede tamamlanip ana pencere /login'de kaldigi icin o kural
    // gecerli girisleri de eliyordu.
    private func validate(_ key: String) async {
        let result = await UsageAPI.check(sessionKey: key)

        // Arayuze dokunan her sey ana is parcaciginda olmali.
        await MainActor.run {
            self.validatingKey = nil

            switch result {
            case .valid:
                log("sessionKey valid — sign-in complete")
                self.finish(with: key)

            case .invalid:
                // Sunucu acikca reddetti; bir daha bu degeri denemeyelim ama
                // pencereyi acik birakalim — kullanici girisi tamamlayinca
                // cerez yeni bir degerle guncellenecek ve onu dogrulayacagiz.
                log("sessionKey rejected — sign-in still in progress")
                self.rejectedKeys.insert(key)

            case .unreachable:
                // Sonuc belirsiz. Anahtari KARALISTEYE ALMIYORUZ — sadece
                // birakip gecıyoruz; zamanlayici birazdan tekrar deneyecek.
                log("validation inconclusive (network?) — will retry")
            }
        }
    }

    private func finish(with sessionKey: String) {
        // onFinish'i nil'e cekmek, ayni girise birden fazla kez tepki
        // vermemizi engelliyor (zamanlayici saniyede bir kontrol ediyor).
        guard let onFinish else { return }
        self.onFinish = nil

        stopPolling()
        closePopup()
        window?.close()
        window = nil
        webView = nil

        onFinish(sessionKey)
    }

    // MARK: - Popup (Google/SSO) destegi — WKUIDelegate

    // Sayfa window.open cagirdiginda WebKit bu fonksiyonu sorar:
    // "bu yeni pencereyi acacak misin?". nil dondurursek popup hic
    // acilmaz — Google ile girisin sessizce basarisiz olmasinin sebebi
    // tam olarak buydu. Yeni bir WKWebView dondurerek "evet, ac" diyoruz.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // ONEMLI: WebKit'in verdigi "configuration" nesnesini AYNEN
        // kullanmak zorundayiz. Kendi yenimizi kurarsak popup, acan
        // sayfayla ayni oturumu (ve cerezleri) paylasmaz ve OAuth akisi
        // yine kirilir.
        log("popup opened: \(safeURL(navigationAction.request.url))")

        let popup = makeWebView(configuration: configuration)
        let popupWindow = makeWindow(for: popup, title: "Signing in…")

        self.popupWebView = popup
        self.popupWindow = popupWindow

        popupWindow.makeKeyAndOrderFront(nil)
        return popup
    }

    // OAuth bittiginde popup kendini kapatmak ister (window.close).
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        log("popup closed")
        closePopup()
        // Popup kapandiginda giris tamamlanmis olabilir; beklemeden bak.
        captureSessionKey()
    }

    private func closePopup() {
        popupWindow?.delegate = nil  // kendi kapatmamiz windowWillClose'u tetiklemesin
        popupWindow?.close()
        popupWindow = nil
        popupWebView = nil
    }

    // MARK: - Pencere kapatma — NSWindowDelegate

    // Kullanici girisi tamamlamadan pencereyi kapatirsa, zamanlayiciyi
    // bosuna calisir halde birakmayalim.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        stopPolling()
        closePopup()
        onFinish = nil
        window = nil
        webView = nil
    }
}
