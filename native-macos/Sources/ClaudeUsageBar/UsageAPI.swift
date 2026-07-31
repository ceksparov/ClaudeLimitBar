import Foundation

// claude.ai'nin, kullanim ayarlari sayfasinin kendi kullandigi ic API'sine
// konusan istemci. Yerel dosyaya gore buyuk avantaji: sifirlanma zamanini
// TAHMIN etmek zorunda degiliz, sunucu bize kesin zamani soyluyor.
//
// Not: Bu, Anthropic'in resmi olarak dokumante ettigi bir API degil —
// tarayicidaki sayfanin kullandigi ic ucnokta. Degisirse uygulama
// yerel dosyaya geri duser (bkz. AppDelegate.refresh).

// Hatalari kendi turumuzde toplamak, cagiran tarafin "ne oldu"yu net
// ayirt edebilmesini saglar — ozellikle "oturum dustu" durumunu, cunku
// o durumda kullaniciya tekrar giris yaptirmamiz gerekiyor.
// LocalizedError'a uymak, error.localizedDescription cagrildiginda
// asagidaki Turkce metinlerin cikmasini saglar.
enum APIError: LocalizedError {
    case notSignedIn
    case unauthorized
    case badStatus(Int)
    case noOrganization
    // Sunucu "cok sik istek attin" dedi. retryAfter, sunucunun onerdigi
    // bekleme suresi (Retry-After basligi); vermemisse nil.
    case rateLimited(retryAfter: TimeInterval?)
    // Cloudflare'in bot kontrolu. Oturumla ilgisi YOK, gecici bir engel.
    case blocked

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .unauthorized: return "Session expired — sign in again"
        case .badStatus(let code): return "Server returned \(code)"
        case .noOrganization: return "No organization found for this account"
        case .rateLimited: return "Rate limited — backing off"
        case .blocked: return "Temporarily blocked by the site's bot check"
        }
    }
}

enum UsageAPI {
    private static let host = "https://claude.ai"

    // URLSession.shared kendi cerez deposunu kullanir ve bizim elle
    // yazdigimiz Cookie basligini ezebilir. Bu yuzden cerezleri tamamen
    // kapali, kendi oturumumuzu kuruyoruz — tek kimlik kaynagi
    // Keychain'deki sessionKey olsun.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Sunucudan gelen JSON'un sekli
    //
    // Asagidaki struct'lar yalnizca bu dosyada kullanildigi icin "private".
    // JSONDecoder'a .convertFromSnakeCase diyecegiz; o sayede sunucudaki
    // "five_hour" alani buradaki "fiveHour" ozelligine otomatik eslesiyor
    // (Swift'in isimlendirme adeti camelCase oldugu icin bu daha okunakli).

    private struct APIWindow: Decodable {
        let utilization: Double
        let resetsAt: String?
    }

    private struct APIUsage: Decodable {
        let fiveHour: APIWindow?
        let sevenDay: APIWindow?
    }

    private struct APIOrganization: Decodable {
        let uuid: String
        let name: String?
        let capabilities: [String]?
    }

    // Menude organizasyon secimi gosterebilmek icin disariya actigimiz
    // sadelestirilmis tur (bkz. AppDelegate.appendOrganizationMenu).
    struct Organization {
        let uuid: String
        let name: String
    }

    // MARK: - Genel istek yardimcisi
    //
    // "<T: Decodable>" = generic (jenerik) fonksiyon: hangi turu istersen
    // onu cozup dondururum demek. Boylece hem organizasyon listesi hem de
    // kullanim verisi icin ayni fonksiyonu kullanabiliyoruz.
    // "async throws" = bu fonksiyon beklemeli (ag istegi) ve hata firlatabilir.
    private static func get<T: Decodable>(_ path: String, sessionKey: String) async throws -> T {
        var request = URLRequest(url: URL(string: host + path)!)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Sunucu, tarayici disindan gelen isteklere farkli davranabildigi
        // icin normal bir tarayici kimligi gonderiyoruz.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badStatus(0) }

        // 429 = "cok sik istek atiyorsun". Bunu ayirt etmemiz sart: ayni
        // hizda istek atmaya devam edersek engel uzayabilir. Cagiran taraf
        // bunu gorup bir sure hic istek atmamali (bkz. AppDelegate.pauseUntil).
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }

