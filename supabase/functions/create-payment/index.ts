// Supabase Edge Function: create-payment
// Creates the order in the database (prices, promos and stock are checked there),
// then asks iPaymu (Redirect Payment, API v2) for a payment page the website sends the customer to.
//
// Secrets (Edge Functions → Secrets):
//   IPAYMU_VA                iPaymu VA number (Sandbox VA while testing)
//   IPAYMU_API_KEY           iPaymu API Key (Sandbox key while testing)
//   IPAYMU_IS_PRODUCTION     "false" while testing, "true" when live
//   ALLOWED_ORIGINS          e.g. "https://camilanika.github.io"
//   SITE_URL                 e.g. "https://camilanika.github.io/"
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// "Verify JWT" can stay ON: the website always sends the public anon key in Authorization.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const VA = Deno.env.get("IPAYMU_VA") ?? "";
const API_KEY = Deno.env.get("IPAYMU_API_KEY") ?? "";
const IS_PROD = Deno.env.get("IPAYMU_IS_PRODUCTION") === "true";
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://camilanika.github.io/";
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ?? "https://camilanika.github.io")
  .split(",").map((s) => s.trim()).filter(Boolean);

const IPAYMU_BASE = IS_PROD ? "https://my.ipaymu.com" : "https://sandbox.ipaymu.com";
const NOTIFY_URL = `${SUPABASE_URL}/functions/v1/ipaymu-webhook`;
// iPaymu counts expiry in whole hours, so the order is held for the same 60 minutes
const EXPIRES_MINUTES = 60;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

