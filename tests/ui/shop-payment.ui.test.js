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

// ---------------------------------------------------------------- regressions for QA findings (docs/test-cases-and-automation.docx §4)
test("PAY: pressing 'Bayar online' again while the first request runs doesn't create a second order", async () => {
  const page = await openShop();
  await page.route(/\/functions\/v1\/create-payment$/, async (r) => { await new Promise((s) => setTimeout(s, 1500)); r.fallback(); });
  const before = (await H.sql("select count(*)::int n from public.orders"))[0].n;
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
  await page.fill("#cust-name", "Dobel");
  await page.fill("#cust-phone", "081234567890");
  await page.locator("#pay-btn").click();
  await page.locator("#cust-addr").type("x");                 // any typing redraws the cart
  await page.locator("#pay-btn").click({ timeout: 1000 }).catch(() => {});
  await page.waitForTimeout(3500);
  const after = (await H.sql("select count(*)::int n from public.orders"))[0].n;
  assert.equal(after - before, 1, "orders created by one checkout");
  await page.context().close().catch(() => {});
});

test("DEF-002: a refused checkout explains why and keeps the cart (online payment off, too many unpaid orders)", async () => {
  const cases = [
    ["update public.shop_settings set online_payment = 'test' where id = 1", /Pembayaran online belum dibuka/],
    ["update public.shop_settings set online_payment = 'on', checkout_max_pending = 1 where id = 1", /belum dibayar/],
  ];
  // an unpaid order for the same number (written differently) already exists
  await H.sql("select public.create_order(null, '[{\"variant_id\":1,\"quantity\":1}]', null, 'Lama', '+62 812-3456-7890')");
  try {
    for (const [setup, message] of cases) {
      await H.sql(setup);
      const before = (await H.sql("select count(*)::int n from public.orders"))[0].n;
      const page = await openShop();
      await page.locator("[data-pick]").first().click();
      await page.locator("[data-add]:visible").first().click();
      await page.locator("[data-open-cart]:visible").first().click();
      if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
      await page.fill("#cust-name", "Ditolak");
      await page.fill("#cust-phone", "081234567890");
      await page.locator("#pay-btn").click();
      await page.waitForFunction((src) => new RegExp(src).test(document.body.innerText), message.source);
      assert.equal((await H.sql("select count(*)::int n from public.orders"))[0].n, before, "no order created");
      assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("cn-cart-v2") || "[]").length), 1, "the cart is kept");
      assert.deepEqual(page.__errors || [], []);
      await page.context().close();
    }
  } finally {
    await H.sql("update public.shop_settings set online_payment = 'on', checkout_max_pending = 1000 where id = 1");
  }
});

test("SHOP: a malformed order link still loads the menu", async () => {
  const page = await H.open("#pesanan/%E0", { uid: null, viewport: PHONE, file: "" });
  await page.waitForTimeout(2500);
  assert.ok(await page.locator("[data-pick]").count() > 0, "menu cards shown; page errors: " + JSON.stringify(page.__errors || []));
  await page.context().close();
});

test("AUTH: logging out clears the customer's details from the checkout form", async () => {
  await H.sql("update public.profiles set full_name = 'Rina Pelanggan', phone = '081299998888', address = 'Jl. Rahasia No. 7' where id = $1", [H.CUSTOMER]);
  const page = await H.open("", { uid: H.CUSTOMER, viewport: PHONE, file: "" });
  await page.locator("[data-pick]").first().waitFor();
  await page.waitForFunction(() => document.getElementById("cust-name").value === "Rina Pelanggan");
  await page.locator("#acct-btn").click();
  await page.locator("#logout").click();
  await page.waitForTimeout(800);
  const left = await page.evaluate(() => ["cust-name", "cust-phone", "cust-addr"].map((id) => document.getElementById(id).value).filter(Boolean));
  assert.deepEqual(left, [], "details still in the form after logout");
  await page.context().close();
});

test("A11Y: closed drawers can't be reached with the keyboard; an open one can (OBS-32)", async () => {
  const page = await openShop("");
  const inert = () => page.evaluate(() => [...document.querySelectorAll(".drawer")].map((d) => [d.id, d.inert]));
  assert.deepEqual(await inert(), [["drawer", true], ["notif", true], ["account", true]]);
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  await page.waitForFunction(() => document.getElementById("drawer").classList.contains("open"));
  assert.deepEqual(await inert(), [["drawer", false], ["notif", true], ["account", true]]);
  await page.context().close();
});

test("A11Y: sideways-scrolling rows can be focused with the keyboard (OBS-34)", async () => {
  const page = await openShop("");
  const rows = await page.evaluate(() => [...document.querySelectorAll(".perks ul, .bottle-row")].map((r) => r.tabIndex));
  assert.ok(rows.length >= 1 && rows.every((t) => t === 0), "tabIndex of scroll rows: " + JSON.stringify(rows));
  await page.context().close();
});

test("OBS-35: the privacy notice reads well on a phone and is linked where customers sign up and pay", async () => {
  // the notice itself
  const notice = await H.open("", { uid: null, viewport: PHONE, file: "privacy.html" });
  await notice.locator("h1").waitFor();
  assert.equal(await notice.locator("h1").innerText(), "Kebijakan Privasi");
  for (const id of ["siapa", "data", "pihak-lain", "luar-negeri", "lama-simpan", "hak", "keamanan", "anak", "perubahan"]) {
    assert.equal(await notice.locator(`h2#${id}`).count(), 1, `section #${id}`);
  }
  assert.match(await notice.locator("#kontak a").getAttribute("href"), /^https:\/\/wa\.me\/6281368976966\?/);
  assert.ok(await notice.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), "no sideways scrolling on a phone");
  assert.deepEqual(notice.__errors || [], []);
  await notice.context().close();

  // the shop links to it: footer, checkout, sign-up form
  const page = await openShop();
  assert.equal(await page.locator("footer a[href='privacy.html']").count(), 1, "footer link");
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
  await page.locator("#privacy-note a[href='privacy.html']").waitFor({ state: "visible" });
  await page.evaluate(() => document.querySelector("[data-open-account]").click());
  await page.locator("[data-mode='signup']").click();
  await page.locator("#privacy-consent a[href='privacy.html']").waitFor({ state: "visible" });
  await page.locator("[data-mode='login']").click();
  assert.equal(await page.locator("#privacy-consent").count(), 0, "the sign-up note is not shown on the login form");
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});
