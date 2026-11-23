// Keeps an open tab on the latest version of the site.
// Browsers already re-check every page, script and style on each visit (.htaccess: Cache-Control no-cache).
// This covers a tab that stays open, like a phone that brings back yesterday's tab: when the tab comes back
// into view, it asks the server whether this page or its scripts changed since the tab loaded them. If they
// did, the tab reloads itself, unless something has been typed on the page; then it offers a "Muat ulang" bar
// so nothing typed is lost. The cart, account and orders are kept in the browser, so a reload loses none of them.
(() => {
  const own = (src) => { try { const u = new URL(src, location.href); return u.origin === location.origin && /\.js$/.test(u.pathname) && !/\/vendor\//.test(u.pathname) ? u.pathname : null; } catch { return null; } };
  const files = [location.pathname, ...[...document.scripts].map((s) => own(s.src)).filter(Boolean)];
  const stamp = async (f) => {
    try {
      const r = await fetch(f, { method: "HEAD", cache: "no-store" });
      return r.ok ? r.headers.get("etag") || r.headers.get("last-modified") || null : null;
    } catch { return null; }   // offline: try again next time
  };
  const seen = {};
  let typed = false, shown = false, checking = false, hiddenAt = 0;
  document.addEventListener("input", (e) => { if (e.isTrusted) typed = true; }, true);

  async function remember() { for (const f of files) seen[f] = await stamp(f); }
  async function check() {
    if (checking || shown) return;
    checking = true;
    try {
      for (const f of files) {
        const now = await stamp(f);
        if (now && seen[f] && now !== seen[f]) return update();
        if (now && !seen[f]) seen[f] = now;
      }
    } finally { checking = false; }
  }
  function update() {
    if (!typed && !document.querySelector("[aria-busy=true]")) { location.reload(); return; }
    shown = true;
    const bar = document.createElement("div");
    bar.setAttribute("role", "status");
    bar.style.cssText = "position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:10000;display:flex;gap:12px;align-items:center;" +
      "background:#3B2218;color:#fff;font:600 14px/1.3 system-ui,sans-serif;padding:10px 12px 10px 16px;border-radius:12px;box-shadow:0 8px 24px rgba(0,0,0,.25);max-width:calc(100% - 32px)";
    bar.innerHTML = '<span>Ada versi baru dari halaman ini.</span><button type="button" style="font:inherit;border:0;border-radius:8px;padding:8px 12px;background:#B8325A;color:#fff;cursor:pointer">Muat ulang</button>';
    bar.querySelector("button").addEventListener("click", () => location.reload());
    document.body.appendChild(bar);
  }

  remember();
  // back to the tab after a while, or the browser restored the page from memory
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { hiddenAt = Date.now(); return; }
    if (Date.now() - hiddenAt > 30000) check();
  });
  addEventListener("pageshow", (e) => { if (e.persisted) check(); });
  // a tab left open in view (a shop counter screen): look every 15 minutes
  setInterval(() => { if (!document.hidden) check(); }, 15 * 60 * 1000);
})();
