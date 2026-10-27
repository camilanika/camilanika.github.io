// CamilaNika storefront: menu from Supabase, cart, promos, accounts, Midtrans payment, order status.
(() => {
  const CFG = window.CN_CONFIG;
  // ONLINE_PAYMENT: true = on for everyone, false = off, "test" = only after opening the site with ?test=1
  // (remembered in this browser tab; ?test=0 turns it off again)
  const ONLINE = (() => {
    if (CFG.ONLINE_PAYMENT === true) return true;
    if (CFG.ONLINE_PAYMENT !== "test") return false;
    const t = new URLSearchParams(location.search).get("test");
    try {
      if (t === "1") sessionStorage.setItem("cn-test", "1");
      if (t === "0") sessionStorage.removeItem("cn-test");
      return sessionStorage.getItem("cn-test") === "1";
    } catch { return t === "1"; }
  })();
  const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);
  const WA = CFG.WHATSAPP;
  const $ = (id) => document.getElementById(id);
  const rp = (n) => "Rp" + Math.round(n).toLocaleString("id-ID");
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} },
  };

  const SIZES = { S: "250 ml", M: "500 ml", L: "1000 ml" };
  const SIZE_ATTR = "Ukuran";
  const ERRORS = {
    CART_EMPTY: "Keranjang masih kosong.",
    OUT_OF_STOCK: "Maaf, stok salah satu menu tidak cukup. Jumlahnya sudah kami sesuaikan, cek lagi ya.",
    PRODUCT_UNAVAILABLE: "Ada menu yang sudah tidak tersedia. Keranjang sudah diperbarui.",
    PROMO_NOT_APPLICABLE: "Kode promo tidak berlaku untuk pesanan ini.",
    NAME_REQUIRED: "Isi nama dulu ya.",
    PHONE_REQUIRED: "Isi nomor WhatsApp dulu ya.",
    PAYMENT_GATEWAY_ERROR: "Pembayaran sedang bermasalah. Coba lagi sebentar, atau kirim pesanan lewat WhatsApp.",
    PAYMENT_NOT_CONFIGURED: "Pembayaran online belum aktif. Silakan pesan lewat WhatsApp.",
    INVALID_QUANTITY: "Jumlah pesanan tidak valid.",
    INVALID_CHOICE: "Pilihan menu tidak valid, coba tambah ulang ke keranjang.",
    ADDON_UNAVAILABLE: "Tambahan (extra shot) tidak tersedia untuk menu ini.",
    SHOP_CLOSED: "Maaf, toko sedang tutup. Pesanan belum bisa dibuat.",
    LOCATION_REQUIRED: "Pilih lokasi pengantaran di peta dulu ya.",
    OUT_OF_RANGE: "Lokasi di luar jangkauan antar. Chat kami lewat WhatsApp untuk atur pengiriman.",
    LOCATION_INVALID: "Lokasi belum valid, pilih ulang di peta.",
    VOUCHER_LOGIN_REQUIRED: "Masuk ke akun dulu untuk memakai voucher.",
    VOUCHER_NOT_YOURS: "Voucher ini milik akun lain, jadi tidak bisa dipakai.",
    VOUCHER_USED: "Voucher ini sudah pernah dipakai.",
    VOUCHER_EXPIRED: "Voucher ini sudah kedaluwarsa.",
    VOUCHER_REVOKED: "Voucher ini sudah dibatalkan.",
    VOUCHER_PENDING: "Voucher ini baru aktif setelah pembayaran pertama kamu berhasil.",
    VOUCHER_RESERVED: "Voucher ini sedang dipakai di pesanan lain yang belum dibayar.",
    VOUCHER_NOT_APPLICABLE: "Voucher ini tidak berlaku untuk menu di keranjang.",
    VOUCHER_MIN_SPEND: "Belanjaan belum mencapai minimal voucher.",
    VOUCHER_NO_SHIPPING: "Voucher ini hanya memotong ongkir, dan pesanan ini tidak kena ongkir. Simpan vouchernya untuk lain kali.",
  };
  const errMsg = (raw) => {
    const min = String(raw || "").match(/VOUCHER_MIN_SPEND:(\d+)/);
    if (min) return `Voucher ini berlaku untuk belanja minimal ${rp(+min[1])}.`;
    const held = String(raw || "").match(/VOUCHER_RESERVED:(CN-[\w-]+)/);
    if (held) return `Voucher ini sedang dipakai di pesanan ${held[1]} yang belum dibayar. Lanjutkan pembayarannya di Pesanan, atau tunggu sampai waktunya habis.`;
    const code = String(raw || "").replace(/^.*?([A-Z_]{5,}).*$/s, "$1");
    return ERRORS[code] || "Terjadi kesalahan. Coba lagi, atau pesan lewat WhatsApp.";
  };
  const STATUS = {
    pending: "Menunggu pembayaran", paid: "Sudah dibayar", processing: "Sedang disiapkan", ready: "Siap diantar", shipping: "Sedang diantar",
    completed: "Selesai", cancelled: "Dibatalkan", expired: "Kedaluwarsa", failed: "Gagal",
  };

  // ------------------------------------------------------------------ state
  let menu = { products: [], promotions: [] };
  let size = "M";
  let cart = store.get("cn-cart-v2", []);
  let quote = null;          // last server quote
  let shop = { open: true }; // open / closed, from shop_status()
  let promoCode = "";
  let session = null;
  let profile = null;
  const save = () => store.set("cn-cart-v2", cart);

  // ------------------------------------------------------------------ menu rendering
  // Main menus (categories) -> submenus (sections) -> products, all from the database.
  const SIZE_ORDER = ["S", "M", "L"];
  const attrValues = (p, a) => [...new Set(p.variants.map((v) => v.attrs?.[a]).filter(Boolean))];
  const usesSize = (p) => p.attr_names.includes(SIZE_ATTR);
  const sizeLabel = (s) => (SIZES[s] ? `${s} · ${SIZES[s]}` : s);

  const chipGroup = (opts, label, def = 0, attr = "", show = (o) => o) =>
    `<div class="opt"><div class="opt-label">${esc(label)}</div><div class="chips" role="group" aria-label="${esc(label)}" data-attr="${esc(attr)}" data-label="${esc(label)}">${opts
      .map((o, i) => `<button type="button" class="chip" data-v="${esc(o)}" aria-pressed="${i === def}">${esc(show(o))}</button>`)
      .join("")}</div></div>`;

  // ---- menu card: photo, name, price, Tambah. Options (size, flavour, sugar, extra shot) open in a sheet.
  const sizesOf = (p) => attrValues(p, SIZE_ATTR).sort((a, b) => (SIZE_ORDER.indexOf(a) + 1 || 99) - (SIZE_ORDER.indexOf(b) + 1 || 99));
  const hasOptions = (p) => p.variants.length > 1 || (p.choices || []).length > 0 || !!p.addon_label;
  const cardImg = (p, cls = "pc-img") => `<div class="${cls}${usesSize(p) ? " ill" : ""}">${p.image_url ? `<img src="${esc(p.image_url)}" alt="${esc(p.name)}" loading="lazy" onerror="this.remove()">` : ""}</div>`;
  const cardHTML = (p) => `<article class="pcard" data-card="${p.id}">
      <div class="pc-media">${cardImg(p)}<b class="pc-qty num" data-qty hidden></b></div>
      <h3>${esc(p.name)}</h3>
      <div class="pc-foot"><div class="pc-price num" data-from></div><span class="stock-tag" data-stock></span>
      <button class="pc-add" type="button" data-pick>Tambah</button></div>
    </article>`;
  // the sheet: everything you can choose for one product
  function sheetHTML(p) {
    const attrs = p.attr_names.filter((a) => a !== SIZE_ATTR);
    const sizes = usesSize(p) ? sizesOf(p) : [];
    const sizeDef = Math.max(0, sizes.indexOf(size) >= 0 ? sizes.indexOf(size) : sizes.indexOf("M"));
    const opts = (sizes.length ? chipGroup(sizes, "Ukuran", sizeDef, SIZE_ATTR, sizeLabel) : "") +
      attrs.map((a) => chipGroup(attrValues(p, a), a === "Rasa" ? "Pilih rasa" : a, 0, a)).join("") +
      (p.choices || []).map((c) => chipGroup(c.options, c.label, c.default ?? 0)).join("") +
      (p.addon_label ? `<div class="opt"><div class="opt-label">Tambahan</div><label class="check" data-addon-wrap><input type="checkbox" data-addon> <span>${esc(p.addon_label)}</span> <span class="num" data-addon-price></span></label></div>` : "");
    return `<article class="os-card" data-product="${p.id}">
      <div class="os-top">${cardImg(p, "os-img")}<div class="os-info"><h3 id="os-title">${esc(p.name)}</h3>${p.subtitle ? `<p>${esc(p.subtitle)}</p>` : ""}${p.note ? `<em class="note-tag">${esc(p.note)}</em>` : ""}<div class="price num" data-price></div></div></div>
      <div class="os-opts">${opts}</div>
      <div class="os-foot"><span class="stock-tag" data-stock></span>
        <div class="os-row"><div class="qty os-qty" role="group" aria-label="Jumlah"><button type="button" data-step="-1" aria-label="Kurangi">−</button><span class="num" data-n>1</span><button type="button" data-step="1" aria-label="Tambah satu">+</button></div>
        <button class="btn btn-rose add" type="button" data-add>Tambah</button></div></div>
    </article>`;
  }

  // ---- photo showcase + info lines for a main menu (all configured in the admin page)
  const TAG_COLORS = ["#E8C07A", "#D9586F", "#F2D46B", "#A14A2E", "#6E9A3E", "#2F7FA8"];
  const ICON_INFO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.5 2.5L16 9.5"/></svg>';
  const showcaseImages = (c) => (Array.isArray(c.showcase_images) ? c.showcase_images : []).filter((i) => i && i.url);
  function showcaseHTML(c) {
    const imgs = showcaseImages(c);
    if (!imgs.length || c.showcase_layout === "none") return "";
    const img = (i, extra = "") => `<img src="${esc(i.url)}" alt="${esc(i.alt || i.caption || "")}" loading="lazy"${extra}>`;
    if (c.showcase_layout === "row") {
      return `<div class="bottle-row">${imgs.map((i) => `<figure class="bottle">${img(i)}${i.caption ? `<figcaption>${esc(i.caption)}${i.tag ? `<span>${esc(i.tag)}</span>` : ""}</figcaption>` : ""}</figure>`).join("")}</div>
        ${imgs.length > 3 ? '<p class="swipe-hint">Geser untuk lihat foto lainnya →</p>' : ""}`;
    }
    // mosaic: first photo is tall; if the grid would leave a gap, the last photo goes full width
    const k = imgs.length, solo = k === 1, lastWide = !solo && (k + 1) % 2 === 1;
    const rows = solo ? 2 : Math.ceil((k + 1 + (lastWide ? 1 : 0)) / 2);
    return `<div class="mosaic" style="--rows:${rows};grid-template-rows:repeat(${rows},var(--mosaic-row)) auto">
      ${imgs.map((i, n) => `<figure class="${solo ? "solo" : n === k - 1 && lastWide ? "wide" : ""}">${img(i)}${i.caption ? `<figcaption>${esc(i.caption)}</figcaption>` : ""}</figure>`).join("")}
      ${c.showcase_note ? `<div class="note" aria-hidden="true">${esc(c.showcase_note)}</div>` : ""}
      <img class="sticker" src="img/logo.jpg" alt="">
    </div>`;
  }
  const infoHTML = (c) =>
    (c.highlights || []).filter(Boolean).map((h) => `<p class="deliv">${ICON_INFO}${esc(h)}</p>`).join("") +
    ((c.tags || []).filter(Boolean).length ? `<div class="fillings">${c.tags.filter(Boolean).map((t, i) => `<div><i style="background:${TAG_COLORS[i % TAG_COLORS.length]}"></i>${esc(t)}</div>`).join("")}</div>` : "");
  const sizesIn = (c) => {
    const all = new Set();
    c.sections.forEach((s) => s.products.filter(usesSize).forEach((p) => attrValues(p, SIZE_ATTR).forEach((v) => all.add(v))));
    return [...all].sort((a, b) => (SIZE_ORDER.indexOf(a) + 1 || 99) - (SIZE_ORDER.indexOf(b) + 1 || 99));
  };

  function catHTML(c, i) {
    const showcase = showcaseHTML(c);
    const side = !!showcase && c.showcase_layout === "mosaic";
    const sizes = sizesIn(c);
    if (sizes.length && !sizes.includes(size)) size = sizes.includes("M") ? "M" : sizes[0];
    const head = `<div class="sec-head">
        ${c.eyebrow ? `<p class="eyebrow">${esc(c.eyebrow)}</p>` : ""}
        <h2 id="cat-${esc(c.slug)}">${esc(c.heading || c.name)}${c.heading_script ? ` <span class="script" style="font-size:.6em">${esc(c.heading_script)}</span>` : ""}</h2>
        ${c.description ? `<p>${esc(c.description)}</p>` : ""}
      </div>${infoHTML(c) ? `<div class="cat-info">${infoHTML(c)}</div>` : ""}`;
    const secs = c.sections.map((s) => `
      <section class="series acc-${esc(s.accent || "caramel")}" id="sub-${esc(s.slug)}" aria-labelledby="sub-h-${esc(s.slug)}">
        <div class="series-head"><h3 id="sub-h-${esc(s.slug)}">${esc(s.name)}</h3>${s.tagline ? `<p>${esc(s.tagline)}</p>` : ""}</div>
        <div class="menu-grid">${s.products.map(cardHTML).join("")}</div>
      </section>`).join("");
    const main = head + (side ? "" : showcase) + secs;
    return `<section class="block cat${i % 2 ? " alt" : ""}" id="${esc(c.slug)}" aria-labelledby="cat-${esc(c.slug)}">
      <div class="wrap${side ? " cat-side" : ""}">${side ? `<div class="cat-media">${showcase}</div>` : ""}<div class="cat-main">${main}</div></div>
    </section>`;
  }

  // ---- shop bar: search + one chip per submenu (or per main menu with a single submenu); sticky while browsing the menu
  const ICON_SEARCH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>';
  const ICON_LIST = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16"/></svg>';
  function shopBarHTML(cats) {
    const tabs = cats.flatMap((c) => c.sections.map((s) => `<a href="#sub-${esc(s.slug)}" data-cat="${esc(c.slug)}">${esc(s.name.replace(/ Series$/, ""))}</a>`));
    const list = cats.map((c) => `<div class="sb-cat"><a href="#${esc(c.slug)}" class="sb-cat-name">${esc(c.name)}</a>${c.sections.length > 1 ? c.sections.map((s) => `<a href="#sub-${esc(s.slug)}">${s.icon ? esc(s.icon) + " " : ""}${esc(s.name.replace(/ Series$/, ""))}</a>`).join("") : ""}</div>`).join("");
    return `<div class="shopbar" id="shopbar"><div class="wrap sb-row">
      <button class="sb-catbtn" type="button" id="sb-catbtn" aria-haspopup="true" aria-expanded="false" aria-controls="sb-cats">${ICON_LIST}<span id="sb-catname">${esc(cats[0].name)}</span></button>
      <nav class="sb-chips" aria-label="Submenu">${tabs.join("")}</nav>
      <div class="sb-search" id="sb-search" role="search" hidden>${ICON_SEARCH}<input type="search" id="sb-q" placeholder="Cari menu, mis. latte, cireng" aria-label="Cari menu" autocomplete="off" enterkeyhint="search"><button class="sb-x" type="button" id="sb-close" aria-label="Tutup pencarian">×</button></div>
      <button class="sb-btn" type="button" id="sb-open" aria-label="Cari menu" aria-controls="sb-search" aria-expanded="false">${ICON_SEARCH}</button>
    </div><div class="sb-cats" id="sb-cats" hidden><div class="wrap">${list}</div></div></div>`;
  }
  const catMenu = (open) => { const m = $("sb-cats"); if (!m) return; m.hidden = !open; $("sb-catbtn").setAttribute("aria-expanded", String(open)); };
  document.addEventListener("click", (e) => {
    if (e.target.closest("#sb-catbtn")) { catMenu($("sb-cats").hidden); return; }
    if (!e.target.closest("#sb-cats a") && e.target.closest("#sb-cats")) return;
    if ($("sb-cats") && !$("sb-cats").hidden) catMenu(false);
  });
  const fold = (t) => String(t ?? "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  function indexSearch() {
    document.querySelectorAll("#menu-root [data-card]").forEach((card) => {
      const p = productById(card.dataset.card); if (!p) return;
      const words = [p.name, p.subtitle, p.note, card.closest(".series")?.querySelector(".series-head")?.textContent, card.closest(".cat")?.querySelector(".sec-head h2")?.textContent,
        ...(p.variants || []).flatMap((v) => [v.name, ...Object.values(v.attrs || {})]), ...(p.choices || []).flatMap((c) => c.options || [])];
      card.dataset.hay = fold(words.filter(Boolean).join(" "));
    });
  }
  function applySearch(raw) {
    const words = fold(raw).trim().split(/\s+/).filter(Boolean), on = words.length > 0, root = $("menu-root");
    root.classList.toggle("searching", on);
    let hits = 0;
    root.querySelectorAll("[data-card]").forEach((card) => { const ok = !on || words.every((w) => card.dataset.hay?.includes(w)); card.hidden = !ok; if (ok) hits++; });
    root.querySelectorAll(".series, .cat").forEach((el) => { el.hidden = on && !el.querySelector("[data-card]:not([hidden])"); });
    $("sb-empty").hidden = !on || hits > 0;
    setOffsets(); setActive();
  }
  // put the top of the menu right under the header (results start there)
  const toMenuTop = () => { const r = $("menu-root"); scrollTo({ top: r.getBoundingClientRect().top + scrollY - hdr.offsetHeight + 1, behavior: "instant" }); };
  function openSearch() {
    catMenu(false);
    $("sb-search").hidden = false; $("sb-open").hidden = true; $("sb-open").setAttribute("aria-expanded", "true");
    document.querySelector(".sb-chips").hidden = true; $("sb-catbtn").hidden = true;
    toMenuTop(); $("sb-q").focus();
  }
  function closeSearch() {
    $("sb-q").value = ""; applySearch("");
    $("sb-search").hidden = true; $("sb-open").hidden = false; $("sb-open").setAttribute("aria-expanded", "false");
    document.querySelector(".sb-chips").hidden = false; $("sb-catbtn").hidden = false;
    setOffsets(); toMenuTop(); $("sb-open").focus();
  }
  document.addEventListener("click", (e) => {
    if (e.target.closest("#sb-open")) openSearch();
    else if (e.target.closest("#sb-close")) closeSearch();
  });
  // fade the chip row's edge only while more chips are hidden off to the right
  document.addEventListener("scroll", (e) => { const r = e.target; if (r.classList?.contains("sb-chips")) r.classList.toggle("at-end", r.scrollLeft + r.clientWidth >= r.scrollWidth - 4); }, true);
  document.addEventListener("input", (e) => {
    if (e.target.id !== "sb-q") return;
    applySearch(e.target.value);
    const r = $("menu-root"); if (r.getBoundingClientRect().top < hdr.offsetHeight - 2) toMenuTop();
  });
  document.addEventListener("keydown", (e) => {
    if (e.target.id !== "sb-q") return;
    if (e.key === "Escape") { e.stopPropagation(); closeSearch(); }
    if (e.key === "Enter") { e.preventDefault(); e.target.blur(); }
  });

  function renderMenu() {
    const root = $("menu-root");
    const bySection = new Map();
    menu.products.forEach((p) => { if (!bySection.has(p.section_id)) bySection.set(p.section_id, []); bySection.get(p.section_id).push(p); });
    const cats = (menu.categories || [])
      .map((c) => ({ ...c, sections: c.sections.map((s) => ({ ...s, products: bySection.get(s.id) || [] })).filter((s) => s.products.length) }))
      .filter((c) => c.sections.length);
    if (!cats.length) {
      root.innerHTML = `<section class="block"><div class="wrap"><p class="menu-status">Menu belum tersedia. Pesan langsung lewat <a href="https://wa.me/${WA}" target="_blank" rel="noopener">WhatsApp</a>.</p></div></section>`;
      $("nav-menus").innerHTML = "";
      return;
    }
    root.innerHTML = shopBarHTML(cats) + cats.map(catHTML).join("") +
      `<section class="block sb-none" id="sb-empty" hidden><div class="wrap"><p class="op-empty">Menu yang kamu cari belum ada. Coba kata lain, atau <a href="https://wa.me/${WA}" target="_blank" rel="noopener">tanya kami lewat WhatsApp</a>.</p></div></section>`;
    indexSearch();
    $("nav-menus").innerHTML = cats.map((c) => `<a href="#${esc(c.slug)}">${esc(c.name)}</a>`).join("");
    $("see-menu").href = "#" + cats[0].slug;
    navLinks = [...root.querySelectorAll(".sb-chips a")];
    refreshCards();
    setOffsets(); setActive();
    // jump to an anchor from the URL once the menu exists (e.g. camilanika.github.io/#camilan)
    if (location.hash && !renderMenu.jumped) { renderMenu.jumped = true; document.getElementById(location.hash.slice(1))?.scrollIntoView(); }
  }

  const productById = (id) => menu.products.find((p) => p.id === +id);

  function selection(card) {
    const p = productById(card.dataset.product);
    const sel = {}, choices = {};
    card.querySelectorAll(".chips").forEach((g) => {
      const v = g.querySelector('[aria-pressed="true"]')?.dataset.v;
      if (g.dataset.attr) sel[g.dataset.attr] = v; else choices[g.dataset.label] = v;
    });
    if (usesSize(p) && !sel[SIZE_ATTR]) sel[SIZE_ATTR] = size;
    const variant = p.variants.find((v) => p.attr_names.every((a) => v.attrs?.[a] === sel[a]));
    const addonBox = card.querySelector("[data-addon]");
    const addon = !!(addonBox && addonBox.checked && variant && variant.addon_price != null);
    return { p, variant, choices, addon };
  }

  const inCartOf = (vid) => cart.filter((l) => l.variant_id === vid).reduce((s, l) => s + l.qty, 0);
  const leftOf = (v) => (v.available == null ? Infinity : v.available - inCartOf(v.id));
  // the sheet (one product, the options chosen in it)
  function updateCard(card) {
    if (!card) return;
    const { p, variant, addon } = selection(card);
    const priceEl = card.querySelector("[data-price]"), btn = card.querySelector("[data-add]"), tag = card.querySelector("[data-stock]");
    const wrap = card.querySelector("[data-addon-wrap]"), nEl = card.querySelector("[data-n]");
    if (!variant) {
      priceEl.innerHTML = "–"; btn.disabled = true; btn.textContent = "Tidak tersedia"; tag.textContent = ""; if (wrap) wrap.hidden = true;
      return;
    }
    const sz = variant.attrs?.[SIZE_ATTR];
    priceEl.innerHTML = `${rp(variant.price)}${sz && SIZES[sz] ? `<small>${esc(SIZES[sz])}</small>` : ""}`;
    if (wrap) {
      wrap.closest(".opt").hidden = variant.addon_price == null;
      card.querySelector("[data-addon-price]").textContent = variant.addon_price != null ? "+" + rp(variant.addon_price) : "";
    }
    const left = leftOf(variant);
    let n = Math.max(1, Math.min(+nEl.textContent || 1, left === Infinity ? 99 : Math.max(left, 1)));
    nEl.textContent = n;
    card.querySelector('[data-step="-1"]').disabled = n <= 1;
    card.querySelector('[data-step="1"]').disabled = n >= left || n >= 99;
    tag.className = "stock-tag" + (variant.available != null && variant.available <= 0 ? " out" : "");
    tag.textContent = variant.available == null ? "" : variant.available <= 0 ? "Stok habis" : variant.available <= 5 ? `Sisa ${variant.available}` : "";
    btn.disabled = !shop.open || left <= 0;
    btn.textContent = !shop.open ? "Toko tutup" : variant.available != null && variant.available <= 0 ? "Habis" : left <= 0 ? "Stok di keranjang"
      : `Tambah · ${rp((variant.price + (addon ? variant.addon_price : 0)) * n)}`;
  }
  // a menu card: lowest price, sold out / closed state, how many are in the cart
  function updateMenuCard(card) {
    const p = productById(card.dataset.card); if (!p) return;
    const btn = card.querySelector("[data-pick]"), tag = card.querySelector("[data-stock]"), q = card.querySelector("[data-qty]");
    const prices = [...new Set(p.variants.map((v) => v.price))];
    card.querySelector("[data-from]").innerHTML = (prices.length > 1 ? '<small>mulai</small> ' : "") + rp(Math.min(...prices));
    const n = cart.filter((l) => l.product_id === p.id).reduce((s, l) => s + l.qty, 0);
    q.hidden = !n; q.textContent = n; q.setAttribute("aria-label", `${n} di keranjang`);
    const soldOut = p.variants.every((v) => v.available != null && v.available <= 0);
    const full = !soldOut && p.variants.every((v) => leftOf(v) <= 0);
    btn.disabled = !shop.open || soldOut || (full && !hasOptions(p));
    btn.textContent = !shop.open ? "Toko tutup" : soldOut ? "Habis" : full && !hasOptions(p) ? "Stok di keranjang" : "Tambah";
    tag.className = "stock-tag" + (soldOut ? " out" : "");
    const avail = p.variants.filter((v) => v.available != null).map((v) => v.available);
    tag.textContent = soldOut ? "Stok habis" : avail.length === p.variants.length && Math.max(...avail) <= 5 ? `Sisa ${Math.max(...avail)}` : "";
  }
  function refreshCards() {
    document.querySelectorAll("[data-card]").forEach(updateMenuCard);
    updateCard(document.querySelector("#opt-sheet [data-product]"));
  }

  // ---- option sheet
  let sheetFrom = null;
  function openSheet(p, from) {
    sheetFrom = from || null;
    $("opt-body").innerHTML = sheetHTML(p);
    updateCard($("opt-body").firstElementChild);
    $("opt-bg").hidden = false; $("opt-sheet").hidden = false;
    document.body.classList.add("sheet-open");
    requestAnimationFrame(() => $("opt-sheet").classList.add("open"));
    $("opt-close").focus();
  }
  function closeSheet() {
    if ($("opt-sheet").hidden) return;
    $("opt-sheet").classList.remove("open"); $("opt-bg").hidden = true; $("opt-sheet").hidden = true;
    document.body.classList.remove("sheet-open");
    $("opt-body").innerHTML = "";
    sheetFrom?.focus?.({ preventScroll: true }); sheetFrom = null;
  }
  // focus stays inside the sheet while it is open
  document.addEventListener("keydown", (e) => {
    if ($("opt-sheet").hidden) return;
    if (e.key === "Escape") { e.stopPropagation(); closeSheet(); return; }
    if (e.key !== "Tab") return;
    const f = [...$("opt-sheet").querySelectorAll("button:not([disabled]),input")].filter((x) => x.offsetParent);
    if (!f.length) return;
    if (e.shiftKey && document.activeElement === f[0]) { e.preventDefault(); f[f.length - 1].focus(); }
    else if (!e.shiftKey && document.activeElement === f[f.length - 1]) { e.preventDefault(); f[0].focus(); }
  }, true);
  document.addEventListener("click", (e) => {
    if (e.target.closest("#opt-close") || e.target.id === "opt-bg") { closeSheet(); return; }
    const st = e.target.closest("[data-step]");
    if (st) { const card = st.closest("[data-product]"), nEl = card.querySelector("[data-n]"); nEl.textContent = Math.max(1, +nEl.textContent + +st.dataset.step); updateCard(card); return; }
    const pick = e.target.closest("[data-pick]");
    if (!pick) return;
    const p = productById(pick.closest("[data-card]").dataset.card);
    if (hasOptions(p)) { openSheet(p, pick); return; }
    // nothing to choose: straight into the cart
    const v = p.variants[0];
    if (!v || !shop.open || leftOf(v) <= 0) return;
    addLine({ key: `${v.id}|{}|false`, variant_id: v.id, product_id: p.id, choices: {}, addon: false, name: p.name, detail: v.name || "", price: v.price });
    refreshCards();
    pick.classList.remove("added"); void pick.offsetWidth; pick.classList.add("added"); pick.textContent = "Ditambahkan ✓";
    setTimeout(() => updateMenuCard(pick.closest("[data-card]")), 1100);
  });

  document.addEventListener("click", (e) => {
    const c = e.target.closest(".chip");
    if (c) {
      c.parentElement.querySelectorAll(".chip").forEach((b) => b.setAttribute("aria-pressed", b === c));
      if (c.parentElement.dataset.attr === SIZE_ATTR) size = c.dataset.v;
      const card = c.closest("[data-product]"); if (card) updateCard(card);
      return;
    }
    const add = e.target.closest("[data-add]");
    if (add) {
      const card = add.closest("[data-product]");
      const { p, variant, choices, addon } = selection(card);
      if (!variant) return;
      const flavor = variant.attrs?.Rasa;
      // "Flavored Americano" + Peach -> "Peach Americano"
      const name = flavor && usesSize(p) ? `${flavor} ${p.name.replace(/^Flavou?red\s+/i, "")}` : p.name;
      const sz = variant.attrs?.[SIZE_ATTR];
      const detailParts = [usesSize(p) ? `${sz} · ${SIZES[sz] || ""}` : variant.name, ...Object.values(choices), addon ? p.addon_label.toLowerCase() : null];
      const n = Math.max(1, Math.min(+card.querySelector("[data-n]")?.textContent || 1, leftOf(variant)));
      addLine({
        key: `${variant.id}|${JSON.stringify(choices)}|${addon}`, variant_id: variant.id, product_id: p.id,
        choices, addon, name, detail: detailParts.filter(Boolean).join(" · "),
        price: variant.price + (addon ? variant.addon_price : 0),
      }, null, n);
      toast(`${n}× ${name} masuk keranjang`);
      closeSheet(); refreshCards();
    }
  });
  document.addEventListener("change", (e) => { if (e.target.matches("[data-addon]")) updateCard(e.target.closest("[data-product]")); });


  // sticky submenu bar
  const hdr = document.querySelector("header");
  let navLinks = [];
  function setOffsets() {
    const bar = document.querySelector(".menu-bar");
    document.documentElement.style.setProperty("--hdr", hdr.offsetHeight + "px");
    document.documentElement.style.setProperty("--bar", (bar ? bar.offsetHeight : 0) + "px");
    document.documentElement.style.setProperty("--sbar", ($("shopbar")?.offsetHeight || 0) + "px");
  }
  function setActive() {
    const bar = document.querySelector(".menu-bar"), sbar = $("shopbar");
    const line = hdr.offsetHeight + (sbar ? sbar.offsetHeight : 0) + (bar ? bar.offsetHeight : 0) + 40;
    let cur = navLinks[0]?.getAttribute("href").slice(1) ?? null;
    navLinks.forEach((a) => { const el = document.getElementById(a.getAttribute("href").slice(1)); if (el && !el.hidden && el.getBoundingClientRect().top <= line) cur = el.id; });
    // reaching a main menu's heading switches to that menu (its first submenu) even before its first submenu
    let catNow = null;
    document.querySelectorAll("#menu-root .cat").forEach((c) => { if (!c.hidden && c.getBoundingClientRect().top <= line) catNow = c.id; });
    const curLink = navLinks.find((a) => a.getAttribute("href") === "#" + cur);
    if (catNow && curLink && curLink.dataset.cat !== catNow) { const first = navLinks.find((a) => a.dataset.cat === catNow); if (first) cur = first.getAttribute("href").slice(1); }
    let active = null;
    navLinks.forEach((a) => { const on = a.getAttribute("href") === "#" + cur; a.setAttribute("aria-current", on); if (on) active = a; });
    const cat = active?.dataset.cat;
    if (cat && cat !== setActive.cat) {
      setActive.cat = cat;
      navLinks.forEach((a) => { a.hidden = a.dataset.cat !== cat; });
      $("sb-catname").textContent = document.querySelector(`#sb-cats a[href="#${cat}"]`)?.textContent || "";
      setActive.last = null;
    }
    // keep the active chip in view inside the scrolling chip row
    if (active && active !== setActive.last) {
      setActive.last = active;
      const row = active.parentElement;
      requestAnimationFrame(() => row.scrollTo({ left: row.scrollLeft + active.getBoundingClientRect().left - row.getBoundingClientRect().left - (row.clientWidth - active.offsetWidth) / 2, behavior: "smooth" }));
    }
  }
  addEventListener("resize", setOffsets);
  addEventListener("scroll", setActive, { passive: true });

  // ------------------------------------------------------------------ promo banner
  const mainPromo = () => menu.promotions.find((p) => p.min_spend > 0) || menu.promotions[0] || null;
  function renderPromo() {
    const pr = mainPromo(), box = $("promo-box");
    if (!pr) { box.hidden = true; return; }
    box.hidden = false;
    $("promo-big").innerHTML = pr.discount_type === "free_item" ? "FREE" : pr.discount_type === "percent" ? `${pr.value}%` : esc(rp(pr.value).replace("Rp", "Rp "));
    const lower = (t) => t.charAt(0).toLowerCase() + t.slice(1);
    const what = pr.discount_type === "free_item" ? lower(pr.gift_text) : pr.discount_type === "percent" ? `diskon ${pr.value}%` : `potongan ${rp(pr.value)}`;
    $("promo-title").textContent = pr.min_spend > 0 ? `Belanja di atas ${rp(pr.min_spend)}, dapat ${what}` : pr.name;
    $("promo-desc").textContent = pr.description || "";
  }

  // ------------------------------------------------------------------ cart
  function addLine(item, btn, n = 1) {
    const ex = cart.find((l) => l.key === item.key);
    ex ? (ex.qty += n) : cart.push({ ...item, qty: n });
    save(); renderCart(); scheduleQuote();
    if (btn) { btn.classList.remove("added"); void btn.offsetWidth; btn.classList.add("added"); const t = btn.innerHTML; btn.textContent = "Ditambahkan ✓"; setTimeout(() => { if (btn.textContent === "Ditambahkan ✓") btn.innerHTML = t; }, 1100); }
  }
  const subtotal = () => cart.reduce((s, l) => s + l.price * l.qty, 0);
  const cartItems = () => cart.map((l) => ({ variant_id: l.variant_id, quantity: l.qty, addon: l.addon, choices: l.choices }));

  function syncCartWithMenu() {
    // refresh prices; drop lines whose variant disappeared
    cart = cart.filter((l) => {
      const p = productById(l.product_id), v = p?.variants.find((x) => x.id === l.variant_id);
      if (!v) return false;
      l.price = v.price + (l.addon && v.addon_price != null ? v.addon_price : 0);
      if (l.addon && v.addon_price == null) l.addon = false;
      return true;
    });
    save();
  }

  function buildMsg(total) {
    const name = $("cust-name").value.trim(), phone = $("cust-phone").value.trim(), addr = $("cust-addr").value.trim();
    let m = "Halo CamilaNika, saya mau pesan:\n";
    cart.forEach((l) => (m += `- ${l.qty}x ${l.name} (${l.detail}) = ${rp(l.price * l.qty)}\n`));
    m += `\nTotal: ${rp(total)}`;
    (quote?.gifts || []).forEach((g) => (m += `\n(Dapat ${g.gift})`));
    if (promoCode) m += `\nKode promo: ${promoCode}`;
    if (name) m += `\nNama: ${name}`;
    if (phone) m += `\nNo. WA: ${phone}`;
    if (addr) m += `\nAlamat/catatan: ${addr}`;
    if (deliv.loc) m += `\nLokasi: ${mapsLink(deliv.loc.lat, deliv.loc.lng)}`;
    const ds = deliveryState();
    if (deliv.settings?.enabled && deliv.quote?.ok) m += `\nOngkir: ${ds.fee ? rp(ds.fee) : "gratis"}`;
    const sd = shipDiscount(quote && quote.subtotal === subtotal() ? quote : null, ds.fee);
    if (sd) m += `\nPotongan ongkir (voucher): −${rp(sd)}`;
    return m;
  }

  // a voucher that only takes money off the ongkir: never more than the ongkir itself
  const shipDiscount = (q, fee) => (q?.shipping_cap ? Math.min(q.shipping_cap, fee) : 0);
  // contextual cart bar: same count and total as the cart drawer; hidden while the cart is empty
  function renderCartBar(count, total) {
    const bar = $("cart-bar"), was = renderCartBar.count || 0;
    bar.hidden = !count;
    $("cb-count").textContent = count;
    $("cb-items").textContent = `${count} item`;
    $("cb-total").textContent = rp(total);
    bar.setAttribute("aria-label", `Lihat keranjang: ${count} item, total ${rp(total)}`);
    if (count > was && was) { bar.classList.remove("bump"); void bar.offsetWidth; bar.classList.add("bump"); }
    renderCartBar.count = count;
    // leave room at the bottom of the page so the bar never covers the last content
    document.documentElement.style.setProperty("--cartbar", count ? bar.offsetHeight + 24 + "px" : "0px");
  }
  function renderCart() {
    const sub = subtotal(), count = cart.reduce((s, l) => s + l.qty, 0);
    const q = quote && quote.subtotal === sub ? quote : null;
    const ds = deliveryState();
    const sd = shipDiscount(q, ds.fee);
    const disc = q ? q.discount : 0, total = sub - disc + ds.fee - sd;
    $("shipdisc-row").hidden = !q?.shipping_cap;
    $("shipdisc-label").textContent = `Potongan ongkir (${q?.voucher_code || "voucher"})`;
    $("cart-shipdisc").textContent = sd ? "−" + rp(sd) : "–";
    $("shipdisc-note").hidden = !(q?.shipping_cap && !ds.fee && !ds.blocking);
    $("shipdisc-note").textContent = ds.fee ? "" : (deliv.settings?.enabled && !deliv.loc ? "Pilih lokasi pengantaran dulu supaya potongan ongkir bisa dihitung." : ERRORS.VOUCHER_NO_SHIPPING);
    $("cart-count").textContent = count;
    $("cart-count").hidden = !count;
    renderCartBar(count, total);
    $("cart-subtotal").textContent = rp(sub);
    $("disc-row").hidden = !disc;
    $("disc-label").textContent = q?.promo_name ? `Diskon (${q.promo_name})` : "Diskon";
    $("cart-discount").textContent = "−" + rp(disc);
    $("cart-total").textContent = rp(total);
    $("ship-row").hidden = !(deliv.settings?.enabled && deliv.loc && deliv.quote?.ok);
    $("cart-ship").textContent = ds.fee ? rp(ds.fee) : "Gratis";
    $("loc-info").textContent = ds.text;
    $("loc-info").className = "promo-msg" + (ds.blocking && deliv.loc ? " loc-bad" : "");
    $("pick-loc").textContent = deliv.loc ? "📍 Ubah lokasi di peta" : "📍 Pilih lokasi di peta";
    const gifts = q?.gifts || [];
    $("gift-msg").hidden = !gifts.length;
    $("gift-msg").textContent = gifts.map((g) => "🎁 " + g.gift).join(" · ");
    $("cart-lines").innerHTML = cart.length ? cart.map((l, i) => `
      <div class="line"><b>${esc(l.name)}</b><span class="lp num">${rp(l.price * l.qty)}</span>
        <small>${esc(l.detail)} · ${rp(l.price)}</small>
        <div class="qty"><button type="button" data-q="${i}" data-d="-1" aria-label="Kurangi">−</button><span class="num">${l.qty}</span><button type="button" data-q="${i}" data-d="1" aria-label="Tambah">+</button></div>
      </div>`).join("") : `<div class="empty"><img src="img/logo.jpg" alt="" style="width:110px;margin:0 auto;border-radius:50%"><b>Keranjang masih kosong</b><span>Pilih minuman atau cireng, lalu tekan Tambah ke keranjang.</span></div>`;

    const pr = mainPromo();
    const bar = document.querySelector(".drawer .progress");
    if (pr && pr.min_spend > 0) {
      bar.hidden = false;
      $("promo-bar").style.width = Math.min(100, (sub / pr.min_spend) * 100) + "%";
      const what = pr.discount_type === "free_item" ? pr.gift_text.charAt(0).toLowerCase() + pr.gift_text.slice(1) : pr.name;
      $("promo-msg").textContent = sub >= pr.min_spend ? `Yeay! Kamu dapat ${what}.` : `Tambah ${rp(pr.min_spend - sub)} lagi untuk dapat ${what}.`;
    } else { bar.hidden = true; $("promo-msg").textContent = ""; }

    $("to-checkout").hidden = !cart.length || !$("checkout").hidden;
    if (!cart.length) $("checkout").hidden = true;
    $("send-wa").href = cart.length ? `https://wa.me/${WA}?text=${encodeURIComponent(buildMsg(total))}` : `https://wa.me/${WA}`;
    // ordering is off while the shop is closed
    $("shop-cart-note").hidden = shop.open;
    $("shop-cart-note").textContent = shopClosedText();
    $("to-checkout").disabled = !shop.open;
    $("pay-btn").disabled = !shop.open || deliveryState().blocking;
    $("send-wa").classList.toggle("is-disabled", !shop.open);
    $("send-wa").setAttribute("aria-disabled", String(!shop.open));
  }

  // ------------------------------------------------------------------ delivery location (OpenStreetMap, free)
  const mapsLink = (lat, lng) => `https://www.google.com/maps?q=${lat},${lng}`;
  let deliv = { settings: null, loc: store.get("cn-loc", null), quote: null };
  async function loadDeliverySettings() {
    const { data } = await sb.rpc("delivery_settings");
    if (data) deliv.settings = data;
    if (deliv.loc) await quoteDelivery();
  }
  async function quoteDelivery() {
    if (!deliv.loc) { deliv.quote = null; return; }
    const { data } = await sb.rpc("delivery_quote", { p_lat: deliv.loc.lat, p_lng: deliv.loc.lng });
    deliv.quote = data || null;
  }
  const fmtKm = (km) => (km == null ? "" : `${String(Math.round(km * 10) / 10).replace(".", ",")} km`);
  function deliveryState() {
    const s = deliv.settings, q = deliv.quote;
    const enabled = !!s?.enabled;
    if (!deliv.loc) return { fee: 0, blocking: enabled, text: enabled ? "Pilih lokasi di peta untuk menghitung ongkir." : "" };
    if (q && !q.ok) return { fee: 0, blocking: true, text: q.error === "OUT_OF_RANGE" ? `Lokasi ${fmtKm(q.km)} dari toko, di luar jangkauan antar (maks ${fmtKm(Number(q.max_km))}). Chat kami lewat WhatsApp untuk atur pengiriman.` : "Lokasi belum valid, pilih ulang di peta." };
    if (!enabled) return { fee: 0, blocking: false, text: `📍 Lokasi dipilih (${fmtKm(q?.km)} dari toko)` };
    return { fee: q?.fee || 0, blocking: false, text: `📍 ${fmtKm(q?.km)} dari toko · ${q?.fee ? "ongkir " + rp(q.fee) : "gratis ongkir"}` };
  }

  // Leaflet loads only when the map is opened
  let leafletLoading = null;
  function loadLeaflet() {
    if (window.L) return Promise.resolve();
    if (leafletLoading) return leafletLoading;
    leafletLoading = new Promise((res, rej) => {
      const css = document.createElement("link"); css.rel = "stylesheet"; css.href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css";
      document.head.appendChild(css);
      const js = document.createElement("script"); js.src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js";
      js.onload = res; js.onerror = () => { leafletLoading = null; rej(new Error("leaflet")); };
      document.head.appendChild(js);
    });
    return leafletLoading;
  }
  let map, pin, pinQuoteTimer;
  async function openMap() {
    $("map-modal").hidden = false;
    $("map-info").textContent = "Memuat peta…";
    try { await loadLeaflet(); } catch (e) { $("map-info").textContent = "Peta gagal dimuat. Tulis alamat lengkap saja ya."; return; }
    const s = deliv.settings || { origin_lat: -6.5561334, origin_lng: 106.7827129 };
    const start = deliv.loc || { lat: s.origin_lat, lng: s.origin_lng };
    if (!map) {
      map = L.map("map", { zoomControl: true }).setView([start.lat, start.lng], deliv.loc ? 17 : 14);
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>' }).addTo(map);
      L.circleMarker([s.origin_lat, s.origin_lng], { radius: 7, color: "#D9586F", fillOpacity: .9 }).addTo(map).bindTooltip("CamilaNika");
      pin = L.marker([start.lat, start.lng], { draggable: true }).addTo(map);
      pin.on("dragend", () => previewPin());
      map.on("click", (e) => { pin.setLatLng(e.latlng); previewPin(); });
    } else {
      pin.setLatLng([start.lat, start.lng]); map.setView([start.lat, start.lng], deliv.loc ? 17 : 14);
    }
    setTimeout(() => map.invalidateSize(), 50);
    $("map-info").textContent = deliv.loc ? "Geser pin kalau perlu, lalu Simpan lokasi." : "Ketuk peta atau geser pin ke rumah kamu, lalu Simpan lokasi.";
    if (deliv.loc) previewPin();
  }
  function previewPin() {
    clearTimeout(pinQuoteTimer);
    pinQuoteTimer = setTimeout(async () => {
      const { lat, lng } = pin.getLatLng();
      const { data: q } = await sb.rpc("delivery_quote", { p_lat: lat, p_lng: lng });
      if (!q) return;
      $("map-info").textContent = !q.ok
        ? (q.error === "OUT_OF_RANGE" ? `${fmtKm(q.km)} dari toko, di luar jangkauan antar (maks ${fmtKm(Number(q.max_km))}).` : "Lokasi tidak valid.")
        : !q.enabled ? `${fmtKm(q.km)} dari toko.` : `${fmtKm(q.km)} dari toko · ${q.fee ? "ongkir " + rp(q.fee) : "gratis ongkir"}`;
    }, 300);
  }
  async function saveMapLocation() {
    const { lat, lng } = pin.getLatLng();
    deliv.loc = { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6 };
    store.set("cn-loc", deliv.loc);
    $("map-modal").hidden = true;
    await quoteDelivery();
    renderCart();
    // fill the address box from the map if it's still empty (free OpenStreetMap lookup, once per save)
    if (!$("cust-addr").value.trim()) {
      try {
        const r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=18&accept-language=id&lat=${deliv.loc.lat}&lon=${deliv.loc.lng}`);
        const j = await r.json();
        if (j?.display_name && !$("cust-addr").value.trim()) {
          $("cust-addr").value = j.display_name.split(", ").slice(0, 5).join(", ") + "\n(tambahkan blok/no. rumah & patokan)";
          renderCart();
        }
      } catch (e) {}
    }
  }
  function useMyLocation() {
    if (!navigator.geolocation) { $("map-info").textContent = "Perangkat ini tidak bisa membagikan lokasi."; return; }
    $("map-info").textContent = "Mencari lokasi kamu…";
    navigator.geolocation.getCurrentPosition(
      (p) => { const ll = [p.coords.latitude, p.coords.longitude]; pin.setLatLng(ll); map.setView(ll, 17); previewPin(); },
      () => { $("map-info").textContent = "Lokasi tidak diizinkan. Geser pin secara manual ya."; },
      { enableHighAccuracy: true, timeout: 10000 });
  }
  $("pick-loc").addEventListener("click", openMap);
  $("map-save").addEventListener("click", saveMapLocation);
  $("map-gps").addEventListener("click", useMyLocation);
  $("map-close").addEventListener("click", () => { $("map-modal").hidden = true; });
  $("map-modal").addEventListener("click", (e) => { if (e.target.id === "map-modal") $("map-modal").hidden = true; });

  // chat with the admin about a paid order (delivery details)
  function deliveryChatLink(o) {
    let m = `Halo CamilaNika, pesanan saya ${o.order_number} sudah dibayar. Mohon diproses pengirimannya ya.`;
    if (o.address) m += `\nAlamat: ${o.address}`;
    if (o.delivery_lat != null) m += `\nLokasi: ${mapsLink(o.delivery_lat, o.delivery_lng)}`;
    m += `\nDetail tambahan (patokan / jam antar): `;
    return `https://wa.me/${WA}?text=${encodeURIComponent(m)}`;
  }

  // ------------------------------------------------------------------ shop open / closed
  function shopClosedText() {
    if (shop.open) return "";
    if (shop.reason === "schedule") return `Toko sedang tutup. Buka setiap hari pukul ${shop.open_time}–${shop.close_time} WIB.${shop.message ? " " + shop.message : ""}`;
    return shop.message || "Toko sedang tutup untuk sementara. Sampai jumpa lagi!";
  }
  function renderShop() {
    const banner = $("shop-banner");
    banner.hidden = shop.open;
    banner.textContent = shopClosedText();
    refreshCards();
    renderCart();
  }
  async function loadShop() {
    const { data, error } = await sb.rpc("shop_status");
    if (!error && data) {
      const changed = data.open !== shop.open;
      shop = data;
      if (changed || !shop.open) renderShop();
    }
  }
  setInterval(loadShop, 60000);

  const showErr = (msg) => { $("cart-err").hidden = !msg; $("cart-err").textContent = msg || ""; };

  let quoteTimer = null;
  function scheduleQuote() { clearTimeout(quoteTimer); quoteTimer = setTimeout(runQuote, 350); }
  async function runQuote(strictCode = false) {
    if (!cart.length) { quote = null; showErr(""); renderCart(); return; }
    let { data, error } = await sb.rpc("quote_cart", { p_items: cartItems(), p_promo_code: promoCode || null });
    if (error && /PROMO_NOT_APPLICABLE|VOUCHER_/.test(error.message) && !strictCode) {
      promoCode = ""; $("promo-code").value = "";
      ({ data, error } = await sb.rpc("quote_cart", { p_items: cartItems(), p_promo_code: null }));
    }
    if (error) {
      quote = null;
      if (/OUT_OF_STOCK|PRODUCT_UNAVAILABLE/.test(error.message)) await refreshMenu();
      if (/OUT_OF_STOCK:(\d+):(\d+)/.test(error.message)) {
        const [, vid, avail] = error.message.match(/OUT_OF_STOCK:(\d+):(\d+)/);
        trimVariant(+vid, +avail);
      }
      showErr(errMsg(error.message));
    } else { quote = data; showErr(""); }
    renderCart();
    return { data, error };
  }
  function trimVariant(vid, avail) {
    let left = avail;
    cart = cart.filter((l) => {
      if (l.variant_id !== vid) return true;
      l.qty = Math.min(l.qty, left); left -= l.qty;
      return l.qty > 0;
    });
    save();
  }

  $("cart-lines").addEventListener("click", (e) => {
    const b = e.target.closest("[data-q]"); if (!b) return;
    const l = cart[+b.dataset.q]; l.qty += +b.dataset.d;
    if (l.qty <= 0) cart.splice(+b.dataset.q, 1);
    save(); renderCart(); scheduleQuote();
    refreshCards();
  });
  ["cust-name", "cust-phone", "cust-addr"].forEach((id) => $(id).addEventListener("input", renderCart));
  $("send-wa").addEventListener("click", (e) => { if (!shop.open) { e.preventDefault(); showErr(shopClosedText()); } });
  $("to-checkout").addEventListener("click", () => { $("checkout").hidden = false; renderCart(); $("cust-name").focus(); });
  $("apply-code").addEventListener("click", async () => {
    promoCode = $("promo-code").value.trim().toUpperCase();
    const btn = $("apply-code"); btn.disabled = true;
    const { error } = await runQuote(true);
    btn.disabled = false;
    if (error && /PROMO_NOT_APPLICABLE|VOUCHER_/.test(error.message)) { const m = errMsg(error.message); promoCode = ""; await runQuote(); showErr(m); }
    if (!error && promoCode) refreshBadgesSoon();
  });
  $("promo-code").addEventListener("keydown", (e) => { if (e.key === "Enter") $("apply-code").click(); });

  // drawers
  const bg = $("drawer-bg");
  const openDrawer = (el) => { closeAll(); el.classList.add("open"); el.setAttribute("aria-hidden", "false"); bg.hidden = false; el.querySelector(".icon-btn")?.focus(); };
  const closeAll = () => { document.querySelectorAll(".drawer.open").forEach((d) => { d.classList.remove("open"); d.setAttribute("aria-hidden", "true"); }); bg.hidden = true; };
  document.querySelectorAll("[data-open-cart]").forEach((b) => b.addEventListener("click", () => { openDrawer($("drawer")); scheduleQuote(); }));
  $("close-cart").addEventListener("click", closeAll); bg.addEventListener("click", closeAll);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") { if (document.querySelector(".drawer.open")) closeAll(); else if (!$("orders-page").hidden) closeOrders(); } });

  // ------------------------------------------------------------------ payment
  let snapLoading = null;
  function loadSnap() {
    if (window.snap) return Promise.resolve();
    if (snapLoading) return snapLoading;
    snapLoading = new Promise((res, rej) => {
      const s = document.createElement("script");
      s.src = CFG.MIDTRANS_IS_PRODUCTION ? "https://app.midtrans.com/snap/snap.js" : "https://app.sandbox.midtrans.com/snap/snap.js";
      s.dataset.clientKey = CFG.MIDTRANS_CLIENT_KEY;
      s.onload = res; s.onerror = () => { snapLoading = null; rej(new Error("snap")); };
      document.head.appendChild(s);
    });
    return snapLoading;
  }

  const rememberOrder = (o) => {
    const list = store.get("cn-orders", []).filter((x) => x.order_number !== o.order_number);
    list.unshift({ order_number: o.order_number, access_token: o.access_token, token: o.token || null, at: Date.now() });
    store.set("cn-orders", list.slice(0, 30));
  };
  const findOrder = (num) => store.get("cn-orders", []).find((x) => x.order_number === num);

  function openSnap(token, orderNumber) {
    window.snap.pay(token, {
      onSuccess: () => { clearCart(); showStatus(orderNumber, true); },
      onPending: () => { clearCart(); showStatus(orderNumber, true); },
      onError: () => showStatus(orderNumber, true),
      onClose: () => showStatus(orderNumber, true),
    });
  }
  function clearCart() { cart = []; promoCode = ""; quote = null; $("promo-code").value = ""; save(); renderCart(); refreshCards(); }

  $("pay-btn").addEventListener("click", async () => {
    showErr("");
    const name = $("cust-name").value.trim(), phone = $("cust-phone").value.trim();
    if (!name) { showErr(ERRORS.NAME_REQUIRED); $("cust-name").focus(); return; }
    if (!/^\+?[0-9 \-]{8,16}$/.test(phone)) { showErr("Nomor WhatsApp belum benar."); $("cust-phone").focus(); return; }
    if (deliveryState().blocking) { showErr(deliveryState().text || ERRORS.LOCATION_REQUIRED); return; }
    if (quote?.shipping_cap && !deliveryState().fee) { showErr($("shipdisc-note").textContent || ERRORS.VOUCHER_NO_SHIPPING); return; }
    const btn = $("pay-btn"), label = btn.querySelector("span");
    btn.disabled = true; label.textContent = "Menyiapkan pembayaran…";
    try {
      const snapReady = loadSnap();
      const { data: s } = await sb.auth.getSession();
      const res = await fetch(`${CFG.SUPABASE_URL}/functions/v1/create-payment`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json", apikey: CFG.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}`,
          ...(s?.session?.access_token ? { "x-user-token": s.session.access_token } : {}),
        },
        body: JSON.stringify({
          items: cartItems(), promo_code: promoCode || null,
          customer: { name, phone, email: $("cust-email").value.trim(), address: $("cust-addr").value.trim(), lat: deliv.loc?.lat ?? null, lng: deliv.loc?.lng ?? null },
        }),
      });
      const out = await res.json().catch(() => ({ error: "PAYMENT_GATEWAY_ERROR" }));
      if (!res.ok || out.error) {
        if (/OUT_OF_STOCK|PRODUCT_UNAVAILABLE/.test(out.detail || out.error)) { await refreshMenu(); await runQuote(); }
        if (/SHOP_CLOSED/.test(out.detail || out.error)) await loadShop();
        showErr(errMsg(out.detail || out.error)); return;
      }
      rememberOrder(out);
      if (out.free) { clearCart(); closeAll(); showStatus(out.order_number, true); return; }
      await snapReady;
      closeAll();
      openSnap(out.token, out.order_number);
    } catch (e) {
      showErr(ERRORS.PAYMENT_GATEWAY_ERROR);
    } finally {
      btn.disabled = false; label.textContent = "Bayar online";
    }
  });

  // ------------------------------------------------------------------ orders page  (#pesanan  and  #pesanan/CN-...)
  const OP = $("orders-page");
  let pollTimer = null, opFilter = "all", opCache = [];
  const ORDER_COLS = "order_number,status,total,subtotal,discount,shipping_discount,promo_code,gifts,created_at,paid_at,expires_at,payment_method,customer_name,phone,address,notes,delivery_fee,delivery_km,delivery_lat,delivery_lng,snap_token,order_items(product_name,variant_name,choices,addon,quantity,unit_price,line_total)";
  // an unpaid order whose 30 minutes are up counts as expired, even before the server tidies it up
  const effStatus = (o) => (o.status === "pending" && o.expires_at && new Date(o.expires_at) <= new Date() ? "expired" : o.status);
  const payToken = (o) => (effStatus(o) === "pending" ? o.snap_token || findOrder(o.order_number)?.token || null : null);
  const fmtDate = (d) => new Date(d).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" });
  const fmtTime = (d) => new Date(d).toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" });
  const itemsOf = (o) => o.items || o.order_items || [];
  const PAY_METHOD = { credit_card: "Kartu kredit/debit", gopay: "GoPay", qris: "QRIS", shopeepay: "ShopeePay", bank_transfer: "Transfer bank (VA)",
    echannel: "Mandiri Bill", permata: "Permata VA", cstore: "Indomaret/Alfamart", akulaku: "Akulaku", kredivo: "Kredivo", free: "Gratis (promo)" };
  const STATUS_MSG = {
    pending: "Pembayaran belum kami terima. Kalau sudah bayar, status berubah otomatis dalam beberapa saat.",
    paid: "Terima kasih! Pembayaran diterima, pesanan segera kami siapkan.",
    processing: "Pesanan sedang disiapkan.", ready: "Pesanan sudah siap dan menunggu kurir.",
    shipping: "Pesanan sedang dalam perjalanan ke alamat kamu.", completed: "Pesanan selesai. Selamat menikmati!",
    expired: "Waktu pembayaran habis, jadi pesanan ini batal otomatis. Silakan pesan lagi.",
    failed: "Pembayaran gagal. Silakan pesan lagi.", cancelled: "Pesanan dibatalkan.",
  };
  const FILTERS = [["all", "Semua"], ["pending", "Belum dibayar"], ["active", "Diproses"], ["completed", "Selesai"], ["closed", "Batal"]];
  const inFilter = (o, f) => {
    const st = effStatus(o);
    return f === "all" || (f === "pending" && st === "pending") || (f === "active" && ["paid", "processing", "ready", "shipping"].includes(st)) ||
      (f === "completed" && st === "completed") || (f === "closed" && ["expired", "failed", "cancelled"].includes(st));
  };

  async function fetchOrder(num) {
    const saved = findOrder(num);
    if (saved) {
      const { data } = await sb.rpc("get_order_status", { p_order_number: num, p_access_token: saved.access_token });
      if (data) return data;
    }
    if (session) {
      const { data } = await sb.from("orders").select(ORDER_COLS).eq("order_number", num).maybeSingle();
      if (data) return { ...data, items: data.order_items };
    }
    return null;
  }

  // the customer's orders: from their account (any device) + orders made on this device without logging in
  async function loadOrders() {
    const byNum = new Map();
    if (session) {
      const { data, error } = await sb.from("orders").select(ORDER_COLS).eq("user_id", session.user.id).order("created_at", { ascending: false }).limit(50);
      if (error) throw error;
      data.forEach((o) => byNum.set(o.order_number, { ...o, items: o.order_items }));
    }
    const saved = store.get("cn-orders", []).filter((r) => !byNum.has(r.order_number));
    const extra = await Promise.all(saved.map((r) => sb.rpc("get_order_status", { p_order_number: r.order_number, p_access_token: r.access_token }).then(({ data }) => data, () => null)));
    extra.filter(Boolean).forEach((o) => byNum.set(o.order_number, o));
    return [...byNum.values()].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  }

  const itemSummary = (o) => {
    const it = itemsOf(o), n = it.reduce((a, i) => a + i.quantity, 0);
    if (!it.length) return "";
    return `${it[0].quantity}× ${it[0].product_name} ${it[0].variant_name}${it.length > 1 ? ` · +${n - it[0].quantity} lainnya` : ""}`;
  };
  const orderRow = (o) => {
    const st = effStatus(o), tok = payToken(o);
    return `<button type="button" class="op-row" data-order="${esc(o.order_number)}">
      <b>${esc(o.order_number)}</b><span class="badge-st ${esc(st)}">${esc(STATUS[st] || st)}</span>
      <span class="meta">${fmtDate(o.created_at)} · ${esc(itemSummary(o))}</span><span class="amt">${rp(o.total)}</span>
      ${tok && o.expires_at ? `<span class="due">Bayar sebelum ${fmtTime(o.expires_at)} →</span>` : ""}
    </button>`;
  };

  // navigation: each view is a history entry, so the phone's back button works
  const opDepth = () => (history.state && history.state.cnOrders) || 0;
  function navOrders(num) {
    const h = num ? "#pesanan/" + encodeURIComponent(num) : "#pesanan";
    if (location.hash === h) return route();
    history.pushState({ cnOrders: opDepth() + 1 }, "", location.pathname + location.search + h);
    route();
  }
  function closeOrders() {
    const d = opDepth();
    if (d) history.go(-d);
    else { history.replaceState(null, "", location.pathname + location.search); route(); }
  }
  function backOrders() {
    if (!/^#pesanan\//.test(location.hash)) return closeOrders();   // list and voucher page: back = close
    if (opDepth() >= 2) return history.back();
    history.replaceState({ cnOrders: Math.max(opDepth(), 1) }, "", location.pathname + location.search + "#pesanan");
    route();
  }
  function navVouchers() {
    if (location.hash === "#voucher") return route();
    history.pushState({ cnOrders: opDepth() + 1 }, "", location.pathname + location.search + "#voucher");
    route();
  }
  function navLoyalty() {
    if (location.hash === "#loyalty") return route();
    history.pushState({ cnOrders: opDepth() + 1 }, "", location.pathname + location.search + "#loyalty");
    route();
  }
  function route() {
    clearTimeout(pollTimer);
    const m = location.hash.match(/^#pesanan(?:\/(.+))?$/), mv = location.hash === "#voucher", ml = location.hash === "#loyalty";
    if (!m && !mv && !ml) { if (!OP.hidden) { OP.hidden = true; document.body.style.overflow = ""; } return; }
    closeAll();
    OP.hidden = false; document.body.style.overflow = "hidden"; OP.scrollTop = 0;
    if (ml) renderLoyaltyPage(); else if (mv) renderVoucherPage(); else if (m[1]) renderOrderDetail(decodeURIComponent(m[1])); else renderOrderList();
  }
  window.addEventListener("popstate", route);
  window.addEventListener("hashchange", route);
  $("op-close").addEventListener("click", closeOrders);
  $("op-back").addEventListener("click", backOrders);
  document.addEventListener("click", (e) => {
    const row = e.target.closest("[data-order]");
    if (row) { e.preventDefault(); navOrders(row.dataset.order); return; }
    if (e.target.closest("[data-open-orders]")) { e.preventDefault(); navOrders(); return; }
    if (e.target.closest("[data-open-vouchers]")) { e.preventDefault(); navVouchers(); return; }
    if (e.target.closest("[data-open-loyalty]")) { e.preventDefault(); navLoyalty(); return; }
    if (e.target.closest("[data-open-notifs]")) { e.preventDefault(); openDrawer(NF); renderNotifs(); return; }
    const cp = e.target.closest("[data-copy]");
    if (cp) { copyText(cp.dataset.copy); return; }
    const ap = e.target.closest("[data-apply]");
    if (ap) applyCode(ap.dataset.apply);
  });
  async function copyText(t) {
    try { await navigator.clipboard.writeText(t); toast(`Kode ${t} disalin`); }
    catch (e) { toast(`Kode: ${t}`); }
  }
  function applyCode(code) {
    if (!OP.hidden) closeOrders();
    setTimeout(() => {
      $("promo-code").value = code;
      openDrawer($("drawer"));
      if (cart.length) { $("checkout").hidden = false; renderCart(); }
      if (!cart.length) { promoCode = code; showErr(""); toast("Kode sudah diisi. Tambahkan menu ke keranjang, nanti langsung terpakai."); return; }
      $("apply-code").click();
    }, 60);
  }
  // after paying (or closing the payment popup) show that order's page
  const showStatus = (num) => navOrders(num);

  async function renderOrderList() {
    $("op-title").textContent = "Pesanan saya";
    const body = $("op-body");
    body.innerHTML = `<p class="form-msg">Memuat pesanan…</p>`;
    try { opCache = await loadOrders(); }
    catch (e) { body.innerHTML = `<p class="form-msg err">Gagal memuat pesanan. Coba lagi sebentar.</p>`; return; }
    if (!/^#pesanan$/.test(location.hash)) return;
    const guestNote = session ? "" : `<p class="op-note">Pesanan tanpa akun hanya tersimpan di perangkat ini. <button type="button" class="linkish" data-open-account>Masuk</button> untuk melihat pesanan dari akun kamu.</p>`;
    if (!opCache.length) {
      body.innerHTML = `<div class="op-empty"><p>Belum ada pesanan.</p><button type="button" class="btn btn-rose" id="op-shop">Lihat menu</button></div>${guestNote}`;
      $("op-shop").addEventListener("click", closeOrders);
      return;
    }
    const draw = () => {
      const list = opCache.filter((o) => inFilter(o, opFilter));
      const count = (f) => opCache.filter((o) => inFilter(o, f)).length;
      body.innerHTML = `
        <div class="op-filters" role="group" aria-label="Saring pesanan">${FILTERS.filter(([f]) => f === "all" || count(f)).map(([f, label]) =>
          `<button type="button" class="chip" data-f="${f}" aria-pressed="${opFilter === f}">${label}${f === "all" ? "" : ` (${count(f)})`}</button>`).join("")}</div>
        <div class="op-list">${list.length ? list.map(orderRow).join("") : `<p class="op-empty">Tidak ada pesanan di sini.</p>`}</div>
        ${guestNote}`;
      body.querySelectorAll("[data-f]").forEach((b) => b.addEventListener("click", () => { opFilter = b.dataset.f; draw(); }));
    };
    if (opFilter !== "all" && !opCache.some((o) => inFilter(o, opFilter))) opFilter = "all";
    draw();
    refreshBadgesSoon();
  }

  async function renderOrderDetail(num) {
    $("op-title").textContent = "Detail pesanan";
    const body = $("op-body");
    body.innerHTML = `<p class="form-msg">Memuat pesanan…</p>`;
    let tries = 0;
    const load = async () => {
      const o = await fetchOrder(num);
      if (location.hash !== "#pesanan/" + encodeURIComponent(num)) return;
      if (!o) {
        body.innerHTML = `<p class="form-msg">Pesanan <b>${esc(num)}</b> tidak ditemukan di perangkat ini. Masuk ke akun yang dipakai saat memesan, atau tanya kami lewat WhatsApp.</p>
          <a class="btn btn-wa" style="justify-content:center" target="_blank" rel="noopener" href="https://wa.me/${WA}?text=${encodeURIComponent("Halo CamilaNika, saya mau tanya pesanan " + num)}">Tanya lewat WhatsApp</a>`;
        return;
      }
      const st = effStatus(o), tok = payToken(o), it = itemsOf(o);
      const ask = `<a class="btn btn-ghost" target="_blank" rel="noopener" href="https://wa.me/${WA}?text=${encodeURIComponent("Halo CamilaNika, saya mau tanya pesanan " + num)}">Tanya lewat WhatsApp</a>`;
      const actions = st === "pending"
        ? (tok ? `<button class="btn btn-rose" type="button" id="od-pay">Lanjutkan pembayaran · ${rp(o.total)}</button>${ask}`
               : `<p class="form-msg">Link pembayaran untuk pesanan ini tidak tersedia di perangkat ini. Kalau sudah bayar, statusnya berubah otomatis; kalau belum, chat kami.</p>${ask}`)
        : ["paid", "processing", "ready", "shipping"].includes(st) ? `<a class="btn btn-wa" target="_blank" rel="noopener" href="${deliveryChatLink(o)}">Chat admin untuk pengiriman</a>`
        : ask;
      const line = (l, r, cls = "") => `<div class="od-line ${cls}"><span>${l}</span><span>${r}</span></div>`;
      body.innerHTML = `
        <div class="od-sec">
          <div class="oc-head"><b>${esc(o.order_number)}</b><span class="badge-st ${esc(st)}">${esc(STATUS[st] || st)}</span></div>
          <small class="od-muted">Dipesan ${fmtDate(o.created_at)}${o.paid_at ? ` · dibayar ${fmtDate(o.paid_at)}` : ""}</small>
          <p class="od-msg">${esc(STATUS_MSG[st] || "")}</p>
          ${tok && o.expires_at ? `<p class="due">Bayar sebelum pukul ${fmtTime(o.expires_at)}, setelah itu pesanan batal otomatis.</p>` : ""}
          <div class="od-actions">${actions}</div>
        </div>
        <div class="od-sec">
          <h4>Rincian</h4>
          ${it.map((i) => line(`${esc(i.product_name)}<small>${esc(i.variant_name)}${Object.values(i.choices || {}).map((c) => " · " + esc(c)).join("")}${i.addon ? " · " + esc(i.addon) : ""} · ${i.quantity}×${i.unit_price ? " " + rp(i.unit_price) : ""}</small>`, rp(i.line_total))).join("")}
          ${(o.gifts || []).map((g) => `<span class="gift-msg">🎁 ${esc(g.gift)}</span>`).join("")}
          ${o.subtotal != null ? line("Subtotal", rp(o.subtotal), "sub") : ""}
          ${o.discount - (o.shipping_discount || 0) > 0 ? line(`Diskon${o.promo_code && !o.shipping_discount ? " (" + esc(o.promo_code) + ")" : ""}`, "−" + rp(o.discount - (o.shipping_discount || 0)), "disc") : ""}
          ${line(`Ongkir${o.delivery_km ? ` <small style="display:inline">(${fmtKm(Number(o.delivery_km))})</small>` : ""}`, o.delivery_fee ? rp(o.delivery_fee) : "Gratis")}
          ${o.shipping_discount ? line(`Potongan ongkir${o.promo_code ? " (" + esc(o.promo_code) + ")" : ""}`, "−" + rp(o.shipping_discount), "disc") : ""}
          ${line("Total", rp(o.total), "total")}
        </div>
        <div class="od-sec">
          <h4>Pengiriman</h4>
          ${o.customer_name ? `<div>${esc(o.customer_name)}${o.phone ? " · " + esc(o.phone) : ""}</div>` : ""}
          <div>${o.address ? esc(o.address) : `<span class="od-muted">Alamat belum diisi</span>`}</div>
          ${o.delivery_lat != null ? `<a href="${mapsLink(o.delivery_lat, o.delivery_lng)}" target="_blank" rel="noopener">📍 Lihat lokasi di peta</a>` : ""}
          ${o.notes ? `<div class="od-muted">Catatan: ${esc(o.notes)}</div>` : ""}
        </div>
        ${o.payment_method ? `<div class="od-sec"><h4>Pembayaran</h4><div>${esc(PAY_METHOD[o.payment_method] || o.payment_method)}</div></div>` : ""}
        <button type="button" class="linkish" data-open-orders style="justify-self:start">← Semua pesanan</button>`;
      $("od-pay")?.addEventListener("click", async (e) => {
        const b = e.currentTarget; b.disabled = true;
        try { await loadSnap(); openSnap(tok, num); }
        catch (err) { b.insertAdjacentHTML("afterend", `<p class="form-msg err">Halaman pembayaran gagal dibuka. Coba lagi.</p>`); }
        finally { b.disabled = false; }
      });
      refreshBadgesSoon();
      if (st === "pending" && ++tries < 60) pollTimer = setTimeout(load, 5000);
    };
    await load();
  }

  // ------------------------------------------------------------------ loyalty (#loyalty + card in Akun saya)
  const loyBar = (pct, label) => `<div class="loy-bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}" aria-label="${esc(label)}"><span style="width:${pct}%"></span></div>`;
  async function fillLoyaltyCard() {
    const el = $("am-loyalty"); if (!el || !session) return;
    const { data, error } = await sb.rpc("my_loyalty");
    if (!$("am-loyalty") || error || !data?.enabled) { if ($("am-loyalty")) $("am-loyalty").innerHTML = ""; return; }
    const nx = data.next;
    $("am-loyalty").innerHTML = `<button type="button" class="loy-card" data-open-loyalty aria-label="Program loyalty: total belanja ${rp(data.spend)}">
      <span class="loy-top"><b>⭐ Loyalty</b><span>${rp(data.spend)}</span></span>
      ${nx ? `${loyBar(nx.percent, `Progres ${nx.percent}% menuju ${rp(nx.threshold)}`)}<small>Belanja <b>${rp(nx.remaining)}</b> lagi untuk ${esc(nx.reward)}</small>`
           : `<small>Semua hadiah loyalty sudah terbuka 🎉</small>`}
    </button>`;
  }
  async function renderLoyaltyPage() {
    $("op-title").textContent = "Program Loyalty";
    const body = $("op-body");
    if (!session) {
      body.innerHTML = `<div class="vc-card"><b>Program Loyalty</b><p style="margin:0;color:var(--muted)">Masuk untuk melihat total belanja dan hadiah voucher kamu.</p>
        <button type="button" class="btn btn-rose" data-open-account style="justify-content:center">Masuk / Daftar</button></div>`;
      return;
    }
    body.innerHTML = `<p class="form-msg">Memuat…</p>`;
    const { data, error } = await sb.rpc("my_loyalty");
    if (location.hash !== "#loyalty") return;
    if (error || !data) { body.innerHTML = `<p class="form-msg err">Data loyalty gagal dimuat. Coba lagi sebentar.</p>`; return; }
    if (!data.enabled && !data.vouchers.length) { body.innerHTML = `<p class="op-empty">Program loyalty belum aktif. Nantikan ya!</p>`; return; }
    const nx = data.next;
    const tierLine = (t) => {
      const got = t.times > 0;
      return `<li class="loy-tier ${got ? "got" : ""}">
        <span class="loy-ic" aria-hidden="true">${got ? "✓" : "🔒"}</span>
        <span class="loy-tx"><b>${t.recurring ? "Setiap " : ""}${rp(t.threshold)} → ${esc(t.reward)}</b>
          <small>${esc(t.name)}${t.min_spend ? ` · min. belanja ${rp(t.min_spend)}` : ""} · berlaku ${t.valid_days} hari${t.description ? " · " + esc(t.description) : ""}</small></span>
        <span class="loy-st">${got ? (t.recurring ? `${t.times}× didapat` : "Terbuka") : "Belum"}</span></li>`;
    };
    body.innerHTML = `
      <section class="vc-card loy-hero" aria-labelledby="loy-h">
        <h3 id="loy-h" style="margin:0">Hadiah Loyalty Kamu</h3>
        <p style="margin:0">Kamu sudah belanja <b class="loy-big">${rp(data.spend)}</b></p>
        ${data.highest ? `<small class="od-muted">Milestone tertinggi: ${esc(data.highest.name)} (${rp(data.highest.threshold)})</small>` : ""}
        ${nx ? `<p style="margin:.3rem 0 0">Hadiah berikutnya di <b>${rp(nx.threshold)}</b></p>
          ${loyBar(nx.percent, `Progres ${nx.percent}%`)}
          <div class="loy-row"><span>Progres: <b>${nx.percent}%</b></span><span>${rp(data.spend)} / ${rp(nx.threshold)}</span></div>
          <p style="margin:0">Belanja <b>${rp(nx.remaining)}</b> lagi untuk dapat <b>${esc(nx.reward)}</b>${nx.min_spend ? ` (min. belanja ${rp(nx.min_spend)})` : ""}.</p>`
          : `<p style="margin:.3rem 0 0">🎉 Semua hadiah loyalty yang tersedia sudah kamu buka. Terima kasih sudah jadi pelanggan setia!</p>`}
        <small class="od-muted">Dihitung dari pesanan yang sudah dibayar, setelah diskon${data.include_shipping ? "" : ", tanpa ongkir"}. Pesanan yang dibatalkan tidak dihitung.</small>
      </section>
      <section class="vc-sec" aria-labelledby="loy-t"><h4 id="loy-t">Milestone</h4>
        ${data.tiers.length ? `<ul class="loy-tiers">${data.tiers.map(tierLine).join("")}</ul>` : `<p class="op-empty">Belum ada milestone aktif.</p>`}</section>
      <section class="vc-sec" aria-labelledby="loy-v"><h4 id="loy-v">Voucher Loyalty</h4>
        ${data.vouchers.length ? data.vouchers.map(voucherCard).join("") : `<p class="op-empty" style="padding:.6rem 0">Belum ada. Voucher muncul di sini otomatis saat milestone tercapai.</p>`}</section>
      ${data.history.length ? `<section class="vc-sec" aria-labelledby="loy-r"><h4 id="loy-r">Riwayat belanja yang dihitung</h4>
        <div class="vc-card" style="gap:.3rem">${data.history.map((h) => `<div class="od-line"><span>${h.order ? `<button type="button" class="linkish" data-order="${esc(h.order)}">${esc(h.order)}</button>` : "–"} <small style="display:inline">${fmtDate(h.at)}${h.kind === "reverse" ? " · dibatalkan" : ""}</small></span><span style="color:${h.amount < 0 ? "var(--rose)" : "var(--wa)"}">${h.amount < 0 ? "−" : "+"}${rp(Math.abs(h.amount))}</span></div>`).join("")}</div></section>` : ""}`;
    refreshBadgesSoon();
  }

  // ------------------------------------------------------------------ voucher page (#voucher)
  const VST = { available: "Bisa dipakai", pending: "Menunggu pembayaran pertama", reserved: "Sedang dipakai", used: "Sudah dipakai", expired: "Kedaluwarsa", revoked: "Dibatalkan" };
  const offerOf = (x) => x.discount_type === "free_item" ? `Gratis ${x.gift_text || "hadiah"}` : x.discount_type === "percent" ? `Diskon ${x.value}%` : x.discount_type === "shipping" ? `Gratis ongkir s/d ${rp(x.value)}` : `Potongan ${rp(x.value)}`;
  const forWhat = (x) => (x.applies_to_all || !(x.products || []).length) ? "Berlaku untuk semua menu" : `Hanya untuk: ${x.products.map(esc).join(", ")}`;
  const codeRow = (code, canUse) => `<div class="vc-code"><code>${esc(code)}</code>
      <button type="button" class="btn btn-ghost" data-copy="${esc(code)}" aria-label="Salin kode ${esc(code)}">Salin kode</button>
      ${canUse ? `<button type="button" class="btn btn-rose" data-apply="${esc(code)}" aria-label="Pakai voucher ${esc(code)}">Pakai</button>` : ""}</div>`;
  function voucherCard(v) {
    const st = v.status, ok = st === "available";
    const terms = [
      v.min_spend ? `Minimal belanja ${rp(v.min_spend)}` : "Tanpa minimal belanja",
      v.max_discount && v.discount_type === "percent" ? `Maksimal potongan ${rp(v.max_discount)}` : "",
      v.discount_type === "shipping" ? "Hanya memotong ongkos kirim (harga menu tidak berubah)" : "",
      st === "pending" ? "Aktif setelah pembayaran pertama kamu berhasil" : v.expires_at ? `${st === "expired" ? "Berakhir" : "Berlaku sampai"} ${fmtDate(v.expires_at)}` : "Tanpa batas waktu",
      forWhat(v), "Sekali pakai",
      v.campaign ? `Dari kampanye ${esc(v.campaign)}` : "",
      v.tier ? `Hadiah loyalty: ${esc(v.tier)}` : "",
      st === "reserved" && v.reserved_order ? `Sedang dipakai di pesanan <button type="button" class="linkish" data-order="${esc(v.reserved_order)}">${esc(v.reserved_order)}</button> yang belum dibayar` : "",
      st === "used" && v.used_order ? `Dipakai di pesanan <button type="button" class="linkish" data-order="${esc(v.used_order)}">${esc(v.used_order)}</button>${v.used_at ? " · " + fmtDate(v.used_at) : ""}` : "",
    ].filter(Boolean);
    return `<article class="vc-card ${ok || st === "pending" ? "" : "dim"}">
      <div class="vc-top"><span class="vc-offer">${esc(offerOf(v))}</span><span class="badge-st ${esc(st)}">${esc(VST[st] || st)}</span></div>
      <ul class="vc-terms">${terms.map((t) => `<li>${t}</li>`).join("")}</ul>
      ${codeRow(v.code, ok)}
    </article>`;
  }
  function promoCard(pr) {
    const terms = [
      pr.min_spend ? `Minimal belanja ${rp(pr.min_spend)}` : "Tanpa minimal belanja",
      pr.max_discount && pr.discount_type === "percent" ? `Maksimal potongan ${rp(pr.max_discount)}` : "",
      pr.ends_at ? `Berlaku sampai ${fmtDate(pr.ends_at)}` : "Selama persediaan / sampai diumumkan berakhir",
      forWhat(pr), pr.code ? "Ketik kodenya di keranjang" : "Otomatis terpakai di keranjang",
    ].filter(Boolean);
    return `<article class="vc-card">
      <div class="vc-top"><b>${esc(pr.name)}</b><span class="badge-st paid">Sedang berlaku</span></div>
      <span class="vc-offer">${esc(offerOf(pr))}</span>
      ${pr.description ? `<p style="margin:0">${esc(pr.description)}</p>` : ""}
      <ul class="vc-terms">${terms.map((t) => `<li>${t}</li>`).join("")}</ul>
      ${pr.code ? codeRow(pr.code, true) : `<button type="button" class="btn btn-ghost" data-shop-now style="justify-content:center">Belanja sekarang</button>`}
    </article>`;
  }
  async function renderVoucherPage() {
    $("op-title").textContent = "Kode Voucher";
    const body = $("op-body");
    body.innerHTML = `<p class="form-msg">Memuat voucher…</p>`;
    let data;
    if (session) {
      const r = await sb.rpc("my_vouchers");
      if (r.error) { body.innerHTML = `<p class="form-msg err">Voucher gagal dimuat. Coba lagi sebentar.</p>`; return; }
      data = r.data;
    } else {
      const r = await sb.rpc("public_promotions");
      data = { promos: r.data || [], referral: [], admin: [] };
    }
    if (location.hash !== "#voucher") return;
    const empty = (t) => `<p class="op-empty" style="padding:.6rem 0">${t}</p>`;
    body.innerHTML = `
      <section class="vc-sec" aria-labelledby="vc-promo"><h4 id="vc-promo">Promo</h4>
        ${data.promos.length ? data.promos.map(promoCard).join("") : empty("Belum ada promo yang berjalan. Cek lagi nanti ya.")}</section>
      ${session ? `
      <section class="vc-sec" aria-labelledby="vc-ref"><h4 id="vc-ref">Voucher Referral</h4>
        ${data.referral.length ? data.referral.map(voucherCard).join("") : empty("Belum ada voucher referral. Voucher ini didapat saat daftar dengan kode referral CamilaNika.")}</section>
      <section class="vc-sec" aria-labelledby="vc-loy"><h4 id="vc-loy">Voucher Loyalty</h4>
        ${(data.loyalty || []).length ? data.loyalty.map(voucherCard).join("") : empty(`Belum ada voucher loyalty. Kumpulkan total belanja untuk membuka hadiah. <button type="button" class="linkish" data-open-loyalty>Lihat progres</button>`)}</section>
      <section class="vc-sec" aria-labelledby="vc-adm"><h4 id="vc-adm">Voucher dari Admin</h4>
        ${data.admin.length ? data.admin.map(voucherCard).join("") : empty("Belum ada voucher khusus untuk kamu.")}</section>` : `
      <div class="vc-card"><b>Voucher pribadi</b><p style="margin:0;color:var(--muted)">Masuk untuk melihat voucher referral dan voucher dari admin.</p>
        <button type="button" class="btn btn-rose" data-open-account style="justify-content:center">Masuk / Daftar</button></div>`}`;
    body.querySelectorAll("[data-shop-now]").forEach((b) => b.addEventListener("click", () => { closeOrders(); setTimeout(() => $("menu-root")?.scrollIntoView({ behavior: "smooth" }), 80); }));
    refreshBadgesSoon();
  }

  // a short list for the account panel: latest orders + a link to the full page
  async function fillOrderPreview(el) {
    let list;
    try { list = await loadOrders(); } catch (e) { el.innerHTML = `<p class="form-msg err">Gagal memuat pesanan.</p>`; return; }
    if (!el.isConnected) return;
    const due = list.filter((o) => payToken(o)).length;
    el.innerHTML = list.length
      ? `${list.slice(0, 3).map(orderRow).join("")}
         <button type="button" class="btn btn-ghost" data-open-orders style="justify-content:center">Lihat semua pesanan (${list.length})${due ? ` · ${due} belum dibayar` : ""}</button>`
      : `<p class="form-msg">Belum ada pesanan.</p>`;
  }

  // ------------------------------------------------------------------ account
  const acct = $("account");
  $("acct-btn").addEventListener("click", () => { renderAccount(); openDrawer(acct); });
  document.addEventListener("click", (e) => { if (e.target.closest("[data-open-account]")) { renderAccount(); openDrawer(acct); } });
  acct.addEventListener("click", (e) => { if (e.target.closest("[data-close-account]")) closeAll(); });
  let acctMode = "login";

  function renderAccount(mode) {
    if (mode) acctMode = mode;
    const body = $("acct-body");
    if (acctMode === "recovery") {
      $("acct-title").textContent = "Buat password baru";
      body.innerHTML = `<form class="acct-form" id="f-newpass"><div class="field"><label for="np">Password baru</label><input id="np" type="password" minlength="8" autocomplete="new-password" required></div>
        <button class="btn btn-rose" type="submit">Simpan password</button><p class="form-msg" id="f-msg"></p></form>`;
      $("f-newpass").addEventListener("submit", async (e) => {
        e.preventDefault();
        const { error } = await sb.auth.updateUser({ password: $("np").value });
        formMsg(error ? "Gagal menyimpan password." : "Password tersimpan.", !!error);
        if (!error) setTimeout(() => renderAccount("login"), 800);
      });
      return;
    }
    if (session) return renderProfile();
    $("acct-title").textContent = "Akun";
    const recent = store.get("cn-orders", []);
    const waHelp = `https://wa.me/${WA}?text=${encodeURIComponent("Halo CamilaNika, saya lupa password akun saya.")}`;
    body.innerHTML = `
      <div class="acct-tabs"><button type="button" data-mode="login" aria-pressed="${acctMode !== "signup"}">Masuk</button><button type="button" data-mode="signup" aria-pressed="${acctMode === "signup"}">Daftar</button></div>
      ${acctMode === "reset" ? `
      <div class="acct-form">
        <p>Lupa password? Chat kami lewat WhatsApp dari nomor yang kamu daftarkan, nanti kami buatkan password baru.</p>
        <a class="btn btn-wa" href="${waHelp}" target="_blank" rel="noopener" style="justify-content:center">Minta reset lewat WhatsApp</a>
        <button type="button" class="linkish" data-mode="login">Kembali ke Masuk</button>
      </div>` : `
      <form class="acct-form" id="f-auth">
        ${acctMode === "signup" ? `<div class="field"><label for="a-name">Nama</label><input id="a-name" autocomplete="name" required></div>` : ""}
        <div class="field"><label for="a-id">${acctMode === "signup" ? "No. WhatsApp" : "No. WhatsApp atau email"}</label>
          <input id="a-id" ${acctMode === "signup" ? 'type="tel" inputmode="tel" autocomplete="tel" placeholder="08xxxxxxxxxx"' : 'autocomplete="username" placeholder="08xxxxxxxxxx"'} required></div>
        <div class="field"><label for="a-pass">Password${acctMode === "signup" ? " <small>(minimal 8 karakter)</small>" : ""}</label><input id="a-pass" type="password" minlength="8" autocomplete="${acctMode === "signup" ? "new-password" : "current-password"}" required></div>
        ${acctMode === "signup" ? `<div class="field"><label for="a-ref">Kode referral <small>(opsional)</small></label><input id="a-ref" autocomplete="off" maxlength="24" style="text-transform:uppercase" placeholder="mis. CAMILAJUNI" value="${esc(refCode())}"><p class="ref-hint" id="ref-hint" aria-live="polite"></p></div>` : ""}
        <button class="btn btn-rose" type="submit">${acctMode === "signup" ? "Daftar" : "Masuk"}</button>
        ${acctMode === "signup" ? "" : `<button type="button" class="linkish" data-mode="reset">Lupa password?</button>`}
        <p class="form-msg" id="f-msg"></p>
      </form>`}
      <p class="form-msg">Dengan akun, riwayat pesanan, notifikasi, dan voucher kamu tersimpan, dan data pengiriman terisi otomatis.</p>
      <div class="am-menu">
        ${recent.length ? `<button type="button" class="am-item" data-open-orders><span class="ic" aria-hidden="true">📦</span><span class="lbl">Pesanan di perangkat ini</span><span class="chev" aria-hidden="true">›</span></button>` : ""}
        <button type="button" class="am-item" data-open-vouchers><span class="ic" aria-hidden="true">🏷️</span><span class="lbl">Promo yang berlaku</span><span class="chev" aria-hidden="true">›</span></button>
      </div>`;
    body.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => renderAccount(b.dataset.mode)));
    $("f-auth")?.addEventListener("submit", onAuthSubmit);
    if ($("a-ref")) {
      let t = null;
      const check = async () => {
        const code = $("a-ref").value.trim().toUpperCase(), h = $("ref-hint");
        if (!code) { h.textContent = ""; h.className = "ref-hint"; return; }
        const { data } = await sb.rpc("referral_preview", { p_code: code });
        if ($("a-ref")?.value.trim().toUpperCase() !== code) return;
        if (data?.ok) { h.textContent = `🎁 Kamu akan dapat voucher: ${data.reward}${data.reward_on === "first_payment" ? " (aktif setelah pembayaran pertama)" : ""}.`; h.className = "ref-hint ok"; }
        else { h.textContent = REF_ERR[data?.error] || REF_ERR.REFERRAL_INVALID; h.className = "ref-hint bad"; }
      };
      $("a-ref").addEventListener("input", () => { clearTimeout(t); t = setTimeout(check, 400); });
      if ($("a-ref").value) check();
    }
  }

  const REF_ERR = {
    REFERRAL_INVALID: "Kode referral tidak ditemukan. Cek lagi, atau kosongkan.",
    REFERRAL_EXPIRED: "Kode referral ini sudah berakhir. Kosongkan untuk daftar tanpa voucher.",
    REFERRAL_PAUSED: "Kode referral ini sedang tidak aktif. Kosongkan untuk daftar tanpa voucher.",
    REFERRAL_NOT_STARTED: "Kode referral ini belum mulai berlaku.",
    REFERRAL_FULL: "Kuota voucher untuk kode ini sudah habis. Kosongkan untuk daftar tanpa voucher.",
  };
  const REWARD_REASON = {
    REFERRAL_DAILY_LIMIT: "kuota voucher hari ini sudah habis", REFERRAL_DEVICE_LIMIT: "batas voucher untuk jaringan ini sudah tercapai",
    REFERRAL_FULL: "kuota voucher sudah habis", REFERRAL_EXPIRED: "kampanye sudah berakhir", REFERRAL_PAUSED: "kampanye sedang dijeda",
  };
  const refCode = () => { try { return sessionStorage.getItem("cn-ref") || ""; } catch (e) { return ""; } };
  let lastReward = null, refOpen = false;
  const formMsg = (t, err) => { const m = $("f-msg"); if (m) { m.textContent = t; m.className = "form-msg" + (err ? " err" : ""); } };

  // Accounts made with a WhatsApp number log in with a private address <62number>@phone.camilanika.invalid
  const PHONE_DOMAIN = "phone.camilanika.invalid";
  const normPhone = (raw) => {
    let d = String(raw || "").replace(/\D/g, "");
    if (d.startsWith("0")) d = "62" + d.slice(1); else if (d.startsWith("8")) d = "62" + d;
    return /^62\d{8,13}$/.test(d) ? d : null;
  };
  const loginId = (raw) => (raw.includes("@") ? raw.trim() : normPhone(raw) ? `${normPhone(raw)}@${PHONE_DOMAIN}` : null);
  const realEmail = (e) => (e && !e.endsWith("@" + PHONE_DOMAIN) ? e : "");

  async function onAuthSubmit(e) {
    e.preventDefault();
    const btn = e.submitter || e.target.querySelector("[type=submit]"); btn.disabled = true;
    const id = $("a-id").value.trim();
    try {
      if (acctMode === "signup") {
        if (!normPhone(id)) return formMsg("Nomor WhatsApp belum benar. Contoh: 081234567890", true);
        const res = await fetch(`${CFG.SUPABASE_URL}/functions/v1/phone-signup`, {
          method: "POST",
          headers: { "Content-Type": "application/json", apikey: CFG.SUPABASE_ANON_KEY, Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}` },
          body: JSON.stringify({ name: $("a-name").value.trim(), phone: id, password: $("a-pass").value, referral_code: $("a-ref")?.value.trim().toUpperCase() || null }),
        });
        const out = await res.json().catch(() => ({ error: "SIGNUP_FAILED" }));
        if (out.error === "PHONE_TAKEN") {
          renderAccount("login"); $("a-id").value = id;
          return formMsg("Nomor ini sudah terdaftar. Silakan masuk, atau pakai \"Lupa password?\" kalau lupa.", true);
        }
        if (!res.ok || out.error) {
          if (/^REFERRAL_/.test(out.error)) { $("a-ref")?.focus(); return formMsg(REF_ERR[out.error] || REF_ERR.REFERRAL_INVALID, true); }
          return formMsg({ PHONE_INVALID: "Nomor WhatsApp belum benar.", PASSWORD_TOO_SHORT: "Password minimal 8 karakter.", NAME_REQUIRED: "Isi nama dulu ya.",
            RATE_LIMITED: "Terlalu banyak pendaftaran dari jaringan ini. Coba lagi dalam 1 jam." }[out.error] || "Gagal mendaftar. Coba lagi sebentar.", true);
        }
        lastReward = out.referral || null;
        try { sessionStorage.removeItem("cn-ref"); } catch (e) {}
        // account exists and is ready: log straight in
        const { error } = await sb.auth.signInWithPassword({ email: out.login, password: $("a-pass").value });
        if (error) return formMsg("Akun dibuat, tapi gagal masuk otomatis. Silakan masuk.", true);
      } else {
        const email = loginId(id);
        if (!email) return formMsg("Isi nomor WhatsApp atau email yang benar.", true);
        const { error } = await sb.auth.signInWithPassword({ email, password: $("a-pass").value });
        if (error) return formMsg(/confirm/i.test(error.message) ? "Konfirmasi email kamu dulu ya." : "Nomor/email atau password salah.", true);
      }
    } finally { btn.disabled = false; }
  }

  async function renderProfile() {
    $("acct-title").textContent = "Akun saya";
    const body = $("acct-body");
    const name = profile?.full_name || "Pelanggan";
    const rw = lastReward; lastReward = null;
    const reward = !rw ? "" : rw.rewarded ? `
      <div class="am-reward" role="status">
        <b>🎉 Selamat! Kamu dapat voucher${rw.voucher.campaign ? " dari " + esc(rw.voucher.campaign) : ""}</b>
        <div class="vc-code"><code>${esc(rw.voucher.code)}</code><button type="button" class="btn btn-ghost" data-copy="${esc(rw.voucher.code)}">Salin</button></div>
        <small>${esc(rw.voucher.offer)} · ${rw.voucher.status === "pending" ? "aktif setelah pembayaran pertama kamu berhasil" : "berlaku sampai " + fmtDate(rw.voucher.expires_at)}</small>
        <button type="button" class="btn btn-rose" data-open-vouchers style="justify-content:center">Lihat di Kode Voucher</button>
      </div>` : `<p class="form-msg">Akun berhasil dibuat. Voucher referral tidak bisa diberikan karena ${esc(REWARD_REASON[rw.reason] || "kode tidak memenuhi syarat")}.</p>`;
    const item = (key, ic, label, sub) => `<button type="button" class="am-item" data-am="${key}" ${key === "profile" ? 'aria-expanded="false" aria-controls="am-profile"' : ""}>
        <span class="ic" aria-hidden="true">${ic}</span><span class="lbl">${label}${sub ? `<small>${sub}</small>` : ""}</span>
        ${key === "profile" ? "" : `<span class="badge-red" data-badge="${key}" hidden></span>`}<span class="chev" aria-hidden="true">›</span></button>`;
    body.innerHTML = `${reward}
      <div class="am-head"><span class="am-avatar" aria-hidden="true">${esc(name.trim().charAt(0).toUpperCase() || "C")}</span>
        <div style="min-width:0"><b>${esc(name)}</b><small>${esc(profile?.phone || realEmail(session.user.email) || "")}</small></div></div>
      <div id="am-loyalty"></div>
      <nav class="am-menu" aria-label="Menu akun">
        ${item("profile", "👤", "Profile", "Nama, No. WhatsApp, Alamat")}
        <div class="am-panel" id="am-profile" hidden>
          <form class="acct-form" id="f-profile">
            <div class="field"><label for="p-name">Nama</label><input id="p-name" autocomplete="name" value="${esc(profile?.full_name)}"></div>
            <div class="field"><label for="p-phone">No. WhatsApp</label><input id="p-phone" type="tel" autocomplete="tel" value="${esc(profile?.phone)}"></div>
            <div class="field"><label for="p-addr">Alamat</label><textarea id="p-addr" rows="2">${esc(profile?.address)}</textarea></div>
            <button class="btn btn-rose" type="submit">Simpan profil</button>
            <p class="form-msg" id="f-msg" aria-live="polite"></p>
          </form>
          <details class="acct-sec" style="margin-top:.6rem"><summary style="cursor:pointer;font-weight:800">Ganti password</summary>
            <form class="acct-form" id="f-pass" style="margin-top:.6rem"><div class="field"><label for="p-pass">Password baru (minimal 8 karakter)</label><input id="p-pass" type="password" minlength="8" autocomplete="new-password" required></div>
            <button class="btn btn-ghost" type="submit">Simpan password</button><p class="form-msg" id="f-pmsg"></p></form></details>
        </div>
        ${item("orders", "📦", "Pesanan", "Riwayat & status pesanan")}
        ${item("notifications", "🔔", "Notifikasi", "Menu baru, promo, update pesanan")}
        ${item("vouchers", "🎟️", "Kode Voucher", "Promo, voucher referral & dari admin")}
      </nav>
      <button class="btn btn-ghost" type="button" id="logout" style="justify-content:center">Keluar</button>`;
    renderBadges();
    fillLoyaltyCard();
    body.querySelectorAll("[data-am]").forEach((b) => b.addEventListener("click", () => {
      const k = b.dataset.am;
      if (k === "profile") { const open = b.getAttribute("aria-expanded") !== "true"; b.setAttribute("aria-expanded", String(open)); $("am-profile").hidden = !open; if (open) $("p-name").focus(); }
      else if (k === "orders") navOrders();
      else if (k === "notifications") { openDrawer(NF); renderNotifs(); }
      else if (k === "vouchers") navVouchers();
    }));
    $("f-profile").addEventListener("submit", async (e) => {
      e.preventDefault();
      const upd = { full_name: $("p-name").value.trim(), phone: $("p-phone").value.trim(), address: $("p-addr").value.trim() };
      if (!upd.full_name) return formMsg("Nama tidak boleh kosong.", true);
      if (upd.phone && !normPhone(upd.phone)) return formMsg("Nomor WhatsApp belum benar. Contoh: 081234567890", true);
      const btn = e.submitter; if (btn) btn.disabled = true;
      const { error } = await sb.from("profiles").update(upd).eq("id", session.user.id);
      if (btn) btn.disabled = false;
      if (!error) {
        profile = { ...profile, ...upd }; prefill(true);
        $("acct-label").textContent = profile.full_name.split(" ")[0] || "Akun";
        body.querySelector(".am-head b").textContent = profile.full_name;
        body.querySelector(".am-head small").textContent = profile.phone || "";
      }
      formMsg(error ? "Gagal menyimpan. Coba lagi." : "Profil tersimpan ✓", !!error);
    });
    $("logout").addEventListener("click", async () => { await sb.auth.signOut(); closeAll(); });
    $("f-pass").addEventListener("submit", async (e) => {
      e.preventDefault();
      const { error } = await sb.auth.updateUser({ password: $("p-pass").value });
      const m = $("f-pmsg"); m.textContent = error ? "Gagal menyimpan password." : "Password baru tersimpan."; m.className = "form-msg" + (error ? " err" : "");
      if (!error) $("p-pass").value = "";
    });
    refreshBadges();
  }

  function prefill(force) {
    if (!profile) return;
    const set = (id, v) => { if (v && (force || !$(id).value)) $(id).value = v; };
    set("cust-name", profile.full_name); set("cust-phone", profile.phone); set("cust-addr", profile.address);
    if (realEmail(session?.user?.email)) set("cust-email", session.user.email);
    $("guest-note").hidden = true;
  }

  async function onSession(s) {
    session = s;
    profile = null;
    if (s) {
      const { data } = await sb.from("profiles").select("full_name,phone,address,role").eq("id", s.user.id).maybeSingle();
      profile = data;
      prefill(false);
    } else {
      $("guest-note").hidden = false;
    }
    $("acct-label").textContent = s ? (profile?.full_name?.split(" ")[0] || "Akun") : "Masuk";
    if (acct.classList.contains("open") && acctMode !== "recovery") renderAccount();
    if (!$("orders-page").hidden) route();
    startNotifPolling();
    if (refOpen) { refOpen = false; if (!s) { renderAccount("signup"); openDrawer(acct); } }
    if (NF.classList.contains("open")) renderNotifs();
  }
  // referral link: camilanika.github.io/?ref=CODE opens sign-up with the code filled in
  {
    const ref = new URLSearchParams(location.search).get("ref");
    if (ref && /^[A-Za-z0-9-]{4,24}$/.test(ref)) {
      try { sessionStorage.setItem("cn-ref", ref.toUpperCase()); } catch (e) {}
      refOpen = true; acctMode = "signup";
      const q = new URLSearchParams(location.search); q.delete("ref");
      history.replaceState(history.state, "", location.pathname + (q.toString() ? "?" + q : "") + location.hash);
    }
  }
  sb.auth.onAuthStateChange((event, s) => {
    if (event === "PASSWORD_RECOVERY") { session = s; renderAccount("recovery"); openDrawer(acct); return; }
    if (event === "SIGNED_IN" || event === "SIGNED_OUT" || event === "INITIAL_SESSION" || event === "USER_UPDATED") {
      setTimeout(() => onSession(s), 0); // avoid calling Supabase inside the auth callback
    }
  });

  // ------------------------------------------------------------------ notifications
  const NF = $("notif");
  const NF_ICON = { product: "🆕", promo: "🏷️", order: "📦", voucher: "🎟️", account: "👋" };
  let nf = { items: [], unread: 0 }, nfTimer = null;
  const toastEl = $("toast"); let toastT = null;
  const toast = (t) => { toastEl.textContent = t; toastEl.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => (toastEl.hidden = true), 3200); };

  // ------------------------------------------------------------------ red badges (Akun saya)
  let badges = { orders: 0, notifications: 0, vouchers: 0, total: 0 }, badgeT = null;
  const BADGE_LABEL = { orders: (n) => `${n} pesanan belum selesai`, notifications: (n) => `${n} notifikasi belum dibaca`, vouchers: (n) => `${n} voucher bisa dipakai` };
  function renderBadges() {
    const b = badges, t = (b.orders || 0) + (b.notifications || 0) + (b.vouchers || 0);
    const main = $("acct-badge");
    main.hidden = !t; main.textContent = t > 99 ? "99+" : String(t);
    $("acct-btn").setAttribute("aria-label", t ? `Akun saya, ${t} perlu dilihat` : "Akun saya");
    document.querySelectorAll("[data-badge]").forEach((el) => {
      const n = b[el.dataset.badge] || 0;
      el.hidden = !n; el.textContent = n > 99 ? "99+" : String(n);
      el.setAttribute("aria-label", BADGE_LABEL[el.dataset.badge](n));
    });
  }
  function setBadge(n) { nf.unread = n; badges.notifications = n; renderBadges(); }
  async function refreshBadges() {
    if (!session) { badges = { orders: 0, notifications: 0, vouchers: 0, total: 0 }; nf.unread = 0; return renderBadges(); }
    const { data, error } = await sb.rpc("my_badges");
    if (!error && data) { badges = data; nf.unread = data.notifications; renderBadges(); }
  }
  const refreshBadgesSoon = () => { clearTimeout(badgeT); badgeT = setTimeout(refreshBadges, 300); };
  const refreshUnread = refreshBadges;
  function startNotifPolling() {
    clearInterval(nfTimer);
    refreshBadges();
    if (session) nfTimer = setInterval(() => { if (document.visibilityState === "visible") refreshBadges(); }, 60000);
  }
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && session) refreshBadges(); });

  NF.addEventListener("click", (e) => { if (e.target.closest("[data-close-notif]")) closeAll(); });

  async function renderNotifs() {
    $("notif-title").textContent = "Notifikasi";
    const body = $("notif-body");
    if (!session) {
      body.innerHTML = `<div class="nf-empty"><p>Masuk untuk menerima kabar menu baru, promo, dan update pesanan kamu.</p>
        <button type="button" class="btn btn-rose" data-open-account>Masuk / Daftar</button></div>`;
      return;
    }
    body.innerHTML = `<p class="form-msg">Memuat…</p>`;
    const { data, error } = await sb.rpc("my_notifications", { p_limit: 60 });
    if (!NF.classList.contains("open")) return;
    if (error || !data) { body.innerHTML = `<p class="form-msg err">Notifikasi gagal dimuat. Coba lagi sebentar.</p>`; return; }
    nf.items = data.items; setBadge(data.unread);
    drawNotifs();
  }
  function drawNotifs() {
    const body = $("notif-body");
    if (!nf.items.length) { body.innerHTML = `<div class="nf-empty"><p>Belum ada notifikasi.</p><p style="font-size:.9rem">Kabar menu baru, promo, dan update pesanan kamu akan muncul di sini.</p></div>`; return; }
    body.innerHTML = `
      <div class="nf-tools"><span>${nf.unread ? `${nf.unread} belum dibaca` : "Semua sudah dibaca"}</span>
        ${nf.unread ? `<button type="button" class="linkish" id="nf-all">Tandai semua dibaca</button>` : ""}</div>
      <div class="nf-list">${nf.items.map((n) => `
        <button type="button" class="nf-item ${n.read ? "read" : "unread"}" data-nf="${n.id}">
          <span class="nf-ic" aria-hidden="true">${NF_ICON[n.kind] || "🔔"}</span>
          <b>${esc(n.title)}</b>${n.read ? "<span></span>" : `<span class="nf-dot" title="Belum dibaca"></span>`}
          ${n.body ? `<p>${esc(n.body)}</p>` : ""}
          <small>${fmtDate(n.created_at)}${n.available ? "" : ` · <span class="gone">${n.kind === "promo" ? "promo sudah berakhir" : n.kind === "product" ? "sudah tidak tersedia" : n.kind === "voucher" ? "voucher sudah tidak ada" : "tidak ditemukan"}</span>`}</small>
        </button>`).join("")}</div>`;
    $("nf-all")?.addEventListener("click", async () => {
      const { error } = await sb.rpc("mark_notifications_read", { p_ids: null });
      if (error) return toast("Gagal menandai. Coba lagi.");
      nf.items.forEach((n) => (n.read = true)); setBadge(0); drawNotifs();
    });
    body.querySelectorAll("[data-nf]").forEach((b) => b.addEventListener("click", () => openNotif(nf.items.find((n) => String(n.id) === b.dataset.nf))));
  }

  async function openNotif(n) {
    if (!n) return;
    if (!n.read) {
      n.read = true; setBadge(Math.max(0, nf.unread - 1));
      sb.rpc("mark_notifications_read", { p_ids: [n.id] }).then(({ error }) => { if (error) refreshUnread(); });
    }
    if (n.kind === "order") { navOrders(n.ref_id); return; }
    if (n.link === "#loyalty") { navLoyalty(); return; }
    if (n.kind === "voucher" || n.kind === "account") { navVouchers(); return; }
    if (n.kind === "promo") { renderPromoDetail(n.ref_id); return; }
    if (n.kind === "product") {
      const card = document.querySelector(`[data-card="${CSS.escape(String(n.ref_id))}"]`);
      if (!n.available || !card) { drawNotifs(); toast("Produk ini sudah tidak tersedia."); return; }
      closeAll();
      card.scrollIntoView({ behavior: "smooth", block: "center" });
      card.classList.remove("flash"); void card.offsetWidth; card.classList.add("flash");
    }
  }

  async function renderPromoDetail(id) {
    $("notif-title").textContent = "Detail promo";
    const body = $("notif-body");
    body.innerHTML = `<p class="form-msg">Memuat…</p>`;
    const { data: pr, error } = await sb.rpc("promo_details", { p_id: Number(id) });
    const back = `<button type="button" class="linkish" id="nf-back" style="justify-self:start">← Semua notifikasi</button>`;
    if (error || !pr) {
      body.innerHTML = `<p class="form-msg">Promo ini sudah tidak tersedia.</p>${back}`;
    } else {
      const big = pr.discount_type === "free_item" ? "GRATIS" : pr.discount_type === "percent" ? `Diskon ${pr.value}%` : `Potongan ${rp(pr.value)}`;
      const per = pr.ends_at ? `Berlaku sampai ${fmtDate(pr.ends_at)}` : pr.starts_at ? `Mulai ${fmtDate(pr.starts_at)}` : "";
      body.innerHTML = `<div class="pd-card">
          <span class="badge-st ${pr.live ? "paid" : "expired"}" style="justify-self:start">${pr.live ? "Sedang berlaku" : "Sudah berakhir"}</span>
          <h3 style="margin:0">${esc(pr.name)}</h3>
          <div class="pd-big">${esc(big)}</div>
          ${pr.discount_type === "free_item" && pr.gift_text ? `<div>🎁 ${esc(pr.gift_text)}</div>` : ""}
          ${pr.description ? `<p style="margin:0">${esc(pr.description)}</p>` : ""}
          <ul style="margin:0;padding-left:1.1rem;color:var(--muted)">
            ${pr.min_spend ? `<li>Minimal belanja ${rp(pr.min_spend)}</li>` : ""}
            ${pr.max_discount ? `<li>Maksimal potongan ${rp(pr.max_discount)}</li>` : ""}
            ${per ? `<li>${per}</li>` : ""}
            <li>${pr.code ? "Masukkan kode di keranjang" : "Otomatis terpakai di keranjang"}</li>
          </ul>
          ${pr.code ? `<div class="pd-code"><span>${esc(pr.code)}</span>${pr.live ? `<button type="button" class="btn btn-rose" id="pd-use">Pakai kode</button>` : ""}</div>` : ""}
          ${pr.live && !pr.code ? `<button type="button" class="btn btn-rose" id="pd-shop" style="justify-content:center">Belanja sekarang</button>` : ""}
        </div>${back}`;
      $("pd-use")?.addEventListener("click", () => {
        $("promo-code").value = pr.code; openDrawer($("drawer")); $("apply-code").click();
      });
      $("pd-shop")?.addEventListener("click", () => { closeAll(); document.querySelector("#menu-root")?.scrollIntoView({ behavior: "smooth" }); });
    }
    $("nf-back").addEventListener("click", () => { $("notif-title").textContent = "Notifikasi"; drawNotifs(); });
  }

  // ------------------------------------------------------------------ copy phone
  if ($("foot-year")) $("foot-year").textContent = new Date().getFullYear();
  $("copy-phone").addEventListener("click", (e) => {
    const btn = e.currentTarget;
    navigator.clipboard?.writeText("0" + WA.replace(/^62/, "")).then(() => { btn.textContent = "Tersalin"; setTimeout(() => (btn.textContent = "Salin nomor"), 1500); })
      .catch(() => { const r = document.createRange(); r.selectNodeContents($("phone")); const s = getSelection(); s.removeAllRanges(); s.addRange(r); });
  });

  // ------------------------------------------------------------------ boot
  async function refreshMenu() {
    const { data, error } = await sb.rpc("get_menu");
    if (error || !data) throw error || new Error("menu");
    menu = data;
    syncCartWithMenu();
    renderMenu(); renderPromo(); renderCart();
  }

  // Online payment can be switched off in config.js (WhatsApp / GoFood ordering still works)
  if (ONLINE && CFG.ONLINE_PAYMENT === "test") {
    const b = document.createElement("div");
    b.textContent = "MODE TES · pembayaran online (Sandbox) aktif · buka ?test=0 untuk keluar";
    b.style.cssText = "position:fixed;left:8px;bottom:8px;z-index:9999;background:#b45309;color:#fff;font:600 12px/1.3 system-ui,sans-serif;padding:6px 10px;border-radius:8px;opacity:.92;pointer-events:none";
    document.body.appendChild(b);
  }
  if (!ONLINE) {
    $("pay-btn").hidden = true;
    document.querySelector(".pay-note").hidden = true;
    $("to-checkout").textContent = "Lanjut isi data & pesan";
  }

  (async () => {
    setOffsets();
    renderCart();
    await Promise.all([loadShop(), loadDeliverySettings()]);
    try { await refreshMenu(); }
    catch (e) {
      $("menu-root").innerHTML = `<section class="block"><div class="wrap"><p class="menu-status">Menu belum bisa dimuat. Coba muat ulang halaman, atau pesan langsung lewat <a href="https://wa.me/${WA}" target="_blank" rel="noopener">WhatsApp</a>.</p></div></section>`;
    }
    if (cart.length) scheduleQuote();
    // back from a Midtrans redirect (e.g. GoPay app): ?order=CN-...
    const params = new URLSearchParams(location.search);
    const num = params.get("order") || params.get("order_id");
    if (num) {
      history.replaceState(null, "", location.pathname + location.hash);
      const st = params.get("transaction_status");
      if (st === "settlement" || st === "capture" || st === "pending") clearCart();
      showStatus(num, true);
    } else if (/^#(pesanan|voucher|loyalty)/.test(location.hash)) route();
  })();
})();
