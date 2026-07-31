import Foundation

// Bu dosyada arayüzle (menü çubuğu, renkler) ilgili hiçbir şey yok — sadece
// "dosyayı oku, sayıları hesapla" mantığı. Ekrana çizme işini AppDelegate.swift
// yapıyor. Bu, menubar/claude-usage.10s.js'teki JS mantığının Swift'e
// birebir çevirisi — aynı dosyayı okur, aynı hesabı yapar, aynı sonucu verir.

// "struct" = veriyi bir arada tutan basit bir kutu (JS'teki {fh: 5, sd: 9}
// gibi ama tip-güvenli). "Codable" ise Swift'e "bu struct'ı JSON'dan otomatik
// doldurabilirsin" demek — JSON.parse'ı elle yazmamıza gerek kalmıyor,
// alan adları (fh, sd, t, u, samples) JSON'daki adlarla otomatik eşleşiyor.

struct RawUsage: Codable {
    let fh: Int  // 5 saatlik pencere kullanım yüzdesi
    let sd: Int  // haftalık (7 gün) pencere kullanım yüzdesi
}

struct RawSample: Codable {
    let t: Double     // örneğin alındığı an (milisaniye, Unix epoch)
    let u: RawUsage   // o andaki fh/sd değerleri
}

struct RawHistory: Codable {
    let samples: [RawSample]  // dosyadaki tüm örneklerin listesi (dizi)
}

// KeyPath, Swift'e özgü biraz soyut bir kavram: "RawUsage struct'ının HANGİ
// alanına bakacağımı sonradan seçebileceğim bir işaretçi" gibi düşün.
// Yani \.fh, "RawUsage içindeki fh alanını göster" demenin kısa yolu.
// Bunu kullanmamızın sebebi: aşağıdaki "limits" listesinde hem fh hem sd
// için AYNI hesaplama fonksiyonlarını (estimateReset gibi) tekrar tekrar
// yazmadan kullanabilmek — "hangi alana bakılacağı" bir parametre oluyor.
struct LimitWindow {
    let id: String          // onbellek anahtari; API tarafiyla ayni olmali
    let key: KeyPath<RawUsage, Int>
    let label: String       // menüde görünecek Türkçe isim
    let windowMs: Double     // pencerenin süresi (5 saat ya da 7 gün, milisaniye cinsinden)
}

// "let" = değişmeyen sabit (JS'teki const gibi). Bu dosyanın en üst
// seviyesinde tanımlanan sabitler, programın her yerinden erişilebilir.
let limits: [LimitWindow] = [
    LimitWindow(id: "fiveHour", key: \.fh, label: "Current session", windowMs: 5 * 60 * 60 * 1000),
    LimitWindow(id: "sevenDay", key: \.sd, label: "Weekly (7 days)", windowMs: 7 * 24 * 60 * 60 * 1000),
]

let staleMs: Double = 15 * 60 * 1000  // bu süreden eskiyse veriyi "bayat" sayıyoruz

// Claude masaüstü uygulamasının kullanım verisini yazdığı dosyanın tam yolu.
// NSHomeDirectory(), o an giriş yapmış kullanıcının ev klasörünü (/Users/xxx)
// döndürür — kullanıcı adını koda hardcode etmemize gerek kalmaz.
let historyPath: String = {
    NSHomeDirectory() + "/Library/Application Support/Claude/plan-usage-history.json"
}()

// "enum Error" = kendi hata türümüzü tanımlamak. JS'te "throw new Error(...)"
// yerine Swift'te önce hangi hataların olabileceğini burada listeleriz.
enum UsageError: Error {
    case empty  // dosya var ama içinde hiç örnek (sample) yok
}

// "throws" = bu fonksiyon hata fırlatabilir demek. Çağıran taraf bunu
// "try" ile çağırmak ve olası hatayı yakalamak (catch) zorunda —
// JS'teki try/catch'e çok benzer, sadece derleyici bunu sana zorunlu kılıyor.
func loadHistory() throws -> [RawSample] {
    // Data(contentsOf:) dosyayı ham bayt olarak okur (JS'teki readFileSync gibi)
    let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
    // JSONDecoder, yukarıdaki Codable struct'ları kullanarak JSON'u otomatik ayrıştırır
    let history = try JSONDecoder().decode(RawHistory.self, from: data)
    if history.samples.isEmpty { throw UsageError.empty }
    return history.samples
}

// Claude uygulamasi arada bir, tek bir ornekte hatali sifir bildiriyor.
// Boyle bir ornek, oncesi ve sonrasina bakinca anlasilir: deger sifirdan
// sonra DOGRUDAN eski seviyesine donuyorsa ortada gercek bir sifirlanma
// yoktur (gercek sifirlanmadan sonra deger sifirdan yavasca tirmanir),
// sadece anlik bir raporlama hatasi vardir. Bu ornekleri hesaba katmadan
// once ayikliyoruz.
func withoutGlitches(_ samples: [RawSample], key: KeyPath<RawUsage, Int>) -> [RawSample] {
    samples.enumerated().filter { index, sample in
        // Sadece sifir degerleri supheli; ilk ve son ornegi karsilastiracak
        // komsusu olmadigi icin oldugu gibi birakiyoruz.
        guard sample.u[keyPath: key] == 0, index > 0, index < samples.count - 1 else { return true }

        let before = samples[index - 1].u[keyPath: key]
        let after = samples[index + 1].u[keyPath: key]
        return !(before > 0 && after >= before)  // eski seviyeye dondu -> hatali okuma
    }
    .map(\.element)
}

