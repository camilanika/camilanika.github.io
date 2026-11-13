// Browser tests for the menu grid (Nov 2026): every product in one grid, tabs to filter by submenu,
// header links and outside links choose a filter, search looks through everything.
// Run: cd tests && npm run test:ui (needs PGHOST/PGPORT, see tests/README.md)
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

const shop = async (hash = "") => {
  const page = await H.open("?test=1" + hash, { uid: null, viewport: { width: 1280, height: 900 }, file: "" });
  await page.locator("#menu-grid [data-pick]").first().waitFor();
  return page;
};
const visible = (page) => page.locator("#menu-grid [data-card]:visible").count();

test("MENU: 'Semua' shows every product in one grid, a tab shows only its submenu", async () => {
  const [{ n }] = await H.sql("select count(*)::int n from public.products p where public.product_on_sale(p.id) and not p.is_bundle");
  const page = await shop();
  assert.equal(await visible(page), n, "all products");
  assert.equal(await page.locator('#shopbar .mf[aria-pressed="true"]').innerText(), "Semua");
  const tab = page.locator('#shopbar .mf:not([data-filter="all"])').first();
  const slug = await tab.getAttribute("data-filter");
  const [{ k }] = await H.sql(`select count(*)::int k from public.products p join public.menu_sections s on s.id = p.section_id
                                where s.slug = $1 and public.product_on_sale(p.id)`, [slug]);
  await tab.click();
  assert.equal(await tab.getAttribute("aria-pressed"), "true");
  assert.equal(await visible(page), k, "only that submenu");
  assert.equal(await page.locator("#mf-info").isVisible(), true, "submenu info shown");
  await page.locator('#shopbar .mf[data-filter="all"]').click();
  assert.equal(await visible(page), n);
  await page.context().close();
});

test("MENU: a header link and a link from outside (#camilan) open the menu on that main menu", async () => {
  const cats = await H.sql(`select c.slug, count(*)::int k from public.menu_categories c join public.menu_sections s on s.category_id = c.id
                             join public.products p on p.section_id = s.id where public.product_on_sale(p.id) and not p.is_bundle group by c.slug, c.sort_order order by c.sort_order`);
  const page = await shop();
  await page.locator(`#nav-menus a[href="#${cats[1].slug}"]`).click();
  assert.equal(await visible(page), cats[1].k, "header link filters");
  await page.context().close();
  const deep = await shop("#" + cats[0].slug);
  assert.equal(await visible(deep), cats[0].k, "deep link filters");
  await deep.context().close();
});

test("MENU: search looks through every product; closing it brings back the chosen tab", async () => {
  const page = await shop();
  const tab = page.locator('#shopbar .mf:not([data-filter="all"])').first();
  await tab.click();
  const inTab = await visible(page);
  await page.click("#sb-open");
  await page.fill("#sb-q", "zzzz-tidak-ada");
  assert.equal(await page.locator("#sb-empty").isVisible(), true, "nothing found message");
  await page.fill("#sb-q", "");
  await page.fill("#sb-q", "a");
  assert.ok(await visible(page) > inTab, "search is not limited to the tab");
  await page.click("#sb-close");
  assert.equal(await visible(page), inTab, "tab filter is back");
  await page.context().close();
});
