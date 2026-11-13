// The admin-only API reference is not in the public page source (QA fix OBS-9, 13 Nov 2026).
// docs.html keeps only the login gate and the drawing code; the reference is in api/private/docs-content.json,
// which api/docs.php hands out only to admins. Run: node --test tests/unit/*.test.js
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (f) => fs.readFileSync(path.join(ROOT, f), "utf8");

test("ADMIN-04: docs.html source names no admin function, table or storage path", () => {
  const src = read("docs.html");
  const names = src.match(/\b(admin_[a-z_]+|cashflow_[a-z_]+|expense-receipts|offline_orders|loyalty_[a-z_]+|voucher_[a-z_]+)\b/g) || [];
  assert.deepEqual([...new Set(names)], [], "found in the public page source");
  assert.doesNotMatch(src, /<template id="docs-tpl">/, "no hidden copy of the reference");
  assert.match(src, /fetch\("api\/docs\.php"/, "the reference is loaded from api/docs.php");
});

test("ADMIN-04: the private reference still covers every admin and cashflow function the pages call", () => {
  const d = JSON.parse(read("api/private/docs-content.json"));
  const documented = new Set(d.groups.flatMap((g) => g.eps.map((e) => e[1].replace(/^rpc\//, ""))));
  const used = new Set();
  for (const f of ["admin.html", "js/cashflow.js"]) for (const m of read(f).matchAll(/rpc\("((?:admin|cashflow)_[a-z_]+)"/g)) used.add(m[1]);
  const missing = [...used].filter((n) => !documented.has(n));
  assert.ok(used.size > 20, "found the admin calls");
  assert.deepEqual(missing, [], "called by the admin pages but not documented");
  assert.ok(d.html.includes("CamilaNika API Reference"));
});

test("ADMIN-04: the private reference can't be downloaded directly", () => {
  assert.match(read(".htaccess"), /RedirectMatch 404 \^\/api\/private\(\/\|\$\)/);
  assert.match(read("api/private/.htaccess"), /Require all denied/);
  const php = read("api/docs.php");
  assert.match(php, /rpc\/is_admin/, "docs.php asks Supabase is_admin with the caller's token");
  assert.match(php, /trim\(\$res\) !== 'true'/, "anything but true is refused");
});
