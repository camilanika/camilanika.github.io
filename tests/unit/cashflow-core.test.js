// Unit tests for js/cashflow-core.js (dates, money parsing, form previews). Run: node --test tests/unit/
const test = require("node:test");
const assert = require("node:assert/strict");
const C = require("../../js/cashflow-core.js");

// 2026-10-29 01:30 WIB = 2026-10-28 18:30 UTC (a Thursday). Checks that WIB, not UTC, decides "today".
const NOW = new Date("2026-10-28T18:30:00Z");

test("today is the Jakarta calendar day, not the UTC one", () => {
  assert.equal(C.jakartaDate(NOW), "2026-10-29");
  assert.equal(C.jakartaDate(new Date("2026-10-28T16:59:59Z")), "2026-10-28");
  assert.equal(C.jakartaDate(new Date("2026-10-28T17:00:00Z")), "2026-10-29");
});

test("date presets (#26)", () => {
  assert.deepEqual(C.presetRange("today", NOW), { from: "2026-10-29", to: "2026-10-29" });
  assert.deepEqual(C.presetRange("yesterday", NOW), { from: "2026-10-28", to: "2026-10-28" });
  assert.deepEqual(C.presetRange("week", NOW), { from: "2026-10-26", to: "2026-10-29" }, "week starts Monday");
  assert.deepEqual(C.presetRange("month", NOW), { from: "2026-10-01", to: "2026-10-29" });
  assert.deepEqual(C.presetRange("year", NOW), { from: "2026-01-01", to: "2026-10-29" });
  assert.deepEqual(C.presetRange("custom", NOW, { from: "2026-02-01", to: "2026-02-14" }), { from: "2026-02-01", to: "2026-02-14" });
  assert.throws(() => C.presetRange("decade", NOW));
});

test("week preset on a Monday and a Sunday", () => {
  assert.deepEqual(C.presetRange("week", new Date("2026-10-26T03:00:00Z")), { from: "2026-10-26", to: "2026-10-26" });
  assert.deepEqual(C.presetRange("week", new Date("2026-11-01T03:00:00Z")), { from: "2026-10-26", to: "2026-11-01" });
});

test("yesterday across a month and year boundary", () => {
  assert.deepEqual(C.presetRange("yesterday", new Date("2027-01-01T03:00:00Z")), { from: "2026-12-31", to: "2026-12-31" });
  assert.deepEqual(C.presetRange("yesterday", new Date("2028-03-01T03:00:00Z")), { from: "2028-02-29", to: "2028-02-29" });
});

test("range validation", () => {
  assert.equal(C.validateRange({ from: "2026-10-01", to: "2026-10-31" }), null);
  assert.match(C.validateRange({ from: "2026-10-31", to: "2026-10-01" }), /setelah/);
  assert.match(C.validateRange({ from: "2026-02-30", to: "2026-03-01" }), /belum lengkap/);
  assert.match(C.validateRange({ from: "", to: "2026-03-01" }), /belum lengkap/);
});

test("datetime-local values are WIB", () => {
  assert.equal(C.wibInputToIso("2026-10-15T11:05"), "2026-10-15T11:05:00+07:00");
  assert.equal(C.wibInputToIso(""), null);
  assert.equal(C.isoToWibInput("2026-10-15T04:05:00Z"), "2026-10-15T11:05");
  assert.equal(C.isoToWibInput("2026-10-31T17:30:00Z"), "2026-11-01T00:30");
  assert.equal(C.nowWibInput(NOW), "2026-10-29T01:30");
});

test("IDR formatting", () => {
  assert.equal(C.formatRp(1250000), "Rp1.250.000");
  assert.equal(C.formatRp(0), "Rp0");
  assert.equal(C.formatRp(-45000), "−Rp45.000");
  assert.equal(C.formatRp(null), "–");
});

test("Rupiah input parsing rejects decimals, negatives and text (#15)", () => {
  assert.equal(C.parseRupiah("12500"), 12500);
  assert.equal(C.parseRupiah("12.500"), 12500);
  assert.equal(C.parseRupiah("Rp 1.250.000"), 1250000);
  assert.equal(C.parseRupiah(" rp12500 "), 12500);
  assert.equal(C.parseRupiah(13000), 13000);
  for (const bad of ["", "-5", "12,5", "12.5", "1.25", "abc", "12.50.0", 10.5, -1, null, undefined]) {
    assert.ok(Number.isNaN(C.parseRupiah(bad)), `rejects ${JSON.stringify(bad)}`);
  }
});

