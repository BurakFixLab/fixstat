# FixStat kurulumu

[English](INSTALL.md)

> **macOS 10.13 High Sierra ve üstünde** (Intel) ve **macOS 11 Big Sur ve üstünde** (Apple
> Silicon) çalışır. macOS 14 ve sonrasında SwiftUI arayüzü, eski sürümlerde aynı özelliklere
> sahip bir AppKit arayüzü açılır. macOS 10.13 – 10.15 henüz gerçek donanımda denenmedi —
> geri bildirimlerinizi bekliyoruz.

- [1. İndirme](#indirme)
- [2. İlk açılış](#ilk-acilis)
- [3. Menü çubuğunda bulma](#menu-cubugu)
- [4. Oturum açılışında başlatma (isteğe bağlı)](#oturum-acilisi)
- [Güncelleme](#guncelleme)
- [Kaldırma](#kaldirma)
- [Kaynaktan derleme](#kaynaktan-derleme)
- [Sorun giderme](#sorun-giderme)

<a id="indirme"></a>

## 1. İndirme

1. [Releases](../../releases) sayfasından `FixStat.dmg` dosyasını indirin.
2. Çift tıklayın. FixStat, bir ok ve Uygulamalar klasörünün olduğu bir pencere açılır.
3. **FixStat**'ı **Uygulamalar** klasörünün üzerine sürükleyin, sonra disk görüntüsünü
   çıkarın (Finder kenar çubuğunda "FixStat"ın yanındaki ⏏ düğmesi). DMG dosyası
   sonra silinebilir.

<a id="ilk-acilis"></a>

## 2. İlk açılış

FixStat ücretsiz ve açık kaynaktır, ancak Apple tarafından notarize edilmemiştir (bunun için
ücretli geliştirici hesabı gerekir). Bu yüzden macOS ilk açılışı engeller. Bunu yalnızca bir
kez yapmanız gerekir.

**macOS 15 Sequoia ve sonrası**

1. Uygulamalar klasöründe FixStat'a çift tıklayın. macOS *"FixStat" açılmadı* der — **Bitti**'ye tıklayın.
2. **Sistem Ayarları › Gizlilik ve Güvenlik**'i açın ve **Güvenlik** bölümüne inin.
3. *"FixStat" engellendi…* yazısının yanındaki **Yine de Aç**'a tıklayın ve parolanızla onaylayın.
4. Ardından gelen pencerede bir kez daha **Yine de Aç**'a tıklayın.

**macOS 14 Sonoma ve öncesi (10.13 – 14)**

1. Uygulamalar klasöründe FixStat'a **sağ tıklayın** (veya Control ile tıklayın) ve **Aç**'ı seçin.
2. Çıkan pencerede **Aç**'a tıklayın.
3. Pencerede **Aç** düğmesi yoksa: **Sistem Tercihleri › Güvenlik ve Gizlilik › Genel**
   (macOS 13 – 14'te Sistem Ayarları › Gizlilik ve Güvenlik) › **Yine de Aç**.

**Tüm sürümler için alternatif (Terminal)**

```bash
xattr -dr com.apple.quarantine /Applications/FixStat.app
```

Bu komut "internetten indirildi" işaretini kaldırır; FixStat sonra normal açılır. macOS
uygulamanın *"hasarlı olduğu ve açılamayacağını"* söylerse de bunu kullanın.

FixStat **özel bir izin gerektirmez**: yönetici yetkisi, Erişilebilirlik veya Tam Disk Erişimi,
ağ erişimi yoktur. Yalnızca sensör değerlerini okur; SMC'ye asla yazmaz.

**Donanım kontrolü**, ilgili testleri ilk açtığınızda macOS üzerinden kamera, mikrofon ve
Bluetooth izni ister; bunlar yalnızca test ekrandayken kullanılır.

Tek istisna isteğe bağlı **tam SSD testidir** (Araçlar › SSD sağlığı ve testi). Diskin tüm
yüzeyini okumak için yönetici parolanız (her seferinde sorulur, FixStat saklamaz) ve **Tam
Disk Erişimi** gerekir: Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi › FixStat'ı
açın (macOS 12 ve öncesinde: Sistem Tercihleri › Güvenlik ve Gizlilik › Gizlilik › Tam Disk
Erişimi; macOS 10.13'te bu ayar yoktur). Tarama diski yalnızca okur.

<a id="menu-cubugu"></a>

## 3. Menü çubuğunda bulma

FixStat açılışta pencere göstermez — sağ üstteki **menü çubuğunda** çalışır (batarya
simgesi, yüzde ve CPU sıcaklığı). Paneli açmak için tıklayın. Pencerelerinden biri (bir araç,
Ayarlar) açıkken Dock simgesi de görünür, böylece pencere diğer uygulamaların arkasında
kaybolmaz; Ayarlar › Genel › **Dock simgesini her zaman göster** simgeyi kalıcı yapar.

- Paneldeki **Ayarlar…**: menü çubuğunda ne görüneceği, teknisyen modu, görünüm
  (sistem / açık / koyu), eşikler, güncelleme sıklığı, sensör isimleri.
- **Geçmiş**: bataryanın şarj, akım ve sağlık geçmişi.
- **Çık**: FixStat'ı kapatır.

<a id="oturum-acilisi"></a>

## 4. Oturum açılışında başlatma (isteğe bağlı)

Ayarlar › Genel › **Oturum açılışında başlat**. macOS 13 ve sonrasında macOS, FixStat'a
**Sistem Ayarları › Genel › Giriş Öğeleri ve Uzantılar** bölümünden izin vermenizi
isteyebilir. macOS 12 ve öncesinde FixStat küçük bir launch agent ekler
(`~/Library/LaunchAgents/io.github.burakfixlab.fixstat.login.plist`) ve seçeneği
kapattığınızda siler.

<a id="guncelleme"></a>

## Güncelleme

FixStat'tan çıkın, Uygulamalar'daki `FixStat.app`'i yeni sürümle değiştirin ve tekrar açın
(macOS sorarsa 2. adımı tekrarlayın). Ayarlar, özel sensör isimleri ve batarya geçmişi korunur.

<a id="kaldirma"></a>

## Kaldırma

1. FixStat Ayarları'nda **Oturum açılışında başlat**'ı kapatın, ardından **Çık**'a tıklayın.
2. `FixStat.app`'i Uygulamalar klasöründen Çöp Sepeti'ne taşıyın.
3. İsteğe bağlı — ayarları, özel sensör isimlerini ve batarya geçmişini silmek için:
   ```bash
   rm -rf ~/Library/Application\ Support/FixStat
   rm -f ~/Library/LaunchAgents/io.github.burakfixlab.fixstat.login.plist
   defaults delete io.github.burakfixlab.fixstat
   ```

<a id="kaynaktan-derleme"></a>

## Kaynaktan derleme

macOS 14 veya üstü ve Xcode 16 veya üstü (Swift 6) gerekir. Başka araç gerekmez. Bu şekilde
derlenen uygulama da yayınlanan sürüm gibi macOS 10.13 ve üstünde çalışır.

```bash
git clone https://github.com/BurakFixLab/fixstat.git
cd fixstat
scripts/build-app.sh          # build/FixStat.app oluşturur
open build/FixStat.app
```

Kendi derlediğiniz uygulamada karantina işareti olmaz, 2. adıma gerek yoktur. Komut satırı araçları:

```bash
swift build -c release
.build/release/sensordump     # batarya, sıcaklıklar, fanlar
```

<a id="sorun-giderme"></a>

## Sorun giderme

| Sorun | Çözüm |
|---|---|
| Simge menü çubuğunda görünmüyor | Çentikli MacBook'larda dolu bir menü çubuğu öğeleri çentiğin arkasına saklayabilir. Birkaç menü çubuğu uygulamasını kapatın veya bir menü çubuğu yöneticisi kullanın. FixStat'ın çalıştığını Etkinlik Monitörü'nden kontrol edin. |
| *"FixStat" açılmadı* / *açılamıyor* | 2. adıma bakın veya `xattr` komutunu kullanın. |
| *"hasarlı ve açılamıyor"* | 2. adımdaki `xattr` komutunu kullanın. |
| Oturum açılışında başlamıyor | Sistem Ayarları › Genel › Giriş Öğeleri ve Uzantılar'da FixStat'a izin verin (macOS 13 ve sonrası). Eski sürümlerde seçeneği kapatıp yeniden açın. |
| Panel ekran görüntülerinden farklı görünüyor | macOS 13 ve öncesinde FixStat AppKit arayüzünü kullanır: aynı veriler ve araçlar, daha sade bir görünüm. |
| Sensörlerde "tahmini" yazıyor | Mac modeliniz için henüz doğrulanmış sensör haritası yok; isimler çip ve anahtar kalıplarından tahmin ediliyor. [Modelinizi eklemeye yardım edebilirsiniz](CONTRIBUTING.md). |
| Tam SSD testi başlamıyor / "macOS diskin okunmasını engelledi" | Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi'nde FixStat'ı açın. Uygulamayı değiştirdikten veya yeniden derledikten sonra kapatıp tekrar açın (imzasız derleme yeni bir uygulama sayılır). |
| Dil yanlış | FixStat sistem dilini izler. Yalnızca FixStat için değiştirmek: Sistem Ayarları › Genel › Dil ve Bölge › Uygulamalar. |

Soru veya sorun için: [issue açın](../../issues).
