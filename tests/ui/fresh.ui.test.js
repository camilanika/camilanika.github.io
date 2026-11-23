// js/fresh.js: an open tab that comes back into view picks up a new deploy (reload, or a "Muat ulang" bar
// when something has been typed on the page). The server's ETag for js/shop.js is faked here.
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

async function openWithEtags() {
  const page = await H.open("", { uid: null, viewport: { width: 390, height: 844 }, file: "" });
  let version = "v1";
  await page.context().route(/\/js\/shop\.js/, async (r) => {
    if (r.request().method() !== "HEAD") return r.continue();
    r.fulfill({ status: 200, headers: { etag: `"${version}"` }, body: "" });
  });
  await page.reload();
  await page.locator("[data-pick]").first().waitFor();
  await page.waitForTimeout(500);   // fresh.js remembers the current versions
  return { page, deploy: () => { version = "v2"; } };
}
const backToTab = (page) => page.evaluate(() => dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true })));

test("a tab brought back after a deploy reloads itself", async () => {
  const { page, deploy } = await openWithEtags();
  await page.evaluate(() => { window.__old = 1; });
  await backToTab(page);
  await page.waitForTimeout(400);
  assert.equal(await page.evaluate(() => window.__old), 1, "nothing changed: no reload");
  deploy();
  await Promise.all([page.waitForEvent("load"), backToTab(page)]);
  assert.equal(await page.evaluate(() => window.__old), undefined, "reloaded onto the new version");
  await page.context().close();
});

test("with something typed on the page, it offers Muat ulang instead of reloading", async () => {
  const { page, deploy } = await openWithEtags();
  await page.evaluate(() => { window.__old = 1; });
  await page.locator("[data-pick]").first().click();
  await page.locator("[data-add]:visible").first().click();
  await page.locator("[data-open-cart]:visible").first().click();
  if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
  await page.fill("#cust-name", "Pembeli");
  deploy();
  await backToTab(page);
  await page.getByRole("status").filter({ hasText: "Ada versi baru" }).waitFor();
  assert.equal(await page.evaluate(() => window.__old), 1, "not reloaded");
  await Promise.all([page.waitForEvent("load"), page.getByRole("button", { name: "Muat ulang" }).click()]);
  await page.context().close();
});