        // claude.ai'nin onunde Cloudflare var. Bot kontrolu yaptiginda
        // 403 + HTML bir sayfa donuyor ("Just a moment..."), gercek API ise
        // her zaman JSON doner.
        //
        // Bu ayrim onemli cunku 403'u kosulsuz "oturum gecersiz" saymak,
        // gecici bir bot kontrolunde kullanicinin GAYET GECERLI oturumunu
        // silmemize yol acardi. Uygulamanin kendi istemcisi su an bu
        // kontrole takilmiyor (olculdu; takilan curl idi) — yani bu bilinen
        // bir arizanin duzeltmesi degil, ileride takilirsa oturumu yok
        // etmemek icin konulmus bir koruma.
        let isJSON = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")

        if !isJSON && (http.statusCode == 401 || http.statusCode == 403) {
            throw APIError.blocked
        }

        // Sadece sunucunun GERCEK yaniti kimlik hatasi sayilir.
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Organizasyon kimligi
    //
    // Kullanim adresi /api/organizations/{ORG_ID}/usage seklinde, yani org
    // kimligi zorunlu. Bunu her seferinde cekmemek icin UserDefaults'ta
    // onbellege aliyoruz.
    private static func organizationId(sessionKey: String) async throws -> String {
        if let cached = SessionStore.orgId { return cached }

        let orgs: [APIOrganization] = try await get("/api/organizations", sessionKey: sessionKey)

        // Sirasiyla: kullanicinin actikca sectigi (hala erisimi varsa),
        // sonra sohbet yetenegi olan ilki, sonra listedeki ilki.
        //
        // Kullanicinin secimini ilk sirada denemek onemli: orgId hata
        // kurtarmasi sirasinda temizlenebiliyor ve o zaman buraya geri
        // geliyoruz — tercihi burada hatirlamazsak kullanicinin secimi her
        // gecici hatada sessizce kaybolurdu.
        let chosen = orgs.first { $0.uuid == SessionStore.preferredOrgId }
            ?? orgs.first { $0.capabilities?.contains("chat") == true }
            ?? orgs.first
        guard let uuid = chosen?.uuid else { throw APIError.noOrganization }

        SessionStore.orgId = uuid
        return uuid
    }

    // Bir anahtarin durumu UC ihtimalli — ve bu ayrim onemli. "Gecersiz" ile
    // "su an ulasamadim" ayni sey degil: ikisini birlestirirsek, giris
    // aninda bir saniyelik internet kesintisi kullanicinin GERCEK anahtarini
    // kalici olarak "gecersiz" diye isaretler ve giris bir daha hic
    // tamamlanmaz. Bu yuzden sadece sunucunun acikca reddettigi durumu
    // gecersiz sayiyoruz.
    enum KeyCheck {
        case valid        // sunucu kabul etti
        case invalid      // sunucu acikca reddetti (401/403)
        case unreachable  // sonuc belirsiz — ag hatasi, zaman asimi vs.
    }

    // Bir sessionKey gercekten calisiyor mu? Giris penceresi bunu, yakaladigi
    // cerezi kabul etmeden once sormak icin kullaniyor.
    //
    // Neden gerekli: giris akisi sirasinda claude.ai, henuz gecerli olmayan
    // ya da eski bir oturumdan kalma bir sessionKey cerezi birakmis olabilir.
    // "Cerez var mi" diye bakmak bu yuzden yeterli degil — tek kesin olcut,
    // o anahtarla gercekten bir istek atip sonucuna bakmak.
    static func check(sessionKey: String) async -> KeyCheck {
        do {
            let orgs: [APIOrganization] = try await get("/api/organizations", sessionKey: sessionKey)
            return orgs.isEmpty ? .invalid : .valid
        } catch APIError.unauthorized {
            return .invalid
        } catch {
            // Ag hatasi, zaman asimi, beklenmedik yanit bicimi… Hepsinde
            // "bilmiyorum" deyip tekrar denemeyi tercih ediyoruz.
            return .unreachable
        }
    }

