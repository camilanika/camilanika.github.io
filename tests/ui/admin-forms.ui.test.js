// Browser tests for admin forms that take Rupiah amounts, against a real local database.
// Run: cd tests && npm run test:ui   (needs PGHOST/PGPORT, see tests/README.md)
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

// Type like a person (no fill()), so the browser parses the number input the way it does for a real admin.
async function typeInto(page, sel, txt) {
  await page.locator(sel).click({ clickCount: 3 });
  await page.keyboard.press("Backspace");
  await page.keyboard.type(txt);
}

test("ADMIN: a new voucher typed with plain digits is saved with those amounts", async () => {
  const page = await H.open("#vouchers/vouchers");
  await page.locator("#vnew").click();
  await typeInto(page, "#nvv", "10000");
  await typeInto(page, "#nvmin", "50000");
  await typeInto(page, "#nvc", "QAPLAIN1");
  await page.click("#nvsave");
  await page.waitForFunction(() => !document.querySelector("#nvsave"));
  const [v] = await H.sql("select value, min_spend from public.vouchers where code = 'QAPLAIN1'");
  assert.deepEqual(v, { value: 10000, min_spend: 50000 });
  await page.context().close();
});

// Regression for DEF-001 (docs/test-cases-and-automation.docx): Rupiah written the Indonesian way ("10.000") used to be
// read by parseInt() as 10. admin.html now reads every whole-number field with intIn().
test("ADMIN: an amount typed as \"10.000\" is not saved as Rp10", async () => {
  const page = await H.open("#vouchers/vouchers");
  await page.locator("#vnew").click();
  await typeInto(page, "#nvv", "10.000");
  await typeInto(page, "#nvmin", "50.000");
  await typeInto(page, "#nvc", "QAFMT1");
  await page.click("#nvsave");
  await page.waitForTimeout(1000);
  const rows = await H.sql("select value, min_spend from public.vouchers where code = 'QAFMT1'");
  assert.deepEqual(rows, [{ value: 10000, min_spend: 50000 }], "\"10.000\" means ten thousand");
  await page.context().close();
});

test("ADMIN: a decimal amount is refused, not rounded or saved empty", async () => {
  const page = await H.open("#vouchers/vouchers");
  await page.locator("#vnew").click();
  await typeInto(page, "#nvv", "10.5");
  await typeInto(page, "#nvc", "QADEC1");
  await page.click("#nvsave");
  await page.locator("#nvmsg", { hasText: /Isi nilai potongan/ }).waitFor();
  assert.equal((await H.sql("select count(*)::int n from public.vouchers where code = 'QADEC1'"))[0].n, 0);
  await page.context().close();
});

// ---------------------------------------------------------------- regressions for other QA fixes (8 Nov 2026)
test("ADMIN: the admin page refuses to work inside another site's frame (OBS-31)", async () => {
  const page = await H.open("", { file: "index.html" });
  await page.setContent(`<h1>other site</h1><iframe src="${H.base}/admin.html" width="800" height="500"></iframe>`);
  // frame-busting: the admin page replaces the framing page instead of showing inside it
  await page.waitForURL(/\/admin\.html/, { timeout: 8000 });
  assert.equal(page.frames().length, 1, "no frame left");
  await page.context().close();
});

test("ADMIN: an order paid after its stock was resold shows 'Perlu dicek' (OBS-2, OBS-4)", async () => {
  const [o] = await H.sql("select order_number from public.orders where status = 'completed' order by order_number limit 1");
  await H.sql("update public.orders set payment_issue = 'OVERSOLD:1:2' where order_number = $1", [o.order_number]);
  const page = await H.open("#orders/" + o.order_number);
  const badge = page.locator(".card.order .badge", { hasText: "Perlu dicek" });
  await badge.waitFor();
  assert.match(await badge.getAttribute("title"), /stoknya terjual ke pesanan lain \(stok kurang 2\)/);
  await H.sql("update public.orders set payment_issue = null where order_number = $1", [o.order_number]);
  await page.context().close();
});

test("ADMIN: 'Reset password' is offered for customers and yourself, not for other admins (OBS-23)", async () => {
  await H.sql("insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a2', 'admin2@test.local') on conflict do nothing");
  await H.sql("update public.profiles set role = 'admin', full_name = 'Admin Dua' where id = '00000000-0000-0000-0000-0000000000a2'");
  const page = await H.open("#customers");
  const row = (name) => page.locator("#cbody tr", { hasText: name });
  await row("Admin Dua").waitFor();
  assert.equal(await row("Admin Dua").locator("[data-reset]").count(), 0, "other admin: no reset");
  assert.equal(await row("Admin Tes").locator("[data-reset]").count(), 1, "yourself: reset offered");
  await page.context().close();
});

test("CASH: 'Hari ini' moves to the new day after midnight WIB without reopening the page (OBS-26)", async () => {
  const page = await H.open("");
  await page.clock.setFixedTime(new Date("2026-11-08T16:59:00Z"));   // 23.59 WIB
  await page.evaluate(() => { location.hash = "#cashflow"; });
  await page.locator('#cf-presets [data-p="today"]').click();
  await page.locator("#cf-range", { hasText: "8 Nov 2026" }).waitFor();
  await page.clock.setFixedTime(new Date("2026-11-08T17:01:00Z"));   // 00.01 WIB, next day
  await page.click("#cf-ref");
  await page.locator("#cf-range", { hasText: "9 Nov 2026" }).waitFor({ timeout: 5000 });
  await page.context().close();
});
