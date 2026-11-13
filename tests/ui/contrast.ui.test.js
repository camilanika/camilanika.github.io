// OBS-33: text and buttons meet WCAG AA colour contrast (1.4.3) on the shop, its panels, the privacy notice
// and the admin page, in light and dark mode. Checked with axe-core, as in the QA inspection (NF-04).
// The logo ("Camila" + rose "Nika", .brand b) is excluded: WCAG 1.4.3 exempts logotypes.
const test = require("node:test");
const assert = require("node:assert/strict");
const { start } = require("./harness");

const AXE = require.resolve("axe-core/axe.min.js");
let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

const PHONE = { width: 390, height: 844 };
const DESK = { width: 1280, height: 900 };

async function contrastProblems(page) {
  // let colour transitions finish first: right after a light/dark switch a button is still between its two colours
  // (endless animations such as the photo gallery never finish, so they are not waited for)
  // (and a panel that opens on the next frame has not started its transition yet, so wait two frames first)
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  await page.evaluate(() => Promise.all(document.getAnimations().filter((a) => a.effect?.getTiming().iterations !== Infinity).map((a) => a.finished.catch(() => {}))));
  await page.addScriptTag({ path: AXE });
  const v = await page.evaluate(async () => (await axe.run({ exclude: [[".brand b"]] }, { runOnly: ["color-contrast"] })).violations);
  return v.flatMap((x) => x.nodes.map((n) => {
    const d = (n.any[0] || {}).data || {};
    return `${n.target.join(" ")}: ${d.fgColor} on ${d.bgColor} = ${d.contrastRatio}:1 (needs ${d.expectedContrastRatio})`;
  }));
}

for (const scheme of ["light", "dark"]) for (const [name, vp] of [["phone", PHONE], ["desktop", DESK]]) {
  test(`OBS-33: shop, options sheet, cart and sign-up form meet AA contrast (${name}, ${scheme} mode)`, async () => {
    const page = await H.open("?test=1", { uid: null, viewport: vp, file: "" });
    await page.emulateMedia({ colorScheme: scheme });
    await page.locator("[data-pick]").first().waitFor();
    const found = [];
    found.push(...await contrastProblems(page));
    await page.locator("[data-pick]").first().click();
    if (await page.locator("#opt-sheet").isVisible()) {
      found.push(...await contrastProblems(page));
      await page.locator("[data-add]:visible").first().click();
    }
    await page.locator("[data-open-cart]:visible").first().click();
    if (await page.locator("#to-checkout").isVisible()) await page.locator("#to-checkout").click();
    found.push(...await contrastProblems(page));
    await page.keyboard.press("Escape");
    await page.evaluate(() => document.querySelector("[data-open-account]").click());
    await page.locator("[data-mode='signup']").click();
    found.push(...await contrastProblems(page));
    assert.deepEqual([...new Set(found)], []);
    await page.context().close();
  });
}

test("OBS-33: the privacy notice meets AA contrast", async () => {
  const page = await H.open("", { uid: null, viewport: PHONE, file: "privacy.html" });
  await page.locator("h1").waitFor();
  assert.deepEqual(await contrastProblems(page), []);
  await page.context().close();
});

for (const scheme of ["light", "dark"]) {
  test(`OBS-33: admin login and order list meet AA contrast (${scheme} mode)`, async () => {
    const login = await H.open("", { uid: null, viewport: DESK });
    await login.emulateMedia({ colorScheme: scheme });
    await login.locator("input").first().waitFor();
    assert.deepEqual(await contrastProblems(login), [], "login");
    await login.context().close();
    const page = await H.open("#orders", { viewport: DESK });
    await page.emulateMedia({ colorScheme: scheme });
    await page.locator("#olist .order").first().waitFor();
    assert.deepEqual(await contrastProblems(page), [], "orders");
    await page.context().close();
  });
}
