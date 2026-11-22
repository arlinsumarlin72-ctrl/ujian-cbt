# Ujian CBT - Panduan Pemasangan

Situs statis (GitHub Pages) + database Supabase. Gratis untuk ≤10 peserta (cek harga terbaru).

## 1. Supabase
1. Buat akun di supabase.com, lalu **New project** (catat password database).
2. Buka **SQL Editor**, tempel seluruh isi `supabase/schema.sql`, klik **Run**. (Database yang sudah berjalan: JANGAN jalankan ulang `schema.sql`; pakai file `supabase/patch-*.sql` berurutan. Salinan fungsi terbaru ada di `supabase/fungsi-live-*.sql`.)
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
   - **Per bagian (mis. per 20)**: pilih *Langsung lanjut* atau *Terkunci sampai admin membuka*. Pada mode terkunci, isi soal bagian lain tidak dikirim ke peserta.
   - **Diskusi**: di daftar sesi klik *Peserta dan diskusi*. *Mulai diskusi* menghentikan waktu semua peserta dan membekukan jawaban; *Selesai diskusi dan buka bagian berikutnya* menjalankan waktu lagi dan membuka bagian baru.
   - **Mode ketat**: peserta ujian layar penuh; pindah tab/aplikasi atau keluar layar penuh dicatat (waktu dan lama) dan terlihat admin. Pencatatan dihentikan saat diskusi.
   - Admin bisa membuka **Analisis** dan **Tinjau soal** tiap peserta yang sudah mengumpulkan, dari panel yang sama.
   - **Rekap untuk diskusi** (panel yang sama): per bagian, soal diurutkan dari persentase benar terendah, lengkap dengan sebaran jawaban. Muncul setelah ada peserta yang menyelesaikan bagian itu.
   - **Peserta boleh jeda mandiri**: tombol Jeda menghentikan waktu pribadi dan menyembunyikan soal (tidak bisa bersama mode ketat).
5. Peserta: menu **Latihan** membuat sesi pribadi dari soal yang terakhir salah, bendera, bercatatan, atau belum pernah dikerjakan. Latihan tidak masuk peringkat. Catatan pribadi ditulis di bawah soal. Coretan pilihan dan stabilo hanya tersimpan di perangkat.
   - Admin > Soal > Kelola: jenis soal (diagnosis, tatalaksana, dosis obat, dst) bisa dikoreksi per soal.
4. Bagikan alamat situs; peserta daftar dengan nama + PIN.

## Batasan jujur
- Mode ketat hanya **mendeteksi**, tidak bisa memblokir aplikasi lain (batasan browser). iPhone tidak mendukung layar penuh, jadi hanya pindah tab/aplikasi yang terdeteksi.
- Jenis soal ditebak dari kalimat tanya (kata kunci); koreksi manual lewat tab Soal bila perlu.
- PIN sederhana (tanpa pembatasan percobaan): cukup untuk kelompok kecil, bukan untuk ujian resmi.
- Jawaban yang kuncinya sudah terbuka masih bisa diubah lewat devtools browser.
- Parser PDF paling rawan; gambar di PDF tidak terbaca. Penomoran otomatis Word bersifat heuristik. Selalu cek pratinjau sebelum simpan.
- Supabase gratis menjeda proyek yang tidak aktif ±1 minggu: klik Restore di dashboard.
