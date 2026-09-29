# FixStat kurulumu

[English](INSTALL.md)

> **Test sürümü.** FixStat şu an **macOS 14 Sonoma veya üstünü** gerektirir.
> Eski sürümler için destek (macOS 10.13 High Sierra'ya kadar) yakında geliyor.

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

1. [Releases](../../releases) sayfasından `FixStat.zip` dosyasını indirin.
2. Zip dosyasına çift tıklayarak açın.
3. **FixStat.app**'i **Uygulamalar** (Applications) klasörüne sürükleyin.

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

**macOS 14 Sonoma**

1. Uygulamalar klasöründe FixStat'a **sağ tıklayın** (veya Control ile tıklayın) ve **Aç**'ı seçin.
2. Çıkan pencerede **Aç**'a tıklayın.

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
açın. Tarama diski yalnızca okur.

<a id="menu-cubugu"></a>

## 3. Menü çubuğunda bulma

FixStat'ın Dock simgesi yoktur ve açılışta pencere göstermez — sağ üstteki **menü
çubuğunda** çalışır (batarya simgesi, yüzde ve CPU sıcaklığı). Paneli açmak için tıklayın.

- Paneldeki **Ayarlar…**: menü çubuğunda ne görüneceği, teknisyen modu, görünüm
  (sistem / açık / koyu), eşikler, güncelleme sıklığı, sensör isimleri.
- **Geçmiş**: bataryanın şarj, akım ve sağlık geçmişi.
- **Çık**: FixStat'ı kapatır.

<a id="oturum-acilisi"></a>

## 4. Oturum açılışında başlatma (isteğe bağlı)

Ayarlar › Genel › **Oturum açılışında başlat**. macOS, FixStat'a **Sistem Ayarları › Genel ›
Giriş Öğeleri ve Uzantılar** bölümünden izin vermenizi isteyebilir.

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
   defaults delete io.github.burakfixlab.fixstat
   ```

<a id="kaynaktan-derleme"></a>

## Kaynaktan derleme

macOS 14 veya üstü ve Xcode 16 veya üstü (Swift 6) gerekir. Başka araç gerekmez.

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
| Oturum açılışında başlamıyor | Sistem Ayarları › Genel › Giriş Öğeleri ve Uzantılar'da FixStat'a izin verin. |
| Sensörlerde "tahmini" yazıyor | Mac modeliniz için henüz doğrulanmış sensör haritası yok; isimler çip ve anahtar kalıplarından tahmin ediliyor. [Modelinizi eklemeye yardım edebilirsiniz](CONTRIBUTING.md). |
| Tam SSD testi başlamıyor / "macOS diskin okunmasını engelledi" | Sistem Ayarları › Gizlilik ve Güvenlik › Tam Disk Erişimi'nde FixStat'ı açın. Uygulamayı değiştirdikten veya yeniden derledikten sonra kapatıp tekrar açın (imzasız derleme yeni bir uygulama sayılır). |
| Dil yanlış | FixStat sistem dilini izler. Yalnızca FixStat için değiştirmek: Sistem Ayarları › Genel › Dil ve Bölge › Uygulamalar. |

Soru veya sorun için: [issue açın](../../issues).
