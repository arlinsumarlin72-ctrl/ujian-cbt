# Ujian CBT - Panduan Pemasangan

Situs statis (GitHub Pages) + database Supabase. Gratis untuk ≤10 peserta (cek harga terbaru).

## 1. Supabase
1. Buat akun di supabase.com, lalu **New project** (catat password database).
2. Buka **SQL Editor**, tempel seluruh isi `supabase/schema.sql`, klik **Run**.
3. Buka **Project Settings > API**: salin **Project URL** dan **anon public key** (JANGAN pakai service_role).

## 2. Isi konfigurasi
Edit `js/config.js`:
```js
window.APP_CONFIG = { SUPABASE_URL: 'https://xxxx.supabase.co', SUPABASE_ANON_KEY: 'eyJ...' };
```

## 3. GitHub Pages
1. Buat repo publik baru, unggah seluruh isi folder ini.
2. **Settings > Pages > Deploy from branch > main / root**.
3. Alamat situs muncul beberapa menit kemudian.

## 4. Pemakaian
1. Buka situs, **daftar duluan**: pendaftar pertama otomatis admin.
2. Admin > Soal: unggah file soal + file kunci (docx/pdf/xlsx/csv/txt), periksa pratinjau, simpan.
3. Admin > Sesi: pilih file, jumlah soal, timer, kapan kunci tampil. Soal diacak sekali, sama untuk semua peserta.
4. Bagikan alamat situs; peserta daftar dengan nama + PIN.

## Batasan jujur
- PIN sederhana (tanpa pembatasan percobaan): cukup untuk kelompok kecil, bukan untuk ujian resmi.
- Jawaban yang kuncinya sudah terbuka masih bisa diubah lewat devtools browser.
- Parser PDF paling rawan; gambar di PDF tidak terbaca. Penomoran otomatis Word bersifat heuristik. Selalu cek pratinjau sebelum simpan.
- Supabase gratis menjeda proyek yang tidak aktif ±1 minggu: klik Restore di dashboard.
