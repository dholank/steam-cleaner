# Steam Cleaner

[![Safety checks](https://github.com/dholank/steam-cleaner/actions/workflows/test.yml/badge.svg)](https://github.com/dholank/steam-cleaner/actions/workflows/test.yml)
![Windows](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)

Steam Cleaner adalah script PowerShell untuk mereset file client Steam tanpa menghapus library game dan data pengguna.

Script hanya mempertahankan:

```text
Steam\
|- steamapps\   Game dan library Steam
|- userdata\    Data pengguna dan sebagian save/config
`- steam.exe    Launcher Steam
```

Semua file dan folder lain di dalam lokasi instalasi Steam akan dihapus permanen.

> [!CAUTION]
> Penghapusan tidak masuk Recycle Bin. Tutup Steam dan backup file custom yang berada di luar `steamapps` atau `userdata` sebelum melanjutkan.

## Cara Menjalankan

Buka PowerShell, lalu jalankan:

```powershell
irm https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 | iex
```

Steam Cleaner akan:

1. Mendeteksi lokasi instalasi Steam.
2. Memvalidasi tanda tangan digital Valve pada `steam.exe`.
3. Memastikan Steam dan proses latar belakangnya sudah ditutup.
4. Menampilkan lokasi Steam, jumlah file, ukuran, dan daftar lengkap yang akan dihapus.
5. Menunggu konfirmasi sebelum melakukan penghapusan.
6. Memeriksa ulang isi folder agar perubahan mendadak tidak ikut terhapus.

Saat konfirmasi muncul, ketik persis:

```text
DELETE
```

Cukup ketik `DELETE`, tanpa path, tanda kutip, atau teks tambahan. Tekan Enter tanpa mengetik apa pun untuk membatalkan.

## Preview Tanpa Menghapus

Download script terlebih dahulu:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/dholank/steam-cleaner/main/steam-cleaner.ps1 -OutFile .\steam-cleaner.ps1
```

Lalu jalankan mode preview:

```powershell
.\steam-cleaner.ps1 -PreviewOnly
```

Jika Steam berada di lokasi khusus:

```powershell
.\steam-cleaner.ps1 -SteamPath 'D:\Steam' -PreviewOnly
```

Hapus `-PreviewOnly` setelah daftar target sudah diperiksa dan siap dibersihkan.

## Yang Aman dan Yang Terhapus

| Lokasi | Hasil |
| --- | --- |
| `steamapps` | Dipertahankan, termasuk game yang terpasang. |
| `userdata` | Dipertahankan. |
| `steam.exe` | Dipertahankan. |
| File client Steam lainnya | Dihapus dan akan dibuat ulang oleh Steam. |
| Skin, script, atau file custom di luar daftar aman | Dihapus. Backup terlebih dahulu bila masih diperlukan. |
| Screenshot di luar `userdata` | Dihapus. Backup terlebih dahulu bila masih diperlukan. |

Steam biasanya mengunduh ulang file client yang diperlukan saat pertama kali dibuka setelah pembersihan.

## Jika Terjadi Error

### Steam masih berjalan

Pilih **Steam > Exit**, lalu periksa Task Manager. Steam Cleaner tidak menghentikan proses secara paksa.

### Instalasi Steam tidak ditemukan

Gunakan versi lokal dan tentukan lokasinya:

```powershell
.\steam-cleaner.ps1 -SteamPath 'D:\Steam'
```

### Tanda tangan digital tidak valid

Pastikan `steam.exe` berasal dari instalasi resmi Steam. Script menolak executable tanpa tanda tangan Valve yang valid.

### Isi folder berubah setelah preview

Ada proses yang membuat atau mengubah file setelah preview ditampilkan. Tutup Steam dan program terkait, lalu jalankan script kembali.

## Perlindungan

- Menolak drive root, UNC path, relative path, junction, symbolic link, dan folder sistem.
- Memastikan `steamapps`, `userdata`, dan `steam.exe` memiliki tipe yang benar dan bukan link.
- Memvalidasi `steam.exe` menggunakan tanda tangan Authenticode Valve.
- Tidak pernah mengikuti link ketika membaca atau menghapus isi folder.
- Memeriksa ulang rencana penghapusan setelah konfirmasi.
- Menghapus folder hanya setelah seluruh isinya yang terverifikasi sudah dihapus.
- Berhenti jika Steam kembali berjalan atau target berubah selama proses.

Remote execution mempercayai isi repository ini. Untuk penggunaan terkontrol, ganti `main` pada URL dengan commit SHA yang sudah diperiksa.

## Development

Struktur repository:

```text
steam-cleaner.ps1            Cleaner utama dan entry point irm | iex
clean-steam.ps1              Alias kompatibilitas untuk URL lama
tests\safety.tests.ps1       Pemeriksaan dengan instalasi Steam sintetis
tests\run-tests.ps1          Syntax validation dan test runner
.github\workflows\test.yml  Windows PowerShell 5.1 dan PowerShell 7
```

Jalankan pemeriksaan offline:

```powershell
powershell -NoProfile -File .\tests\run-tests.ps1
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Fixture pengujian hanya memakai folder sementara yang dibuat khusus dan tidak menyentuh instalasi Steam pengguna.

