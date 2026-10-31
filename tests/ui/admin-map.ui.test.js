// The Leaflet map on Admin → Toko must stay below the header, the phone menu drawer and popups.
// Run: cd tests && npm run test:ui
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

test("map zoom buttons don't cover the header or the menu drawer (phone)", async () => {
  const page = await H.open("#shop", { viewport: { width: 390, height: 844 } });
  const zoom = page.locator("#dl-map .leaflet-control-zoom-in");
  await zoom.waitFor();
  // scroll so the zoom button sits right under the sticky header
  await page.evaluate(() => {
    const z = document.querySelector("#dl-map .leaflet-control-zoom-in").getBoundingClientRect();
    const h = document.getElementById("topbar").getBoundingClientRect();
    window.scrollBy(0, z.top - (h.top + h.height / 2) + z.height / 2);
  });
  await page.waitForTimeout(200);
  const onTop = (sel) => page.evaluate((s) => {
    const z = document.querySelector("#dl-map .leaflet-control-zoom-in").getBoundingClientRect();
    const el = document.elementFromPoint(z.left + z.width / 2, z.top + z.height / 2);
    return { underHeader: z.top < document.getElementById("topbar").getBoundingClientRect().bottom, winner: !!el?.closest(s), inMap: !!el?.closest(".leaflet-container") };
  }, sel);
  let r = await onTop("#topbar");
  assert.ok(r.underHeader, "test setup: the zoom button is under the header");
  assert.ok(r.winner && !r.inMap, "header is on top of the map");
  // open the phone menu drawer over it
  await page.click("#nav-toggle");
  await page.waitForTimeout(400);
  r = await onTop("#sidenav, #nav-scrim");
  assert.ok(r.winner && !r.inMap, "menu drawer is on top of the map");
  await page.context().close();
});