// Mevcut pencerenin ne zaman sifirlanacagini TAHMIN eder. (Giris yapilmissa
// bu fonksiyona hic gerek yok — canli API kesin zamani veriyor. Burasi
// yalnizca yedek yol.)
//
// Temel fikir: bir pencere icinde kullanim yuzdesi yalnizca ARTAR, asla
// azalmaz. Dolayisiyla ardisik iki ornek arasindaki her DUSUS, arada bir
// sifirlanma oldugunun kanitidir.
//
// Onceki surum sinirlari yalnizca 0 degerine bakarak ariyordu ve bu hatali
// idi: sifirlanmadan hemen sonra kullanima devam edilirse deger hicbir
// ornekte 0 gorunmez (gercek ornek: %92 -> %3). O durumda sinir kaciriliyor,
// algoritma cok daha eski bir sinira yuruyor ve gecmiste kalan bir zaman
// hesaplayip "bilinmiyor" donuyordu.
//
// "key: KeyPath<RawUsage, Int>" parametresi sayesinde bu TEK fonksiyon hem
// fh hem sd için çalışıyor — çağıran taraf hangisine bakacağını \.fh ya da
// \.sd olarak veriyor (bkz. UsageData.fileSnapshot'taki kullanım).
func estimateReset(
    samples: [RawSample], key: KeyPath<RawUsage, Int>, windowMs: Double, now: Double
) -> Double? {  // dönüş tipindeki "?" = "ya bir sayı ya da hiçbir şey (nil)" demek — Optional
    let samples = withoutGlitches(samples, key: key)

    // "guard let" = "last diye bir şey varsa devam et, yoksa hemen çık (return)".
    guard let last = samples.last, last.u[keyPath: key] > 0 else { return nil }

    // En son dususu (yani en yakin sifirlanmayi) geriye dogru tarayarak bul.
    var boundary = 0  // hic dusus yoksa dosyanin basindan itibaren bakariz
    var i = samples.count - 1
    while i > 0 {
        if samples[i].u[keyPath: key] < samples[i - 1].u[keyPath: key] {
            boundary = i
            break
        }
        i -= 1
    }

    // Pencere, sifirlanma aninda degil, ondan sonraki ILK GERCEK KULLANIMDA
    // baslar. Ornegin gece boyu Claude kullanilmadiysa, sifirlanma ile ilk
    // kullanim arasinda saatlerce bosluk olabilir.
    var start = boundary
    while start < samples.count && samples[start].u[keyPath: key] == 0 { start += 1 }
    guard start < samples.count else { return nil }

    let resetAt = samples[start].t + windowMs
    return resetAt > now ? resetAt : nil
}

// Milisaniyeyi "4s 32dk" gibi okunaklı bir Türkçe metne çeviriyor.
func formatDuration(_ ms: Double) -> String {
    if ms <= 0 { return "soon" }
    let totalMin = Int((ms / 60000).rounded())
    let days = totalMin / 1440
    let hours = (totalMin % 1440) / 60
    let mins = totalMin % 60
    if days > 0 { return "\(days)d \(hours)h" }  // \(...) = string interpolation, JS'teki ${...} ile ayni
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// Menüde "Sıfırlanma: ..." satırında gösterilecek metni üretir. Veri canlı
// API'den geldiyse sunucunun verdiği kesin zamanı yazıyoruz; yerel dosyadan
// geldiyse kendi tahminimiz olduğunu kullanıcıya açıkça belirtiyoruz.
func resetLabel(percent: Int, resetAt: Date?, isEstimate: Bool, now: Date) -> String {
    // "if let resetAt" = "resetAt gerçekten bir değer içeriyorsa, onu aç ve kullan"
    if let resetAt {
        let text = formatDuration(resetAt.timeIntervalSince(now) * 1000)
        return isEstimate ? "\(text) (estimated)" : text
    }
    if percent == 0 { return "no usage yet" }
    return "unknown"
}

// Yerel dosyadan okunan ham örnekleri, canlı API'nin de kullandığı ortak
// UsageSnapshot şekline çeviriyor. Bu dönüşüm sayesinde AppDelegate tek bir
// çizim koduyla her iki kaynağı da gösterebiliyor (bkz. UsageSnapshot.swift).
func fileSnapshot(samples: [RawSample], now: Double) -> UsageSnapshot {
    guard let last = samples.last else {
        return UsageSnapshot(windows: [], capturedAt: Date(), source: .localFile)
    }

    // "limits.map { ... }" = listedeki her eleman için köşeli parantez
    // içindeki dönüşümü uygulayıp yeni bir liste üret (JS'teki .map ile aynı).
    let windows = limits.map { limit in
        // Daha önce API'den öğrendiğimiz KESIN zaman hâlâ gelecekteyse onu
        // kullan — tahmin yürütmeye gerek yok, çünkü o an değişmedi.
        // Haftalık pencerede bu özellikle değerli: sıfırlanma günler sonra
        // olduğu için önbellekteki değer günlerce doğru kalıyor.
        let cached = SessionStore.cachedResetAt(limit.id)
        let cachedIsUsable = (cached?.timeIntervalSinceNow ?? -1) > 0

        // estimateReset milisaniye döndürüyor; Date'e çeviriyoruz.
        let estimated = estimateReset(
            samples: samples, key: limit.key, windowMs: limit.windowMs, now: now
        ).map { Date(timeIntervalSince1970: $0 / 1000) }

        return UsageSnapshot.Window(
            label: limit.label,
            percent: last.u[keyPath: limit.key],
            resetAt: cachedIsUsable ? cached : estimated,
            resetIsEstimate: !cachedIsUsable
        )
    }

    return UsageSnapshot(
        windows: windows,
        capturedAt: Date(timeIntervalSince1970: last.t / 1000),
        source: .localFile
    )
}
