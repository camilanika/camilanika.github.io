// CamilaNika storefront: menu from Supabase, cart, promos, accounts, Midtrans payment, order status.
(() => {
  const CFG = window.CN_CONFIG;
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
  };
  const errMsg = (raw) => {
    const code = String(raw || "").replace(/^.*?([A-Z_]{5,}).*$/s, "$1");
    return ERRORS[code] || "Terjadi kesalahan. Coba lagi, atau pesan lewat WhatsApp.";
  };
  const STATUS = {
    pending: "Menunggu pembayaran", paid: "Sudah dibayar", processing: "Sedang disiapkan",
    completed: "Selesai", cancelled: "Dibatalkan", expired: "Kedaluwarsa", failed: "Gagal",
  };

  // ------------------------------------------------------------------ state
  let menu = { products: [], promotions: [] };
  let size = "M";
  let cart = store.get("cn-cart-v2", []);
  let quote = null;          // last server quote
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

  const chipGroup = (opts, label, def = 0, attr = "") =>
    `<div class="opt-label">${esc(label)}</div><div class="chips" role="group" aria-label="${esc(label)}" data-attr="${esc(attr)}" data-label="${esc(label)}">${opts
      .map((o, i) => `<button type="button" class="chip" data-v="${esc(o)}" aria-pressed="${i === def}">${esc(o)}</button>`)
      .join("")}</div>`;

  const cardHTML = (p) => {
    const drinkStyle = usesSize(p);
    const attrs = p.attr_names.filter((a) => a !== SIZE_ATTR);
    const chips = attrs.map((a) => chipGroup(attrValues(p, a), a === "Rasa" ? "Pilih rasa" : a, 0, a)).join("") +
      (p.choices || []).map((c) => chipGroup(c.options, c.label, c.default ?? 0)).join("");
    const addon = p.addon_label
      ? `<label class="check" data-addon-wrap><input type="checkbox" data-addon> ${esc(p.addon_label)} <span class="num" data-addon-price></span></label>` : "";
    const head = `<div class="item-top"><h3>${esc(p.name)}${p.subtitle ? `<span>${esc(p.subtitle)}</span>` : ""}${p.note ? `<em class="note-tag">${esc(p.note)}</em>` : ""}</h3><div class="price num" data-price></div></div>`;
    const btn = `<span class="stock-tag" data-stock></span><button class="btn btn-rose add" type="button" data-add>Tambah ke keranjang</button>`;
    if (drinkStyle || !p.image_url) {
      const img = drinkStyle && p.image_url ? `<img class="drink-ill" src="${esc(p.image_url)}" alt="Ilustrasi ${esc(p.name)}" width="200" height="200" loading="lazy" onerror="this.remove()">` : "";
      return `<article class="item" data-product="${p.id}">${img}${head}${chips}${addon}${btn}</article>`;
    }
    return `<article class="item kuah" data-product="${p.id}"><img src="${esc(p.image_url)}" alt="${esc(p.name)}" loading="lazy" onerror="this.remove()"><div style="display:grid;gap:.6rem;min-width:0">${head}${chips}${addon}${btn}</div></article>`;
  };

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
      <img class="sticker" src="img/logo-cireng.jpg" alt="">
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
    const nav = c.sections.length > 1
      ? `<nav class="series-nav" aria-label="Submenu ${esc(c.name)}">${c.sections.map((s) => `<a href="#sub-${esc(s.slug)}">${s.icon ? esc(s.icon) + " " : ""}${esc(s.name.replace(/ Series$/, ""))}</a>`).join("")}</nav>` : "<span></span>";
    const sw = sizes.length
      ? `<div class="size-switch" role="group" aria-label="Pilih ukuran">${sizes.map((s) => `<button type="button" data-size="${esc(s)}" aria-pressed="${s === size}">${esc(sizeLabel(s))}${s === "L" && sizes.length > 1 ? '<span class="hemat"> · lebih hemat</span>' : ""}</button>`).join("")}</div>` : "";
    const bar = c.sections.length > 1 || sizes.length ? `<div class="menu-bar">${nav}${sw}</div>` : "";
    const secs = c.sections.map((s) => `
      <section class="series acc-${esc(s.accent || "caramel")}" id="sub-${esc(s.slug)}" aria-labelledby="sub-h-${esc(s.slug)}">
        <div class="series-head"><h3 id="sub-h-${esc(s.slug)}">${esc(s.name)}</h3>${s.tagline ? `<p>${esc(s.tagline)}</p>` : ""}</div>
        <div class="menu-grid">${s.products.map(cardHTML).join("")}</div>
      </section>`).join("");
    const main = head + (side ? "" : showcase) + bar + secs;
    return `<section class="block cat${i % 2 ? " alt" : ""}" id="${esc(c.slug)}" aria-labelledby="cat-${esc(c.slug)}">
      <div class="wrap${side ? " cat-side" : ""}">${side ? `<div class="cat-media">${showcase}</div>` : ""}<div class="cat-main">${main}</div></div>
    </section>`;
  }

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
    root.innerHTML = cats.map(catHTML).join("");
    $("nav-menus").innerHTML = cats.map((c) => `<a href="#${esc(c.slug)}">${esc(c.name)}</a>`).join("");
    $("see-menu").href = "#" + cats[0].slug;
    navLinks = [...root.querySelectorAll(".series-nav a")];
    document.querySelectorAll("[data-product]").forEach(updateCard);
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
    if (usesSize(p)) sel[SIZE_ATTR] = size;
    const variant = p.variants.find((v) => p.attr_names.every((a) => v.attrs?.[a] === sel[a]));
    const addonBox = card.querySelector("[data-addon]");
    const addon = !!(addonBox && addonBox.checked && variant && variant.addon_price != null);
    return { p, variant, choices, addon };
  }

  function updateCard(card) {
    const { p, variant } = selection(card);
    const priceEl = card.querySelector("[data-price]"), btn = card.querySelector("[data-add]"), tag = card.querySelector("[data-stock]");
    const wrap = card.querySelector("[data-addon-wrap]");
    if (!variant) {
      priceEl.innerHTML = "–"; btn.disabled = true; btn.textContent = "Tidak tersedia"; tag.textContent = ""; if (wrap) wrap.hidden = true;
      return;
    }
    const sub = usesSize(p) ? SIZES[size] || size : "";
    priceEl.innerHTML = `${rp(variant.price)}${sub ? `<small>${esc(sub)}</small>` : ""}`;
    if (wrap) {
      wrap.hidden = variant.addon_price == null;
      card.querySelector("[data-addon-price]").textContent = variant.addon_price != null ? "+" + rp(variant.addon_price) : "";
    }
    const inCart = cart.filter((l) => l.variant_id === variant.id).reduce((s, l) => s + l.qty, 0);
    if (variant.available == null) { // unlimited stock
      btn.disabled = false; btn.textContent = "Tambah ke keranjang"; tag.className = "stock-tag"; tag.textContent = "";
      return;
    }
    const left = variant.available - inCart;
    btn.disabled = left <= 0;
    btn.textContent = variant.available <= 0 ? "Habis" : left <= 0 ? "Stok di keranjang" : "Tambah ke keranjang";
    tag.className = "stock-tag" + (variant.available <= 0 ? " out" : "");
    tag.textContent = variant.available <= 0 ? "Stok habis" : variant.available <= 5 ? `Sisa ${variant.available}` : "";
  }

  document.addEventListener("click", (e) => {
    const c = e.target.closest(".chip");
    if (c) {
      c.parentElement.querySelectorAll(".chip").forEach((b) => b.setAttribute("aria-pressed", b === c));
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
      const detailParts = [usesSize(p) ? `${size} · ${SIZES[size] || ""}` : variant.name, ...Object.values(choices), addon ? p.addon_label.toLowerCase() : null];
      addLine({
        key: `${variant.id}|${JSON.stringify(choices)}|${addon}`, variant_id: variant.id, product_id: p.id,
        choices, addon, name, detail: detailParts.filter(Boolean).join(" · "),
        price: variant.price + (addon ? variant.addon_price : 0),
      }, add);
      updateCard(card);
    }
  });
  document.addEventListener("change", (e) => { if (e.target.matches("[data-addon]")) updateCard(e.target.closest("[data-product]")); });

  document.addEventListener("click", (e) => {
    const b = e.target.closest(".size-switch button"); if (!b) return;
    size = b.dataset.size;
    document.querySelectorAll(".size-switch button").forEach((x) => x.setAttribute("aria-pressed", x.dataset.size === size));
    document.querySelectorAll("[data-product]").forEach(updateCard);
  });

  // sticky submenu bar
  const hdr = document.querySelector("header");
  let navLinks = [];
  function setOffsets() {
    const bar = document.querySelector(".menu-bar");
    document.documentElement.style.setProperty("--hdr", hdr.offsetHeight + "px");
    document.documentElement.style.setProperty("--bar", (bar ? bar.offsetHeight : 0) + "px");
  }
  function setActive() {
    const bar = document.querySelector(".menu-bar");
    const line = hdr.offsetHeight + (bar ? bar.offsetHeight : 0) + 40;
    let cur = null;
    document.querySelectorAll(".series").forEach((sec) => { if (sec.getBoundingClientRect().top <= line) cur = sec.id; });
    navLinks.forEach((a) => a.setAttribute("aria-current", a.getAttribute("href") === "#" + cur));
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
  function addLine(item, btn) {
    const ex = cart.find((l) => l.key === item.key);
    ex ? ex.qty++ : cart.push({ ...item, qty: 1 });
    save(); renderCart(); scheduleQuote();
    if (btn) { btn.classList.remove("added"); void btn.offsetWidth; btn.classList.add("added"); const t = btn.textContent; btn.textContent = "Ditambahkan ✓"; setTimeout(() => { if (btn.textContent === "Ditambahkan ✓") btn.textContent = t; }, 1100); }
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
    return m;
  }

  function renderCart() {
    const sub = subtotal(), count = cart.reduce((s, l) => s + l.qty, 0);
    const q = quote && quote.subtotal === sub ? quote : null;
    const disc = q ? q.discount : 0, total = sub - disc;
    $("cart-count").textContent = count;
    $("cart-subtotal").textContent = rp(sub);
    $("disc-row").hidden = !disc;
    $("disc-label").textContent = q?.promo_name ? `Diskon (${q.promo_name})` : "Diskon";
    $("cart-discount").textContent = "−" + rp(disc);
    $("cart-total").textContent = rp(total);
    const gifts = q?.gifts || [];
    $("gift-msg").hidden = !gifts.length;
    $("gift-msg").textContent = gifts.map((g) => "🎁 " + g.gift).join(" · ");
    $("cart-lines").innerHTML = cart.length ? cart.map((l, i) => `
      <div class="line"><b>${esc(l.name)}</b><span class="lp num">${rp(l.price * l.qty)}</span>
        <small>${esc(l.detail)} · ${rp(l.price)}</small>
        <div class="qty"><button type="button" data-q="${i}" data-d="-1" aria-label="Kurangi">−</button><span class="num">${l.qty}</span><button type="button" data-q="${i}" data-d="1" aria-label="Tambah">+</button></div>
      </div>`).join("") : `<div class="empty"><img src="img/logo-cireng.jpg" alt="" style="width:110px;margin:0 auto;border-radius:50%"><b>Keranjang masih kosong</b><span>Pilih minuman atau cireng, lalu tekan Tambah ke keranjang.</span></div>`;

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
  }

  const showErr = (msg) => { $("cart-err").hidden = !msg; $("cart-err").textContent = msg || ""; };

  let quoteTimer = null;
  function scheduleQuote() { clearTimeout(quoteTimer); quoteTimer = setTimeout(runQuote, 350); }
  async function runQuote(strictCode = false) {
    if (!cart.length) { quote = null; showErr(""); renderCart(); return; }
    let { data, error } = await sb.rpc("quote_cart", { p_items: cartItems(), p_promo_code: promoCode || null });
    if (error && /PROMO_NOT_APPLICABLE/.test(error.message) && !strictCode) {
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
    document.querySelectorAll("[data-product]").forEach(updateCard);
  });
  ["cust-name", "cust-phone", "cust-addr"].forEach((id) => $(id).addEventListener("input", renderCart));
  $("to-checkout").addEventListener("click", () => { $("checkout").hidden = false; renderCart(); $("cust-name").focus(); });
  $("apply-code").addEventListener("click", async () => {
    promoCode = $("promo-code").value.trim().toUpperCase();
    const btn = $("apply-code"); btn.disabled = true;
    const { error } = await runQuote(true);
    btn.disabled = false;
    if (error && /PROMO_NOT_APPLICABLE/.test(error.message)) { promoCode = ""; await runQuote(); showErr(ERRORS.PROMO_NOT_APPLICABLE); }
  });
  $("promo-code").addEventListener("keydown", (e) => { if (e.key === "Enter") $("apply-code").click(); });

  // drawers
  const bg = $("drawer-bg");
  const openDrawer = (el) => { closeAll(); el.classList.add("open"); el.setAttribute("aria-hidden", "false"); bg.hidden = false; el.querySelector(".icon-btn")?.focus(); };
  const closeAll = () => { document.querySelectorAll(".drawer.open").forEach((d) => { d.classList.remove("open"); d.setAttribute("aria-hidden", "true"); }); bg.hidden = true; };
  document.querySelectorAll("[data-open-cart]").forEach((b) => b.addEventListener("click", () => { openDrawer($("drawer")); scheduleQuote(); }));
  $("close-cart").addEventListener("click", closeAll); bg.addEventListener("click", closeAll);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeAll(); closeStatus(); } });

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
    store.set("cn-orders", list.slice(0, 10));
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
  function clearCart() { cart = []; promoCode = ""; quote = null; $("promo-code").value = ""; save(); renderCart(); document.querySelectorAll("[data-product]").forEach(updateCard); }

  $("pay-btn").addEventListener("click", async () => {
    showErr("");
    const name = $("cust-name").value.trim(), phone = $("cust-phone").value.trim();
    if (!name) { showErr(ERRORS.NAME_REQUIRED); $("cust-name").focus(); return; }
    if (!/^\+?[0-9 \-]{8,16}$/.test(phone)) { showErr("Nomor WhatsApp belum benar."); $("cust-phone").focus(); return; }
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
          customer: { name, phone, email: $("cust-email").value.trim(), address: $("cust-addr").value.trim() },
        }),
      });
      const out = await res.json().catch(() => ({ error: "PAYMENT_GATEWAY_ERROR" }));
      if (!res.ok || out.error) {
        if (/OUT_OF_STOCK|PRODUCT_UNAVAILABLE/.test(out.detail || out.error)) { await refreshMenu(); await runQuote(); }
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

  // ------------------------------------------------------------------ order status
  let pollTimer = null;
  const closeStatus = () => { $("status-modal").hidden = true; clearTimeout(pollTimer); };
  $("close-status").addEventListener("click", closeStatus);
  $("status-modal").addEventListener("click", (e) => { if (e.target.id === "status-modal") closeStatus(); });

  async function fetchOrder(num) {
    const saved = findOrder(num);
    if (saved) {
      const { data } = await sb.rpc("get_order_status", { p_order_number: num, p_access_token: saved.access_token });
      if (data) return data;
    }
    if (session) {
      const { data } = await sb.from("orders").select("order_number,status,total,subtotal,discount,gifts,created_at,paid_at,order_items(product_name,variant_name,choices,addon,quantity,line_total)").eq("order_number", num).maybeSingle();
      if (data) return { ...data, items: data.order_items };
    }
    return null;
  }

  const orderCard = (o) => `
    <div class="order-card">
      <div class="oc-head"><b>${esc(o.order_number)}</b><span class="badge-st ${esc(o.status)}">${esc(STATUS[o.status] || o.status)}</span></div>
      <small style="color:var(--muted)">${new Date(o.created_at).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" })}</small>
      <ul>${(o.items || o.order_items || []).map((i) => `<li>${i.quantity}× ${esc(i.product_name)} · ${esc(i.variant_name)}${Object.values(i.choices || {}).map((c) => " · " + esc(c)).join("")}${i.addon ? " · " + esc(i.addon) : ""}</li>`).join("")}</ul>
      ${(o.gifts || []).map((g) => `<span class="gift-msg">🎁 ${esc(g.gift)}</span>`).join("")}
      ${o.discount ? `<span style="color:var(--wa);font-weight:700">Diskon −${rp(o.discount)}</span>` : ""}
      <span class="tot">Total ${rp(o.total)}</span>
    </div>`;

  async function showStatus(num, poll = false) {
    $("status-modal").hidden = false;
    $("status-title").textContent = "Pesanan " + num;
    $("status-body").innerHTML = `<p class="form-msg">Memuat status…</p>`;
    clearTimeout(pollTimer);
    let tries = 0;
    const load = async () => {
      const o = await fetchOrder(num);
      if (!o) { $("status-body").innerHTML = `<p class="form-msg">Pesanan tidak ditemukan di perangkat ini. Masuk ke akun kamu, atau hubungi kami lewat WhatsApp dengan nomor pesanan <b>${esc(num)}</b>.</p>`; return; }
      const saved = findOrder(num);
      const msg = {
        pending: "Pembayaran belum kami terima. Kalau sudah bayar, status akan berubah otomatis dalam beberapa saat.",
        paid: "Terima kasih! Pembayaran diterima, pesanan segera kami siapkan.",
        processing: "Pesanan sedang disiapkan.", completed: "Pesanan selesai. Selamat menikmati!",
        expired: "Waktu pembayaran habis. Silakan pesan lagi.", failed: "Pembayaran gagal. Silakan coba lagi.",
        cancelled: "Pesanan dibatalkan.",
      }[o.status] || "";
      $("status-body").innerHTML = `<p>${esc(msg)}</p>${orderCard(o)}
        ${o.status === "pending" && saved?.token ? `<button class="btn btn-rose" type="button" id="resume-pay" style="justify-content:center">Lanjutkan pembayaran</button>` : ""}
        <a class="btn btn-wa" style="justify-content:center" target="_blank" rel="noopener" href="https://wa.me/${WA}?text=${encodeURIComponent("Halo CamilaNika, saya mau tanya pesanan " + num)}">Tanya lewat WhatsApp</a>`;
      $("resume-pay")?.addEventListener("click", async () => { await loadSnap(); closeStatus(); openSnap(saved.token, num); });
      if (poll && o.status === "pending" && ++tries < 40) pollTimer = setTimeout(load, 5000);
    };
    await load();
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
        <button class="btn btn-rose" type="submit">${acctMode === "signup" ? "Daftar" : "Masuk"}</button>
        ${acctMode === "signup" ? "" : `<button type="button" class="linkish" data-mode="reset">Lupa password?</button>`}
        <p class="form-msg" id="f-msg"></p>
      </form>`}
      <p class="form-msg">Dengan akun, riwayat pesanan kamu tersimpan dan data pengiriman terisi otomatis.</p>
      ${recent.length ? `<div class="acct-sec"><h4>Pesanan di perangkat ini</h4><div id="recent-orders"><p class="form-msg">Memuat…</p></div></div>` : ""}`;
    body.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => renderAccount(b.dataset.mode)));
    $("f-auth")?.addEventListener("submit", onAuthSubmit);
    if (recent.length) loadRecent(recent);
  }

  async function loadRecent(recent) {
    const out = [];
    for (const r of recent.slice(0, 5)) {
      const { data } = await sb.rpc("get_order_status", { p_order_number: r.order_number, p_access_token: r.access_token });
      if (data) out.push(data);
    }
    const el = $("recent-orders"); if (!el) return;
    el.innerHTML = out.length ? out.map(orderCard).join("") : `<p class="form-msg">Belum ada.</p>`;
  }

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
          body: JSON.stringify({ name: $("a-name").value.trim(), phone: id, password: $("a-pass").value }),
        });
        const out = await res.json().catch(() => ({ error: "SIGNUP_FAILED" }));
        if (out.error === "PHONE_TAKEN") {
          renderAccount("login"); $("a-id").value = id;
          return formMsg("Nomor ini sudah terdaftar. Silakan masuk, atau pakai \"Lupa password?\" kalau lupa.", true);
        }
        if (!res.ok || out.error) {
          return formMsg({ PHONE_INVALID: "Nomor WhatsApp belum benar.", PASSWORD_TOO_SHORT: "Password minimal 8 karakter.", NAME_REQUIRED: "Isi nama dulu ya." }[out.error] || "Gagal mendaftar. Coba lagi sebentar.", true);
        }
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
    body.innerHTML = `
      <form class="acct-form" id="f-profile">
        <p class="form-msg">${esc(realEmail(session.user.email) || profile?.phone || "")}</p>
        <div class="field"><label for="p-name">Nama</label><input id="p-name" autocomplete="name" value="${esc(profile?.full_name)}"></div>
        <div class="field"><label for="p-phone">No. WhatsApp</label><input id="p-phone" type="tel" autocomplete="tel" value="${esc(profile?.phone)}"></div>
        <div class="field"><label for="p-addr">Alamat</label><textarea id="p-addr" rows="2">${esc(profile?.address)}</textarea></div>
        <button class="btn btn-ghost" type="submit">Simpan profil</button>
        <p class="form-msg" id="f-msg"></p>
      </form>
      <details class="acct-sec"><summary style="cursor:pointer;font-weight:800">Ganti password</summary>
        <form class="acct-form" id="f-pass" style="margin-top:.6rem"><div class="field"><label for="p-pass">Password baru (minimal 8 karakter)</label><input id="p-pass" type="password" minlength="8" autocomplete="new-password" required></div>
        <button class="btn btn-ghost" type="submit">Simpan password</button><p class="form-msg" id="f-pmsg"></p></form></details>
      <div class="acct-sec"><h4>Riwayat pesanan</h4><div id="my-orders"><p class="form-msg">Memuat…</p></div></div>
      <button class="btn btn-ghost" type="button" id="logout" style="justify-content:center">Keluar</button>`;
    $("f-profile").addEventListener("submit", async (e) => {
      e.preventDefault();
      const upd = { full_name: $("p-name").value.trim(), phone: $("p-phone").value.trim(), address: $("p-addr").value.trim() };
      const { error } = await sb.from("profiles").update(upd).eq("id", session.user.id);
      if (!error) { profile = { ...profile, ...upd }; prefill(true); }
      formMsg(error ? "Gagal menyimpan." : "Tersimpan.", !!error);
    });
    $("logout").addEventListener("click", async () => { await sb.auth.signOut(); closeAll(); });
    $("f-pass").addEventListener("submit", async (e) => {
      e.preventDefault();
      const { error } = await sb.auth.updateUser({ password: $("p-pass").value });
      const m = $("f-pmsg"); m.textContent = error ? "Gagal menyimpan password." : "Password baru tersimpan."; m.className = "form-msg" + (error ? " err" : "");
      if (!error) $("p-pass").value = "";
    });
    const { data, error } = await sb.from("orders")
      .select("order_number,status,total,discount,gifts,created_at,order_items(product_name,variant_name,choices,addon,quantity,line_total)")
      .eq("user_id", session.user.id).order("created_at", { ascending: false }).limit(30);
    const el = $("my-orders"); if (!el) return;
    el.innerHTML = error ? `<p class="form-msg err">Gagal memuat pesanan.</p>` : data.length ? data.map(orderCard).join("") : `<p class="form-msg">Belum ada pesanan.</p>`;
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
  }
  sb.auth.onAuthStateChange((event, s) => {
    if (event === "PASSWORD_RECOVERY") { session = s; renderAccount("recovery"); openDrawer(acct); return; }
    if (event === "SIGNED_IN" || event === "SIGNED_OUT" || event === "INITIAL_SESSION" || event === "USER_UPDATED") {
      setTimeout(() => onSession(s), 0); // avoid calling Supabase inside the auth callback
    }
  });

  // ------------------------------------------------------------------ copy phone
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
  if (!CFG.ONLINE_PAYMENT) {
    $("pay-btn").hidden = true;
    document.querySelector(".pay-note").hidden = true;
    $("to-checkout").textContent = "Lanjut isi data & pesan";
  }

  (async () => {
    setOffsets();
    renderCart();
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
    }
  })();
})();
