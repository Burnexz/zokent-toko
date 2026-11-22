// js/supabase-client.js
// Koneksi Supabase + helper login/peran. Dipakai oleh toko, admin, dan kasir.
// PENTING: hanya anon/publishable key di sini. JANGAN PERNAH memasang service_role key.

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

// === ISI DENGAN DATA PROYEK BARU ANDA (Supabase > Project Settings > API Keys) ===
const SUPABASE_URL = 'https://xunfvbrqbrxwdxmcelyh.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_GAhWSccyXR_Q8vy89NIgRw_pxlzR6uY';
// ==================================================================================

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true },
});

// Alamat halaman dihitung dari lokasi file ini, jadi aman dipakai dari folder mana pun
// dan di subpath GitHub Pages (misalnya /nama-repo/).
const URL_LOGIN = new URL('../login.html', import.meta.url).href;
const URL_ADMIN = new URL('../admin/index.html', import.meta.url).href;
const URL_KASIR = new URL('../kasir/index.html', import.meta.url).href;

/** Halaman tujuan setelah login, sesuai peran. */
export function halamanUntukPeran(role) {
  return role === 'owner' ? URL_ADMIN : URL_KASIR;
}

/** Ambil sesi login saat ini (atau null). */
export async function getSesi() {
  try {
    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;
    return data.session;
  } catch (err) {
    console.error('getSesi gagal:', err);
    return null;
  }
}

/** Ambil profil user: { full_name, role, is_active } atau null. */
export async function getProfil(userId) {
  try {
    const { data, error } = await supabase
      .from('profiles')
      .select('full_name, role, is_active')
      .eq('id', userId)
      .maybeSingle();
    if (error) throw error;
    return data;
  } catch (err) {
    console.error('getProfil gagal:', err);
    return null;
  }
}

/** Login email + password. Mengembalikan { ok, profil, pesan }. */
export async function login(email, password) {
  try {
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) return { ok: false, pesan: 'Email atau password salah.' };

    const profil = await getProfil(data.user.id);
    if (!profil) {
      await supabase.auth.signOut();
      return { ok: false, pesan: 'Profil akun tidak ditemukan. Hubungi owner.' };
    }
    if (!profil.is_active) {
      await supabase.auth.signOut();
      return { ok: false, pesan: 'Akun belum diaktifkan oleh owner.' };
    }
    return { ok: true, profil };
  } catch (err) {
    console.error('login gagal:', err);
    return { ok: false, pesan: 'Tidak bisa terhubung. Cek koneksi internet.' };
  }
}

export async function logout() {
  try {
    await supabase.auth.signOut();
  } catch (err) {
    console.error('logout gagal:', err);
  } finally {
    window.location.href = URL_LOGIN;
  }
}

/**
 * Pasang di bagian atas halaman yang butuh login.
 *   const { sesi, profil } = await wajibLogin(['owner']);          // admin
 *   const { sesi, profil } = await wajibLogin(['owner', 'cashier']); // kasir
 * Jika belum login, akun nonaktif, atau peran tidak cocok, halaman dialihkan
 * dan fungsi ini tidak pernah selesai (kode halaman setelahnya tidak jalan).
 * Catatan: ini hanya kenyamanan tampilan. Keamanan sebenarnya ada di RLS dan fungsi database.
 */
export async function wajibLogin(peranDiizinkan = ['owner', 'cashier']) {
  const sesi = await getSesi();
  if (!sesi) {
    window.location.replace(URL_LOGIN);
    return new Promise(() => {});
  }
  const profil = await getProfil(sesi.user.id);
  if (!profil || !profil.is_active || !peranDiizinkan.includes(profil.role)) {
    const tujuan = profil && profil.is_active ? halamanUntukPeran(profil.role) : URL_LOGIN;
    window.location.replace(tujuan);
    return new Promise(() => {});
  }
  return { sesi, profil };
}
