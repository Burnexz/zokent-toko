// js/util.js
// Helper umum: format rupiah, escape HTML (cegah XSS), tanggal, toast, dan terjemah error.

const formatRupiah = new Intl.NumberFormat('id-ID', {
  style: 'currency',
  currency: 'IDR',
  maximumFractionDigits: 0,
});

/** 15000 -> "Rp 15.000" */
export function rupiah(angka) {
  return formatRupiah.format(Number(angka) || 0);
}

/** Escape teks dari database sebelum dimasukkan ke innerHTML. */
export function esc(teks) {
  return String(teks ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

/** Tanggal/jam lokal, contoh: "22 Nov 2026, 06.15" */
export function tanggalLokal(iso) {
  try {
    return new Date(iso).toLocaleString('id-ID', { dateStyle: 'medium', timeStyle: 'short' });
  } catch {
    return '';
  }
}

/** Toast sederhana. jenis: 'info' | 'sukses' | 'error' */
export function toast(pesan, jenis = 'info') {
  try {
    let wadah = document.getElementById('toast-wadah');
    if (!wadah) {
      wadah = document.createElement('div');
      wadah.id = 'toast-wadah';
      wadah.className = 'fixed top-4 inset-x-0 z-50 flex flex-col items-center gap-2 px-4 pointer-events-none';
      document.body.appendChild(wadah);
    }
    const warna = { info: 'bg-slate-800', sukses: 'bg-green-600', error: 'bg-red-600' }[jenis] || 'bg-slate-800';
    const el = document.createElement('div');
    el.className = `${warna} text-white text-sm px-4 py-3 rounded-lg shadow-lg max-w-sm w-full text-center`;
    el.textContent = pesan;
    wadah.appendChild(el);
    setTimeout(() => el.remove(), 3500);
  } catch (err) {
    console.error('toast gagal:', err);
    alert(pesan);
  }
}

/**
 * Ubah error Supabase menjadi pesan yang bisa dibaca pengguna.
 * Pesan dari fungsi database (raise exception) sudah berbahasa Indonesia, jadi dipakai langsung.
 */
export function pesanError(error, cadangan = 'Terjadi kesalahan. Coba lagi.') {
  if (!error) return cadangan;
  const pesan = String(error.message || '');
  if (/Failed to fetch|NetworkError|network/i.test(pesan)) return 'Tidak bisa terhubung. Cek koneksi internet.';
  if (/row-level security|permission denied/i.test(pesan)) return 'Anda tidak punya izin untuk aksi ini.';
  if (/duplicate key/i.test(pesan)) return 'Data dengan nilai yang sama sudah ada.';
  if (error.code && /^P0001$/.test(error.code)) return pesan; // raise exception dari fungsi database
  return pesan || cadangan;
}
