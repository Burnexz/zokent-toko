# Zokent Toko

Satu repo, tiga bagian, satu database Supabase.

```
login.html            masuk owner / kasir (diarahkan sesuai peran)
toko/index.html       toko online untuk pelanggan
admin/index.html      dasbor owner
kasir/index.html      kasir POS
js/                   modul bersama (koneksi Supabase, login, helper)
supabase/schema.sql   tabel, keamanan (RLS), dan fungsi transaksi
```

## Setup (sekali saja)

1. **Buat proyek Supabase baru**, lalu buka *SQL Editor > New query*, tempel isi `supabase/schema.sql`, klik *Run*.
2. **Matikan pendaftaran mandiri:** *Authentication > Sign In / Providers > Email*, matikan *Allow new users to sign up*.
3. **Buat akun owner:** *Authentication > Users > Add user*, isi email dan password (centang *Auto Confirm User*).
4. **Jadikan akun itu owner.** Di SQL Editor jalankan (ganti emailnya):

   ```sql
   update public.profiles
   set role = 'owner', is_active = true, full_name = 'Nur Rohman'
   where id = (select id from auth.users where email = 'EMAIL-OWNER@contoh.com');
   ```

5. **Isi kunci proyek** di `js/supabase-client.js` (`SUPABASE_URL` dan `SUPABASE_ANON_KEY`, dari *Project Settings > API Keys*). Hanya publishable/anon key, bukan service_role.
6. **Upload ke GitHub**, lalu aktifkan *Settings > Pages > Deploy from a branch > main / root*.

## Akun kasir

Buat lewat *Authentication > Users > Add user*. Akun baru otomatis berstatus **nonaktif**; owner mengaktifkannya dari dasbor admin.

## Keamanan

- Pengunjung hanya bisa membaca katalog (tanpa harga beli) dan mengirim pesanan lewat fungsi `create_online_order`.
- Harga dan stok selalu dihitung di database, bukan dari browser.
- Penjualan kasir lewat `create_pos_sale` (atomik: transaksi + pengurangan stok sekaligus).
- Hanya owner yang boleh mengubah produk, stok, status pesanan, dan akun.
