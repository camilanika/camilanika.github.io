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
// lists only show date / name / amount; actions live in the Detail window
async function inDetail(page, rowText, button) {
  await page.locator("#cf-list tbody tr", { hasText: rowText }).first().click();
  await page.locator("#modal-box .cf-detail").waitFor();
  await page.locator("#modal-box").getByRole("button", { name: button }).click();
}
async function openCashflow(sub = "") {
  const page = await H.open("#cashflow" + (sub ? "/" + sub : ""));
  await page.locator(".cf-card .cf-val").first().waitFor();
  return page;
}
async function waitCard(page, label, value) {
  await page.waitForFunction(([l, v]) => [...document.querySelectorAll(".cf-card")].some((c) => c.querySelector(".cf-lbl")?.textContent === l && c.querySelector(".cf-val")?.textContent === v), [label, value], { timeout: 5000 });
}

test("dashboard shows the right totals for this month, with no trace of test orders (#1, #3, #25)", async () => {
  const page = await openCashflow();
  assert.match(await text(page, ".cf-card:has-text('Total Income') .cf-hint"), /Online Rp44\.500 \(2 pesanan\) · offline Rp0/);
  assert.equal(await card(page, "Total Income"), rp(44500));
  assert.equal(await card(page, "Total Items Sold"), "3");
  assert.equal(await card(page, "Net Cashflow"), rp(44500));
  assert.equal(await page.locator(".cf-card").count(), 5, "no Real Order Income, Completed Real Orders or Mock cards");
  assert.doesNotMatch(await text(page, "#cf-cards"), /Real Order Income|Completed Real Orders/);
  assert.doesNotMatch(await text(page, "#app"), /Mock Order Value/);
  assert.match(await text(page, "#cf-banners"), /Sandbox/);
  assert.match(await text(page, "#cf-banners"), /1 pesanan selesai.*perlu ditinjau/);
  // the paid-but-not-completed order and the test order are not listed (#2, #3)
  await page.locator(".cf-table").waitFor();
  const list = await text(page, "#cf-list");
  assert.doesNotMatch(list, /Belum selesai/);
  assert.doesNotMatch(list, /TES SISTEM|Chocolate|Mock/);
  assert.equal(await page.locator("#cf-list tbody tr").count(), 2);
  assert.equal(await page.locator("#cf-f-class").count(), 0, "no Real/Mock filter");
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("date presets apply to every section (#26)", async () => {
  const page = await openCashflow();
  await page.click('[data-p="yesterday"]');
  await waitCard(page, "Total Income", "Rp0");
  await page.locator(".cf-empty").waitFor();
  assert.match(await text(page, "#cf-list"), /Belum ada transaksi/);
  await page.click('[data-s="menu"]');
  await page.locator("#cf-menu .cf-empty").waitFor();
  await page.click('[data-p="custom"]');
  await page.fill("#cf-from", "2026-10-31"); await page.fill("#cf-to", "2026-10-01");
  await page.click("#cf-apply");
  await page.locator(".toast:not([hidden])", { hasText: "Tanggal akhir" }).waitFor();
  await page.click('[data-p="today"]');
  await waitCard(page, "Total Income", rp(44500));
  await page.locator("#cf-menu .cf-table").waitFor();
  await page.context().close();
});

test("test orders: hide from Cashflow, restore and label from Pesanan (#4, #5)", async () => {
  const page = await openCashflow("orders");
  page.on("dialog", (d) => d.accept());              // the Pesanan page asks with confirm()
  await page.selectOption("#cf-f-oclass", "review");
  await page.waitForFunction(() => document.querySelectorAll("#cf-list tbody tr").length === 1);
  await inDetail(page, "Sari", "Ini pesanan tes");
  assert.match(await text(page, "#cf-confirm-body"), /hilang dari Cashflow Summary/);
  await page.click("#cf-yes");
  await waitCard(page, "Total Income", rp(26000));
  await page.locator("#cf-list .cf-empty").waitFor();
  let [o] = await H.sql("select status, classification, classification_review from orders where customer_name = 'Sari'");
  assert.deepEqual(o, { status: "completed", classification: "mock", classification_review: false }, "status untouched");

  // Pesanan: the order shows as a test order and can be switched back
  await page.goto(page.url().replace(/#.*$/, "#orders"));
  await page.selectOption("#of", "all");
  const sari = page.locator("#olist .order", { hasText: "Sari" });
  await sari.locator(".badge.cf-mock", { hasText: "Pesanan tes" }).waitFor();
  await sari.getByRole("button", { name: "Tandai pembelian asli" }).click();
  await sari.getByRole("button", { name: "Tandai pesanan tes" }).waitFor();
  // and a test order can be counted if it was a real purchase after all
  const tes = page.locator("#olist .order", { hasText: "TES SISTEM" });
  await tes.getByRole("button", { name: "Tandai pembelian asli" }).click();
  await tes.getByRole("button", { name: "Tandai pesanan tes" }).waitFor();
  await page.goto(page.url().replace(/#.*$/, "#cashflow/orders"));
  await waitCard(page, "Total Income", rp(94000));
  await page.click("#cf-reset");                      // the "Perlu ditinjau" filter is still on from before
  await page.locator("#cf-list tbody tr", { hasText: "TES SISTEM" }).waitFor();
  // put it back: hidden again
  await page.goto(page.url().replace(/#.*$/, "#orders"));
  await page.selectOption("#of", "all");
  await page.locator("#olist .order", { hasText: "TES SISTEM" }).getByRole("button", { name: "Tandai pesanan tes" }).click();
  await page.locator("#olist .order", { hasText: "TES SISTEM" }).locator(".badge.cf-mock").waitFor();
  await page.goto(page.url().replace(/#.*$/, "#cashflow/orders"));
  await waitCard(page, "Total Income", rp(44500));
  assert.doesNotMatch(await text(page, "#cf-list"), /TES SISTEM/);
  assert.doesNotMatch(await text(page, "#cf-banners"), /perlu ditinjau/, "nothing left to review");
  [o] = await H.sql("select classification, classification_review from orders where customer_name = 'Sari'");
  assert.deepEqual(o, { classification: "real", classification_review: false });
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
  await inDetail(page, "NOTA-77", "Ubah");
  await page.locator("#of-items tr").nth(0).locator('[data-k="quantity"]').fill("1");
  await page.click("#of-save");
  await waitCard(page, "Offline Order Income", rp(47000));

  // delete asks first; cancelling keeps it
  await inDetail(page, "NOTA-77", "Hapus");
  assert.match(await text(page, "#modal-box h2"), /Hapus penjualan offline/);
  await page.click("#cf-no");
  assert.equal((await H.sql("select count(*)::int n from offline_orders where deleted_at is null"))[0].n, 1);
  await inDetail(page, "NOTA-77", "Hapus");
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

test("offline sales are always real; a stored test sale is never shown (#12)", async () => {
  await H.sql(`select set_config('request.jwt.claim.sub', $1, false), public.cashflow_save_offline_order($2::jsonb)`,
    [H.ADMIN, JSON.stringify({ client_token: "55555555-5555-5555-5555-555555555555", order_date: new Date().toISOString(), order_ref: "TES-OFF",
      source: "other", payment_method: "cash", classification: "mock", items: [{ variant_id: 25, quantity: 10 }] })]);
  const page = await openCashflow("offline");
  const before = await card(page, "Total Income");
  await page.click("#cf-add-off");
  await page.locator("#cf-of").waitFor();
  assert.equal(await page.locator('input[name="of-class"]').count(), 0, "no Real/Mock choice in the form");
  await page.click("#modal [data-close]");
  await page.locator("#cf-list").waitFor();
  assert.doesNotMatch(await text(page, "#cf-list"), /TES-OFF/);
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

  await inDetail(page, "Botol 250 ml", "Ubah");
  await page.fill("#ef-amount", "60000");
  await page.click("#ef-save");
  await waitCard(page, "Total Expenses", rp(60000));
  assert.equal(await card(page, "Net Cashflow"), rp(income - 60000));

  await inDetail(page, "Botol 250 ml", "Hapus");
  assert.match(await text(page, "#modal-box h2"), /Hapus pengeluaran/);
  await page.keyboard.press("Escape");               // closing the dialog = cancel
  assert.equal((await H.sql("select count(*)::int n from expenses where deleted_at is null"))[0].n, 1);
  await inDetail(page, "Botol 250 ml", "Hapus");
  await page.click("#cf-yes");
  await waitCard(page, "Total Expenses", "Rp0");
  await page.context().close();
});

test("transaction filters and search (#27)", async () => {
  const page = await openCashflow("transactions");
  await page.locator("#cf-list .cf-table").waitFor();
  const count = async () => Number((await text(page, ".cf-pager .muted")).match(/^(\d+)/)?.[1] ?? 0);
  const total = await count();
  await page.selectOption("#cf-f-source", "offline");
  await page.waitForFunction(() => [...document.querySelectorAll("#cf-list tbody tr")].every((r) => /Offline ·/.test(r.textContent)));
  await page.click("#cf-reset");
  await page.fill("#cf-q", "matcha");
  await page.waitForFunction(() => document.querySelectorAll("#cf-list tbody tr").length === 1);
  assert.match(await text(page, "#cf-list tbody"), /Sari/);
  await page.click("#cf-reset");
  await page.waitForFunction((n) => (document.querySelector(".cf-pager .muted")?.textContent || "").startsWith(n + " "), total);
  await page.context().close();
});

test("menu sales: ranking, test orders never included (#18, #21)", async () => {
  const page = await openCashflow("menu");
  await page.locator("#cf-menu .cf-table").waitFor();
  const names = await page.locator("#cf-menu .cf-table tbody tr td:first-child b").allInnerTexts();
  assert.equal(names[0], "Americano");
  assert.ok(!names.some((n) => /Chocolate/.test(n)), "test orders not in the ranking");
  assert.equal(await page.locator("#m-scope").count(), 0, "no option to show test orders");
  await page.selectOption("#m-sort", "revenue");
  await page.fill("#m-q", "zzz");
  await page.locator("#cf-menu", { hasText: "Tidak ada menu yang cocok" }).waitFor();
  await page.context().close();
});

test("system orders are read-only here and link to Pesanan (#7)", async () => {
  const page = await openCashflow("orders");
  await page.locator("#cf-list .cf-table").waitFor();
  const row = page.locator("#cf-list tbody tr", { hasText: "Budi" });
  await row.getByRole("button", { name: "Detail" }).click();
  await page.locator("#modal-box .cf-detail").waitFor();
  assert.equal(await page.locator("#modal-box").getByRole("button", { name: "Hapus" }).count(), 0, "online orders can't be deleted here");
  assert.equal(await page.locator("#modal-box").getByRole("button", { name: "Ubah" }).count(), 0, "or edited");
  await page.click("text=Buka di Pesanan");
  await page.locator("#olist .order").first().waitFor();
  assert.equal(await page.locator("#olist .order").count(), 1);
  assert.match(await text(page, "#olist"), /Budi/);
  assert.doesNotMatch(await text(page, "#olist"), /Pesanan tes/);
  await page.locator("#olist").getByRole("button", { name: "Tandai pesanan tes" }).waitFor();
  // the normal Pesanan page and its filters still work
  await page.click("#ofall");
  await page.waitForFunction(() => document.querySelectorAll("#olist .order").length >= 1 && !/Menampilkan pesanan/.test(document.querySelector("#olist").textContent));
  await page.selectOption("#of", "all");
  await page.waitForFunction(() => document.querySelectorAll("#olist .order").length === 4);
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("lists show only date, name and amount; details are in the Detail window", async () => {
  const page = await openCashflow("transactions");
  await page.locator("#cf-list .cf-table").waitFor();
  assert.deepEqual(await page.locator("#cf-list thead th").allInnerTexts().then((h) => h.map((x) => x.trim().toLowerCase())), ["tanggal", "transaksi", "jumlah", ""]);
  const row = await text(page, "#cf-list tbody tr:first-child");
  assert.doesNotMatch(row, /QRIS|Americano|Matcha|Ubah|Hapus/, "no items, payment or edit buttons in the row");
  await page.locator("#cf-list tbody tr", { hasText: "Budi" }).click();
  const detail = await text(page, "#modal-box");
  assert.match(detail, /Americano/); assert.match(detail, /QRIS/); assert.match(detail, /Pesanan online/);
  await page.click("#modal [data-close]");
  await page.click('[data-s="menu"]');
  await page.locator("#cf-menu .cf-table").waitFor();
  assert.equal(await page.locator("#cf-menu .cf-table thead th").count(), 4);
  await page.locator("#cf-menu .cf-table tbody tr").first().click();
  assert.match(await text(page, "#modal-box"), /Rata-rata per item[\s\S]*Kontribusi/);
  await page.context().close();
});

test("offline sale not paid yet: listed and owed, counted once marked lunas", async () => {
  const page = await openCashflow("offline");
  const before = Number((await card(page, "Total Income")).replace(/\D/g, ""));
  await page.click("#cf-add-off");
  await page.locator("#of-items tr").nth(0).locator("select").selectOption({ label: "Americano · S 250 ml — Rp13.000" });
  await page.locator("#of-items tr").nth(0).locator('[data-k="quantity"]').fill("4");
  await page.fill("#of-cust", "Bu Tini");
  await page.check('input[name="of-pst"][value="unpaid"]');
  assert.equal(await page.locator("#of-paidat-wrap").isHidden(), true, "no paid date while unpaid");
  await page.click("#of-save");
  await page.locator("#cf-banners", { hasText: "belum dibayar (Rp52.000)" }).waitFor();
  assert.equal(Number((await card(page, "Total Income")).replace(/\D/g, "")), before, "not income yet");
  const row = page.locator("#cf-list tbody tr", { hasText: "Bu Tini" });
  await row.locator(".badge.cf-unpaid").waitFor();
  // filter: belum dibayar
  await page.selectOption("#cf-f-pst", "unpaid");
  await page.waitForFunction(() => [...document.querySelectorAll("#cf-list tbody tr")].every((r) => /Belum dibayar/.test(r.textContent)));
  // the bill says it isn't paid
  await row.click();
  await page.locator("#modal-box").getByRole("button", { name: "🖨️ Cetak nota" }).click();
  await page.waitForFunction(() => /Bu Tini/.test(document.getElementById("cn-nota-frame")?.getAttribute("srcdoc") || ""));
  assert.match(await page.locator("#cn-nota-frame").getAttribute("srcdoc"), /Belum dibayar/);
  // mark it paid
  await page.locator("#modal-box").getByRole("button", { name: "Tandai lunas" }).click();
  await page.selectOption("#pf-pay", "qris");
  await page.click("#pf-save");
  await waitCard(page, "Total Income", rp(before + 52000));
  assert.doesNotMatch(await text(page, "#cf-banners"), /belum dibayar/);
  const [o] = await H.sql("select payment_status, payment_method, paid_at is not null as has_paid from offline_orders where customer_name = 'Bu Tini'");
  assert.deepEqual(o, { payment_status: "paid", payment_method: "qris", has_paid: true });
  await page.context().close();
});

test("Pelanggan filter lists this period's customers and filters every list", async () => {
  await H.sql(`select set_config('request.jwt.claim.sub', $1, false), public.cashflow_save_offline_order($2::jsonb)`,
    [H.ADMIN, JSON.stringify({ client_token: "77777777-0000-0000-0000-0000000000aa", order_date: new Date().toISOString(), customer_name: 'Ana "<b>"',
      source: "walk_in", payment_method: "cash", items: [{ variant_id: 1, quantity: 1 }] })]);
  const page = await openCashflow("transactions");
  await page.locator("#cf-f-cust").waitFor();
  const opts = await page.locator("#cf-f-cust option").allInnerTexts();
  assert.ok(opts.includes("Budi (1)") && opts.includes("Sari (1)"), opts.join(", "));
  assert.ok(!opts.some((o) => /TES SISTEM/.test(o)), "no test-order customers");
  await page.selectOption("#cf-f-cust", "Budi");
  await page.waitForFunction(() => document.querySelectorAll("#cf-list tbody tr").length === 1 && /Budi/.test(document.querySelector("#cf-list tbody").textContent));
  // names with quotes / tags work and are shown as text
  await page.selectOption("#cf-f-cust", 'Ana "<b>"');
  await page.waitForFunction(() => /Ana "<b>"/.test(document.querySelector("#cf-list tbody")?.textContent || ""));
  await page.click('[data-s="offline"]');
  await page.locator("#cf-f-cust").waitFor();
  assert.equal(await page.locator("#cf-f-cust option").filter({ hasText: "Budi" }).count(), 1, "same list on Penjualan offline");
  await page.click('[data-s="expenses"]');
  await page.locator("#cf-filters").waitFor();
  assert.equal(await page.locator("#cf-f-cust").count(), 0, "no Pelanggan filter on Pengeluaran");
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("print a bill (nota) from Pesanan and from Cashflow", async () => {
  const page = await H.open("#orders");
  await page.selectOption("#of", "all");
  const budi = page.locator("#olist .order", { hasText: "Budi" });
  await budi.getByRole("button", { name: "🖨️ Cetak nota" }).click();
  const frame = page.locator("#cn-nota-frame");
  await frame.waitFor({ state: "attached" });
  let doc = await frame.getAttribute("srcdoc");
  assert.match(doc, /NOTA PENJUALAN/); assert.match(doc, /Buyer: Budi/); assert.match(doc, /Americano/);
  assert.match(doc, /Item: 2 Pcs/); assert.match(doc, /TOTAL PEMBAYARAN<\/span><b>Rp26\.000/);
  // offline sale, from the Cashflow detail window
  await H.sql(`select set_config('request.jwt.claim.sub', $1, false), public.cashflow_save_offline_order($2::jsonb)`,
    [H.ADMIN, JSON.stringify({ client_token: "66666666-6666-6666-6666-666666666666", order_date: new Date().toISOString(), order_ref: "NOTA-PRINT",
      customer_name: "Pak Dedi", source: "walk_in", payment_method: "cash", items: [{ variant_id: 1, quantity: 2 }] })]);
  await page.goto(page.url().replace(/#.*$/, "#cashflow/offline"));
  await page.locator("#cf-list tbody tr", { hasText: "Pak Dedi" }).click();
  await page.locator("#modal-box").getByRole("button", { name: "🖨️ Cetak nota" }).click();
  await page.waitForFunction(() => /NOTA-PRINT/.test(document.getElementById("cn-nota-frame")?.getAttribute("srcdoc") || ""));
  doc = await page.locator("#cn-nota-frame").getAttribute("srcdoc");
  assert.match(doc, /Buyer: Pak Dedi/); assert.match(doc, /Rp26\.000/);
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
