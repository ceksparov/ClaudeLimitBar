import Foundation
import Security

// sessionKey, Claude hesabina tam erisim veren gercek bir kimlik bilgisi —
// bunu duz bir dosyaya (ornegin .env'e) yazmak, makineye erisen herkesin
// hesabi ele gecirebilmesi demek olurdu. macOS Keychain ise isletim
// sisteminin sifreli kasasi: veriyi diskte sifreli tutar ve sadece izin
// verilen uygulamaya geri verir. Bu yuzden anahtari oraya koyuyoruz.
//
// "enum" burada ilginc bir Swift deyimi: icinde hic "case" yok, sadece
// static fonksiyonlar var. Bunun sebebi, bu turden yanlislikla bir ornek
// (instance) olusturulamamasi — yani "SessionStore()" yazilamaz. Sadece
// fonksiyonlari bir arada tutan bir isim alani (namespace) olarak duruyor.
enum SessionStore {
    // Keychain'de kayitlar "service + account" ikilisiyle adreslenir;
    // bunlar bizim kaydimizi baskalarininkinden ayiran etiketler.
    private static let service = "ClaudeUsageBar"
    private static let account = "sessionKey"

    // Keychain API'si Objective-C'den de eski, C tabanli bir arayuz
    // (Security framework). Bu yuzden parametreleri tek tek vermek yerine
    // bir sozlukte toplayip fonksiyona veriyoruz. kSecClassGenericPassword
    // = "bu bir genel amacli parola kaydi" demek.
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // "computed property" (hesaplanan ozellik): disaridan bir degiskenmis
    // gibi "SessionStore.sessionKey" diye okunur, ama her okundugunda
    // asagidaki kod calisip Keychain'e gider.
    static var sessionKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true      // sadece varligini degil, degerini de dondur
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // "var item: CFTypeRef?" + "&item" — C tarzi "sonucu su adrese yaz"
        // deseni. Swift'te "&" isareti, degiskeni fonksiyona degistirilebilir
        // sekilde vermek demek.
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func save(sessionKey: String) {
        // Keychain "ayni kaydi guncelle" icin ayri bir fonksiyon ister;
        // once silip sonra eklemek hem daha kisa hem de daha az hata riskli.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = Data(sessionKey.utf8)
        // kSecAttrAccessibleWhenUnlocked = anahtar SADECE kullanici cihaza
        // giris yapmisken okunabilsin. Varsayilana birakmak yerine bunu
        // acikca yaziyoruz ki niyet kodda gorunur olsun.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        // Synchronizable = false: bu anahtar iCloud Keychain uzerinden
        // diger cihazlara YAYILMASIN. Tek bir makineye ait, kisa omurlu bir
        // oturum bilgisi; baska cihazlara kopyalanmasi gereksiz bir risk.
        query[kSecAttrSynchronizable as String] = false
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    // Organizasyon kimligi gizli bir bilgi degil (sadece bir UUID), o yuzden
    // Keychain'e koymaya gerek yok. UserDefaults, macOS'un basit ayar
    // deposu — tarayicidaki localStorage'in karsiligi gibi dusunulebilir.
    // Bunu onbellege aliyoruz ki her kullanim sorgusunda organizasyon
    // listesini bastan cekmek zorunda kalmayalim.
    static var orgId: String? {
        get { UserDefaults.standard.string(forKey: "orgId") }
        set { UserDefaults.standard.set(newValue, forKey: "orgId") }
    }

    // API'den ogrendigimiz KESIN sifirlanma zamanlarini sakliyoruz.
    //
    // Neden: sifirlanma zamani mutlak bir an ("31 Temmuz 19:10"). Bir kez
    // ogrendikten sonra internet gitse de, oturum dusse de o an degismez —
    // gecene kadar dogru kalir. Onbelleklemezsek, API'ye ulasamadigimiz
    // anda bu kesin bilgiyi atip yerel dosyadan tahmin yurutmeye
    // basliyorduk; kullaniciya gercekle uyusmayan bir sayi gostermenin
    // sebebi tam olarak buydu.
    static func cachedResetAt(_ id: String) -> Date? {
        let seconds = UserDefaults.standard.double(forKey: "resetAt.\(id)")
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func setCachedResetAt(_ id: String, _ date: Date?) {
        let key = "resetAt.\(id)"
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
