// Opening hours on every page come from Admin → Toko (js/hours.js, commits 35588fb and d5ba914, 13 Nov 2026).
// Regression for OBS-38: the pages said 10.00–20.00 while the shop's real schedule was different (QA run INSP-5).
// shop_status is answered by a stand-in here, so the test never calls the real Supabase project.
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

async function openWithHours(file, status) {
  const page = await H.open("", { uid: null, file });
  await page.context().route(/\/rest\/v1\/rpc\/shop_status$/, (r) =>
    status ? r.fulfill({ contentType: "application/json", body: JSON.stringify(status) }) : r.abort());
  await page.reload();
  await page.waitForLoadState("networkidle");
  return page;
}
const shown = (page) => page.locator("[data-shop-hours]").allTextContents();   // some are inside closed FAQ answers

for (const file of ["faq.html", "terms.html", "refund.html", "contact.html", "privacy.html", "index.html"]) {
  test(`ORD-05: ${file} shows the opening hours set in Admin`, async () => {
    const page = await openWithHours(file, { open: true, schedule_enabled: true, open_time: "08:00", close_time: "21:30" });
    const hours = await shown(page);
    assert.ok(hours.length > 0, "the page shows opening hours");
    assert.deepEqual([...new Set(hours)], ["08.00–21.30"]);
    await page.context().close();
  });
}

test("ORD-05: without a schedule, or when Supabase can't be reached, the written hours stay", async () => {
  for (const status of [{ open: true, schedule_enabled: false, open_time: "08:00", close_time: "21:30" }, null]) {
    const page = await openWithHours("faq.html", status);
    assert.deepEqual([...new Set(await shown(page))], ["10.00–20.00"]);
    await page.context().close();
  }
});
