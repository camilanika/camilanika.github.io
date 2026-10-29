// UI test harness: a fresh PostgreSQL database built from the repo's SQL, a small web server
// that serves the site (with tests/ui/fake-supabase.js in place of the real client), and Chromium.
// Needs PGHOST/PGPORT pointing at a local PostgreSQL 16+ (see tests/README.md).
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { Pool } = require("pg");
const { chromium } = require("playwright");

const ROOT = path.resolve(__dirname, "../..");
const ADMIN = "00000000-0000-0000-0000-00000000000a";
const CUSTOMER = "00000000-0000-0000-0000-00000000000c";
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml", ".webp": "image/webp" };
const TABLES = new Set(["profiles", "orders", "order_items", "products", "product_variants", "menu_categories", "menu_sections", "shop_settings", "expenses", "offline_orders"]);
const ident = (s) => { if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new Error("bad identifier " + s); return '"' + s + '"'; };

async function asUser(pool, uid, fn) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [uid || ""]);
    await c.query(uid ? "set local role authenticated" : "set local role anon");
    const r = await fn(c);
    await c.query("commit");
    return r;
  } catch (e) { await c.query("rollback").catch(() => {}); throw e; } finally { c.release(); }
}

async function handleRpc(pool, { fn, args, uid }) {
  const names = Object.keys(args);
  const sql = `select ${ident("public")}.${ident(fn)}(${names.map((n, i) => `${ident(n)} => $${i + 1}`).join(", ")}) as r`;
  const vals = names.map((n) => (args[n] !== null && typeof args[n] === "object" ? JSON.stringify(args[n]) : args[n]));
  return asUser(pool, uid, async (c) => (await c.query(sql, vals)).rows[0].r);
}

async function handleSelect(pool, { q, uid }) {
  if (!TABLES.has(q.table)) throw new Error("table not allowed in tests: " + q.table);
  const embedItems = /order_items\(\*\)/.test(q.select);
  const vals = [];
  const where = q.filters.map((f) => {
    vals.push(f.op === "in" ? f.val : f.val);
    return f.op === "in" ? `t.${ident(f.col)} = any($${vals.length})` : `t.${ident(f.col)} = $${vals.length}`;
  });
  const cols = q.select.trim() === "*" || embedItems ? "t.*" : q.select.split(",").map((c) => "t." + ident(c.trim())).join(", ");
  let sql = `select ${cols}${embedItems ? ", coalesce((select json_agg(i order by i.id) from public.order_items i where i.order_id = t.id), '[]') as order_items" : ""} from public.${ident(q.table)} t`;
  if (where.length) sql += " where " + where.join(" and ");
  if (q.order.length) sql += " order by " + q.order.map((o) => `t.${ident(o.col)} ${o.asc ? "asc" : "desc"}`).join(", ");
  if (q.limit) sql += " limit " + Number(q.limit);
  const rows = await asUser(pool, uid, async (c) => (await c.query(sql, vals)).rows);
  return q.single ? rows[0] || null : rows;
}

async function start({ seedSql } = {}) {
  const env = { ...process.env, PGHOST: process.env.PGHOST || "/tmp/pg", PGPORT: process.env.PGPORT || "5433" };
  execFileSync("bash", [path.join(ROOT, "tests/db/build.sh"), "cn_ui"], { env, stdio: "pipe" });
  const pool = new Pool({ host: env.PGHOST, port: Number(env.PGPORT), user: "postgres", database: "cn_ui", max: 4 });
  await pool.query(fs.readFileSync(path.join(__dirname, "fixtures.sql"), "utf8"));
  if (seedSql) await pool.query(seedSql);

  const server = http.createServer(async (req, res) => {
    try {
      if (req.method === "POST" && (req.url === "/__rpc" || req.url === "/__select")) {
        let body = ""; for await (const ch of req) body += ch;
        const b = JSON.parse(body);
        try {
          const data = req.url === "/__rpc" ? await handleRpc(pool, b) : await handleSelect(pool, b);
          res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ data, error: null }));
        } catch (e) {
          res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ data: null, error: { message: e.message } }));
        }
        return;
      }
      const url = decodeURIComponent(new URL(req.url, "http://x").pathname);
      const file = url === "/js/vendor/supabase.js" ? path.join(__dirname, "fake-supabase.js") : path.join(ROOT, url === "/" ? "index.html" : url);
      if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream" });
      fs.createReadStream(file).pipe(res);
    } catch (e) { res.writeHead(500); res.end(String(e)); }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();

  async function open(hash = "", { uid = ADMIN, viewport = { width: 1280, height: 900 } } = {}) {
    const ctx = await browser.newContext({ viewport, locale: "id-ID", timezoneId: "Asia/Jakarta" });
    await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await ctx.newPage();
    page.on("pageerror", (e) => { (page.__errors ||= []).push(e.message); });
    await page.addInitScript((u) => { window.__TEST_UID = u; }, uid);
    await page.goto(`${base}/admin.html${hash}`);
    return page;
  }
  const sql = async (q, v) => (await pool.query(q, v)).rows;
  async function close() { await browser.close(); server.close(); await pool.end(); }
  return { base, open, sql, close, ADMIN, CUSTOMER };
}

module.exports = { start, ADMIN, CUSTOMER };
