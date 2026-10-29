// CamilaNika admin · Cashflow Summary helpers with no DOM or network access,
// so they can be unit-tested in Node (tests/unit/cashflow-core.test.js).
// The database (supabase/migrations/014_cashflow.sql) is the source of truth for every total;
// the calculations here are only previews shown while a form is being filled in.
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.CNCashflowCore = api;
})(typeof self !== "undefined" ? self : this, function () {
  const TZ = "Asia/Jakarta";

  // ------------------------------------------------------------ dates (WIB calendar days, "YYYY-MM-DD")
  const ymdFmt = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" });
  const jakartaDate = (d = new Date()) => ymdFmt.format(d);
  const parseYmd = (s) => { const [y, m, d] = String(s).split("-").map(Number); return new Date(Date.UTC(y, m - 1, d)); };
  const toYmd = (dt) => dt.toISOString().slice(0, 10);
  const isYmd = (s) => /^\d{4}-\d{2}-\d{2}$/.test(String(s)) && toYmd(parseYmd(s)) === s;
  const addDays = (s, n) => { const d = parseYmd(s); d.setUTCDate(d.getUTCDate() + n); return toYmd(d); };

  const PRESETS = { today: "Hari ini", yesterday: "Kemarin", week: "Minggu ini", month: "Bulan ini", year: "Tahun ini", custom: "Pilih tanggal" };

  // Weeks start on Monday (Senin). Every preset ends today, so "this month" means month-to-date.
  function presetRange(preset, now = new Date(), custom = {}) {
    const today = jakartaDate(now);
    switch (preset) {
      case "today": return { from: today, to: today };
      case "yesterday": { const y = addDays(today, -1); return { from: y, to: y }; }
      case "week": { const dow = (parseYmd(today).getUTCDay() + 6) % 7; return { from: addDays(today, -dow), to: today }; }
      case "month": return { from: today.slice(0, 8) + "01", to: today };
      case "year": return { from: today.slice(0, 5) + "01-01", to: today };
      case "custom": return { from: custom.from || today, to: custom.to || custom.from || today };
      default: throw new Error("UNKNOWN_PRESET");
    }
  }
  function validateRange(r) {
    if (!r || !isYmd(r.from) || !isYmd(r.to)) return "Tanggal belum lengkap.";
    if (r.to < r.from) return "Tanggal akhir harus sama dengan atau setelah tanggal awal.";
    if ((parseYmd(r.to) - parseYmd(r.from)) / 864e5 > 3700) return "Rentang tanggal terlalu panjang (maks. 10 tahun).";
    return null;
  }
  const MONTHS = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"];
  const dayLabel = (s) => { const d = parseYmd(s); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`; };
  const rangeLabel = (r) => (r.from === r.to ? dayLabel(r.from) : `${dayLabel(r.from)} – ${dayLabel(r.to)}`);

  // <input type="datetime-local"> value (read as WIB) <-> ISO timestamp with +07:00
  const wibInputToIso = (v) => (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v || "") ? `${v}:00+07:00` : null);
  const isoToWibInput = (iso) => {
    const d = new Date(iso); if (isNaN(d)) return "";
    const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
      .formatToParts(d).map((x) => [x.type, x.value]));
    return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
  };
  const nowWibInput = (now = new Date()) => isoToWibInput(now.toISOString());
  const fmtWib = (iso) => iso ? new Date(iso).toLocaleString("id-ID", { timeZone: TZ, dateStyle: "medium", timeStyle: "short" }) + " WIB" : "–";

  // ------------------------------------------------------------ money (whole Rupiah)
  const formatRp = (n) => {
    if (n == null || n === "" || !isFinite(n)) return "–";
    const v = Math.round(Number(n));
    return (v < 0 ? "−Rp" : "Rp") + Math.abs(v).toLocaleString("id-ID");
  };
  // Accepts "12500", "12.500", "Rp 12.500". Rejects decimals ("12,5"), negatives and text: returns NaN.
  function parseRupiah(input) {
    if (typeof input === "number") return Number.isInteger(input) && input >= 0 ? input : NaN;
    const s = String(input ?? "").replace(/^\s*rp\.?\s*/i, "").replace(/\s+/g, "");
    if (s === "") return NaN;
    if (/^\d+$/.test(s)) return Number(s);
    if (/^\d{1,3}(\.\d{3})+$/.test(s)) return Number(s.replace(/\./g, ""));
    return NaN;
  }
  const MAX_AMOUNT = 1000000000;

  // ------------------------------------------------------------ labels
  const SOURCE = { walk_in: "Walk-in", whatsapp: "WhatsApp", phone: "Telepon", social_media: "Media sosial", other: "Lainnya" };
  const PAYMENT = { cash: "Tunai", bank_transfer: "Transfer bank", qris: "QRIS / e-wallet", card: "Kartu", other: "Lainnya" };
  const TX_SOURCE = { system_real: "Pesanan online", offline: "Penjualan offline", expense: "Pengeluaran" };
  const CLASS = { real: "Real", mock: "Mock (tes)" };
  const paymentLabel = (group, raw) => {
    if (raw && !(raw in PAYMENT)) return `${PAYMENT[group] || "Lainnya"} (${raw.replace(/_/g, " ")})`;
    return PAYMENT[group] || PAYMENT[raw] || "Lainnya";
  };

  // ------------------------------------------------------------ offline order preview (server recalculates)
  function offlinePreview(items, orderDiscount, extraCharge) {
    const errors = [];
    let subtotal = 0, itemDiscount = 0;
    const lines = (items || []).map((it, i) => {
      const q = Number(it.quantity), price = parseRupiah(it.unit_price), disc = it.discount === "" || it.discount == null ? 0 : parseRupiah(it.discount);
      const row = i + 1;
      if (!it.variant_id && !it.product_id && !String(it.product_name || "").trim()) errors.push(`Baris ${row}: pilih menu atau isi nama item.`);
      if (!Number.isInteger(q) || q < 1 || q > 10000) errors.push(`Baris ${row}: jumlah harus angka bulat 1–10.000.`);
      if (!Number.isInteger(price) || price > 100000000) errors.push(`Baris ${row}: harga tidak valid.`);
      if (!Number.isInteger(disc)) errors.push(`Baris ${row}: diskon tidak valid.`);
      const gross = Number.isInteger(q) && Number.isInteger(price) ? q * price : 0;
      if (Number.isInteger(disc) && disc > gross) errors.push(`Baris ${row}: diskon lebih besar dari harga.`);
      const line = Number.isInteger(disc) ? gross - disc : gross;
      subtotal += gross; itemDiscount += Number.isInteger(disc) ? disc : 0;
      return { gross, discount: Number.isInteger(disc) ? disc : 0, line_total: line };
    });
    if (!lines.length) errors.push("Tambahkan minimal satu item.");
    const od = orderDiscount === "" || orderDiscount == null ? 0 : parseRupiah(orderDiscount);
    const ex = extraCharge === "" || extraCharge == null ? 0 : parseRupiah(extraCharge);
    if (!Number.isInteger(od)) errors.push("Diskon pesanan tidak valid.");
    if (!Number.isInteger(ex)) errors.push("Biaya tambahan tidak valid.");
    if (Number.isInteger(od) && od > subtotal - itemDiscount) errors.push("Diskon pesanan lebih besar dari subtotal.");
    const total = subtotal - itemDiscount - (Number.isInteger(od) ? od : 0) + (Number.isInteger(ex) ? ex : 0);
    if (total > MAX_AMOUNT) errors.push("Total terlalu besar.");
    return { lines, subtotal, itemDiscount, orderDiscount: Number.isInteger(od) ? od : 0, extraCharge: Number.isInteger(ex) ? ex : 0, total, errors };
  }

  function validateOfflineHeader(f) {
    const errors = [];
    if (!wibInputToIso(f.order_date)) errors.push("Tanggal & jam pesanan wajib diisi.");
    if (!(f.source in SOURCE)) errors.push("Pilih sumber pesanan.");
    if (!["cash", "bank_transfer", "qris", "other"].includes(f.payment_method)) errors.push("Pilih metode pembayaran.");
    if (!(f.classification in CLASS)) errors.push("Pilih klasifikasi.");
    if (f.entry_mode === "amount") {
      const a = parseRupiah(f.amount);
      if (!Number.isInteger(a) || a <= 0) errors.push("Nominal harus angka lebih dari 0.");
      else if (a > MAX_AMOUNT) errors.push("Nominal terlalu besar.");
    }
    return errors;
  }

  function validateExpense(f) {
    const errors = {};
    if (!wibInputToIso(f.expense_date)) errors.expense_date = "Tanggal & jam wajib diisi.";
    if (!String(f.description || "").trim()) errors.description = "Keterangan wajib diisi.";
    else if (String(f.description).trim().length > 200) errors.description = "Keterangan maksimal 200 karakter.";
    if (!f.category_id) errors.category_id = "Pilih kategori.";
    const a = parseRupiah(f.amount);
    if (!Number.isInteger(a) || a <= 0) errors.amount = "Jumlah harus angka lebih dari 0 (tanpa desimal).";
    else if (a > MAX_AMOUNT) errors.amount = "Jumlah terlalu besar.";
    if (!["cash", "bank_transfer", "qris", "other"].includes(f.payment_method)) errors.payment_method = "Pilih metode pembayaran.";
    return errors;
  }

  // ------------------------------------------------------------ server error codes -> messages
  const ERRORS = {
    NOT_ADMIN: "Hanya admin yang boleh melakukan ini.",
    STALE_RECORD: "Data ini baru saja diubah (mungkin di perangkat lain). Muat ulang lalu coba lagi.",
    RECORD_NOT_FOUND: "Data tidak ditemukan. Mungkin sudah dihapus.",
    TOTAL_MISMATCH: "Total yang dihitung server berbeda dari yang tampil. Periksa lagi harga & diskon.",
    REF_IS_ONLINE_ORDER: "Nomor ini milik pesanan online. Pesanan online sudah tercatat otomatis, jadi jangan dicatat lagi sebagai offline.",
    DUPLICATE_REF: "No. nota ini sudah dipakai penjualan offline lain.",
    DUPLICATE_NAME: "Nama kategori sudah ada.",
    AMOUNT_MUST_BE_POSITIVE: "Jumlah harus lebih dari 0.",
    INVALID_NUMBER: "Ada angka yang tidak valid (gunakan angka bulat tanpa desimal).",
    NUMBER_TOO_LARGE: "Angka terlalu besar.",
    AMOUNT_TOO_LARGE: "Jumlah terlalu besar.",
    TOTAL_TOO_LARGE: "Total terlalu besar.",
    DATE_IN_FUTURE: "Tanggal tidak boleh di masa depan.",
    DATE_REQUIRED: "Tanggal wajib diisi.",
    INVALID_DATE: "Tanggal tidak valid.",
    DATE_RANGE_INVALID: "Tanggal akhir harus setelah tanggal awal.",
    ITEMS_REQUIRED: "Tambahkan minimal satu item.",
    INVALID_QUANTITY: "Jumlah item tidak valid.",
    INVALID_PRICE: "Harga tidak valid.",
    INVALID_ITEM_DISCOUNT: "Diskon item tidak boleh lebih besar dari harga.",
    ORDER_DISCOUNT_TOO_LARGE: "Diskon pesanan lebih besar dari subtotal.",
    VARIANT_NOT_FOUND: "Varian menu tidak ditemukan (mungkin sudah dihapus).",
    PRODUCT_NOT_FOUND: "Menu tidak ditemukan (mungkin sudah dihapus).",
    CATEGORY_REQUIRED: "Pilih kategori.",
    CATEGORY_INACTIVE: "Kategori ini disembunyikan. Pilih kategori lain.",
    DESCRIPTION_REQUIRED: "Keterangan wajib diisi.",
    INVALID_PAYMENT_METHOD: "Pilih metode pembayaran.",
  };
  function errorText(e) {
    const msg = (e && (e.message || e.details)) || String(e || "");
    const code = (msg.match(/[A-Z][A-Z_]{4,}/) || [])[0];
    if (code && ERRORS[code]) return ERRORS[code];
    if (/failed to fetch|network/i.test(msg)) return "Koneksi terputus. Periksa internet lalu coba lagi.";
    return msg || "Terjadi kesalahan.";
  }

  const newToken = () => (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID()
    : "10000000-1000-4000-8000-100000000000".replace(/[018]/g, (c) => (c ^ (Math.random() * 16) >> (c / 4)).toString(16)));

  return { TZ, PRESETS, jakartaDate, addDays, isYmd, presetRange, validateRange, rangeLabel, dayLabel,
    wibInputToIso, isoToWibInput, nowWibInput, fmtWib, formatRp, parseRupiah, MAX_AMOUNT,
    SOURCE, PAYMENT, TX_SOURCE, CLASS, paymentLabel, offlinePreview, validateOfflineHeader, validateExpense,
    ERRORS, errorText, newToken };
});
