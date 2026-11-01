// Shop checkout → Midtrans → back to the order page. Snap is a stand-in the test controls.
// Bug: cancel payment A, go home, pay B → the page went back to order A (fixed: late callbacks from
// an older payment window are ignored; the order page is replaced, not stacked).
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

const PHONE = { width: 390, height: 844 };
async function openShop(q = "?test=1") {
  const page = await H.open(q, { uid: null, viewport: PHONE, file: "" });
  await page.locator("[data-pick]").first().waitFor();
  return page;
}
// add the first menu item and pay; returns the order number Snap was opened for
async function checkoutAndPay(page, name) {
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
  await page.fill("#cust-name", name);
  await page.fill("#cust-phone", "081234567890");
  const before = await page.evaluate(() => window.__snap?.calls.length || 0);
  await page.locator("#pay-btn").click();
  await page.waitForFunction((n) => (window.__snap?.calls.length || 0) > n, before);
  // the order exists: the cart is already empty and saved that way (before the payment window is used)
  assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("cn-cart-v2") || "[]").length), 0, "cart cleared when the order is created");
  return page.evaluate(() => window.__snap.calls.at(-1).token.replace(/^snap-/, ""));
}
const shownOrder = (page) => page.locator("#orders-page:not([hidden]) .oc-head b").innerText();

test("cancel payment A, go home, pay B: lands on B even if A's window calls back late", async () => {
  const page = await openShop();
  const A = await checkoutAndPay(page, "Pembeli A");
  await page.evaluate(() => window.__snap.calls[0].opts.onClose());          // customer closes the payment window
  await page.waitForFunction((a) => location.hash === "#pesanan/" + a, A);
  assert.equal(await shownOrder(page), A);
  await page.click("#op-close");                                            // back to the shop
  await page.waitForFunction(() => document.getElementById("orders-page").hidden);

  const B = await checkoutAndPay(page, "Pembeli B");
  assert.notEqual(A, B);
  await H.sql("select public.mark_order_paid($1, 'ref', 'qris')", [B]);    // Midtrans webhook
  await page.evaluate(() => {
    window.__snap.calls[1].opts.onSuccess();                                 // B paid
    window.__snap.calls[0].opts.onClose();                                   // late callback from A's window
    window.__snap.calls[0].opts.onPending();
  });
  await page.waitForTimeout(500);
  assert.equal(await page.evaluate(() => location.hash), "#pesanan/" + B);
  await page.locator("#orders-page .badge-st", { hasText: "Sudah dibayar" }).waitFor();
  assert.equal(await shownOrder(page), B);
  // Back from B's page closes the orders page; it doesn't lead to A
  await page.click("#op-back");
  await page.waitForFunction(() => /^#pesanan$/.test(location.hash) || document.getElementById("orders-page").hidden);
  assert.doesNotMatch(await page.evaluate(() => location.hash), new RegExp(A));
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("paid but the webhook is late: shows 'confirming' and updates without a refresh", async () => {
  const page = await openShop();
  const C = await checkoutAndPay(page, "Pembeli C");
  await page.evaluate(() => window.__snap.calls.at(-1).opts.onSuccess());   // Midtrans: paid; our server: still pending
  await page.locator("#orders-page .badge-st", { hasText: "Mengonfirmasi pembayaran" }).waitFor();
  assert.equal(await page.locator("#od-pay").count(), 0, "no 'Lanjutkan pembayaran' for an order that was just paid");
  await H.sql("select public.mark_order_paid($1, 'ref', 'qris')", [C]);    // webhook arrives
  await page.locator("#orders-page .badge-st", { hasText: "Sudah dibayar" }).waitFor({ timeout: 6000 });
  await page.context().close();
});

test("redirected back from Midtrans (?order=…) opens that order, not an older one", async () => {
  const page = await openShop();
  const A = await checkoutAndPay(page, "Pembeli D");
  await page.evaluate(() => window.__snap.calls.at(-1).opts.onClose());
  await page.waitForFunction((a) => location.hash === "#pesanan/" + a, A);
  await page.click("#op-close");
  const B = await checkoutAndPay(page, "Pembeli E");
  await H.sql("select public.mark_order_paid($1, 'ref', 'gopay')", [B]);
  // Midtrans sends the browser to the finish URL (full page load)
  await page.goto(`${H.base}/?order=${B}&order_id=${B}&status_code=200&transaction_status=settlement`);
  await page.waitForFunction((b) => location.hash === "#pesanan/" + b, B);
  await page.locator("#orders-page .badge-st", { hasText: "Sudah dibayar" }).waitFor();
  assert.equal(await shownOrder(page), B);
  assert.equal(await page.evaluate(() => location.search), "", "Midtrans parameters removed from the address");
  await page.context().close();
});

test("cancelled payment: the cart stays empty and the order can be paid from its page", async () => {
  const page = await openShop();
  const A = await checkoutAndPay(page, "Pembeli F");
  await page.evaluate(() => window.__snap.calls.at(-1).opts.onClose());
  await page.waitForFunction((a) => location.hash === "#pesanan/" + a, A);
  await page.locator("#od-pay").waitFor();                                  // Lanjutkan pembayaran
  // a new cart built meanwhile is not wiped when the old order is paid later
  await page.click("#op-close");
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.evaluate((a) => { location.hash = "#pesanan/" + a; }, A);
  await page.locator("#od-pay").click();
  await page.waitForFunction(() => window.__snap.calls.length >= 2);
  await H.sql("select public.mark_order_paid($1, 'ref', 'qris')", [A]);
  await page.evaluate(() => window.__snap.calls.at(-1).opts.onSuccess());
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
