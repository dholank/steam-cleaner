# Steam Cleaner

[![Safety checks](https://github.com/dholank/steam-cleaner/actions/workflows/test.yml/badge.svg)](https://github.com/dholank/steam-cleaner/actions/workflows/test.yml)
![Windows](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)

Kumpulan tool PowerShell untuk membersihkan folder instalasi Steam dan mengunduh depot game melalui SteamCMD.

| Tool | Fungsi |
| --- | --- |
| **Steam Cleaner** | Menghapus isi folder instalasi Steam dan hanya mempertahankan `steamapps`, `userdata`, serta `steam.exe`. |
| **Depot Downloader** | Memilih depot berdasarkan AppID dan lisensi akun, mengunduh manifest yang tepat, lalu menyatukan file ke satu folder game. |

> [!CAUTION]
> Steam Cleaner melakukan penghapusan permanen tanpa Recycle Bin. Tutup Steam dan buat backup sebelum menjalankannya.

## Quick Start

Buka PowerShell, lalu jalankan:

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 | iex
```

Pilih menu:

```text
[1] Clean Steam
[2] Depot Downloader
[3] Reassemble downloaded depots
[Enter] Cancel
```

Persyaratan:

- Windows 10 atau 11.
- Windows PowerShell 5.1 atau PowerShell 7.
- Jalankan sebagai user biasa terlebih dahulu.
- Koneksi internet diperlukan untuk Depot Downloader dan pemasangan SteamCMD pertama kali.

## 1. Membersihkan Folder Steam

Pilih **Clean Steam** dari menu utama. Tool akan:

1. Mendeteksi lokasi Steam.
2. Memastikan `steam.exe` memiliki tanda tangan digital Valve.
3. Memastikan Steam sudah ditutup.
4. Menampilkan seluruh file dan folder yang akan dihapus.
5. Meminta konfirmasi sebelum menghapus apa pun.

Untuk melanjutkan, ketik persis:

```text
DELETE
```

Jangan tambahkan path, tanda kutip, atau teks lain. Tekan Enter tanpa mengetik `DELETE` untuk membatalkan.

Yang dipertahankan:

```text
Steam\
├─ steamapps\
├─ userdata\
└─ steam.exe
```

File konfigurasi, skin, screenshot, mod, atau data lain di luar tiga item tersebut akan dihapus.

### Cleaner saja

Untuk langsung membuka cleaner tanpa menu:

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/clean-steam.ps1 | iex
```

Preview tanpa menghapus:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/dholank/steam-cleaner/main/clean-steam.ps1 -OutFile .\clean-steam.ps1
.\clean-steam.ps1 -PreviewOnly
.\clean-steam.ps1 -SteamPath 'D:\Steam' -PreviewOnly
```

## 2. Mengunduh Depot Game

Pilih **Depot Downloader** untuk mengunduh file game yang dapat diakses oleh akun Steam.

Alurnya:

1. Pilih **Download Location** melalui dialog Windows.
2. Aktifkan **Keep temporary depot files** hanya jika cache ingin disimpan.
3. Masukkan AppID game.
4. Masukkan nama login Steam, atau `anonymous` untuk konten yang memang mendukungnya.
5. Masukkan password dan Steam Guard langsung pada jendela SteamCMD.
6. Periksa keputusan depot yang ditampilkan.
7. Tunggu sampai muncul **Files Ready / Assembly Complete**.

Password dan kode Steam Guard tidak diterima, disimpan, atau ditulis ke log oleh Steam Cleaner.

### Lokasi file

Default Download Location:

```text
C:\Users\<user>\Downloads\Steam Cleaner Downloads
```

Contoh untuk AppID `123` dan InstallDir `MyGame`:

```text
Steam Cleaner Downloads\
├─ .depot-cache\
│  └─ 123\
│     ├─ metadata.json
│     ├─ receipt_<DepotID>.json
│     └─ depot_<DepotID>\
└─ MyGame\                 Final output
```

Setting dialog tersimpan di:

```text
%LOCALAPPDATA%\SteamCleaner\settings.json
```

Log non-rahasia tersimpan di:

```text
%LOCALAPPDATA%\SteamCleaner\logs
```

Cache AppID otomatis dihapus setelah download, assembly, dan verifikasi berhasil. Centang **Keep temporary depot files** untuk mempertahankan cache. Jika terjadi kegagalan, cache selalu dipertahankan agar dapat diperiksa atau dicoba kembali.

### Cara depot dipilih

Steam Cleaner membaca AppInfo, lisensi, dan package metadata melalui SteamCMD.

| Status | Arti |
| --- | --- |
| `DOWNLOAD/HIGH` | Package akun secara eksplisit memberikan akses dan depot cocok dengan konfigurasi. |
| `SKIP/HIGH` | Depot tidak dimiliki atau tidak cocok dengan OS, arsitektur, bahasa, atau kebijakan DLC. |
| `REVIEW/LOW` | Metadata SteamCMD belum cukup untuk membuktikan keputusan secara aman. Download dihentikan. |
| `ERROR` | Depot wajib, shared depot, ownership, edition, atau branch tidak dapat diakses. |

Default konfigurasi adalah Windows, x64, English, public branch, dan `DLC=None`. DLC tetap dilewati meskipun dimiliki. Depot kosong dicatat tanpa diunduh. Steamworks Common Redistributables tidak digabungkan ke output game.

### Assembly dan collision

Depot digabungkan berdasarkan `MountOrder`; depot yang dipasang belakangan menang ketika dua depot memiliki file dengan path yang sama. Semua collision dicatat. Mount order dengan confidence rendah menghentikan assembly untuk review.

Assembly dilakukan terlebih dahulu di:

```text
<InstallDir>.assembling-<id>
```

Seluruh hash diverifikasi sebelum folder tersebut diubah menjadi output final. Jika output final sudah ada, tool meminta lokasi lain atau membatalkan. Versi ini tidak melakukan update atau replace terhadap output lama.

Hasil assembly hanya berupa file siap pakai. Tool tidak membuat `appmanifest`, tidak mendaftarkan instalasi ke Steam, tidak menjalankan prerequisite/install script, dan tidak meluncurkan game.

## Penggunaan Noninteraktif

Clone atau download repository ini untuk memakai parameter lokal:

```powershell
.\steam-cleaner.ps1 -Action Download `
  -AppId 2651280 `
  -UserName myaccount `
  -DownloadRoot 'D:\Steam Cleaner Downloads' `
  -KeepTemporaryDepots $false
```

Menggunakan config JSON:

```powershell
.\steam-cleaner.ps1 -Action Download `
  -AppId 2651280 `
  -UserName myaccount `
  -ConfigPath .\config\depot-settings.json
```

Urutan prioritas setting:

```text
Parameter CLI → Config JSON → Setting tersimpan → Default
```

Lihat [`config/depot-settings.example.json`](config/depot-settings.example.json) untuk contoh config.

## Reassemble dari Cache

Jika opsi keep-cache diaktifkan, output dapat dibuat kembali tanpa mengunduh depot yang sama:

```powershell
.\steam-cleaner.ps1 -Action Reassemble `
  -MetadataPath 'D:\Steam Cleaner Downloads\.depot-cache\2651280\metadata.json' `
  -DownloadRoot 'D:\Steam Cleaner Downloads'
```

Receipt dan SHA256 inventory harus tetap cocok. Cache rusak atau ManifestID yang berbeda tidak akan digunakan secara diam-diam.

## Troubleshooting

### `Steam is running`

Tutup Steam dari menu **Steam → Exit**, lalu periksa Task Manager. Tool tidak menghentikan proses Steam secara otomatis.

### `REVIEW/LOW`

SteamCMD tidak memberikan metadata package/depot yang cukup. Periksa akun, edition game, DLC, dan branch yang digunakan. Tool sengaja tidak menebak depot ambigu.

### `Steam denied depot access`

Pastikan akun memiliki game atau edition yang diperlukan. Login `anonymous` tidak dapat mengunduh sebagian besar game retail.

### `Output already exists`

Pilih Download Location lain atau pindahkan output lama secara manual. Tool tidak menimpa folder game yang sudah ada.

### `Insufficient space`

Download Location membutuhkan ruang untuk raw depot, staging assembly, output final, dan headroom. Kosongkan drive atau pilih drive lain.

### Lokasi masih menunjuk Documents

Versi terbaru menggunakan `Downloads\Steam Cleaner Downloads`. Setting yang masih persis menggunakan default Documents lama akan diarahkan ke default baru tanpa memindahkan atau menghapus data lama.

## Perlindungan yang Diterapkan

- Menolak drive root, UNC path, relative path, traversal, alternate data stream, junction, dan symbolic link.
- Memvalidasi executable Steam dan SteamCMD melalui tanda tangan digital Valve.
- Memeriksa ulang rencana penghapusan setelah konfirmasi.
- Tidak mengikuti link saat membaca, menyalin, atau menghapus file.
- Menghentikan download jika entitlement, manifest, branch, atau mount order ambigu.
- Menulis metadata dan setting secara atomik.
- Memverifikasi receipt dan SHA256 sebelum cache digunakan kembali.
- Mempertahankan cache pada setiap kegagalan.

Remote execution mempercayai isi repository ini. Periksa script sebelum menjalankannya. Untuk penggunaan terkontrol, ganti `main` pada raw URL dengan full commit SHA yang sudah diperiksa.

## Development

Jalankan seluruh 123 pemeriksaan offline:

```powershell
powershell -NoProfile -File .\tests\run-tests.ps1
pwsh -NoProfile -File .\tests\run-tests.ps1
```

GitHub Actions menjalankan syntax validation dan seluruh suite pada Windows PowerShell 5.1 serta PowerShell 7. Fixture pengujian menggunakan folder sementara dan tidak menyentuh instalasi Steam pengguna.

```text
clean-steam.ps1            Standalone Steam cleaner
steam-cleaner.ps1          Menu, local CLI, dan remote launcher
modules/                   Resolver, SteamCMD, cache, metadata, UI, assembly
config/                    Contoh setting non-rahasia
docs/                      Dokumentasi teknis dan batasan operasional
tests/                     Offline test suite dan synthetic fixtures
.github/workflows/test.yml Windows PowerShell 5.1 dan 7 checks
```

Dokumentasi teknis lengkap tersedia di [`docs/depot-downloader.md`](docs/depot-downloader.md).

## Referensi

- [Valve SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD)
- [Valve depot mounting rules](https://partner.steamgames.com/doc/store/application/depots)

SteamKit dan SteamDB tidak digunakan sebagai runtime dependency.
