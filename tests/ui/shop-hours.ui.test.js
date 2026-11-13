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

const shownBy = (page) => page.locator("[data-shop-hours]").evaluateAll((els) => els.map((e) => [e.dataset.shopHours || "", e.textContent]));

for (const file of ["faq.html", "terms.html", "refund.html", "contact.html", "privacy.html", "index.html"]) {
  test(`ORD-05: ${file} shows the opening days and hours set in Admin`, async () => {
    const page = await openWithHours(file, { open: true, schedule_enabled: true, open_time: "08:00", close_time: "21:30", open_days: [1, 2, 3, 4, 5, 6] });
    const hours = await shownBy(page);
    assert.ok(hours.length > 0, "the page shows opening hours");
    for (const [kind, text] of hours) {
      if (kind.startsWith("text")) assert.match(text, /^(S|s)enin–Sabtu pukul 08\.00–21\.30 WIB$/, text);
      else assert.equal(text, "Buka Senin–Sabtu · 08.00–21.30 WIB");
    }
    await page.context().close();
  });
}

test("ORD-05: without a schedule the shop is open every day, so the pages say 'Buka setiap hari' without hours", async () => {
  const page = await openWithHours("faq.html", { open: true, schedule_enabled: false, open_time: "08:00", close_time: "21:30", open_days: [1, 2, 3] });
  const hours = await shownBy(page);
  assert.deepEqual([...new Set(hours.map(([k, t]) => (k ? `${k}:${t}` : t)))].sort(), ["Buka setiap hari", "text-cap:Setiap hari"]);
  await page.context().close();
});

test("ORD-05: days are written the Indonesian way", async () => {
  const page = await openWithHours("faq.html", null);
  const out = await page.evaluate(() => [[1, 2, 3, 4, 5, 6, 7], [1, 2, 3, 4, 5], [5, 6, 7, 1], [6, 7], [1, 3, 5], [2]].map((d) => window.CN_HOURS.days(d)));
  assert.deepEqual(out, ["setiap hari", "Senin–Jumat", "Jumat–Senin", "Sabtu dan Minggu", "Senin, Rabu dan Jumat", "Selasa"]);
  await page.context().close();
});

test("ORD-05: when Supabase can't be reached, the written text stays", async () => {
  const page = await openWithHours("faq.html", null);
  assert.ok((await shown(page)).every((t) => /10\.00–20\.00/.test(t)));
  await page.context().close();
});

test("ORD-05: Admin → Toko has the opening days and shows what the shop pages will say", async () => {
  const page = await H.open("#shop");
  await page.locator("#sh-days [data-day]").first().waitFor();
  assert.equal(await page.locator("#sh-days [data-day]").count(), 7);
  if (!(await page.locator("#sh-sched").isChecked())) await page.locator("#sh-sched").check();
  await page.fill("#sh-ot", "10:00"); await page.fill("#sh-ct", "20:00");
  await page.locator('#sh-days [data-day="7"]').uncheck();
  assert.equal(await page.locator("#sh-preview").innerText(), "Di toko tertulis: Buka Senin–Sabtu · 10.00–20.00 WIB");
  await page.locator("#sh-sched").uncheck();
  assert.equal(await page.locator("#sh-preview").innerText(), "Di toko tertulis: Buka setiap hari");
  await page.context().close();
});
