// Bu dosya, uygulamanın "giriş noktası" — program çalıştığında ilk burası
// işletilir (C/JS'teki main() fonksiyonu gibi, ama Swift'te dosyanın en üst
// seviyesindeki kod otomatik olarak "main" kabul edilir, ayrı bir
// func main() yazmaya gerek yok).

import AppKit  // macOS'un pencere/menü/buton gibi görsel arayüz (GUI) kütüphanesi

// NSApplication, her Mac uygulamasının kalbi — event loop'u (kullanıcı
// tıkladığında, zaman geçtiğinde vs. neler olacağını dinleyen sonsuz döngü)
// o yönetiyor. ".shared" demek "bu uygulamanın TEK örneği" demek (singleton).
let app = NSApplication.shared

// AppDelegate.swift'te tanımladığımız sınıfın (class) bir örneğini oluşturuyoruz.
// "delegate" (vekil) deseni: NSApplication önemli anlarda (uygulama açıldı,
// kapanıyor vs.) bu nesnenin fonksiyonlarını çağırır. Yani asıl mantığımızı
// AppDelegate.swift'e yazdık, burada sadece "işte vekilin bu" diyoruz.
let delegate = AppDelegate()
app.delegate = delegate

// Bu satır, programı sonsuz bir bekleme döngüsüne sokar: kullanıcı menü
// çubuğundaki simgeye tıklayana kadar, ya da "Çıkış"a basılana kadar burada
// bekler. Yani programın "çalışır durumda kalmasını" sağlayan satır bu.
app.run()
