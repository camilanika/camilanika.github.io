// CamilaNika admin · printable bill ("Nota Penjualan"), same layout as the "Nota" sheet in Data Jualan.
// CNNota.fromOnlineOrder(order)   an orders row with order_items (Pesanan page)
// CNNota.fromCashflowRow(row)      a Cashflow Summary transaction (online or offline sale)
// CNNota.html(nota)                the bill as a standalone HTML page (pure: unit-tested in Node)
// CNNota.print(nota)               prints it from a hidden frame (browser only)
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.CNNota = api;
})(typeof self !== "undefined" ? self : this, function () {
  const TZ = "Asia/Jakarta";
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const rp = (n) => (Number(n) < 0 ? "−Rp" : "Rp") + Math.abs(Math.round(Number(n) || 0)).toLocaleString("id-ID");
  const when = (iso) => {
    if (!iso) return "-";
    const d = new Date(iso);
    return isNaN(d) ? "-" : d.toLocaleString("id-ID", { timeZone: TZ, day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }) + " WIB";
  };

  // online order (orders + order_items) -> bill
  function fromOnlineOrder(o) {
    const items = (o.order_items || []).slice().sort((a, b) => (a.id || 0) - (b.id || 0)).map((i) => ({
      product: i.product_name,
      detail: [i.variant_name, ...Object.values(i.choices || {}), i.addon ? "+ " + i.addon : null].filter(Boolean).join(", "),
      qty: i.quantity, unit: i.unit_price, total: i.line_total,
    }));
    const itemDiscount = (o.discount || 0) - (o.shipping_discount || 0);
    const lines = [];
    if (itemDiscount > 0 || o.delivery_fee) lines.push({ label: "Subtotal", amount: o.subtotal });
    if (itemDiscount > 0) lines.push({ label: "Diskon" + (o.promo_code && !o.shipping_discount ? ` (${o.promo_code})` : ""), amount: -itemDiscount });
    if (o.delivery_fee) lines.push({ label: "Ongkos kirim", amount: o.delivery_fee });
    if (o.shipping_discount) lines.push({ label: "Potongan ongkir" + (o.promo_code ? ` (${o.promo_code})` : ""), amount: -o.shipping_discount });
    return {
      number: o.order_number, time: o.paid_at || o.created_at, buyer: o.customer_name || "-",
      items, gifts: (o.gifts || []).map((g) => g.gift).filter(Boolean), lines, total: o.total,
      note: o.status === "pending" ? "Belum dibayar" : ["cancelled", "expired", "failed"].includes(o.status) ? "Pesanan dibatalkan / tidak dibayar" : "",
    };
  }

  // Cashflow Summary row (online order or offline sale) -> bill
  function fromCashflowRow(r) {
    const d = r.detail || {};
    if (r.source === "offline") {
      const items = d.entry_mode === "amount"
        ? [{ product: "Penjualan", detail: "Tanpa rincian item", qty: 1, unit: r.amount, total: r.amount }]
        : (d.items || []).map((i) => ({ product: i.product_name, detail: [i.variant_name, i.discount ? "diskon " + rp(i.discount) : null].filter(Boolean).join(", "), qty: i.quantity, unit: i.unit_price, total: i.line_total }));
      const lines = [];
      if (d.entry_mode === "items" && (d.order_discount || d.extra_charge)) lines.push({ label: "Subtotal", amount: d.subtotal - d.item_discount });
      if (d.order_discount) lines.push({ label: "Diskon", amount: -d.order_discount });
      if (d.extra_charge) lines.push({ label: "Biaya tambahan", amount: d.extra_charge });
      return { number: r.ref, time: r.at, buyer: r.customer_name || "-", items, gifts: [], lines, total: r.amount, note: "" };
    }
    return fromOnlineOrder({
      order_number: r.ref, paid_at: d.paid_at, created_at: d.created_at, customer_name: r.customer_name, status: d.status,
      order_items: (d.items || []).map((i, n) => ({ id: n, product_name: i.product_name, variant_name: i.variant_name, addon: i.addon, unit_price: i.unit_price, quantity: i.quantity, line_total: i.line_total })),
      subtotal: d.subtotal, discount: d.discount, shipping_discount: d.shipping_discount, delivery_fee: d.delivery_fee, promo_code: d.promo_code, total: r.amount,
    });
  }

  function html(n) {
    const pcs = n.items.reduce((s, i) => s + (Number(i.qty) || 0), 0);
    const rows = n.items.length
      ? n.items.map((i) => `<tr><td>${esc(i.product)}</td><td class="dt">${esc(i.detail)}</td><td class="c">${esc(i.qty)}</td><td class="r">${rp(i.unit)}</td><td class="r">${rp(i.total)}</td></tr>`).join("")
      : `<tr><td colspan="5" class="dt">(Tidak ada item)</td></tr>`;
    const gifts = n.gifts.map((g) => `<tr><td>🎁 ${esc(g)}</td><td class="dt">Bonus</td><td class="c">1</td><td class="r">${rp(0)}</td><td class="r">${rp(0)}</td></tr>`).join("");
    const lines = n.lines.map((l) => `<tr class="ln"><td colspan="4" class="r">${esc(l.label)}</td><td class="r">${rp(l.amount)}</td></tr>`).join("");
    return `<!doctype html><html lang="id"><head><meta charset="utf-8"><title>Nota ${esc(n.number)}</title>
<style>
  @page { size: A5 portrait; margin: 10mm; }
  * { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  body { margin: 0; font: 11pt/1.35 "Nunito", Arial, sans-serif; color: #3b2418; }
  .nota { max-width: 160mm; margin: 0 auto; border: 1.5px solid #4A2A1C; }
  .hd { background: #4A2A1C; color: #fff; text-align: center; font-weight: 800; font-size: 15pt; padding: 8px; letter-spacing: .02em; }
  .brand { background: #F6DEDA; text-align: center; font-weight: 800; padding: 5px; }
  .sub { background: #FBF0EE; text-align: center; font-style: italic; font-size: 9pt; padding: 3px; border-bottom: 1px solid #c9b2a6; }
  .meta { display: grid; grid-template-columns: 1fr auto; gap: 3px 10px; padding: 7px 8px; border-bottom: 2px solid #4A2A1C; font-size: 10pt; }
  .meta .r { text-align: right; }
  table { width: 100%; border-collapse: collapse; }
  th { background: #F3E9E4; text-align: left; padding: 6px 8px; border-bottom: 2px solid #4A2A1C; font-size: 10.5pt; }
  td { padding: 5px 8px; vertical-align: top; font-size: 10pt; }
  .c { text-align: center; } .r { text-align: right; white-space: nowrap; } .dt { color: #6b4c3f; }
  tbody tr:last-child td { padding-bottom: 14px; }
  .ln td { padding-top: 2px; padding-bottom: 2px; color: #6b4c3f; }
  .tot { display: flex; justify-content: flex-end; gap: 30px; background: #F6DEDA; border-top: 2px solid #4A2A1C; border-bottom: 2px solid #4A2A1C; padding: 7px 8px; font-weight: 800; }
  .tot b { color: #1F6B2E; }
  .note { text-align: center; color: #b3261e; font-weight: 800; padding: 4px; }
  .ft { text-align: center; padding: 16px 8px 10px; }
  .ft strong { display: block; } .ft small { font-style: italic; color: #6b4c3f; }
</style></head><body><div class="nota">
  <div class="hd">☕ NOTA PENJUALAN</div>
  <div class="brand">CamilaNika</div>
  <div class="sub">Struk Transaksi</div>
  <div class="meta"><span>No. Nota: ${esc(n.number)}</span><span class="r">Waktu: ${esc(when(n.time))}</span>
    <span>Buyer: ${esc(n.buyer)}</span><span class="r">Item: ${pcs} Pcs</span></div>
  <table><thead><tr><th>Produk</th><th>Detail</th><th class="c">Qty</th><th class="r">Harga Satuan</th><th class="r">Total Harga</th></tr></thead>
    <tbody>${rows}${gifts}${lines}</tbody></table>
  <div class="tot"><span>TOTAL PEMBAYARAN</span><b>${rp(n.total)}</b></div>
  ${n.note ? `<div class="note">${esc(n.note)}</div>` : ""}
  <div class="ft"><strong>✨ Terima Kasih Atas Pembeliannya ✨</strong><small>Simpan nota ini sebagai bukti transaksi resmi</small></div>
</div></body></html>`;
  }

  // print from a hidden frame, so the admin page stays as it is
  function print(n) {
    let f = document.getElementById("cn-nota-frame");
    if (f) f.remove();
    f = document.createElement("iframe");
    f.id = "cn-nota-frame";
    f.title = "Nota";
    f.setAttribute("aria-hidden", "true");
    f.style.cssText = "position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden";
    f.onload = () => { try { f.contentWindow.focus(); f.contentWindow.print(); } catch (e) { window.open().document.write(html(n)); } };
    f.srcdoc = html(n);
    document.body.appendChild(f);
  }

  return { fromOnlineOrder, fromCashflowRow, html, print };
});
