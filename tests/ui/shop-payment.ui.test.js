// Shop checkout → iPaymu payment page → back to the order page. iPaymu's page is a stand-in;
// the test follows returnUrl / cancelUrl itself, like the customer's browser would.
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

const PHONE = { width: 390, height: 844 };
const PAY = /^https:\/\/sandbox\.ipaymu\.com\/payment\/sess-/;
async function openShop(q = "?test=1") {
  const page = await H.open(q, { uid: null, viewport: PHONE, file: "" });
  await page.locator("[data-pick]").first().waitFor();
  return page;
}
// add the first menu item and pay; returns the order number of the iPaymu page the browser went to
async function checkoutAndPay(page, name) {
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
  await page.fill("#cust-name", name);
  await page.fill("#cust-phone", "081234567890");
  await Promise.all([page.waitForURL(PAY), page.locator("#pay-btn").click()]);
  // the order exists: the cart is already empty and saved that way (before the payment page is used)
  assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("cn-cart-v2") || "[]").length), 0, "cart cleared when the order is created");
  return page.url().replace(PAY, "");
}
const shownOrder = (page) => page.locator("#orders-page:not([hidden]) .oc-head b").innerText();
const backToShop = (page, q) => page.goto(`${H.base}/${q}`);

test("paid at iPaymu: returnUrl opens that order, then 'confirming' until the webhook, without a refresh", async () => {
  const page = await openShop();
  const C = await checkoutAndPay(page, "Pembeli C");
  await backToShop(page, `?order=${C}&trx_id=123&status=berhasil`);         // iPaymu returnUrl (+ its own parameters)
  await page.waitForFunction((c) => location.hash === "#pesanan/" + c, C);
  await page.locator("#orders-page .badge-st", { hasText: "Mengonfirmasi pembayaran" }).waitFor();
  assert.equal(await page.locator("#od-pay").count(), 0, "no 'Lanjutkan pembayaran' for an order that was just paid");
  assert.equal(await page.evaluate(() => location.search), "", "iPaymu parameters removed from the address");
  await H.sql("select public.mark_order_paid($1, '123', 'qris')", [C]);   // webhook arrives
  await page.locator("#orders-page .badge-st", { hasText: "Sudah dibayar" }).waitFor({ timeout: 6000 });
  assert.equal(await shownOrder(page), C);
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("returning for order B opens B, not an older unpaid order A", async () => {
  const page = await openShop();
  const A = await checkoutAndPay(page, "Pembeli A");
  await backToShop(page, `?order=${A}&cancel=1`);                            // A cancelled at iPaymu
  await page.waitForFunction((a) => location.hash === "#pesanan/" + a, A);
  await page.click("#op-close");
  const B = await checkoutAndPay(page, "Pembeli B");
  assert.notEqual(A, B);
  await H.sql("select public.mark_order_paid($1, 'ref', 'va')", [B]);
  await backToShop(page, `?order=${B}&status=berhasil`);
  await page.waitForFunction((b) => location.hash === "#pesanan/" + b, B);
  await page.locator("#orders-page .badge-st", { hasText: "Sudah dibayar" }).waitFor();
  assert.equal(await shownOrder(page), B);
  await page.context().close();
});

test("cancelled payment: the cart stays empty and the order can be paid again from its page", async () => {
  const page = await openShop();
  const A = await checkoutAndPay(page, "Pembeli F");
  await backToShop(page, `?order=${A}&cancel=1&status=berhasil`);           // cancelUrl never counts as paid
  await page.waitForFunction((a) => location.hash === "#pesanan/" + a, A);
  await page.locator("#od-pay").waitFor();                                  // Lanjutkan pembayaran
  // a new cart built meanwhile is not wiped when the old order is paid
  await page.click("#op-close");
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.evaluate((a) => { location.hash = "#pesanan/" + a; }, A);
  await Promise.all([page.waitForURL(PAY), page.locator("#od-pay").click()]);
  assert.equal(page.url().replace(PAY, ""), A, "reopens the same iPaymu page");
  await H.sql("select public.mark_order_paid($1, 'ref', 'qris')", [A]);
  await backToShop(page, `?order=${A}`);
  await page.locator("#orders-page .badge-st", { hasText: "Sudah dibayar" }).waitFor();
  assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("cn-cart-v2") || "[]").length), 1, "the new cart is kept");
  await page.context().close();
});

test("choosing a new delivery location replaces the address; the same spot keeps typed details", async () => {
  const page = await openShop();
  await page.context().grantPermissions(["geolocation"]);
  await page.route(/nominatim\.openstreetmap\.org\/reverse/, (r) => {
    const lat = new URL(r.request().url()).searchParams.get("lat");
    r.fulfill({ contentType: "application/json", body: JSON.stringify({ display_name: lat.startsWith("-6.55") ? "Jalan Pertama 1, Kencana, Tanah Sareal, Bogor, Jawa Barat, Indonesia" : "Jalan Kedua 2, Cibuluh, Bogor Utara, Bogor, Jawa Barat, Indonesia" }) });
  });
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  await page.locator("#to-checkout").click();
  const pickAt = async (lat, lng) => {
    await page.context().setGeolocation({ latitude: lat, longitude: lng });
    await page.click("#pick-loc");
    await page.locator("#map-modal:not([hidden]) .leaflet-container").waitFor();
    await page.click("#map-gps");
    await page.waitForTimeout(400);
    await page.click("#map-save");
  };
  await pickAt(-6.551, 106.781);
  await page.waitForFunction(() => /Jalan Pertama/.test(document.getElementById("cust-addr").value));
  await page.fill("#cust-addr", "Jalan Pertama 1, blok C3, pagar hijau");    // customer adds details
  await pickAt(-6.551, 106.781);                                            // same spot again
  await page.waitForTimeout(500);
  assert.equal(await page.inputValue("#cust-addr"), "Jalan Pertama 1, blok C3, pagar hijau", "same spot: typed details kept");
  await pickAt(-6.580, 106.800);                                            // a different place
  await page.waitForFunction(() => /Jalan Kedua/.test(document.getElementById("cust-addr").value));
  assert.doesNotMatch(await page.inputValue("#cust-addr"), /Pertama/);
  await page.context().close();
});
