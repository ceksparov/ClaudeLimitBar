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
    let key: KeyPath<RawUsage, Int>
    let label: String       // menüde görünecek Türkçe isim
    let windowMs: Double     // pencerenin süresi (5 saat ya da 7 gün, milisaniye cinsinden)
}

// "let" = değişmeyen sabit (JS'teki const gibi). Bu dosyanın en üst
// seviyesinde tanımlanan sabitler, programın her yerinden erişilebilir.
let limits: [LimitWindow] = [
    LimitWindow(key: \.fh, label: "5 Saatlik Oturum", windowMs: 5 * 60 * 60 * 1000),
    LimitWindow(key: \.sd, label: "Haftalık (7 gün)", windowMs: 7 * 24 * 60 * 60 * 1000),
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

// fromIndex'ten geriye dogru, degerin sifir olmadigi son "serinin" basladigi
// ilk ornegin index'ini dondurur.
func streakStartIndex(_ samples: [RawSample], from: Int, key: KeyPath<RawUsage, Int>) -> Int {
    var i = from
    while i > 0 && samples[i - 1].u[keyPath: key] != 0 { i -= 1 }
    return i
}

// from (dahil, degeri sifir olan) bir ornekten geriye dogru, ayni sifir
// "platosunun" basladigi ilk ornegin index'ini dondurur. Kullanici saatlerce
// Claude'u acmadiysa, bu plato onlarca orneklik duz bir sifir serisi olabilir.
func zeroPlateauStartIndex(_ samples: [RawSample], from: Int, key: KeyPath<RawUsage, Int>) -> Int {
    var i = from
    while i > 0 && samples[i - 1].u[keyPath: key] == 0 { i -= 1 }
    return i
}

// Mevcut pencerenin baslangici. Bir sifir platosu sadece, hemen ardindan
// gelen deger platodan onceki degerden gercekten dusukse "gercek
// sifirlanma" sayilir. Ani bir sifirdan sonra deger dogrudan eski
// seviyesine sicriyorsa (yavasca yukselmiyorsa), bu Claude uygulamasinin bir
// anlik raporlama hatasidir - yoksa boyle sahte sifirlar pencerenin cok
// daha once basladigini sanip tahmini saatlerce yanlis hesaplatabilir.
// Gercek bir sifirlanma bulununca pencere, o an degil, kullanicinin ilk
// gercek kullanim aninda baslar (reset ile ilk kullanim arasinda, ör. gece
// boyu kullanilmadiysa, uzun bir bosluk olsa bile dogru sonuc verir).
//
// "key: KeyPath<RawUsage, Int>" parametresi sayesinde bu TEK fonksiyon hem
// fh hem sd için çalışıyor — çağıran taraf hangisine bakacağını \.fh ya da
// \.sd olarak veriyor (bkz. AppDelegate.swift'teki kullanım).
func estimateReset(
    samples: [RawSample], key: KeyPath<RawUsage, Int>, windowMs: Double, now: Double
) -> Double? {  // dönüş tipindeki "?" = "ya bir sayı ya da hiçbir şey (nil)" demek — Optional
    // "guard let" = "last diye bir şey varsa devam et, yoksa hemen çık (return)".
    // samples.last, dizi boşsa nil döner; bu satır o durumu güvenle ele alıyor.
    guard let last = samples.last else { return nil }
    if last.u[keyPath: key] == 0 { return nil }

    var i = samples.count - 1
    while true {
        let streakStart = streakStartIndex(samples, from: i, key: key)
        if streakStart == 0 { i = 0; break }

        let plateauStart = zeroPlateauStartIndex(samples, from: streakStart - 1, key: key)
        let valueBeforeZero = plateauStart > 0 ? samples[plateauStart - 1].u[keyPath: key] : Int.max
        let valueAfterZero = samples[streakStart].u[keyPath: key]

        if valueAfterZero < valueBeforeZero {
            i = streakStart  // gercek sifirlanma bulundu
            break
        }
        if plateauStart == 0 { i = 0; break }
        i = plateauStart - 1  // sahte sifir platosu - onceki seriyle birlestir, daha eskiye bak
    }

    let windowStart = samples[i].t
    let resetAt = windowStart + windowMs
    return resetAt > now ? resetAt : nil
}

// Milisaniyeyi "4s 32dk" gibi okunaklı bir Türkçe metne çeviriyor.
func formatDuration(_ ms: Double) -> String {
    if ms <= 0 { return "birazdan" }
    let totalMin = Int((ms / 60000).rounded())
    let days = totalMin / 1440
    let hours = (totalMin % 1440) / 60
    let mins = totalMin % 60
    if days > 0 { return "\(days)g \(hours)s" }  // \(...) = string interpolation, JS'teki ${...} ile ayni
    if hours > 0 { return "\(hours)s \(mins)dk" }
    return "\(mins)dk"
}

// Menüde "Sıfırlanma (tahmini): ..." satırında gösterilecek metni üretir.
// "resetAt: Double?" parametresindeki "?" yine Optional — resetAt olmayabilir.
func resetLabel(pct: Int, resetAt: Double?, now: Double) -> String {
    if pct == 0 { return "henüz kullanım yok" }
    // "if let resetAt" = "resetAt gerçekten bir değer içeriyorsa, onu aç ve kullan"
    if let resetAt { return formatDuration(resetAt - now) }
    return "bilinmiyor"
}