function cors(origin: string | null) {
  const allow = origin && ALLOWED.includes(origin) ? origin : ALLOWED[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-user-token",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
async function sha256(text: string) {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}
async function hmacSha256(text: string, key: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text)));
}
// iPaymu timestamp: YYYYMMDDhhmmss (WIB)
function stamp() {
  const d = new Date(Date.now() + 7 * 3600_000).toISOString();
  return d.slice(0, 19).replace(/[-T:]/g, "");
}
// Signed POST to iPaymu API v2: signature = HMAC-SHA256("POST:<va>:<sha256(body)>:<apiKey>", apiKey)
async function ipaymuPost(path: string, payload: unknown) {
  const body = JSON.stringify(payload);
  const signature = await hmacSha256(`POST:${VA}:${await sha256(body)}:${API_KEY}`, API_KEY);
  const res = await fetch(`${IPAYMU_BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", va: VA, signature, timestamp: stamp() },
    body,
  });
  const out = await res.json().catch(() => null);
  return { ok: res.ok && Number(out?.Status) === 200, out };
}

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!VA || !API_KEY) return reply({ error: "PAYMENT_NOT_CONFIGURED" }, 500);

  let body: any;
  try { body = await req.json(); } catch { return reply({ error: "BAD_REQUEST" }, 400); }

  // Logged-in customer? (a guest sends only the public key, which is not a user)
  // The website sends the public key in Authorization (for Supabase's JWT check)
  // and the customer's login token, if any, in x-user-token.
  let userId: string | null = null;
  const token = req.headers.get("x-user-token") ?? "";
  if (token) {
    const { data } = await admin.auth.getUser(token);
    userId = data?.user?.id ?? null;
  }

  const c = body?.customer ?? {};
  const items = Array.isArray(body?.items) ? body.items.slice(0, 50) : [];

  // 1) Create the order + reserve stock (all price/promo/stock checks happen in the database)
  const { data: order, error } = await admin.rpc("create_order", {
    p_user_id: userId,
    p_items: items,
    p_promo_code: str(body?.promo_code, 40) || null,
    p_customer_name: str(c.name, 100),
    p_phone: str(c.phone, 30),
    p_email: str(c.email, 120) || null,
    p_address: str(c.address, 500) || null,
    p_notes: str(c.notes, 500) || null,
    p_expires_minutes: EXPIRES_MINUTES,
    p_lat: Number.isFinite(Number(c.lat)) && c.lat !== null && c.lat !== "" ? Number(c.lat) : null,
    p_lng: Number.isFinite(Number(c.lng)) && c.lng !== null && c.lng !== "" ? Number(c.lng) : null,
  });
  if (error) {
    const code = (error.message || "ORDER_FAILED").split(":")[0];
    return reply({ error: code, detail: error.message }, 400);
  }

  // Cashflow: record which iPaymu environment this order uses (Sandbox orders are counted as Mock, never as income).
  // Best effort: if it fails, the database falls back to shop_settings.payments_mode.
  const { error: tagErr } = await admin.rpc("tag_order_payment_env", {
    p_order_number: order.order_number, p_env: IS_PROD ? "production" : "sandbox",
  });
  if (tagErr) console.error("tag_order_payment_env failed", tagErr.message);

  // Free order (100% discount): nothing to pay
  if (order.total <= 0) {
    await admin.rpc("mark_order_paid", { p_order_number: order.order_number, p_payment_ref: null, p_payment_method: "free" });
    return reply({ free: true, order_number: order.order_number, access_token: order.access_token, total: 0 });
  }

  // 2) Ask iPaymu for a payment page.
  // iPaymu takes the bill as product/qty/price lists and has no discount line, so a discounted order
  // is sent as one line with the final total (the full breakdown stays on the order page).
  const lines: { name: string; qty: number; price: number; desc: string }[] = order.discount > 0
    ? [{ name: `Pesanan ${order.order_number}`, qty: 1, price: order.total, desc: clip(`Termasuk diskon ${order.promo_name ?? ""}`.trim(), 100) }]
    : [
        ...order.items.map((l: any) => ({
          name: clip(`${l.product_name} ${l.variant_name}${l.addon ? " + " + l.addon : ""}`, 100),
          qty: l.quantity, price: l.unit_price, desc: clip(l.variant_name || l.product_name, 100),
        })),
        ...(order.delivery_fee > 0
          ? [{ name: clip(`Ongkos kirim${order.delivery_km ? ` (${order.delivery_km} km)` : ""}`, 100), qty: 1, price: order.delivery_fee, desc: "Ongkir" }]
          : []),
      ];
  // the lines must add up to the order total; if not (rounding etc.), fall back to one line
  const sum = lines.reduce((t, l) => t + l.qty * l.price, 0);
  const bill = sum === order.total ? lines : [{ name: `Pesanan ${order.order_number}`, qty: 1, price: order.total, desc: "CamilaNika" }];

  const sep = SITE_URL.includes("?") ? "&" : "?";
  const back = `${SITE_URL}${sep}order=${encodeURIComponent(order.order_number)}`;
  const payBody = {
    product: bill.map((l) => l.name),
    qty: bill.map((l) => String(l.qty)),
    price: bill.map((l) => String(l.price)),
    description: bill.map((l) => l.desc || "-"),
    returnUrl: back,
    cancelUrl: `${back}&cancel=1`,
    notifyUrl: NOTIFY_URL,
    referenceId: order.order_number,
    buyerName: clip(str(c.name, 100), 50),
    buyerPhone: str(c.phone, 30),
    ...(str(c.email, 120) ? { buyerEmail: str(c.email, 120) } : {}),
    expired: EXPIRES_MINUTES / 60,
    feeDirection: "MERCHANT",   // the customer pays exactly the order total
  };

  let pay: { SessionID?: string; Url?: string } | null = null;
  try {
    const { ok, out } = await ipaymuPost("/api/v2/payment", payBody);
    if (!ok || !out?.Data?.Url) throw new Error(JSON.stringify(out));
    pay = out.Data;
  } catch (e) {
    console.error("iPaymu error", e);
    await admin.rpc("release_order", { p_order_number: order.order_number, p_status: "failed" });
    return reply({ error: "PAYMENT_GATEWAY_ERROR" }, 502);
  }

  // Save the payment link so the customer can continue paying later from "Pesanan saya"
  // (snap_token / snap_redirect_url are the original column names; they now hold the iPaymu session and page)
  const { error: saveErr } = await admin.from("orders")
    .update({ snap_token: pay!.SessionID ?? null, snap_redirect_url: pay!.Url, payment_provider: "ipaymu" })
    .eq("order_number", order.order_number);
  if (saveErr) console.error("Could not save payment link", saveErr.message);

  return reply({
    url: pay!.Url,
    order_number: order.order_number,
    access_token: order.access_token,
    total: order.total,
    discount: order.discount,
    delivery_fee: order.delivery_fee,
    gifts: order.gifts,
  });
});
