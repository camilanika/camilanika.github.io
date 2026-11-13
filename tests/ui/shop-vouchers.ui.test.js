// Checkout picks the best voucher automatically (js/shop.js autoApply, commits c7ebecb and ef7eb31, 13 Nov 2026).
// Catalogue cases PROMO-11 to PROMO-15 in docs/test-cases-and-automation.docx (QA run INSP-4).
const test = require("node:test");
const assert = require("node:assert/strict");
const { start, CUSTOMER } = require("./harness");

let H;
test.before(async () => {
  // two public code promos: HEMAT5 for any order, HEMAT15 once the cart reaches two of the first menu item (set per test)
  H = await start({ seedSql: `
    delete from public.promotions;
    insert into public.promotions (name, code, discount_type, value, min_spend, announce) values
      ('Hemat 5rb', 'HEMAT5', 'fixed', 5000, 0, true),
      ('Hemat 15rb', 'HEMAT15', 'fixed', 15000, 999999999, true);` });
});
test.after(async () => { await H?.close(); });

const PHONE = { width: 390, height: 844 };
const PAY = /^https:\/\/sandbox\.ipaymu\.com\/payment\/sess-/;
const rpNum = (s) => Number(String(s).replace(/[^\d]/g, ""));

// the shop with one of the first menu item in the cart and the checkout form open; returns the item's price
async function openCheckout({ uid = null } = {}) {
  const page = await H.open("?test=1", { uid, viewport: PHONE, file: "" });
  await page.locator("[data-pick]").first().waitFor();
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
  await page.locator("#cart-subtotal, #cart-total").first().waitFor();
  await page.waitForFunction(() => document.querySelector("#cart-total") && /\d/.test(document.querySelector("#cart-total").textContent));
  const unit = await page.evaluate(() => JSON.parse(localStorage.getItem("cn-cart-v2"))[0].price);
  // HEMAT15 needs two of this item
  await H.sql("update public.promotions set min_spend = $1 where code = 'HEMAT15'", [unit * 2]);
  return { page, unit };
}
const code = (page) => page.inputValue("#promo-code");
const total = async (page) => rpNum(await page.locator("#cart-total").innerText());
const waitCode = (page, c) => page.waitForFunction((c) => document.querySelector("#promo-code").value === c, c, { timeout: 5000 });
const plusOne = (page) => page.locator('#cart-lines [data-d="1"]').first().click();

test("PROMO-11: the best code is applied automatically, and the order is charged what the cart showed", async () => {
  const { page, unit } = await openCheckout();
  await waitCode(page, "HEMAT5");
  await page.locator("#auto-msg", { hasText: "HEMAT5 otomatis dipakai" }).waitFor();
  await page.waitForFunction((t) => Number(document.querySelector("#cart-total").textContent.replace(/[^\d]/g, "")) === t, unit - 5000);
  const shown = await total(page);
  await plusOne(page);                                         // two items: HEMAT15 is now better
  await waitCode(page, "HEMAT15");
  await page.waitForFunction((t) => Number(document.querySelector("#cart-total").textContent.replace(/[^\d]/g, "")) === t, unit * 2 - 15000);
  await page.fill("#cust-name", "Voucher Otomatis");
  await page.fill("#cust-phone", "081234567801");
  await Promise.all([page.waitForURL(PAY), page.locator("#pay-btn").click()]);
  const num = page.url().replace(PAY, "");
  const [o] = await H.sql("select total, discount, promo_code from public.orders where order_number = $1", [num]);
  assert.equal(o.total, unit * 2 - 15000, "charged the total the cart showed");
  assert.ok(shown === unit - 5000);
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("PROMO-12: a code the customer cleared is not put back", async () => {
  const { page, unit } = await openCheckout();
  await waitCode(page, "HEMAT5");
  await page.fill("#promo-code", "");
  await page.click("#apply-code");
  await plusOne(page);                                         // a change that would normally trigger a new choice
  await page.waitForTimeout(1500);
  assert.equal(await code(page), "", "the code stays empty");
  assert.equal(await total(page), unit * 2, "no discount");
  assert.ok(await page.locator("#auto-msg").isHidden());
  await page.context().close();
});

test("PROMO-13: a code the customer typed is never replaced by a better one", async () => {
  const { page, unit } = await openCheckout();
  await waitCode(page, "HEMAT5");
  await plusOne(page);
  await waitCode(page, "HEMAT15");                             // two items: the shop picks HEMAT15
  await page.fill("#promo-code", "hemat5");
  await page.click("#apply-code");                             // the customer prefers HEMAT5 (saves less)
  await plusOne(page);                                         // a change that would normally trigger a new choice
  await page.waitForTimeout(1500);
  assert.equal((await code(page)).toUpperCase(), "HEMAT5");   // the box keeps what was typed (shown upper-case by CSS)
  assert.equal(await total(page), unit * 3 - 5000);
  assert.ok(await page.locator("#auto-msg").isHidden(), "not presented as an automatic choice");
  await page.context().close();
});

test("PROMO-14: a logged-in customer's own voucher is chosen when it saves the most, and the link counts it", async () => {
  await H.sql(`insert into public.vouchers (code, source, user_id, discount_type, value, status)
               values ('QA-MINE-20', 'admin', $1, 'fixed', 20000, 'available')`, [CUSTOMER]);
  try {
    const { page } = await openCheckout({ uid: CUSTOMER });
    await waitCode(page, "QA-MINE-20");
    await page.locator("#vc-link", { hasText: "Pilih voucher kamu (1 tersedia)" }).waitFor();
    await page.context().close();
  } finally {
    await H.sql("delete from public.voucher_events where voucher_id in (select id from public.vouchers where code = 'QA-MINE-20'); delete from public.vouchers where code = 'QA-MINE-20'");
  }
});

// Regression for OBS-40: the normal cart quote and the automatic voucher choice ran side by side with no ordering.
// When the normal quote for the old code answered after the automatic choice had switched code, the cart showed the
// old code's discount and total under the new code (Rp45.000 shown, Rp35.000 charged). runQuote() now drops answers
// that are no longer current.
test("PROMO-15: a slow quote for the old code doesn't overwrite the total of the newly chosen code", async () => {
  const { page, unit } = await openCheckout();
  await waitCode(page, "HEMAT5");
  await page.waitForTimeout(800);                              // let every quote for one item finish
  let slowed = false;
  await page.route("**/__rpc", async (route) => {
    const b = JSON.parse(route.request().postData() || "{}");
    // the first HEMAT5 quote after the change is the normal cart quote (it starts 50 ms before the automatic choice)
    if (!slowed && b.fn === "quote_cart" && b.args?.p_promo_code === "HEMAT5") { slowed = true; await new Promise((r) => setTimeout(r, 2000)); }
    await route.continue();
  });
  await plusOne(page);
  await waitCode(page, "HEMAT15");
  await page.waitForTimeout(2500);                             // the slow HEMAT5 quote arrives
  assert.ok(slowed, "the normal quote was slowed");
  assert.equal(await code(page), "HEMAT15");
  assert.equal(await total(page), unit * 2 - 15000, "the total belongs to the code in the box");
  await page.context().close();
});