test("offline order preview matches the server rules (#20)", () => {
  const p = C.offlinePreview([
    { variant_id: 1, quantity: 3, unit_price: "13000" },
    { variant_id: 34, quantity: 2, unit_price: "18.000", discount: "1000" },
    { product_name: "Es batu", quantity: 1, unit_price: 2000 },
  ], "5000", "4.000");
  assert.deepEqual(p.errors, []);
  assert.deepEqual(p.lines.map((l) => l.line_total), [39000, 35000, 2000]);
  assert.equal(p.subtotal, 77000);
  assert.equal(p.itemDiscount, 1000);
  assert.equal(p.total, 75000);
});

test("offline order preview catches bad input", () => {
  assert.match(C.offlinePreview([], "", "").errors.join(), /minimal satu item/);
  assert.match(C.offlinePreview([{ quantity: 1, unit_price: 1000 }], "", "").errors.join(), /pilih menu/);
  assert.match(C.offlinePreview([{ variant_id: 1, quantity: 0, unit_price: 1000 }], "", "").errors.join(), /jumlah/);
  assert.match(C.offlinePreview([{ variant_id: 1, quantity: 1.5, unit_price: 1000 }], "", "").errors.join(), /jumlah/);
  assert.match(C.offlinePreview([{ variant_id: 1, quantity: 1, unit_price: 1000, discount: 2000 }], "", "").errors.join(), /diskon lebih besar/);
  assert.match(C.offlinePreview([{ variant_id: 1, quantity: 1, unit_price: 1000 }], "5000", "").errors.join(), /Diskon pesanan/);
  assert.match(C.offlinePreview([{ variant_id: 1, quantity: 1, unit_price: "-1" }], "", "").errors.join(), /harga/);
});

test("offline header and amount-only validation (#11)", () => {
  const ok = { order_date: "2026-10-15T11:00", source: "walk_in", payment_method: "cash", classification: "real", entry_mode: "items" };
  assert.deepEqual(C.validateOfflineHeader(ok), []);
  assert.deepEqual(C.validateOfflineHeader({ ...ok, entry_mode: "amount", amount: "150.000" }), []);
  assert.equal(C.validateOfflineHeader({ ...ok, entry_mode: "amount", amount: "0" }).length, 1);
  assert.equal(C.validateOfflineHeader({ ...ok, payment_method: "crypto" }).length, 1);
  assert.equal(C.validateOfflineHeader({ ...ok, order_date: "" }).length, 1);
});

test("expense validation (#15)", () => {
  const ok = { expense_date: "2026-10-15T11:00", description: "Botol", category_id: "2", amount: "45.000", payment_method: "qris" };
  assert.deepEqual(C.validateExpense(ok), {});
  assert.ok(C.validateExpense({ ...ok, amount: "0" }).amount);
  assert.ok(C.validateExpense({ ...ok, amount: "-100" }).amount);
  assert.ok(C.validateExpense({ ...ok, amount: "10,5" }).amount);
  assert.ok(C.validateExpense({ ...ok, amount: "2000000000" }).amount);
  assert.ok(C.validateExpense({ ...ok, description: "  " }).description);
  assert.ok(C.validateExpense({ ...ok, category_id: "" }).category_id);
});

test("server error codes become readable messages", () => {
  assert.match(C.errorText({ message: "STALE_RECORD" }), /baru saja diubah/);
  assert.match(C.errorText({ message: "TOTAL_MISMATCH:52000" }), /Total/);
  assert.match(C.errorText({ message: "REF_IS_ONLINE_ORDER" }), /pesanan online/);
  assert.equal(C.errorText({ message: "something else" }), "something else");
});

test("payment labels", () => {
  assert.equal(C.paymentLabel("qris", "qris"), "QRIS / e-wallet");
  assert.equal(C.paymentLabel("qris", "gopay"), "QRIS / e-wallet (gopay)");
  assert.equal(C.paymentLabel("card", "credit_card"), "Kartu (credit card)");
});

test("form tokens are unique UUIDs", () => {
  const a = C.newToken(), b = C.newToken();
  assert.match(a, /^[0-9a-f-]{36}$/);
  assert.notEqual(a, b);
});
