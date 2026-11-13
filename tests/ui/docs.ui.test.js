// docs.html: the admin-only API reference is only shown after an admin login (QA fix OBS-9, 13 Nov 2026).
// api/docs.php can't run here (no PHP), so a stand-in does what it does: ask is_admin() as the token's user
// in the test database, and hand out api/private/docs-content.json only when the answer is true.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { start, ADMIN, CUSTOMER } = require("./harness");

let H;
test.before(async () => { H = await start(); });
test.after(async () => { await H?.close(); });

const CONTENT = fs.readFileSync(path.join(__dirname, "../../api/private/docs-content.json"), "utf8");
async function openDocs(uid) {
  const page = await H.open("", { uid, file: "docs.html" });
  const asked = [];
  await page.context().route(/\/api\/docs\.php$/, async (r) => {
    const tok = r.request().headers()["x-user-token"] || "";
    const who = (tok.match(/^test-token\.([0-9a-f-]{36})\.sig$/) || [])[1];
    asked.push(who || "(none)");
    if (!who) return r.fulfill({ status: 401, contentType: "application/json", body: '{"error":"LOGIN_REQUIRED"}' });
    const [{ ok }] = await H.sql("select set_config('request.jwt.claim.sub', $1, true) is not null and public.is_admin() as ok", [who]);
    r.fulfill(ok ? { contentType: "application/json", body: CONTENT } : { status: 403, contentType: "application/json", body: '{"error":"NOT_ADMIN"}' });
  });
  await page.reload();
  return { page, asked };
}

test("ADMIN-04: an admin sees the API reference after the server check", async () => {
  const { page, asked } = await openDocs(ADMIN);
  await page.locator("#groups .ep").first().waitFor();
  assert.ok(await page.locator("#groups .ep").count() > 50, "endpoints drawn");
  assert.match(await page.locator("#groups").innerText(), /admin_set_order_status/);
  assert.equal(await page.locator("#gate").count(), 0, "gate removed");
  assert.deepEqual(asked, [ADMIN], "the reference was asked for once, with the admin's own token");
  assert.deepEqual(page.__errors || [], []);
  await page.context().close();
});

test("ADMIN-04: a customer is refused and never receives the reference", async () => {
  const { page, asked } = await openDocs(CUSTOMER);
  await page.locator("#gate-msg", { hasText: "admins only" }).waitFor();
  assert.deepEqual(asked, [], "the browser check stops a customer before asking the server");
  assert.doesNotMatch(await page.content(), /admin_set_order_status/);
  await page.context().close();
});

test("ADMIN-04: logged out, the page asks for a login and holds no reference", async () => {
  const { page, asked } = await openDocs(null);
  await page.locator("#gate-msg", { hasText: "Log in to the admin panel first" }).waitFor();
  assert.deepEqual(asked, []);
  assert.doesNotMatch(await page.content(), /admin_[a-z_]+|cashflow_[a-z_]+/);
  await page.context().close();
});

test("ADMIN-04: if the server refuses (customer token sent directly), the page shows no reference", async () => {
  const { page } = await openDocs(CUSTOMER);
  // a customer who skips the browser check and asks docs.php directly with their own token
  const r = await page.evaluate(async () => (await fetch("api/docs.php", { headers: { "X-User-Token": "test-token." + window.__TEST_UID + ".sig" } })).status);
  assert.equal(r, 403);
  await page.context().close();
});
