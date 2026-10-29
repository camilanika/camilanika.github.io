// Supabase Edge Function: create-payment
// Creates the order in the database (prices, promos and stock are checked there),
// then asks Midtrans Snap for a payment token the website opens as a popup.
//
// Secrets (Edge Functions → Secrets):
//   MIDTRANS_SERVER_KEY      Server Key from Midtrans (Sandbox key while testing)
//   MIDTRANS_IS_PRODUCTION   "false" while testing, "true" when live
//   ALLOWED_ORIGINS          e.g. "https://camilanika.github.io"
//   SITE_URL                 e.g. "https://camilanika.github.io/"
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// "Verify JWT" can stay ON: the website always sends the public anon key in Authorization.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVER_KEY = Deno.env.get("MIDTRANS_SERVER_KEY") ?? "";
const IS_PROD = Deno.env.get("MIDTRANS_IS_PRODUCTION") === "true";
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://camilanika.github.io/";
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ?? "https://camilanika.github.io")
  .split(",").map((s) => s.trim()).filter(Boolean);

const SNAP_URL = IS_PROD
  ? "https://app.midtrans.com/snap/v1/transactions"
  : "https://app.sandbox.midtrans.com/snap/v1/transactions";

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

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!SERVER_KEY) return reply({ error: "PAYMENT_NOT_CONFIGURED" }, 500);

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
    p_expires_minutes: 30,
    p_lat: Number.isFinite(Number(c.lat)) && c.lat !== null && c.lat !== "" ? Number(c.lat) : null,
    p_lng: Number.isFinite(Number(c.lng)) && c.lng !== null && c.lng !== "" ? Number(c.lng) : null,
  });
  if (error) {
    const code = (error.message || "ORDER_FAILED").split(":")[0];
    return reply({ error: code, detail: error.message }, 400);
  }

  // Cashflow: record which Midtrans environment this order uses (Sandbox orders are counted as Mock, never as income).
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

  // 2) Ask Midtrans for a Snap token
  const itemDetails = order.items.map((l: any) => ({
    id: String(l.variant_id),
    name: clip(`${l.product_name} ${l.variant_name}${l.addon ? " + " + l.addon : ""}`, 50),
    price: l.unit_price,
    quantity: l.quantity,
  }));
  if (order.discount > 0) {
    itemDetails.push({ id: "DISCOUNT", name: clip(`Diskon ${order.promo_name ?? ""}`.trim(), 50), price: -order.discount, quantity: 1 });
  }
  if (order.delivery_fee > 0) {
    itemDetails.push({ id: "ONGKIR", name: clip(`Ongkos kirim${order.delivery_km ? ` (${order.delivery_km} km)` : ""}`, 50), price: order.delivery_fee, quantity: 1 });
  }

  const sep = SITE_URL.includes("?") ? "&" : "?";
  const snapBody = {
    transaction_details: { order_id: order.order_number, gross_amount: order.total },
    item_details: itemDetails,
    customer_details: {
      first_name: clip(str(c.name, 100), 50),
      phone: str(c.phone, 30),
      ...(str(c.email, 120) ? { email: str(c.email, 120) } : {}),
      shipping_address: { first_name: clip(str(c.name, 100), 50), phone: str(c.phone, 30), address: clip(str(c.address, 500), 200) },
    },
    expiry: { unit: "minutes", duration: 30 },
    callbacks: { finish: `${SITE_URL}${sep}order=${encodeURIComponent(order.order_number)}` },
  };

  let snap: any = null;
  try {
    const res = await fetch(SNAP_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        Authorization: "Basic " + btoa(SERVER_KEY + ":"),
      },
      body: JSON.stringify(snapBody),
    });
    snap = await res.json();
    if (!res.ok || !snap?.token) throw new Error(JSON.stringify(snap));
  } catch (e) {
    console.error("Midtrans error", e);
    await admin.rpc("release_order", { p_order_number: order.order_number, p_status: "failed" });
    return reply({ error: "PAYMENT_GATEWAY_ERROR" }, 502);
  }

  // Save the payment link so the customer can continue paying later from "Pesanan saya"
  const { error: saveErr } = await admin.from("orders")
    .update({ snap_token: snap.token, snap_redirect_url: snap.redirect_url ?? null })
    .eq("order_number", order.order_number);
  if (saveErr) console.error("Could not save payment link", saveErr.message);

  return reply({
    token: snap.token,
    redirect_url: snap.redirect_url,
    order_number: order.order_number,
    access_token: order.access_token,
    total: order.total,
    discount: order.discount,
    delivery_fee: order.delivery_fee,
    gifts: order.gifts,
  });
});
