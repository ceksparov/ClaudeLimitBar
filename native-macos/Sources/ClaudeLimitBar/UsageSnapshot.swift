import Foundation

// Artik verinin iki kaynagi var: canli API (claude.ai) ve masaustu
// uygulamasinin yerel dosyasi. Bu struct, ikisinden gelen veriyi AYNI
// sekle sokuyor. Boylece menuyu cizen kod "bu veri nereden geldi" diye
// hic dusunmek zorunda kalmiyor — tek bir cizim mantigi her iki kaynak
// icin de calisiyor. (Yazilimda buna "adapter" ya da "ortak model"
// yaklasimi denir: farkli kaynaklari tek bir ic temsile cevirmek.)
struct UsageSnapshot {
    enum Source {
        case api        // claude.ai'den canli cekildi — sifirlanma zamani KESIN
        case localFile  // masaustu uygulamasinin dosyasindan — sifirlanma TAHMINI
    }

    struct Window {
        let label: String       // "5 Saatlik Oturum" gibi menuye yazilacak isim
        let percent: Int        // kullanim yuzdesi
        let resetAt: Date?      // sifirlanma ani; bilinmiyorsa nil
        let resetIsEstimate: Bool  // true ise kullaniciya "(tahmini)" diye belirtiyoruz
    }

    let windows: [Window]
    let capturedAt: Date    // bu verinin uretildigi an (yerel dosyada eski olabilir)
    let source: Source
}
