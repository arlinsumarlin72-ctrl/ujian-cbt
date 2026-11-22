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
   - **Timer**: bila kunci tampil per bagian, timer berlaku untuk TIAP bagian (mis. 10 menit untuk 20 nomor). Jam bagian dimulai saat bagian itu terbuka bagi peserta, berhenti saat diskusi/jeda, dan saat habis bagian otomatis diselesaikan (jawaban dikunci, kunci dibuka) lalu bagian berikutnya mulai. Tanpa pembagian bagian, timer berlaku untuk seluruh sesi.
   - **Bantuan diskusi** (panel di atas soal, setelah satu bagian selesai): daftar soal bagian itu dengan persentase benar, jawaban sendiri, dan tombol ✋ "mau dibahas". Urutan bawaan **berurutan (nomor)**; bisa diganti **paling banyak salah dulu**, dan ada kotak **sembunyikan soal yang semua pesertanya benar** (berlaku bila minimal 2 peserta selesai). Admin bisa **Sorot** satu soal (layar semua peserta ikut pindah, bisa dimatikan lewat "Ikuti sorotan admin"; nomor dan bilah sorotan tetap terlihat walau navigasi disembunyikan) dan membuka **Suara ulang**: peserta yang sudah menyelesaikan bagiannya memilih jawaban lagi (rahasia, kunci disembunyikan di layar), lalu admin menutupnya dan hasil tampil di semua layar (jawaban awal vs sesudah diskusi, berapa yang berpindah ke benar). Catatan jujur: kunci sudah pernah terlihat peserta saat menyelesaikan bagian, jadi suara ulang mengandalkan kejujuran. Saat memulai diskusi admin memilih target durasi; semua melihat hitung mundur dan alarm.
   - **Pembahasan kelompok**: **satu teks bersama** yang bisa ditulis/diubah semua peserta setelah kunci soal terbuka (tombol Tulis/Ubah di bawah soal dan di Tinjau), boleh memuat sampai 4 gambar (tempel dengan Ctrl+V / Cmd+V). Pengecekan versi mencegah saling menimpa; hanya admin yang boleh mengosongkannya. Tampil di soal, di Tinjau, dan di sesi/latihan berikutnya. **Catatan pribadi** tetap hanya untuk diri sendiri.
   - **Menyembunyikan**: daftar nomor, bilah kendali admin, dan panel diskusi masing-masing punya tombol Sembunyikan/Tampilkan; pilihan diingat di perangkat.
   - **Kendali di layar ujian**: admin yang ikut mengerjakan punya tombol mulai/selesai diskusi dan buka bagian langsung di layar ujian. Semua peserta melihat status bagian dan berapa teman yang sudah selesai.
   - **Per bagian (mis. per 20)**: pilih *Langsung lanjut* atau *Terkunci sampai admin membuka*. Pada mode terkunci, isi soal bagian lain tidak dikirim ke peserta.
   - **Diskusi**: di daftar sesi klik *Peserta dan diskusi*. *Mulai diskusi* menghentikan waktu semua peserta dan membekukan jawaban; *Selesai diskusi dan buka bagian berikutnya* menjalankan waktu lagi dan membuka bagian baru.
   - **Mode ketat**: peserta ujian layar penuh; pindah tab/aplikasi, keluar layar penuh, tombol **Kembali / geser dua jari / ubah alamat** (ditolak dan dicatat), muat ulang halaman, membuka akun yang sama di tab/perangkat lain (hanya satu klien aktif), "senyap" (tidak ada detak ke server), cetak (diblokir), dan perkiraan developer tools dicatat dan terlihat admin. Pencatatan dihentikan saat diskusi. Tidak ada sistem berbasis browser yang bisa mencegah HP/komputer lain, layar kedua, tangkapan layar, atau bantuan orang lain; untuk ujian berisiko tinggi pakai Safe Exam Browser.
   - Admin yang ikut mengerjakan sebuah sesi baru bisa melihat rekap bagian yang sudah ia selesaikan sendiri (menutup celah mengintip).
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
