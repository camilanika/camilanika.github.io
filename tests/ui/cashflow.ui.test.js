// Browser tests for the Cashflow Summary page (admin.html#cashflow), against a real local database.
// Run: cd tests && npm run test:ui   (needs PGHOST/PGPORT, see tests/README.md)
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

const text = (page, sel) => page.locator(sel).innerText();
const card = (page, label) => page.locator(".cf-card", { hasText: label }).first().locator(".cf-val").innerText();
const rp = (n) => "Rp" + n.toLocaleString("id-ID");
async function openCashflow(sub = "") {
  const page = await H.open("#cashflow" + (sub ? "/" + sub : ""));
  await page.locator(".cf-card .cf-val").first().waitFor();
  return page;
}
async function waitCard(page, label, value) {
  await page.waitForFunction(([l, v]) => [...document.querySelectorAll(".cf-card")].some((c) => c.querySelector(".cf-lbl")?.textContent === l && c.querySelector(".cf-val")?.textContent === v), [label, value], { timeout: 5000 });
}

test("dashboard shows the right totals for this month (#1, #3, #25)", async () => {
  const page = await openCashflow();
  assert.equal(await card(page, "Real Order Income"), rp(44500));
  assert.equal(await card(page, "Completed Real Orders"), "2");
  assert.equal(await card(page, "Mock Order Value"), rp(49500));
  assert.equal(await card(page, "Total Income"), rp(44500));
  assert.equal(await card(page, "Total Items Sold"), "3");
  assert.equal(await card(page, "Net Cashflow"), rp(44500));
  assert.match(await text(page, "#cf-banners"), /Sandbox/);
  assert.match(await text(page, "#cf-banners"), /1 pesanan selesai.*perlu ditinjau/);
  // the paid-but-not-completed order is not listed (#2)
  await page.locator(".cf-table").waitFor();
  assert.doesNotMatch(await text(page, "#cf-list"), /Belum selesai/);
  assert.equal(await page.locator("#cf-list tbody tr").count(), 3);
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("date presets apply to every section (#26)", async () => {
  const page = await openCashflow();
  await page.click('[data-p="yesterday"]');
  await waitCard(page, "Real Order Income", "Rp0");
  await page.locator(".cf-empty").waitFor();
  assert.match(await text(page, "#cf-list"), /Belum ada transaksi/);
  await page.click('[data-s="menu"]');
  await page.locator("#cf-menu .cf-empty").waitFor();
  await page.click('[data-p="custom"]');
  await page.fill("#cf-from", "2026-10-31"); await page.fill("#cf-to", "2026-10-01");
  await page.click("#cf-apply");
  await page.locator(".toast:not([hidden])", { hasText: "Tanggal akhir" }).waitFor();
  await page.click('[data-p="today"]');
  await waitCard(page, "Real Order Income", rp(44500));
  await page.locator("#cf-menu .cf-table").waitFor();
  await page.context().close();
});

test("reclassifying an order updates every total and keeps its status (#4, #5)", async () => {
  const page = await openCashflow("orders");
  await page.locator("#cf-list .cf-table").waitFor();
  const row = page.locator("#cf-list tbody tr", { hasText: "TES SISTEM" });
  await row.getByRole("button", { name: "Jadikan Real" }).click();
  assert.match(await text(page, "#cf-confirm-body"), /Status pesanan tidak berubah/);
  await page.click("#cf-yes");
  await waitCard(page, "Real Order Income", rp(94000));
  assert.equal(await card(page, "Mock Order Value"), "Rp0");
  const [o] = await H.sql("select status, classification, classification_review from orders where customer_name = 'TES SISTEM'");
  assert.deepEqual(o, { status: "completed", classification: "real", classification_review: false });
  // and back
  await page.locator("#cf-list tbody tr", { hasText: "TES SISTEM" }).getByRole("button", { name: "Jadikan Mock (tes)" }).click();
  await page.click("#cf-yes");
  await waitCard(page, "Real Order Income", rp(44500));
  assert.equal(await card(page, "Mock Order Value"), rp(49500));
  await page.context().close();
});

test("offline order with several items: preview, save once, edit, delete with confirmation (#8, #9, #10, #6)", async () => {
  const page = await openCashflow("offline");
  await page.click("#cf-add-off");
  await page.locator("#cf-of").waitFor();
  const rows = page.locator("#of-items tr");
  await rows.nth(0).locator("select").selectOption({ label: "Americano · S 250 ml — Rp13.000" });
  await rows.nth(0).locator('[data-k="quantity"]').fill("3");
  await page.click("#of-addrow");
  await rows.nth(1).locator("select").selectOption({ label: "Matcha Latte · S 250 ml — Rp18.500" });
  await rows.nth(1).locator('[data-k="quantity"]').fill("2");
  await rows.nth(1).locator('[data-k="discount"]').fill("2.000");
  await page.fill("#of-odisc", "1000");
  await page.fill("#of-ref", "NOTA-77");
  await page.fill("#of-cust", "Bu Rina");
  assert.equal(await text(page, "#of-total"), rp(39000 + 37000 - 2000 - 1000));
  // double click on save: one record only
  await page.locator("#of-save").dblclick();
  await page.locator("#modal[hidden]").waitFor({ state: "attached" });
  await waitCard(page, "Offline Order Income", rp(73000));
  assert.equal((await H.sql("select count(*)::int n from offline_orders where deleted_at is null"))[0].n, 1);
  assert.equal(await card(page, "Total Items Sold"), "8");

  // edit: change quantity, server recalculates
  const row = page.locator("#cf-list tbody tr", { hasText: "NOTA-77" });
  await row.getByRole("button", { name: "Ubah" }).click();
  await page.locator("#of-items tr").nth(0).locator('[data-k="quantity"]').fill("1");
  await page.click("#of-save");
  await waitCard(page, "Offline Order Income", rp(47000));

  // delete asks first; cancelling keeps it
  await page.locator("#cf-list tbody tr", { hasText: "NOTA-77" }).getByRole("button", { name: "Hapus" }).click();
  assert.match(await text(page, "#modal-box h2"), /Hapus penjualan offline/);
  await page.click("#cf-no");
  assert.equal((await H.sql("select count(*)::int n from offline_orders where deleted_at is null"))[0].n, 1);
  await page.locator("#cf-list tbody tr", { hasText: "NOTA-77" }).getByRole("button", { name: "Hapus" }).click();
  await page.click("#cf-yes");
  await waitCard(page, "Offline Order Income", "Rp0");
  assert.equal((await H.sql("select count(*)::int n from offline_orders where deleted_at is null"))[0].n, 0);
  await page.context().close();
});

test("an online order number can't be recorded as an offline sale (#13)", async () => {
  const page = await openCashflow("offline");
  const [{ order_number }] = await H.sql("select order_number from orders where customer_name = 'Budi'");
  await page.click("#cf-add-off");
  await page.check('input[name="of-mode"][value="amount"]');
  await page.fill("#of-amount", "26000");
  await page.fill("#of-ref", order_number);
  await page.click("#of-save");
  await page.locator("#of-err", { hasText: "pesanan online" }).waitFor();
  assert.equal((await H.sql("select count(*)::int n from offline_orders"))[0].n, 1, "only the deleted one from the previous test");
  await page.context().close();
});

test("amount-only offline sale counts as income but is disclosed in menu sales (#11, #23)", async () => {
  const page = await openCashflow("offline");
  await page.click("#cf-add-off");
  await page.check('input[name="of-mode"][value="amount"]');
  await page.selectOption("#of-src", "whatsapp");
  await page.selectOption("#of-pay", "bank_transfer");
  await page.fill("#of-amount", "150.000");
  assert.equal(await text(page, "#of-total"), rp(150000));
  await page.click("#of-save");
  await waitCard(page, "Offline Order Income", rp(150000));
  assert.equal(await card(page, "Total Items Sold"), "3");
  await page.click('[data-s="menu"]');
  await page.locator("#cf-menu .cf-table").waitFor();
  assert.match(await text(page, "#cf-menu"), /1 penjualan offline nominal saja \(Rp150\.000\)/);
  await page.context().close();
});

test("offline mock sale is not income (#12)", async () => {
  const page = await openCashflow("offline");
  const before = await card(page, "Total Income");
  await page.click("#cf-add-off");
  await page.locator("#of-items tr").nth(0).locator("select").selectOption({ label: "Chocolate · S 250 ml — Rp16.500" });
  await page.check('input[name="of-class"][value="mock"]');
  await page.click("#of-save");
  await waitCard(page, "Mock Order Value", rp(49500 + 16500));
  assert.equal(await card(page, "Total Income"), before);
  await page.context().close();
});

test("expenses: validation, create, edit, delete with confirmation (#14, #15, #16, #17)", async () => {
  const page = await openCashflow("expenses");
  const incomeText = await card(page, "Total Income");
  const income = Number(incomeText.replace(/\D/g, ""));
  await page.click("#cf-add-exp");
  await page.fill("#ef-desc", "Botol 250 ml");
  await page.selectOption("#ef-cat", { label: "Packaging" });
  await page.selectOption("#ef-pay", "qris");
  for (const bad of ["-5000", "0", "12,5", "abc"]) {
    await page.fill("#ef-amount", bad);
    await page.click("#ef-save");
    await page.locator('.cf-ferr[data-for="amount"]', { hasText: "lebih dari 0" }).waitFor();
  }
  assert.equal((await H.sql("select count(*)::int n from expenses"))[0].n, 0, "invalid amounts never reach the database");
  await page.fill("#ef-amount", "45.000");
  await page.fill("#ef-vendor", "Toko Plastik Jaya");
  await page.setInputFiles("#ef-file", { name: "nota.jpg", mimeType: "image/jpeg", buffer: Buffer.from([0xff, 0xd8, 0xff]) });
  await page.click("#ef-save");
  await waitCard(page, "Total Expenses", rp(45000));
  assert.equal(await card(page, "Net Cashflow"), rp(income - 45000));
  const [e] = await H.sql("select category_name, payment_method, amount, vendor, receipt_path from expenses");
  assert.equal(e.category_name, "Packaging"); assert.equal(e.payment_method, "qris"); assert.equal(e.amount, 45000);
  assert.equal(e.vendor, "Toko Plastik Jaya"); assert.match(e.receipt_path, /^\d{4}\/[0-9a-f-]+\.jpg$/);

  await page.locator("#cf-list tbody tr", { hasText: "Botol 250 ml" }).getByRole("button", { name: "Ubah" }).click();
  await page.fill("#ef-amount", "60000");
  await page.click("#ef-save");
  await waitCard(page, "Total Expenses", rp(60000));
  assert.equal(await card(page, "Net Cashflow"), rp(income - 60000));

  await page.locator("#cf-list tbody tr", { hasText: "Botol 250 ml" }).getByRole("button", { name: "Hapus" }).click();
  assert.match(await text(page, "#modal-box h2"), /Hapus pengeluaran/);
  await page.keyboard.press("Escape");               // closing the dialog = cancel
  assert.equal((await H.sql("select count(*)::int n from expenses where deleted_at is null"))[0].n, 1);
  await page.locator("#cf-list tbody tr", { hasText: "Botol 250 ml" }).getByRole("button", { name: "Hapus" }).click();
  await page.click("#cf-yes");
  await waitCard(page, "Total Expenses", "Rp0");
  await page.context().close();
});

test("transaction filters and search (#27)", async () => {
  const page = await openCashflow("transactions");
  await page.locator("#cf-list .cf-table").waitFor();
  const count = async () => Number((await text(page, ".cf-pager .muted")).match(/^(\d+)/)?.[1] ?? 0);
  const total = await count();
  await page.selectOption("#cf-f-class", "mock");
  await page.waitForFunction(() => /Mock/.test(document.querySelector("#cf-list")?.textContent || ""));
  assert.ok((await page.locator("#cf-list tbody tr").allInnerTexts()).every((t) => /Mock/.test(t)));
  await page.click("#cf-reset");
  await page.fill("#cf-q", "matcha");
  await page.waitForFunction(() => document.querySelectorAll("#cf-list tbody tr").length === 1);
  assert.match(await text(page, "#cf-list tbody"), /Sari/);
  await page.click("#cf-reset");
  await page.waitForFunction((n) => (document.querySelector(".cf-pager .muted")?.textContent || "").startsWith(n + " "), total);
  await page.context().close();
});

test("menu sales: ranking, mock excluded by default, mock view labelled (#18, #21)", async () => {
  const page = await openCashflow("menu");
  await page.locator("#cf-menu .cf-table").waitFor();
  const names = await page.locator("#cf-menu .cf-table tbody tr td:first-child").allInnerTexts();
  assert.equal(names[0], "Americano");
  assert.ok(!names.some((n) => /Chocolate/.test(n)), "mock orders not in real ranking");
  await page.selectOption("#m-scope", "mock");
  await page.locator("#cf-menu .cf-note.warn", { hasText: "MOCK" }).waitFor();
  assert.match(await text(page, "#cf-menu .cf-table"), /Chocolate/);
  await page.selectOption("#m-sort", "revenue");
  await page.fill("#m-q", "zzz");
  await page.locator("#cf-menu", { hasText: "Tidak ada menu yang cocok" }).waitFor();
  await page.context().close();
});

test("system orders are read-only here and link to Pesanan (#7)", async () => {
  const page = await openCashflow("orders");
  await page.locator("#cf-list .cf-table").waitFor();
  const row = page.locator("#cf-list tbody tr", { hasText: "Budi" });
  assert.equal(await row.getByRole("button", { name: "Hapus" }).count(), 0);
  assert.equal(await row.getByRole("button", { name: "Ubah" }).count(), 0);
  await row.getByRole("button", { name: "Detail" }).click();
  await page.click("text=Buka di Pesanan");
  await page.locator("#olist .order").first().waitFor();
  assert.equal(await page.locator("#olist .order").count(), 1);
  assert.match(await text(page, "#olist"), /Budi/);
  assert.match(await text(page, "#olist"), /Real/);
  // the normal Pesanan page and its filters still work
  await page.click("#ofall");
  await page.waitForFunction(() => document.querySelectorAll("#olist .order").length >= 1 && !/Menampilkan pesanan/.test(document.querySelector("#olist").textContent));
  await page.selectOption("#of", "all");
  await page.waitForFunction(() => document.querySelectorAll("#olist .order").length === 4);
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("non-admins can't use the page (#28)", async () => {
  const page = await H.open("#cashflow", { uid: H.CUSTOMER });
  await page.locator("text=Bukan akun admin").waitFor();
  const r = await page.evaluate(() => fetch("/__rpc", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ uid: window.__TEST_UID, fn: "cashflow_summary", args: { p_from: "2026-01-01", p_to: "2026-12-31" } }) }).then((x) => x.json()));
  assert.match(r.error.message, /NOT_ADMIN/);
  await page.context().close();
});

test("two quick login events (as on the live site) don't break the page", async () => {
  const page = await H.open("#cashflow/orders", { doubleAuth: true });
  await page.locator("#cf-list .cf-table").waitFor();
  await page.waitForTimeout(800);
  assert.equal(await page.locator("#cf-filters").count(), 1);
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("phone layout: no sideways scrolling", async () => {
  const page = await H.open("#cashflow/transactions", { viewport: { width: 375, height: 800 } });
  await page.locator("#cf-list .cf-table").waitFor();
  for (const s of ["transactions", "menu", "settings"]) {
    await page.click("#nav-toggle").catch(() => {});
    await page.keyboard.press("Escape");
    await page.click(`[data-s="${s}"]`);
    await page.waitForTimeout(300);
    const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    assert.ok(over <= 1, `${s}: page is ${over}px wider than the screen`);
  }
  await page.click("#cf-add-off");
  const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  assert.ok(over <= 1, `offline form: ${over}px too wide`);
  await page.context().close();
});
