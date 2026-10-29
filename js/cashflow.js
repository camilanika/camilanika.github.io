// CamilaNika admin · Cashflow Summary page (admin.html#cashflow)
// Every number on this page comes from the database functions in supabase/migrations/014_cashflow.sql.
// The browser only shows them, collects input and previews form totals; the server validates and recalculates.
(function () {
  const C = window.CNCashflowCore;
  const { formatRp: rp, fmtWib } = C;
  const SUBS = { transactions: "Transaksi", orders: "Pesanan selesai", offline: "Penjualan offline", expenses: "Pengeluaran", menu: "Penjualan menu", settings: "Pengaturan" };
  const PAGE_SIZE = 25;

  let X;                 // admin helpers, set by render()
  let sub = "transactions";
  let preset = "month", custom = {};
  let range = C.presetRange("month");
  let summary = null, categories = null, catalog = null;
  const filters = { transactions: {}, orders: {}, offline: {}, expenses: {} };
  const pages = { transactions: 1, orders: 1, offline: 1, expenses: 1 };
  const menuOpts = { group: "product", sort: "quantity", section: "", q: "" };
  let menuData = null;
  let loadSeq = 0;

  const esc = (s) => X.esc(s);
  const $ = (id) => document.getElementById(id);
  const rpc = async (fn, args) => { const { data, error } = await X.sb.rpc(fn, args); if (error) throw error; return data; };
  // compact date for tables: "29 Okt 09.41" (year shown when it isn't this year)
  const shortWib = (iso) => {
    if (!iso) return "–";
    const d = new Date(iso), y = new Intl.DateTimeFormat("en", { timeZone: C.TZ, year: "numeric" });
    return d.toLocaleString("id-ID", { timeZone: C.TZ, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit",
      ...(y.format(d) !== y.format(new Date()) ? { year: "numeric" } : {}) });
  };
  const typeBadge = (t) => (t === "income" ? `<span class="badge cf-in">Pemasukan</span>` : `<span class="badge cf-out">Pengeluaran</span>`);

  // ---------------------------------------------------------------- page
  async function render(admin, wantedSub) {
    X = admin;
    if (wantedSub && SUBS[wantedSub]) sub = wantedSub;
    X.app.innerHTML = `
      <div class="bar"><h2>Cashflow Summary</h2>
        <button class="btn btn-rose" id="cf-add-off">+ Penjualan offline</button>
        <button class="btn btn-rose" id="cf-add-exp">+ Pengeluaran</button>
        <button class="btn btn-ghost" id="cf-ref">Muat ulang</button></div>
      <div class="card cf-dates" role="group" aria-label="Periode">
        <div class="cf-chips" id="cf-presets">${Object.entries(C.PRESETS).map(([k, v]) => `<button type="button" data-p="${k}" aria-pressed="${k === preset}">${v}</button>`).join("")}</div>
        <div class="cf-custom" id="cf-custom" ${preset === "custom" ? "" : "hidden"}>
          <label class="f">Dari<input type="date" id="cf-from"></label><label class="f">Sampai<input type="date" id="cf-to"></label>
          <button class="btn btn-ghost btn-sm" id="cf-apply">Terapkan</button></div>
        <div class="muted cf-range" id="cf-range" aria-live="polite"></div>
      </div>
      <div id="cf-banners"></div>
      <section aria-label="Ringkasan" class="cf-cards" id="cf-cards">${cardsSkeleton()}</section>
      <nav class="subtabs" id="cf-subs" aria-label="Bagian Cashflow">${Object.entries(SUBS).map(([k, v]) => `<button type="button" data-s="${k}" aria-pressed="${k === sub}">${v}</button>`).join("")}</nav>
      <div id="cf-body"></div>`;
    $("cf-add-off").onclick = () => offlineForm();
    $("cf-add-exp").onclick = () => expenseForm();
    $("cf-ref").onclick = () => reloadAll();
    $("cf-presets").onclick = (e) => {
      const b = e.target.closest("[data-p]"); if (!b) return;
      preset = b.dataset.p;
      $("cf-presets").querySelectorAll("[data-p]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      $("cf-custom").hidden = preset !== "custom";
      if (preset === "custom") { $("cf-from").value = custom.from || range.from; $("cf-to").value = custom.to || range.to; $("cf-from").focus(); return; }
      range = C.presetRange(preset); resetPages(); reloadAll();
    };
    $("cf-apply").onclick = () => {
      const r = { from: $("cf-from").value, to: $("cf-to").value };
      const bad = C.validateRange(r);
      if (bad) { X.toast(bad); return; }
      custom = r; range = C.presetRange("custom", new Date(), custom); resetPages(); reloadAll();
    };
    $("cf-subs").onclick = (e) => {
      const b = e.target.closest("[data-s]"); if (!b) return;
      sub = b.dataset.s; syncHash();
      $("cf-subs").querySelectorAll("[data-s]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      drawSub();
    };
    syncHash();
    await reloadAll();
    // completed orders show up without a manual refresh
    X.setRefresh(() => { if (!document.hidden && $("modal").hidden) reloadAll(true); }, 60000);
  }
  function syncHash() {
    const h = "#cashflow/" + sub;
    if (location.hash !== h) history.replaceState(null, "", h);
    window.CN_CASHFLOW.sub = sub;
  }
  const resetPages = () => Object.keys(pages).forEach((k) => (pages[k] = 1));

  async function reloadAll(quiet) {
    $("cf-range").textContent = `Periode: ${C.rangeLabel(range)} (WIB)`;
    await Promise.all([loadSummary(quiet), drawSub(quiet)]);
  }

  // ---------------------------------------------------------------- 1. summary cards
  function cardsSkeleton() { return Array.from({ length: 7 }, () => `<div class="card cf-card"><div class="muted">Memuat…</div></div>`).join(""); }
  async function loadSummary(quiet) {
    const seq = ++loadSeq;
    if (!quiet) $("cf-cards").setAttribute("aria-busy", "true");
    try {
      const s = await rpc("cashflow_summary", { p_from: range.from, p_to: range.to });
      if (seq !== loadSeq || !$("cf-cards")) return;
      summary = s;
      const card = (label, value, hint, cls = "") => `<div class="card cf-card ${cls}"><div class="cf-lbl">${label}</div><div class="cf-val">${value}</div>${hint ? `<div class="cf-hint">${hint}</div>` : ""}</div>`;
      $("cf-cards").innerHTML = [
        card("Real Order Income", rp(s.real_order_income), `${s.completed_real_orders} pesanan online selesai`),
        card("Offline Order Income", rp(s.offline_order_income), `${s.offline_real_orders} penjualan offline${s.amount_only_orders ? ` · ${s.amount_only_orders} nominal saja` : ""}`),
        card("Total Income", rp(s.total_income), "Pesanan online + penjualan offline", "cf-strong"),
        card("Total Expenses", rp(s.total_expenses), `${s.expense_count} pengeluaran`),
        card("Net Cashflow", rp(s.net_cashflow), "Pemasukan − pengeluaran tercatat. Bukan laba akuntansi.", s.net_cashflow < 0 ? "cf-neg cf-strong" : "cf-pos cf-strong"),
        card("Completed Real Orders", String(s.completed_real_orders), "Pesanan online berstatus Selesai"),
        card("Total Items Sold", Number(s.total_items_sold).toLocaleString("id-ID"), "Dari pesanan dengan rincian item"),
      ].join("");
      const banners = [];
      if (s.payments_mode === "sandbox") banners.push(`<div class="cf-note warn">Pembayaran online masih <b>Sandbox (tes)</b>: pesanan online baru dianggap <b>tes</b> dan tidak ditampilkan di sini. Ganti ke Production di <a href="#cashflow/settings" data-go="settings">Pengaturan</a> saat Midtrans sudah live.</div>`);
      if (s.orders_to_review > 0) banners.push(`<div class="cf-note">${s.orders_to_review} pesanan selesai di periode ini <b>perlu ditinjau</b>: pastikan itu pembelian asli. <a href="#cashflow/orders" data-go="orders" data-review="1">Tinjau sekarang</a></div>`);
      if (s.unpaid_offline_orders > 0) banners.push(`<div class="cf-note warn">${s.unpaid_offline_orders} penjualan offline <b>belum dibayar</b> (${rp(s.unpaid_offline_value)}), belum dihitung sebagai pemasukan. <a href="#cashflow/offline" data-go="offline" data-unpaid="1">Lihat</a></div>`);
      if (s.estimated_completion_dates > 0) banners.push(`<div class="cf-note">${s.estimated_completion_dates} pesanan selesai sebelum fitur ini ada; tanggal selesainya diperkirakan dari waktu perubahan terakhir.</div>`);
      $("cf-banners").innerHTML = banners.join("");
      $("cf-banners").querySelectorAll("[data-go]").forEach((a) => a.onclick = (e) => {
        e.preventDefault(); sub = a.dataset.go;
        if (a.dataset.review) { filters.orders = { review: true }; pages.orders = 1; }
        if (a.dataset.unpaid) { filters.offline = { payment_status: "unpaid" }; pages.offline = 1; }
        $("cf-subs").querySelectorAll("[data-s]").forEach((x) => x.setAttribute("aria-pressed", String(x.dataset.s === sub)));
        syncHash(); drawSub();
      });
    } catch (e) {
      if ($("cf-cards")) $("cf-cards").innerHTML = `<p class="msg err">Ringkasan gagal dimuat: ${esc(C.errorText(e))}</p>`;
    } finally { $("cf-cards")?.removeAttribute("aria-busy"); }
  }

  // ---------------------------------------------------------------- sections
  async function drawSub(quiet) {
    const body = $("cf-body"); if (!body) return;
    if (sub === "menu") return drawMenu(quiet);
    if (sub === "settings") return drawSettings();
    return drawList(quiet);
  }

  // shared transaction list (Transaksi / Pesanan selesai / Penjualan offline / Pengeluaran)
  const LIST_FIXED = { transactions: {}, orders: {}, offline: { source: "offline" }, expenses: { source: "expense" } };
  async function drawList(quiet) {
    const body = $("cf-body");
    const mySub = sub;
    const f = filters[sub];
    if (!quiet || !$("cf-list")) {
      if (!categories) categories = await rpc("cashflow_categories").catch(() => []);
      // customers who bought in this period, for the Pelanggan filter (not for expenses)
      const customers = sub === "expenses" ? [] : await rpc("cashflow_customers", { p_from: range.from, p_to: range.to }).catch(() => []);
      // the page may have been redrawn (second login event, another section) while waiting
      if (!body || !body.isConnected || sub !== mySub) return;
      const sel = (id, label, opts, val) => `<label class="f">${label}<select id="${id}"><option value="">Semua</option>${opts.map(([k, v]) => `<option value="${esc(k)}" ${String(val ?? "") === String(k) ? "selected" : ""}>${esc(v)}</option>`).join("")}</select></label>`;
      const ctl = [];
      if (sub === "transactions") {
        ctl.push(sel("cf-f-type", "Jenis", [["income", "Pemasukan"], ["expense", "Pengeluaran"]], f.type));
        ctl.push(sel("cf-f-source", "Sumber", Object.entries(C.TX_SOURCE), f.source));
      }
      if (sub === "orders") ctl.push(`<label class="f">Tampilkan<select id="cf-f-oclass"><option value="">Semua pesanan</option><option value="review" ${f.review ? "selected" : ""}>Perlu ditinjau</option></select></label>`);
      if (sub !== "expenses") {
        const opts = customers.map((c) => [c.name, `${c.name} (${c.orders})`]);
        if (f.customer && !customers.some((c) => c.name.toLowerCase() === f.customer.toLowerCase())) opts.unshift([f.customer, f.customer]);
        ctl.push(sel("cf-f-cust", "Pelanggan", opts, f.customer));
      }
      if (sub === "offline") ctl.push(sel("cf-f-pst", "Status bayar", [["paid", "Lunas"], ["unpaid", "Belum dibayar"]], f.payment_status));
      ctl.push(sel("cf-f-pay", "Pembayaran", Object.entries(C.PAYMENT), f.payment));
      if (sub === "transactions" || sub === "expenses") ctl.push(sel("cf-f-cat", "Kategori pengeluaran", (categories || []).map((c) => [c.id, c.name + (c.is_active ? "" : " (disembunyikan)")]), f.category_id));
      const ph = { transactions: "No. pesanan, nota, menu, pelanggan, pengeluaran, vendor…", orders: "No. pesanan, menu, pelanggan…", offline: "No. nota, menu, pelanggan…", expenses: "Keterangan, vendor, kategori…" }[sub];
      const addBtn = sub === "offline" ? `<button class="btn btn-rose" id="cf-add2">+ Penjualan offline</button>` : sub === "expenses" ? `<button class="btn btn-rose" id="cf-add2">+ Pengeluaran</button> <button class="btn btn-ghost" id="cf-cats">Kelola kategori</button>` : "";
      const intro = {
        transactions: "Semua pesanan online yang <b>Selesai</b>, penjualan offline dan pengeluaran pada periode ini. Terbaru di atas.",
        orders: "Pesanan online berstatus <b>Selesai</b>, dihitung pada tanggal selesai. Pesanan menunggu bayar, diproses, dibatalkan, kedaluwarsa dan gagal tidak dihitung. Pesanan tes (Mock) tidak ditampilkan. Ubah status, isi pesanan atau label Real/Mock lewat menu <a href=\"#orders\">Pesanan</a>.",
        offline: "Penjualan di luar website (walk-in, WhatsApp, telepon…). Pesanan online jangan dicatat lagi di sini: sudah otomatis.",
        expenses: "Biaya usaha. Dicatat terpisah dari pemasukan.",
      }[sub];
      body.innerHTML = `<p class="muted cf-intro">${intro}</p>${addBtn ? `<div class="row-actions" style="justify-content:flex-start;margin-bottom:.7rem">${addBtn}</div>` : ""}
        <form class="cf-filters" id="cf-filters" role="search">${ctl.join("")}
          <label class="f cf-q">Cari<input type="search" id="cf-q" placeholder="${ph}" value="${esc(f.q || "")}"></label>
          <button class="btn btn-ghost btn-sm" type="button" id="cf-reset">Reset filter</button></form>
        <div id="cf-list" aria-live="polite"><p class="muted">Memuat…</p></div>`;
      const read = () => {
        const g = (id) => ($(id) ? $(id).value || undefined : undefined);
        const nf = { type: g("cf-f-type"), source: g("cf-f-source"), payment: g("cf-f-pay"), payment_status: g("cf-f-pst"), customer: g("cf-f-cust"), category_id: g("cf-f-cat"), q: $("cf-q").value.trim() || undefined };
        if (sub === "orders") nf.review = g("cf-f-oclass") === "review" || undefined;
        filters[sub] = nf; pages[sub] = 1; loadList();
      };
      $("cf-filters").onchange = (e) => { if (e.target.id !== "cf-q") read(); };
      $("cf-filters").onsubmit = (e) => { e.preventDefault(); read(); };
      let t; $("cf-q").oninput = () => { clearTimeout(t); t = setTimeout(read, 350); };
      // clear the fields in place (redrawing would wipe anything typed straight after)
      $("cf-reset").onclick = () => {
        $("cf-filters").querySelectorAll("select").forEach((x) => (x.value = ""));
        $("cf-q").value = ""; filters[sub] = {}; pages[sub] = 1; loadList();
      };
      $("cf-add2")?.addEventListener("click", () => (sub === "offline" ? offlineForm() : expenseForm()));
      $("cf-cats")?.addEventListener("click", manageCategories);
    }
    await loadList(quiet);
  }

  async function loadList(quiet) {
    const el = $("cf-list"); if (!el) return;
    const mySub = sub;
    const args = { from: range.from, to: range.to, page: pages[sub], page_size: PAGE_SIZE, ...filters[sub], ...LIST_FIXED[sub] };
    if (sub === "orders") args.source = "system";
    Object.keys(args).forEach((k) => (args[k] === undefined || args[k] === "") && delete args[k]);
    if (!quiet) el.setAttribute("aria-busy", "true");
    try {
      const data = await rpc("cashflow_transactions", { p: args });
      if (sub !== mySub || !$("cf-list")) return;
      el.innerHTML = listHtml(data);
      wireList(el, data);
    } catch (e) {
      el.innerHTML = `<p class="msg err">Data gagal dimuat: ${esc(C.errorText(e))} <button class="btn btn-ghost btn-sm" id="cf-retry">Coba lagi</button></p>`;
      $("cf-retry").onclick = () => loadList();
    } finally { el.removeAttribute("aria-busy"); }
  }

  // Lists show only date, what it is and the amount; everything else (items, payment, actions) is in Detail.
  function rowText(r) {
    const d = r.detail || {};
    if (r.source === "expense") return { title: r.description, sub: r.category_name || "Pengeluaran" };
    if (r.source === "offline") return { title: r.customer_name || (d.entry_mode === "amount" ? "Penjualan offline (nominal)" : "Penjualan offline"), sub: `${r.ref} · ${C.SOURCE[d.source] || "Offline"}` };
    return { title: r.customer_name || "Pesanan online", sub: r.ref };
  }
  function listHtml(data) {
    const rows = data.rows || [];
    if (!rows.length) {
      const empty = { transactions: "Belum ada transaksi pada periode ini.", orders: "Belum ada pesanan online yang selesai pada periode ini.", offline: "Belum ada penjualan offline pada periode ini.", expenses: "Belum ada pengeluaran pada periode ini." }[sub];
      const hasFilter = Object.values(filters[sub]).some(Boolean);
      return `<div class="card cf-empty"><p>${empty}</p>${hasFilter ? `<p class="muted">Coba hapus filter atau ganti periode.</p>` : ""}</div>`;
    }
    const what = { transactions: "Transaksi", orders: "Pesanan", offline: "Penjualan", expenses: "Pengeluaran" }[sub];
    const body = rows.map((r) => {
      const d = r.detail || {};
      const t = rowText(r);
      const kind = sub === "transactions" ? (r.ttype === "expense" ? "Pengeluaran · " : r.source === "offline" ? "Offline · " : "Online · ") : "";
      return `<tr class="cf-row" data-uid="${esc(r.uid)}">
        <td class="cf-when">${shortWib(r.at)}</td>
        <td class="cf-main"><b>${esc(t.title)}</b>${d.review ? ` <span class="badge cf-review">Perlu ditinjau</span>` : ""}${d.payment_status === "unpaid" ? ` <span class="badge cf-unpaid">Belum dibayar</span>` : ""}<div class="muted">${kind}${esc(t.sub)}</div></td>
        <td class="num ${r.ttype === "expense" ? "cf-neg" : d.payment_status === "unpaid" ? "cf-muted" : ""}"><b>${r.ttype === "expense" ? "−" : ""}${rp(r.amount)}</b></td>
        <td class="cf-go"><button class="btn btn-ghost btn-sm" data-act="detail" data-uid="${esc(r.uid)}">Detail</button></td></tr>`;
    }).join("");
    const pagesN = Math.max(1, Math.ceil(data.total_count / PAGE_SIZE));
    return `<div class="tbl-wrap"><table class="cf-table cf-compact"><thead><tr><th>Tanggal</th><th>${what}</th><th class="num">Jumlah</th><th></th></tr></thead><tbody>${body}</tbody></table></div>
      <div class="cf-pager"><span class="muted">${data.total_count} data · halaman ${pages[sub]} dari ${pagesN}</span>
        <button class="btn btn-ghost btn-sm" data-pg="-1" ${pages[sub] <= 1 ? "disabled" : ""}>‹ Sebelumnya</button>
        <button class="btn btn-ghost btn-sm" data-pg="1" ${pages[sub] >= pagesN ? "disabled" : ""}>Berikutnya ›</button></div>`;
  }

  function wireList(el, data) {
    const byUid = Object.fromEntries((data.rows || []).map((r) => [r.uid, r]));
    el.querySelectorAll("[data-pg]").forEach((b) => b.onclick = () => { pages[sub] += Number(b.dataset.pg); loadList(); el.scrollIntoView({ block: "start" }); });
    // the whole row opens Detail; the Detail button keeps it reachable by keyboard
    el.querySelectorAll("tr.cf-row").forEach((tr) => tr.onclick = () => { const r = byUid[tr.dataset.uid]; if (r) showDetail(r); });
  }

  async function classify(r, to, btn) {
    const d = r.detail || {};
    const keep = to === r.classification;
    const msg = keep
      ? `Konfirmasi ${r.ref} (${rp(r.amount)}) sebagai pembelian asli?`
      : `Tandai ${r.ref} sebagai pesanan tes? Pesanan ini (${rp(r.amount)}) akan hilang dari Cashflow Summary dan tidak dihitung sebagai pemasukan. Status pesanan tidak berubah, dan labelnya bisa dikembalikan di menu Pesanan.`;
    if (!(await confirmDialog({ title: keep ? "Konfirmasi pesanan" : "Tandai sebagai pesanan tes", body: msg, ok: keep ? "Konfirmasi" : "Tandai tes" }))) return;
    if (btn) btn.disabled = true;
    try {
      await rpc("cashflow_set_order_classification", { p_order_id: d.id, p_classification: to, p_note: null });
      X.toast(keep ? "Pesanan dikonfirmasi" : "Ditandai sebagai pesanan tes");
      menuData = null; reloadAll(true);
    } catch (e) { X.toast(C.errorText(e)); if (btn) btn.disabled = false; }
  }

  // an unpaid offline sale is paid: it counts as income from the payment date
  function markPaid(r) {
    const d = r.detail || {};
    X.openModal(`<div class="modal-head"><h2>Tandai lunas · ${esc(r.ref)}</h2><button class="x" data-close aria-label="Tutup">×</button></div>
      <form id="cf-pf" class="grid2" novalidate>
        <label class="f">Dibayar pada (WIB) *<input type="datetime-local" id="pf-date" required value="${esc(C.nowWibInput())}"></label>
        <label class="f">Pembayaran *<select id="pf-pay">${["cash", "bank_transfer", "qris", "other"].map((k) => `<option value="${k}" ${r.payment === k ? "selected" : ""}>${C.PAYMENT[k]}</option>`).join("")}</select></label>
      </form>
      <p class="muted" style="margin:0">${rp(r.amount)} dihitung sebagai pemasukan pada tanggal bayar.</p>
      <div class="msg err" id="pf-err" role="alert"></div>
      <div class="row-actions"><button class="btn btn-ghost" data-close>Batal</button><button class="btn btn-ok" id="pf-save">Simpan: lunas</button></div>`);
    $("pf-save").onclick = async () => {
      const at = C.wibInputToIso($("pf-date").value);
      if (!at) { $("pf-err").textContent = "Isi tanggal & jam pembayaran."; return; }
      const btn = $("pf-save"); btn.disabled = true;
      try {
        await rpc("cashflow_mark_offline_paid", { p_id: d.id, p_version: d.version, p_paid_at: at, p_payment_method: $("pf-pay").value });
        X.closeModal(); X.toast("Ditandai lunas"); menuData = null; reloadAll(true);
      } catch (e) { $("pf-err").textContent = C.errorText(e); btn.disabled = false; }
    };
  }

  async function deleteRecord(r) {
    const d = r.detail || {};
    const isExp = r.source === "expense";
    const what = isExp ? `pengeluaran "${r.description}" (${rp(r.amount)})` : `penjualan offline ${r.ref} (${rp(r.amount)})`;
    if (!(await confirmDialog({ title: isExp ? "Hapus pengeluaran?" : "Hapus penjualan offline?", body: `Yakin menghapus ${what}? Total cashflow dan statistik menu akan dihitung ulang. Data tetap tersimpan di riwayat audit.`, ok: "Hapus", danger: true }))) return;
    try {
      await rpc(isExp ? "cashflow_delete_expense" : "cashflow_delete_offline_order", { p_id: d.id, p_version: d.version });
      X.toast(isExp ? "Pengeluaran dihapus" : "Penjualan offline dihapus");
      menuData = null; reloadAll(true);
    } catch (e) { X.toast(C.errorText(e)); }
  }

  // ---------------------------------------------------------------- detail
  async function showDetail(r) {
    const d = r.detail || {};
    const items = d.items || [];
    const line = (k, v) => (v === undefined || v === null || v === "" ? "" : `<div class="cf-kv"><span>${k}</span><span>${v}</span></div>`);
    let entity, id, extra = "";
    if (r.source === "expense") {
      entity = "expense"; id = d.id;
      extra = line("Kategori", esc(r.category_name)) + line("Vendor / penerima", esc(r.vendor)) + line("Catatan", esc(d.notes))
        + (d.receipt_path ? `<div class="cf-kv"><span>Bukti</span><span><button class="btn btn-ghost btn-sm" id="cf-receipt">Lihat bukti</button></span></div>` : "");
    } else if (r.source === "offline") {
      entity = "offline_order"; id = d.id;
      extra = line("Status pembayaran", d.payment_status === "unpaid" ? `<span class="badge cf-unpaid">Belum dibayar</span>` : `Lunas · ${fmtWib(d.paid_at)}`) + line("Tanggal pesanan", fmtWib(d.order_date)) + line("Sumber", C.SOURCE[d.source]) + line("Pelanggan", esc(r.customer_name)) + line("Cara input", d.entry_mode === "amount" ? "Nominal saja (tidak masuk statistik menu)" : "Per item menu")
        + line("Catatan", esc(d.notes));
    } else {
      entity = "order"; id = d.id;
      extra = line("Status", "Selesai") + line("Dipesan", fmtWib(d.created_at)) + line("Dibayar", fmtWib(d.paid_at))
        + line("Selesai", fmtWib(d.completed_at) + (d.completed_at_estimated ? " (perkiraan)" : "")) + line("Pelanggan", esc(r.customer_name) + (d.guest ? " · tamu" : ""))
        + line("Lingkungan Midtrans", d.payment_env === "production" ? "Production" : d.payment_env === "sandbox" ? "Sandbox (tes)" : "Tidak tercatat")
        + (d.review && d.classification_note ? line("Catatan", esc(d.classification_note)) : "");
    }
    const itemRows = items.map((i) => `<tr><td>${esc(i.product_name)}${i.variant_name ? ` · <span class="muted">${esc(i.variant_name)}</span>` : ""}${i.addon ? ` · <b>${esc(i.addon)}</b>` : ""}</td><td class="num">${i.quantity}</td><td class="num">${rp(i.unit_price)}</td><td class="num">${i.discount ? "−" + rp(i.discount) : "–"}</td><td class="num">${rp(i.line_total)}</td></tr>`).join("");
    const totals = r.source === "offline" && d.entry_mode === "items"
      ? line("Subtotal", rp(d.subtotal)) + (d.item_discount ? line("Diskon item", "−" + rp(d.item_discount)) : "") + (d.order_discount ? line("Diskon pesanan", "−" + rp(d.order_discount)) : "") + (d.extra_charge ? line("Biaya tambahan", rp(d.extra_charge)) : "")
      : r.source.startsWith("system") ? line("Subtotal", rp(d.subtotal)) + (d.discount ? line("Diskon", "−" + rp(d.discount) + (d.promo_code ? ` (${esc(d.promo_code)})` : "")) : "") + (d.delivery_fee ? line("Ongkir", rp(d.delivery_fee)) : "") : "";
    X.openModal(`<div class="modal-head"><h2>${esc(r.ref)}</h2><button class="x" data-close aria-label="Tutup">×</button></div>
      <div class="cf-detail">
        <div>${typeBadge(r.ttype)} ${d.review ? '<span class="badge cf-review">Perlu ditinjau</span>' : ""}</div>
        ${line("Tanggal transaksi", fmtWib(r.at))}${line("Sumber", r.source === "expense" ? "Pengeluaran" : r.source === "offline" ? "Penjualan offline" : "Pesanan online")}${line("Pembayaran", esc(C.paymentLabel(r.payment, r.payment_raw)))}
        ${r.source === "expense" ? line("Keterangan", esc(r.description)) : ""}${extra}
        ${items.length ? `<div class="tbl-wrap"><table><thead><tr><th>Item</th><th class="num">Jumlah</th><th class="num">Harga</th><th class="num">Diskon</th><th class="num">Total</th></tr></thead><tbody>${itemRows}</tbody></table></div>` : ""}
        ${totals}<div class="cf-kv cf-total"><span>${r.ttype === "expense" ? "Jumlah" : "Total"}</span><span>${rp(r.amount)}</span></div>
        ${r.source.startsWith("system") ? `<p class="muted" style="margin:0">Pesanan online diubah lewat menu Pesanan.</p>` : ""}
        <details id="cf-hist"><summary>Riwayat perubahan</summary><div class="muted">Memuat…</div></details>
      </div>
      <div class="row-actions">
        ${r.source === "system_real" && d.review ? `<button class="btn btn-ok" id="cf-d-keep">Benar, pembelian asli</button><button class="btn btn-ghost" id="cf-d-test">Ini pesanan tes</button>` : ""}
        ${r.ttype === "income" ? `<button class="btn btn-ghost" id="cf-d-nota">🖨️ Cetak nota</button>` : ""}
        ${r.source.startsWith("system") ? `<a class="btn btn-ghost" href="#orders/${encodeURIComponent(r.ref)}" data-close>Buka di Pesanan</a>` : ""}
        ${r.source === "offline" && d.payment_status === "unpaid" ? `<button class="btn btn-ok" id="cf-d-paid">Tandai lunas</button>` : ""}
        ${r.source === "offline" || r.source === "expense" ? `<button class="btn btn-ghost" id="cf-d-edit">Ubah</button><button class="btn btn-ghost cf-danger" id="cf-d-del">Hapus</button>` : ""}
        <button class="btn btn-ghost" data-close>Tutup</button></div>`);
    $("cf-d-nota")?.addEventListener("click", () => window.CNNota.print(window.CNNota.fromCashflowRow(r)));
    $("cf-d-keep")?.addEventListener("click", () => classify(r, r.classification));
    $("cf-d-test")?.addEventListener("click", () => classify(r, "mock"));
    $("cf-d-paid")?.addEventListener("click", () => markPaid(r));
    $("cf-d-edit")?.addEventListener("click", () => (r.source === "expense" ? expenseForm(r) : offlineForm(r)));
    $("cf-d-del")?.addEventListener("click", () => deleteRecord(r));
    $("cf-receipt")?.addEventListener("click", async () => {
      const { data, error } = await X.sb.storage.from("expense-receipts").createSignedUrl(d.receipt_path, 300);
      if (error) return X.toast("Bukti gagal dibuka: " + error.message);
      window.open(data.signedUrl, "_blank", "noopener");
    });
    $("cf-hist").addEventListener("toggle", async (e) => {
      if (!e.target.open || e.target.dataset.loaded) return; e.target.dataset.loaded = "1";
      try {
        const h = await rpc("cashflow_history", { p_entity: entity, p_id: String(id) });
        const A = { create: "Dibuat", update: "Diubah", delete: "Dihapus", classify: "Klasifikasi diubah", review: "Klasifikasi dikonfirmasi" };
        e.target.querySelector("div").outerHTML = h.length ? `<ul class="hist">${h.map((x) => `<li>${fmtWib(x.at)} · ${A[x.action] || esc(x.action)} oleh ${esc(x.by)}${x.after?.classification ? ` → ${C.CLASS[x.after.classification]}` : ""}</li>`).join("")}</ul>` : `<p class="muted">Belum ada perubahan tercatat.</p>`;
      } catch (err) { e.target.querySelector("div").textContent = C.errorText(err); }
    });
  }

  // ---------------------------------------------------------------- confirm dialog (Promise<boolean>)
  function confirmDialog({ title, body, ok, danger }) {
    return new Promise((resolve) => {
      X.openModal(`<div class="modal-head"><h2>${esc(title)}</h2><button class="x" data-close aria-label="Batal">×</button></div>
        <p style="margin:0" id="cf-confirm-body">${esc(body)}</p>
        <div class="row-actions"><button class="btn btn-ghost" data-close id="cf-no">Batal</button><button class="btn ${danger ? "btn-rose" : "btn-ok"}" id="cf-yes">${esc(ok)}</button></div>`);
      const box = $("modal-box"); box.classList.add("cf-small");
      let done = false;
      const finish = (v) => { if (done) return; done = true; obs.disconnect(); box.classList.remove("cf-small"); if (!$("modal").hidden) X.closeModal(); resolve(v); };
      const obs = new MutationObserver(() => { if ($("modal").hidden) finish(false); });
      obs.observe($("modal"), { attributes: true, attributeFilter: ["hidden"] });
      $("cf-yes").onclick = () => finish(true);
      $("cf-yes").focus();
    });
  }

  // ---------------------------------------------------------------- offline order form
  async function offlineForm(r) {
    const d = r?.detail || {};
    const editing = !!r;
    if (!catalog) { try { catalog = await rpc("cashflow_menu_catalog"); } catch (e) { X.toast(C.errorText(e)); catalog = []; } }
    const token = C.newToken();      // one per opened form: a double click or retry can't save twice
    const variantOpts = (sel) => `<option value="">Pilih menu…</option>` + Object.entries(catalog.reduce((g, p) => ((g[p.section_name || "Lainnya"] ||= []).push(p), g), {}))
      .map(([sec, ps]) => `<optgroup label="${esc(sec)}">${ps.flatMap((p) => p.variants.map((v) => `<option value="v${v.id}" data-price="${v.price}" ${sel === "v" + v.id ? "selected" : ""}>${esc(p.name)} · ${esc(v.name)} — ${rp(v.price)}${p.is_active && v.is_active ? "" : " (tidak dijual)"}</option>`)).join("")}</optgroup>`).join("")
      + `<option value="custom" ${sel === "custom" ? "selected" : ""}>Item lain (ketik nama)…</option>`;
    let items = (d.items || []).map((i) => ({ key: i.variant_id ? "v" + i.variant_id : "custom", product_name: i.variant_id ? "" : i.product_name, quantity: i.quantity, unit_price: i.unit_price, discount: i.discount || "" }));
    if (!items.length) items = [{ key: "", product_name: "", quantity: 1, unit_price: "", discount: "" }];
    const mode0 = d.entry_mode || "items";
    X.openModal(`<div class="modal-head"><h2>${editing ? "Ubah penjualan offline " + esc(r.ref) : "Catat penjualan offline"}</h2><button class="x" data-close aria-label="Tutup">×</button></div>
      <form id="cf-of" novalidate>
        <div class="grid3">
          <label class="f">Tanggal & jam (WIB) *<input type="datetime-local" id="of-date" required value="${esc(editing ? C.isoToWibInput(d.order_date || r.at) : C.nowWibInput())}"></label>
          <label class="f">No. nota / referensi<input id="of-ref" maxlength="60" value="${esc(d.order_ref || "")}" placeholder="opsional"></label>
          <label class="f">Nama pelanggan<input id="of-cust" maxlength="120" value="${esc(r?.customer_name || "")}" placeholder="opsional"></label>
          <label class="f">Sumber pesanan *<select id="of-src">${Object.entries(C.SOURCE).map(([k, v]) => `<option value="${k}" ${(d.source || "walk_in") === k ? "selected" : ""}>${v}</option>`).join("")}</select></label>
          <label class="f">Pembayaran *<select id="of-pay">${["cash", "bank_transfer", "qris", "other"].map((k) => `<option value="${k}" ${(r?.payment || "cash") === k ? "selected" : ""}>${C.PAYMENT[k]}</option>`).join("")}</select></label>
          <fieldset class="f cf-radio"><legend>Status pembayaran *</legend>
            <label><input type="radio" name="of-pst" value="paid" ${(d.payment_status || "paid") === "paid" ? "checked" : ""}> Lunas</label>
            <label><input type="radio" name="of-pst" value="unpaid" ${d.payment_status === "unpaid" ? "checked" : ""}> Belum dibayar</label></fieldset>
          <label class="f" id="of-paidat-wrap">Dibayar pada (kosong = saat pesanan)<input type="datetime-local" id="of-paidat" value="${esc(d.paid_at && d.order_date && d.paid_at !== d.order_date ? C.isoToWibInput(d.paid_at) : "")}"></label>
        </div>
        <fieldset class="cf-radio cf-mode"><legend class="muted">Cara mencatat</legend>
          <label><input type="radio" name="of-mode" value="items" ${mode0 === "items" ? "checked" : ""}> Per item menu</label>
          <label><input type="radio" name="of-mode" value="amount" ${mode0 === "amount" ? "checked" : ""}> Nominal saja (tanpa rincian item)</label></fieldset>
        <div id="of-items-wrap">
          <div class="tbl-wrap"><table class="vt cf-items"><thead><tr><th>Menu</th><th class="num">Jumlah</th><th class="num">Harga satuan</th><th class="num">Diskon</th><th class="num">Total baris</th><th></th></tr></thead><tbody id="of-items"></tbody></table></div>
          <div class="row-actions" style="justify-content:flex-start;margin-top:.5rem"><button type="button" class="btn btn-ghost btn-sm" id="of-addrow">+ Tambah item</button></div>
          <div class="grid3" style="margin-top:.7rem">
            <label class="f">Diskon pesanan (Rp)<input id="of-odisc" inputmode="numeric" value="${d.order_discount || ""}" placeholder="0"></label>
            <label class="f">Biaya tambahan / ongkir (Rp)<input id="of-extra" inputmode="numeric" value="${d.extra_charge || ""}" placeholder="0"></label>
          </div>
        </div>
        <div id="of-amount-wrap" hidden>
          <label class="f">Nominal diterima (Rp) *<input id="of-amount" inputmode="numeric" value="${d.entry_mode === "amount" ? r.amount : ""}" placeholder="contoh: 150.000"></label>
          <p class="muted" style="margin:.3rem 0 0;font-size:.85rem">Dihitung sebagai pemasukan, tapi tidak masuk statistik penjualan menu.</p>
        </div>
        <label class="f" style="margin-top:.7rem">Catatan<textarea id="of-notes" rows="2" maxlength="1000">${esc(d.notes || "")}</textarea></label>
        <div class="cf-totalbar"><span>Total</span><b id="of-total">Rp0</b></div>
        <div class="msg err" id="of-err" role="alert"></div>
        <div class="row-actions"><button type="button" class="btn btn-ghost" data-close>Batal</button><button type="submit" class="btn btn-rose" id="of-save">${editing ? "Simpan perubahan" : "Simpan penjualan"}</button></div>
      </form>`);
    const tbody = $("of-items");
    const draw = () => {
      tbody.innerHTML = items.map((it, i) => `<tr data-i="${i}">
        <td data-label="Menu"><select data-k="key" aria-label="Menu baris ${i + 1}">${variantOpts(it.key)}</select>${it.key === "custom" ? `<input data-k="product_name" aria-label="Nama item baris ${i + 1}" placeholder="Nama item" value="${esc(it.product_name)}" style="margin-top:.3rem">` : ""}</td>
        <td data-label="Jumlah" class="num"><input data-k="quantity" inputmode="numeric" aria-label="Jumlah baris ${i + 1}" value="${esc(it.quantity)}" style="width:70px"></td>
        <td data-label="Harga satuan" class="num"><input data-k="unit_price" inputmode="numeric" aria-label="Harga baris ${i + 1}" value="${esc(it.unit_price)}" class="w-price"></td>
        <td data-label="Diskon" class="num"><input data-k="discount" inputmode="numeric" aria-label="Diskon baris ${i + 1}" value="${esc(it.discount)}" placeholder="0" class="w-price"></td>
        <td data-label="Total baris" class="num" data-line="${i}">–</td>
        <td><button type="button" class="btn btn-ghost btn-sm" data-del="${i}" aria-label="Hapus baris ${i + 1}" ${items.length < 2 ? "disabled" : ""}>×</button></td></tr>`).join("");
      recalc();
    };
    const mode = () => document.querySelector('input[name="of-mode"]:checked').value;
    const pst = () => document.querySelector('input[name="of-pst"]:checked').value;
    const syncPst = () => { $("of-paidat-wrap").hidden = pst() !== "paid"; };
    const toPayloadItems = () => items.map((it) => ({
      ...(it.key && it.key !== "custom" ? { variant_id: Number(it.key.slice(1)) } : { product_name: it.product_name }),
      quantity: Number(it.quantity), unit_price: C.parseRupiah(it.unit_price), discount: it.discount === "" ? 0 : C.parseRupiah(it.discount),
    }));
    const recalc = () => {
      const isItems = mode() === "items";
      $("of-items-wrap").hidden = !isItems; $("of-amount-wrap").hidden = isItems;
      if (!isItems) { const a = C.parseRupiah($("of-amount").value); $("of-total").textContent = Number.isInteger(a) ? rp(a) : "–"; return; }
      const p = C.offlinePreview(items.map((it) => ({ ...it, variant_id: it.key && it.key !== "custom" ? 1 : null })), $("of-odisc").value, $("of-extra").value);
      p.lines.forEach((l, i) => { const c = tbody.querySelector(`[data-line="${i}"]`); if (c) c.textContent = rp(l.line_total); });
      $("of-total").textContent = rp(p.total);
    };
    tbody.addEventListener("input", (e) => {
      const tr = e.target.closest("[data-i]"); if (!tr) return;
      const it = items[tr.dataset.i]; const k = e.target.dataset.k;
      if (k === "key") {
        it.key = e.target.value;
        const opt = e.target.selectedOptions[0];
        if (opt?.dataset.price) it.unit_price = opt.dataset.price;   // menu price, can be changed
        draw(); return;
      }
      it[k] = e.target.value; recalc();
    });
    tbody.addEventListener("click", (e) => { const b = e.target.closest("[data-del]"); if (b) { items.splice(Number(b.dataset.del), 1); draw(); } });
    $("of-addrow").onclick = () => { items.push({ key: "", product_name: "", quantity: 1, unit_price: "", discount: "" }); draw(); tbody.querySelector("tr:last-child select")?.focus(); };
    $("cf-of").addEventListener("input", (e) => { if (!e.target.closest("#of-items")) recalc(); });
    $("cf-of").addEventListener("change", (e) => { if (e.target.name === "of-mode") recalc(); if (e.target.name === "of-pst") syncPst(); });
    syncPst();
    draw();
    $("cf-of").onsubmit = async (e) => {
      e.preventDefault();
      const errBox = $("of-err"); errBox.textContent = "";
      const head = { order_date: $("of-date").value, source: $("of-src").value, payment_method: $("of-pay").value,
        classification: "real", entry_mode: mode(), amount: $("of-amount").value };
      let errs = C.validateOfflineHeader(head);
      let preview = null;
      if (head.entry_mode === "items") {
        preview = C.offlinePreview(items.map((it) => ({ ...it, variant_id: it.key && it.key !== "custom" ? 1 : null })), $("of-odisc").value, $("of-extra").value);
        errs = errs.concat(preview.errors);
      }
      if (errs.length) { errBox.innerHTML = errs.map(esc).join("<br>"); return; }
      const payload = {
        client_token: token, order_date: C.wibInputToIso(head.order_date), order_ref: $("of-ref").value.trim() || null,
        customer_name: $("of-cust").value.trim() || null, source: head.source, payment_method: head.payment_method,
        classification: head.classification, entry_mode: head.entry_mode, notes: $("of-notes").value.trim() || null,
        payment_status: pst(), paid_at: pst() === "paid" && $("of-paidat").value ? C.wibInputToIso($("of-paidat").value) : null,
      };
      if (editing) { payload.id = d.id; payload.version = d.version; }
      if (head.entry_mode === "amount") payload.amount = C.parseRupiah(head.amount);
      else Object.assign(payload, { items: toPayloadItems(), order_discount: preview.orderDiscount, extra_charge: preview.extraCharge, expected_total: preview.total });
      const btn = $("of-save"); btn.disabled = true; btn.textContent = "Menyimpan…";
      try {
        const res = await rpc("cashflow_save_offline_order", { p: payload });
        X.closeModal();
        X.toast(res.duplicate ? "Sudah tersimpan sebelumnya" : editing ? "Penjualan offline diperbarui" : `Penjualan offline tersimpan · ${rp(res.total)}${payload.payment_status === "unpaid" ? " · belum dibayar" : ""}`);
        menuData = null; reloadAll(true);
      } catch (err) {
        errBox.textContent = C.errorText(err);
        btn.disabled = false; btn.textContent = editing ? "Simpan perubahan" : "Simpan penjualan";
      }
    };
  }

  // ---------------------------------------------------------------- expense form
  async function expenseForm(r) {
    const d = r?.detail || {};
    const editing = !!r;
    try { categories = await rpc("cashflow_categories"); } catch (e) { X.toast(C.errorText(e)); return; }
    const token = C.newToken();
    const catOpts = categories.filter((c) => c.is_active || c.id === r?.category_id)
      .map((c) => `<option value="${c.id}" ${c.id === r?.category_id ? "selected" : ""}>${esc(c.name)}${c.is_active ? "" : " (disembunyikan)"}</option>`).join("");
    X.openModal(`<div class="modal-head"><h2>${editing ? "Ubah pengeluaran" : "Catat pengeluaran"}</h2><button class="x" data-close aria-label="Tutup">×</button></div>
      <form id="cf-ef" novalidate><div class="grid2">
        <label class="f">Tanggal & jam (WIB) *<input type="datetime-local" id="ef-date" required value="${esc(editing ? C.isoToWibInput(r.at) : C.nowWibInput())}"><span class="cf-ferr" data-for="expense_date"></span></label>
        <label class="f">Jumlah (Rp) *<input id="ef-amount" inputmode="numeric" required value="${editing ? r.amount : ""}" placeholder="contoh: 45.000"><span class="cf-ferr" data-for="amount"></span></label>
        <label class="f">Keterangan *<input id="ef-desc" maxlength="200" required value="${esc(r?.description || "")}" placeholder="contoh: Botol 250 ml 100 pcs"><span class="cf-ferr" data-for="description"></span></label>
        <label class="f">Kategori *<select id="ef-cat" required><option value="">Pilih kategori…</option>${catOpts}</select><span class="cf-ferr" data-for="category_id"></span></label>
        <label class="f">Pembayaran *<select id="ef-pay">${["cash", "bank_transfer", "qris", "other"].map((k) => `<option value="${k}" ${(r?.payment || "cash") === k ? "selected" : ""}>${C.PAYMENT[k]}</option>`).join("")}</select><span class="cf-ferr" data-for="payment_method"></span></label>
        <label class="f">Vendor / penerima<input id="ef-vendor" maxlength="120" value="${esc(r?.vendor || "")}" placeholder="opsional"></label>
        <label class="f">Bukti / nota (foto atau PDF, maks. 5 MB)<input type="file" id="ef-file" accept="image/*,application/pdf">${d.receipt_path ? `<span class="muted" style="font-weight:600">Sudah ada bukti. Pilih file baru untuk mengganti, atau <label class="chk" style="display:inline-flex"><input type="checkbox" id="ef-rm"> hapus bukti</label></span>` : ""}</label>
        <label class="f">Catatan<textarea id="ef-notes" rows="2" maxlength="1000">${esc(d.notes || "")}</textarea></label>
      </div>
      <div class="msg err" id="ef-err" role="alert"></div>
      <div class="row-actions"><button type="button" class="btn btn-ghost" data-close>Batal</button><button type="submit" class="btn btn-rose" id="ef-save">${editing ? "Simpan perubahan" : "Simpan pengeluaran"}</button></div></form>`);
    $("cf-ef").onsubmit = async (e) => {
      e.preventDefault();
      document.querySelectorAll(".cf-ferr").forEach((x) => (x.textContent = ""));
      $("ef-err").textContent = "";
      const f = { expense_date: $("ef-date").value, description: $("ef-desc").value, category_id: $("ef-cat").value, amount: $("ef-amount").value, payment_method: $("ef-pay").value };
      const errs = C.validateExpense(f);
      if (Object.keys(errs).length) {
        Object.entries(errs).forEach(([k, v]) => { const el = document.querySelector(`.cf-ferr[data-for="${k}"]`); if (el) el.textContent = v; });
        $("ef-err").textContent = "Periksa kembali isian yang ditandai."; return;
      }
      const btn = $("ef-save"); btn.disabled = true; btn.textContent = "Menyimpan…";
      try {
        let receipt = $("ef-rm")?.checked ? null : d.receipt_path || null;
        const file = $("ef-file").files[0];
        if (file) {
          if (file.size > 5 * 1024 * 1024) throw new Error("File bukti lebih dari 5 MB.");
          const ext = (file.name.split(".").pop() || "bin").toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 5) || "bin";
          const path = `${f.expense_date.slice(0, 4)}/${token}.${ext}`;
          const { error } = await X.sb.storage.from("expense-receipts").upload(path, file, { contentType: file.type, upsert: false });
          if (error) throw new Error("Bukti gagal diunggah: " + error.message);
          receipt = path;
        }
        const payload = { client_token: token, expense_date: C.wibInputToIso(f.expense_date), description: f.description.trim(), category_id: Number(f.category_id),
          amount: C.parseRupiah(f.amount), payment_method: f.payment_method, vendor: $("ef-vendor").value.trim() || null, receipt_path: receipt, notes: $("ef-notes").value.trim() || null };
        if (editing) { payload.id = d.id; payload.version = d.version; }
        const res = await rpc("cashflow_save_expense", { p: payload });
        X.closeModal();
        X.toast(res.duplicate ? "Sudah tersimpan sebelumnya" : editing ? "Pengeluaran diperbarui" : "Pengeluaran tersimpan");
        reloadAll(true);
      } catch (err) {
        $("ef-err").textContent = C.errorText(err);
        btn.disabled = false; btn.textContent = editing ? "Simpan perubahan" : "Simpan pengeluaran";
      }
    };
  }

  async function manageCategories() {
    const draw = async () => {
      categories = await rpc("cashflow_categories");
      X.openModal(`<div class="modal-head"><h2>Kategori pengeluaran</h2><button class="x" data-close aria-label="Tutup">×</button></div>
        <p class="muted" style="margin:0">Kategori tidak bisa dihapus agar riwayat tetap utuh; sembunyikan saja. Mengganti nama tidak mengubah nama di pengeluaran lama.</p>
        <div class="tbl-wrap"><table><thead><tr><th>Nama</th><th class="num">Dipakai</th><th>Status</th><th></th></tr></thead><tbody>
        ${categories.map((c) => `<tr><td><input data-name="${c.id}" value="${esc(c.name)}" maxlength="60" aria-label="Nama kategori"></td><td class="num">${c.used}</td>
          <td>${c.is_active ? '<span class="badge on">Aktif</span>' : '<span class="badge off">Disembunyikan</span>'}</td>
          <td><div class="row-actions"><button class="btn btn-ghost btn-sm" data-save="${c.id}">Simpan nama</button><button class="btn btn-ghost btn-sm" data-tog="${c.id}">${c.is_active ? "Sembunyikan" : "Tampilkan"}</button></div></td></tr>`).join("")}
        </tbody></table></div>
        <form id="cat-new" class="row-actions" style="justify-content:flex-start"><input id="cat-name" maxlength="60" placeholder="Nama kategori baru" aria-label="Nama kategori baru"><button class="btn btn-rose" type="submit">+ Tambah</button></form>
        <div class="row-actions"><button class="btn btn-ghost" data-close>Selesai</button></div>`);
      const save = async (id, name, active) => {
        try { await rpc("cashflow_save_category", { p_id: id, p_name: name, p_active: active }); X.toast("Kategori disimpan"); draw(); }
        catch (e) { X.toast(C.errorText(e)); }
      };
      $("modal-box").querySelectorAll("[data-save]").forEach((b) => b.onclick = () => save(Number(b.dataset.save), $("modal-box").querySelector(`[data-name="${b.dataset.save}"]`).value, null));
      $("modal-box").querySelectorAll("[data-tog]").forEach((b) => b.onclick = () => { const c = categories.find((x) => x.id === Number(b.dataset.tog)); save(c.id, c.name, !c.is_active); });
      $("cat-new").onsubmit = (e) => { e.preventDefault(); const n = $("cat-name").value.trim(); if (!n) return X.toast("Isi nama kategori."); save(null, n, true); };
    };
    try { await draw(); } catch (e) { X.toast(C.errorText(e)); }
    $("modal").addEventListener("click", function once(e) { if (e.target.closest("[data-close]") || e.target.id === "modal") { $("modal").removeEventListener("click", once); if (sub === "expenses" || sub === "transactions") drawList(); } });
  }

  // ---------------------------------------------------------------- menu sales
  async function drawMenu(quiet) {
    const body = $("cf-body");
    if (!quiet || !$("cf-menu")) {
      body.innerHTML = `<p class="muted cf-intro">Menu yang terjual pada periode ini, dari rincian item pesanan online yang <b>Selesai</b> dan penjualan offline per item.</p>
        <form class="cf-filters" id="cf-mf">
          <label class="f">Kelompokkan<select id="m-group"><option value="product">Per menu</option><option value="variant">Per varian / ukuran</option></select></label>
          <label class="f">Urutkan<select id="m-sort"><option value="quantity">Jumlah terjual</option><option value="revenue">Pendapatan</option></select></label>
          <label class="f">Kategori<select id="m-sec"><option value="">Semua</option></select></label>
          <label class="f cf-q">Cari menu<input type="search" id="m-q" value="${esc(menuOpts.q)}" placeholder="contoh: matcha"></label>
        </form><div id="cf-menu" aria-live="polite"><p class="muted">Memuat…</p></div>`;
      ["group", "sort"].forEach((k) => ($("m-" + k).value = menuOpts[k]));
      $("cf-mf").onchange = (e) => {
        const reload = e.target.id === "m-group";
        menuOpts.group = $("m-group").value; menuOpts.sort = $("m-sort").value; menuOpts.section = $("m-sec").value;
        if (reload) { menuData = null; loadMenu(); } else paintMenu();
      };
      $("cf-mf").onsubmit = (e) => e.preventDefault();
      $("m-q").oninput = () => { menuOpts.q = $("m-q").value.trim(); paintMenu(); };
    }
    menuData = null;
    await loadMenu(quiet);
  }
  async function loadMenu(quiet) {
    const el = $("cf-menu"); if (!el) return;
    if (!quiet) el.setAttribute("aria-busy", "true");
    try {
      menuData = await rpc("cashflow_menu_sales", { p_from: range.from, p_to: range.to, p_scope: "real", p_group: menuOpts.group });
      const secs = menuData.categories.map((c) => c.name);
      $("m-sec").innerHTML = `<option value="">Semua</option>` + secs.map((s) => `<option ${s === menuOpts.section ? "selected" : ""}>${esc(s)}</option>`).join("");
      if (!secs.includes(menuOpts.section)) menuOpts.section = "";
      paintMenu();
    } catch (e) { el.innerHTML = `<p class="msg err">${esc(C.errorText(e))}</p>`; }
    finally { el.removeAttribute("aria-busy"); }
  }
  const bars = (list, key, fmt, cls) => {
    const max = Math.max(1, ...list.map((x) => Number(x[key])));
    return `<ol class="cf-bars">${list.map((x) => `<li><span class="cf-bl">${esc(x.label)}</span><span class="cf-bv">${fmt(x[key])}</span><span class="cf-bt" aria-hidden="true"><span class="cf-bf ${cls}" style="width:${Math.max(2, (100 * Number(x[key])) / max)}%"></span></span></li>`).join("")}</ol>`;
  };
  function paintMenu() {
    const el = $("cf-menu"); if (!el || !menuData) return;
    const m = menuData;
    const q = menuOpts.q.toLowerCase();
    const label = (r) => r.name + (r.variant ? " · " + r.variant : "");
    let rows = m.rows.filter((r) => (!menuOpts.section || r.section_name === menuOpts.section) && (!q || label(r).toLowerCase().includes(q)));
    rows = rows.slice().sort((a, b) => menuOpts.sort === "revenue" ? b.revenue - a.revenue || b.quantity - a.quantity : b.quantity - a.quantity || b.revenue - a.revenue);
    const ins = m.insights || {};
    const num = (n) => Number(n).toLocaleString("id-ID");
    const top = (arr, key) => arr.slice().sort((a, b) => b[key] - a[key]).slice(0, 10).map((r) => ({ ...r, label: label(r) }));
    const disclosure = m.amount_only.orders > 0
      ? `<div class="cf-note">${m.amount_only.orders} penjualan offline <b>nominal saja</b> (${rp(m.amount_only.value)}) tidak punya rincian item, jadi tidak masuk tabel ini. Karena itu pendapatan menu bisa berbeda dari total pemasukan.</div>` : "";
    if (!m.rows.length) {
      el.innerHTML = `${disclosure}<div class="card cf-empty"><p>Belum ada penjualan menu pada periode ini.</p></div>`;
      return;
    }
    el.innerHTML = `
      <section class="cf-cards cf-ins" aria-label="Ringkasan menu">
        <div class="card cf-card"><div class="cf-lbl">Terlaris (jumlah)</div><div class="cf-val sm">${esc(label(ins.top_by_quantity || {}) || "–")}</div><div class="cf-hint">${ins.top_by_quantity ? num(ins.top_by_quantity.quantity) + " terjual" : ""}</div></div>
        <div class="card cf-card"><div class="cf-lbl">Pendapatan tertinggi</div><div class="cf-val sm">${esc(label(ins.top_by_revenue || {}) || "–")}</div><div class="cf-hint">${ins.top_by_revenue ? rp(ins.top_by_revenue.revenue) : ""}</div></div>
        <div class="card cf-card"><div class="cf-lbl">Kategori terbaik</div><div class="cf-val sm">${esc(ins.top_category?.name || "–")}</div><div class="cf-hint">${ins.top_category ? rp(ins.top_category.revenue) + " · " + String(ins.top_category.share).replace(".", ",") + "%" : ""}</div></div>
        <div class="card cf-card"><div class="cf-lbl">Item terjual</div><div class="cf-val">${num(m.total_quantity)}</div></div>
        <div class="card cf-card"><div class="cf-lbl">Pendapatan menu</div><div class="cf-val">${rp(m.total_revenue)}</div></div>
      </section>${disclosure}
      <div class="cf-charts">
        <div class="card"><h3>Terlaris menurut jumlah</h3>${bars(top(m.rows, "quantity"), "quantity", num, "")}</div>
        <div class="card"><h3>Pendapatan per menu</h3>${bars(top(m.rows, "revenue"), "revenue", rp, "rev")}</div>
        <div class="card"><h3>Penjualan per kategori</h3>${bars(m.categories.map((c) => ({ ...c, label: c.name })), "revenue", rp, "cat")}</div>
      </div>
      <div class="tbl-wrap"><table class="cf-table cf-compact"><thead><tr><th>Menu</th><th class="num">Terjual</th><th class="num">Pendapatan</th><th></th></tr></thead><tbody>
        ${rows.length ? rows.map((r, i) => `<tr class="cf-row" data-mi="${i}"><td class="cf-main"><b>${esc(r.name)}</b>${r.variant ? ` · ${esc(r.variant)}` : ""}<div class="muted">${esc(r.section_name)}</div></td><td class="num cf-qty">${num(r.quantity)}<span class="cf-m"> terjual</span></td><td class="num"><b>${rp(r.revenue)}</b></td><td class="cf-go"><button class="btn btn-ghost btn-sm">Detail</button></td></tr>`).join("")
          : `<tr><td colspan="4" class="muted">Tidak ada menu yang cocok dengan filter.</td></tr>`}
      </tbody></table></div>
      <p class="muted cf-foot">${esc(m.note)} Tidak ada perhitungan laba karena data HPP belum terhubung.</p>`;
    el.querySelectorAll("tr[data-mi]").forEach((tr) => tr.onclick = () => menuDetail(rows[Number(tr.dataset.mi)], m));
  }
  function menuDetail(r, m) {
    const line = (k, v) => `<div class="cf-kv"><span>${k}</span><span>${v}</span></div>`;
    const num = (n) => Number(n).toLocaleString("id-ID");
    X.openModal(`<div class="modal-head"><h2>${esc(r.name)}${r.variant ? " · " + esc(r.variant) : ""}</h2><button class="x" data-close aria-label="Tutup">×</button></div>
      <div class="cf-detail">${line("Periode", C.rangeLabel(range))}${line("Kategori", esc(r.section_name))}${line("Terjual", num(r.quantity))}
        ${line("Pendapatan", rp(r.revenue))}${line("Rata-rata per item", rp(r.avg_price))}${line("Kontribusi ke pendapatan menu", String(r.share ?? 0).replace(".", ",") + "%")}
        <p class="muted" style="margin:0;font-size:.85rem">${esc(m.note)}</p></div>
      <div class="row-actions"><button class="btn btn-ghost" data-close>Tutup</button></div>`);
  }

  // ---------------------------------------------------------------- settings
  async function drawSettings() {
    const body = $("cf-body");
    const mode = summary?.payments_mode || "sandbox";
    body.innerHTML = `<div class="list">
      <div class="card"><h3>Pesanan tes</h3>
        <p>Mode pembayaran sekarang: <b>${mode === "production" ? "Production (live)" : "Sandbox (tes)"}</b>.</p>
        <p class="muted">Pesanan yang dibayar lewat Midtrans <b>Sandbox</b> adalah pesanan tes (Mock) dan tidak ditampilkan atau dihitung di Cashflow Summary. Pesanan lewat <b>Production</b> dihitung sebagai penjualan asli. Pilihan di bawah dipakai kalau lingkungannya tidak tercatat; ganti ke Production bersamaan dengan langkah "Going live" di SHOP_SETUP.md. Label tiap pesanan (Real / Mock) bisa diubah di menu <a href="#orders">Pesanan</a>.</p>
        <button class="btn ${mode === "production" ? "btn-ghost" : "btn-rose"}" id="cf-mode">${mode === "production" ? "Kembali ke Sandbox" : "Ganti ke Production"}</button></div>
      <div class="card"><h3>Kategori pengeluaran</h3><p class="muted">Tambah, ganti nama atau sembunyikan kategori.</p><button class="btn btn-ghost" id="cf-cats2">Kelola kategori</button></div>
      <div class="card"><h3>Cara menghitung</h3><ul class="hist">
        <li><b>Real Order Income</b>: total pesanan online berstatus Selesai, menurut tanggal selesai.</li>
        <li><b>Offline Order Income</b>: penjualan offline, menurut tanggal pesanan.</li>
        <li><b>Total Income</b> = Real Order Income + Offline Order Income.</li>
        <li><b>Total Expenses</b>: semua pengeluaran menurut tanggal pengeluaran.</li>
        <li><b>Net Cashflow</b> = Total Income − Total Expenses. Ini arus kas tercatat, bukan laba akuntansi.</li>
        <li>Pesanan tes (Mock) tidak ditampilkan dan tidak dihitung di mana pun di halaman ini.</li>
        <li>Pesanan menunggu bayar, dibayar tapi belum selesai, dibatalkan (termasuk yang di-refund), kedaluwarsa dan gagal tidak dihitung.</li>
        <li>Semua tanggal memakai WIB (GMT+7). Minggu dimulai hari Senin.</li></ul></div></div>`;
    $("cf-cats2").onclick = manageCategories;
    $("cf-mode").onclick = async () => {
      const to = mode === "production" ? "sandbox" : "production";
      const ok = await confirmDialog({ title: "Ganti mode pembayaran", ok: "Ganti",
        body: to === "production" ? "Pesanan online BARU yang lingkungannya tidak tercatat akan dihitung sebagai penjualan asli. Lakukan ini hanya setelah Midtrans Production aktif." : "Pesanan online BARU yang lingkungannya tidak tercatat akan dianggap tes dan disembunyikan dari Cashflow Summary." });
      if (!ok) return;
      try { await rpc("cashflow_set_payments_mode", { p_mode: to }); X.toast("Mode pembayaran diganti"); await loadSummary(true); drawSettings(); }
      catch (e) { X.toast(C.errorText(e)); }
    };
  }

  window.CN_CASHFLOW = { render, sub, SUBS };
})();
