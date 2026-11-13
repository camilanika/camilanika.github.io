// Browser tests for the Nov 2026 storefront sections (migration 020): Paket Hemat, Best Seller, Testimoni,
// and the admin pages that manage them. Run: cd tests && npm run test:ui (needs PGHOST/PGPORT, see tests/README.md)
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => {
  H = await start({ seedSql: `
    update public.inventory set unlimited = true;
    insert into public.testimonials (quote, author, source, sort_order) values ('Latte-nya enak', 'Rina', 'gofood', 1);
    insert into public.testimonials (quote, author, source, is_visible, sort_order) values ('Belum boleh tampil', 'Budi', 'whatsapp', false, 2);` });
});
test.after(async () => { await H?.close(); });

const shop = async (vp = { width: 1280, height: 900 }) => {
  const page = await H.open("?test=1", { uid: null, viewport: vp, file: "" });
  await page.locator("#menu-root [data-pick]").first().waitFor();
  return page;
};

test("SHOP: without pakets, Paket Hemat stays hidden and the menu works as before", async () => {
  const page = await shop();
  assert.equal(await page.locator("#paket-hemat").isHidden(), true, "Paket Hemat hidden");
  assert.equal(await page.locator("#cat-pills").isVisible(), true, "category shortcuts shown");
  await page.context().close();
});

test("ADMIN → SHOP: a paket made in Paket Hemat shows in the shop with its items, normal price and saving, and goes in the cart", async () => {
  const [a, b] = await H.sql(`select v.id, v.price, p.name from public.product_variants v join public.products p on p.id = v.product_id
                               where not p.is_bundle order by p.id, v.id limit 2`);
  const admin = await H.open("#paket");
  await admin.locator("#newbd").click();
  await admin.fill("#bd-name", "Paket Uji");
  await admin.locator("#bd-items [data-iv]").first().selectOption(String(a.id));
  await admin.fill("#bd-items [data-iq]", "2");
  await admin.click("#bd-add");
  await admin.locator("#bd-items [data-iv]").nth(1).selectOption(String(b.id));
  const price = a.price * 2 + b.price - 2000;
  await admin.fill("#bd-price", String(price));
  await assert.doesNotReject(admin.locator("#bd-sum", { hasText: "hemat" }).waitFor({ timeout: 3000 }), "live saving shown");
  await admin.click("#bd-save");
  await admin.locator("#bdbody", { hasText: "Paket Uji" }).waitFor();
  await admin.context().close();

  const page = await shop();
  const card = page.locator("#pk-grid .pkcard", { hasText: "Paket Uji" });
  await card.waitFor();
  assert.match(await card.locator(".pk-items").innerText(), new RegExp("2× " + a.name));
  assert.match(await card.locator(".pk-price").innerText(), /Hemat \d+%/);
  assert.equal(await page.locator("#menu-root [data-card]", { hasText: "Paket Uji" }).count(), 0, "not repeated in the menu lists");
  await card.locator("[data-pick]").click();
  await page.locator("#cart-bar:not([hidden])").waitFor();
  assert.match(await page.locator("#cb-total").innerText(), new RegExp(price.toLocaleString("id-ID").replace(/\./g, "\\.")));
  await page.context().close();
});

test("SHOP: a paket shows 'Habis' while something inside it is sold out", async () => {
  const [{ v }] = await H.sql(`select bi.variant_id v from public.bundle_items bi join public.products p on p.id = bi.bundle_id where p.name = 'Paket Uji' limit 1`);
  await H.sql("update public.inventory set unlimited = false, stock = 0, reserved = 0 where variant_id = $1", [v]);
  const page = await shop();
  const btn = page.locator("#pk-grid .pkcard", { hasText: "Paket Uji" }).locator("[data-pick]");
  assert.equal(await btn.isDisabled(), true);
  assert.equal(await btn.innerText(), "Habis");
  await H.sql("update public.inventory set unlimited = true where variant_id = $1", [v]);
  await page.context().close();
});

test("SHOP: Testimoni shows only visible testimonials; the admin page lists all of them", async () => {
  const page = await shop();
  await page.locator("#testimoni:not([hidden])").waitFor();
  const text = await page.locator("#t-grid").innerText();
  assert.match(text, /Latte-nya enak/);
  assert.doesNotMatch(text, /Belum boleh tampil/);
  await page.context().close();
  const admin = await H.open("#testi");
  await admin.locator("#tsbody", { hasText: "Belum boleh tampil" }).waitFor();
  assert.match(await admin.locator("#tsbody").innerText(), /Disembunyikan/);
  await admin.context().close();
});

test("SHOP: Best Seller counts real paid orders (not test orders), on phones in two columns", async () => {
  const vs = await H.sql("select v.id from public.product_variants v join public.products p on p.id = v.product_id where not p.is_bundle order by p.id limit 2");
  for (const [i, v] of vs.entries()) {
    const [{ o }] = await H.sql("select public.create_order(null, $1::jsonb, null, 'X', $2) o", [JSON.stringify([{ variant_id: v.id, quantity: 1 }]), "08120000999" + i]);
    await H.sql("update public.orders set status = 'paid', paid_at = now(), classification = 'real' where order_number = $1", [o.order_number]);
  }
  const page = await shop({ width: 390, height: 844 });
  await page.locator("#best:not([hidden])").waitFor();
  const n = await page.locator("#best-grid .pc-badge").count();
  assert.ok(n >= 2 && n <= 4, "2 to 4 best sellers");
  const [{ mock }] = await H.sql("select (select array_agg(distinct oi.product_id) from public.order_items oi join public.orders o on o.id = oi.order_id where o.classification = 'mock') as mock");
  const shown = await page.locator("#best-grid [data-card]").evaluateAll((els) => els.map((e) => +e.dataset.card));
  const realOnly = await H.sql("select distinct oi.product_id from public.order_items oi join public.orders o on o.id = oi.order_id where o.classification = 'real' and o.status <> 'pending'");
  assert.ok(shown.every((id) => realOnly.some((r) => +r.product_id === id)), "every best seller comes from a real paid order" + JSON.stringify({ shown, mock }));
  const boxes = await page.locator("#best-grid .pcard").evaluateAll((els) => els.map((e) => e.getBoundingClientRect().top));
  assert.equal(Math.round(boxes[0]), Math.round(boxes[1]), "two cards side by side");
  await page.context().close();
});
