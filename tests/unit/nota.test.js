// Unit tests for js/nota.js (printable bill). Run: node --test tests/unit/*.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const N = require("../../js/nota.js");

const online = {
  order_number: "CN-261029-ABC123", status: "completed", customer_name: "Budi <b>",
  created_at: "2026-10-29T02:00:00Z", paid_at: "2026-10-29T02:05:00Z",
  subtotal: 70000, discount: 15000, shipping_discount: 5000, delivery_fee: 8000, promo_code: "HEMAT10", total: 63000,
  gifts: [{ gift: "Free latte 150 ml" }],
  order_items: [
    { id: 2, product_name: "Matcha Latte", variant_name: "M 500 ml", choices: {}, addon: null, unit_price: 31000, quantity: 1, line_total: 31000 },
    { id: 1, product_name: "Americano", variant_name: "S 250 ml", choices: { "Tingkat gula": "Less Sugar" }, addon: "Extra shot", unit_price: 19500, quantity: 2, line_total: 39000 },
  ],
};

test("online order: items in order, details joined, totals and adjustments", () => {
  const n = N.fromOnlineOrder(online);
  assert.equal(n.number, "CN-261029-ABC123");
  assert.equal(n.time, online.paid_at, "paid time is the bill time");
  assert.deepEqual(n.items.map((i) => i.product), ["Americano", "Matcha Latte"]);
  assert.equal(n.items[0].detail, "S 250 ml, Less Sugar, + Extra shot");
  assert.deepEqual(n.lines, [
    { label: "Subtotal", amount: 70000 },
    { label: "Diskon", amount: -10000 },
    { label: "Ongkos kirim", amount: 8000 },
    { label: "Potongan ongkir (HEMAT10)", amount: -5000 },
  ]);
  assert.equal(n.total, 63000);
  assert.deepEqual(n.gifts, ["Free latte 150 ml"]);
});

test("bill HTML has the Data Jualan 'Nota' layout and escapes text", () => {
  const h = N.html(N.fromOnlineOrder(online));
  for (const part of ["☕ NOTA PENJUALAN", "CamilaNika", "Struk Transaksi", "No. Nota: CN-261029-ABC123", "Waktu: 29 Okt 2026", "Item: 3 Pcs",
    "<th>Produk</th><th>Detail</th>", "Harga Satuan", "Total Harga", "TOTAL PEMBAYARAN", "Rp63.000", "Terima Kasih Atas Pembeliannya",
    "Simpan nota ini sebagai bukti transaksi resmi", "Rp39.000", "−Rp10.000", "🎁 Free latte 150 ml"]) {
    assert.ok(h.includes(part), "missing: " + part);
  }
  assert.ok(h.includes("Buyer: Budi &lt;b&gt;"), "customer name is escaped");
  assert.ok(!h.includes("Belum dibayar"));
});

test("unpaid or cancelled orders are marked on the bill", () => {
  assert.match(N.html(N.fromOnlineOrder({ ...online, status: "pending" })), /Belum dibayar/);
  assert.match(N.html(N.fromOnlineOrder({ ...online, status: "cancelled" })), /dibatalkan/);
});

test("offline sale with items, discounts and extra charge", () => {
  const n = N.fromCashflowRow({ source: "offline", ttype: "income", ref: "NOTA-01", at: "2026-10-29T03:00:00Z", customer_name: "Bu Rina", amount: 75000,
    detail: { entry_mode: "items", subtotal: 77000, item_discount: 1000, order_discount: 5000, extra_charge: 4000,
      items: [{ product_name: "Americano", variant_name: "S 250 ml", quantity: 3, unit_price: 13000, discount: 0, line_total: 39000 },
              { product_name: "Matcha Latte", variant_name: "S 250 ml", quantity: 2, unit_price: 18000, discount: 1000, line_total: 35000 }] } });
  assert.equal(n.items[1].detail, "S 250 ml, diskon Rp1.000");
  assert.deepEqual(n.lines, [{ label: "Subtotal", amount: 76000 }, { label: "Diskon", amount: -5000 }, { label: "Biaya tambahan", amount: 4000 }]);
  assert.match(N.html(n), /Item: 5 Pcs/);
});

test("amount-only offline sale prints one line", () => {
  const n = N.fromCashflowRow({ source: "offline", ttype: "income", ref: "OFF-2", at: "2026-10-29T03:00:00Z", customer_name: null, amount: 150000, detail: { entry_mode: "amount" } });
  assert.equal(n.items.length, 1);
  assert.equal(n.items[0].total, 150000);
  assert.equal(n.buyer, "-");
});

test("online order from a Cashflow row matches the Pesanan version", () => {
  const n = N.fromCashflowRow({ source: "system_real", ttype: "income", ref: online.order_number, at: "x", customer_name: online.customer_name, amount: online.total,
    detail: { status: "completed", paid_at: online.paid_at, created_at: online.created_at, subtotal: 70000, discount: 15000, shipping_discount: 5000, delivery_fee: 8000, promo_code: "HEMAT10",
      items: [{ product_name: "Americano", variant_name: "S 250 ml", addon: "Extra shot", unit_price: 19500, quantity: 2, line_total: 39000 }] } });
  assert.equal(n.total, 63000);
  assert.equal(n.lines.length, 4);
  assert.equal(n.time, online.paid_at);
});

test("unpaid offline sale is marked on the bill and dated on the order day", () => {
  const n = N.fromCashflowRow({ source: "offline", ttype: "income", ref: "BON-1", at: "2026-10-29T08:00:00Z", customer_name: "Bu Tini", amount: 26000,
    detail: { entry_mode: "amount", payment_status: "unpaid", order_date: "2026-10-28T03:00:00Z" } });
  assert.equal(n.note, "Belum dibayar");
  assert.equal(n.time, "2026-10-28T03:00:00Z");
  assert.match(N.html(n), /Belum dibayar/);
});
