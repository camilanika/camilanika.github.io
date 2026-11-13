// Opening hours on every page come from Admin → Toko (shop_status), so the FAQ, footers and policies
// always match the real schedule. The HTML keeps the hours as a fallback for when this can't load.
(() => {
  const C = window.CN_CONFIG;
  const els = document.querySelectorAll("[data-shop-hours]");
  if (!C || !els.length) return;
  fetch(C.SUPABASE_URL + "/rest/v1/rpc/shop_status", {
    method: "POST",
    headers: { apikey: C.SUPABASE_ANON_KEY, Authorization: "Bearer " + C.SUPABASE_ANON_KEY, "Content-Type": "application/json" },
    body: "{}",
  })
    .then((r) => (r.ok ? r.json() : null))
    .then((s) => {
      if (!s || !s.schedule_enabled || !s.open_time || s.open_time === s.close_time) return;
      const f = (t) => t.replace(":", ".");
      els.forEach((e) => (e.textContent = `${f(s.open_time)}–${f(s.close_time)}`));
    })
    .catch(() => {});
})();