    // Hesaba bagli tum organizasyonlar. Cogu kullanicida tek tane olur;
    // Team/Enterprise hesaplarinda birden fazla olabilir ve o zaman
    // kullanicinin hangisine baktigini secebilmesi gerekir.
    static func organizations() async throws -> [Organization] {
        guard let key = SessionStore.sessionKey else { throw APIError.notSignedIn }
        let raw: [APIOrganization] = try await get("/api/organizations", sessionKey: key)
        // Isim bos gelirse kimligi gosteriyoruz; menude bos satir olmasin.
        return raw.map { Organization(uuid: $0.uuid, name: $0.name ?? $0.uuid) }
    }

    // MARK: - Disariya acilan fonksiyonlar

    static func fetchSnapshot() async throws -> UsageSnapshot {
        guard let key = SessionStore.sessionKey else { throw APIError.notSignedIn }

        do {
            return try await snapshot(sessionKey: key)
        } catch APIError.unauthorized {
            // 403 iki ayri seyi birden anlatiyor olabilir: "oturumun
            // gecersiz" ya da "bu organizasyona erisimin yok" — claude.ai
            // ikisini de 403 donuyor, ayirt edemiyoruz. Onbellekteki org
            // kimligi bayatlamis olabilecegi icin (kullanici bir takimdan
            // cikarilmis olabilir) once SADECE onu atip bir kez daha
            // deniyoruz. Boylece cozumu oturumu kapatmak olmayan bir sorun
            // yuzunden kullaniciyi bosuna yeniden giris yapmaya zorlamiyoruz.
            guard SessionStore.orgId != nil else { throw APIError.unauthorized }
            SessionStore.orgId = nil
            return try await snapshot(sessionKey: key)
        }
    }

    private static func snapshot(sessionKey key: String) async throws -> UsageSnapshot {
        let org = try await organizationId(sessionKey: key)
        let usage: APIUsage = try await get("/api/organizations/\(org)/usage", sessionKey: key)

        // Sunucu her pencereyi ayri alanda veriyor; ikisini de ayni
        // "Window" sekline cevirip menunun bekledigi sirada diziyoruz.
        // "compactMap { $0 }" = listedeki nil'leri atip kalanlari birak
        // (ornegin hesapta haftalik limit tanimli degilse o alan nil gelir).
        let windows: [UsageSnapshot.Window] = [
            window(from: usage.fiveHour, id: "fiveHour", label: "Current session"),
            window(from: usage.sevenDay, id: "sevenDay", label: "Weekly (7 days)"),
        ].compactMap { $0 }

        return UsageSnapshot(windows: windows, capturedAt: Date(), source: .api)
    }

    private static func window(from raw: APIWindow?, id: String, label: String) -> UsageSnapshot.Window? {
        guard let raw else { return nil }
        let resetAt = raw.resetsAt.flatMap(parseTimestamp)

        // Kesin zamani sakliyoruz: API'ye ulasamadigimiz bir anda yerel
        // dosyadan tahmin yurutmek yerine bunu kullanacagiz
        // (bkz. SessionStore.cachedResetAt).
        SessionStore.setCachedResetAt(id, resetAt)

        return UsageSnapshot.Window(
            label: label,
            percent: Int(raw.utilization.rounded()),
            resetAt: resetAt,
            resetIsEstimate: false  // API kesin zamani veriyor, tahmin degil
        )
    }

    // Sunucu zamani "2026-07-31T11:10:00.271661+00:00" seklinde gonderiyor.
    // Saniyenin kesirli kismi 6 haneli; Foundation'in hazir ISO8601
    // cozumleyicisi standart olarak 3 hane bekledigi icin bu kadar haneyle
    // bogulabiliyor. Saniye altı hassasiyet bize zaten gereksiz (menude
    // "4s 32dk" yaziyoruz), o yuzden kesirli kismi tamamen atip
    // cozumluyoruz — en dayanikli yol bu.
    static func parseTimestamp(_ text: String) -> Date? {
        var cleaned = text
        if let dot = cleaned.firstIndex(of: "."),
           let end = cleaned[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            cleaned.removeSubrange(dot..<end)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }
}
