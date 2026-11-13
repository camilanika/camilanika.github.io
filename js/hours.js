// Opening hours on every page come from Admin → Toko (shop_status), so the FAQ, footers and policies
// always match the real schedule. The HTML keeps a text as a fallback for when this can't load.
//   <span data-shop-hours>            → "Buka setiap hari · 10.00–20.00 WIB", "Buka Senin–Sabtu · 10.00–20.00 WIB", "Buka setiap hari"
//   <span data-shop-hours="text">     → "setiap hari pukul 10.00–20.00 WIB", "Senin–Sabtu pukul …", "setiap hari" (inside a sentence)
//   <span data-shop-hours="text-cap"> → the same, starting with a capital letter
// Without a schedule (Admin → Toko, "Buka & tutup otomatis" off) the shop is open every day, so no hours are shown.
(() => {
  const DAYS = ["", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"];
  // [1..7] → "setiap hari", "Senin–Jumat", "Sabtu dan Minggu", "Senin, Rabu dan Jumat"
  function days(list) {
    const d = [...new Set((list || []).map(Number).filter((x) => x >= 1 && x <= 7))].sort((a, b) => a - b);
    if (!d.length || d.length === 7) return "setiap hari";
    // a run of 3+ days in a row, also across Sunday → Monday (e.g. Jumat–Senin)
    const has = (x) => d.includes(((x - 1 + 7) % 7) + 1);
    const start = d.find((x) => !has(x - 1));
    let len = 0; while (len < 7 && has(start + len)) len++;
    if (start && len === d.length && len >= 3) return `${DAYS[start]}–${DAYS[((start + len - 2) % 7) + 1]}`;
    const names = d.map((x) => DAYS[x]);
    return names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} dan ${names.at(-1)}`;
  }
  const t = (x) => String(x || "").replace(":", ".");
  function format(s, kind = "") {
    if (!s) return null;
    const when = s.schedule_enabled ? days(s.open_days) : "setiap hari";
    const hours = !s.schedule_enabled ? "" : s.open_time === s.close_time ? "24 jam" : `${t(s.open_time)}–${t(s.close_time)} WIB`;
    if (kind.startsWith("text")) {
      const out = hours ? (hours === "24 jam" ? `${when}, 24 jam` : `${when} pukul ${hours}`) : when;
      return kind === "text-cap" ? out.charAt(0).toUpperCase() + out.slice(1) : out;
    }
    return `Buka ${when}${hours ? " · " + hours : ""}`;
  }
  window.CN_HOURS = { days, format };

  const C = window.CN_CONFIG;
  const els = document.querySelectorAll("[data-shop-hours]");
  if (!C || !els.length) return;
  fetch(C.SUPABASE_URL + "/rest/v1/rpc/shop_status", {
    method: "POST",
    headers: { apikey: C.SUPABASE_ANON_KEY, Authorization: "Bearer " + C.SUPABASE_ANON_KEY, "Content-Type": "application/json" },
    body: "{}",
  })
    .then((r) => (r.ok ? r.json() : null))
    .then((s) => { if (s) els.forEach((e) => (e.textContent = format(s, e.dataset.shopHours || ""))); })
    .catch(() => {});
})();
