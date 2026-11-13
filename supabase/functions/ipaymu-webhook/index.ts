// Supabase Edge Function: ipaymu-webhook
// iPaymu calls this URL whenever a payment changes status. create-payment sends it as notifyUrl;
// also set it in the iPaymu dashboard → Integration → URL Notify / Callback:
//   https://<project-ref>.supabase.co/functions/v1/ipaymu-webhook
//
// Secrets: IPAYMU_VA, IPAYMU_API_KEY, IPAYMU_IS_PRODUCTION (same as create-payment).
// Deploy with "Verify JWT" turned OFF (iPaymu doesn't send a Supabase token).
// The notification body is never trusted: every call is re-checked with iPaymu's Check Transaction API
// (signed with your API Key), and the order number and amount come from that answer.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const VA = Deno.env.get("IPAYMU_VA") ?? "";
const API_KEY = Deno.env.get("IPAYMU_API_KEY") ?? "";
const IS_PROD = Deno.env.get("IPAYMU_IS_PRODUCTION") === "true";
const IPAYMU_BASE = IS_PROD ? "https://my.ipaymu.com" : "https://sandbox.ipaymu.com";
// iPaymu Production only accepts calls from registered IPs, and Edge Functions have no fixed IP.
// When IPAYMU_RELAY_URL is set (e.g. https://camilanika.store/api/ipaymu.php), the signed request goes
// through that relay on the Hostinger server instead, whose IP is registered in the iPaymu dashboard.
const RELAY = (Deno.env.get("IPAYMU_RELAY_URL") ?? "").trim();
const ipaymuUrl = (path: string) =>
  RELAY ? `${RELAY}?env=${IS_PROD ? "prod" : "sandbox"}&path=${encodeURIComponent(path)}` : `${IPAYMU_BASE}${path}`;

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
async function sha256(text: string) {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}
async function hmacSha256(text: string, key: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(text)));
}
function stamp() {
  return new Date(Date.now() + 7 * 3600_000).toISOString().slice(0, 19).replace(/[-T:]/g, "");
}
async function ipaymuPost(path: string, payload: unknown) {
  const body = JSON.stringify(payload);
  const signature = await hmacSha256(`POST:${VA}:${await sha256(body)}:${API_KEY}`, API_KEY);
  const res = await fetch(ipaymuUrl(path), {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", va: VA, signature, timestamp: stamp() },
    body,
  });
  const out = await res.json().catch(() => null);
  return { ok: res.ok && Number(out?.Status) === 200, out };
}

// iPaymu "via" → the payment method names the shop and Cashflow already use
const METHOD: Record<string, string> = { va: "bank_transfer", qris: "qris", cstore: "cstore", cc: "credit_card", cod: "cod" };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!VA || !API_KEY) return json({ error: "NOT_CONFIGURED" }, 500);

  // iPaymu posts form data by default, or JSON if chosen in the dashboard
  let n: Record<string, unknown> = {};
  try {
    const type = req.headers.get("content-type") ?? "";
    if (type.includes("application/json")) n = await req.json();
    else n = Object.fromEntries(new URLSearchParams(await req.text()));
  } catch { return json({ error: "BAD_REQUEST" }, 400); }

  const trxId = String(n.trx_id ?? "").trim();
  if (!/^\d+$/.test(trxId)) return json({ error: "BAD_REQUEST" }, 400);

  // Ask iPaymu directly for this transaction (don't rely on the notification body)
  const { ok, out } = await ipaymuPost("/api/v2/transaction", { transactionId: Number(trxId) });
  if (!ok || !out?.Data) {
    console.error("Check Transaction failed", trxId, JSON.stringify(out));
    return json({ error: "CHECK_FAILED" }, 502); // iPaymu will retry
  }
  const t = out.Data;
  const orderId = String(t.ReferenceId ?? t.referenceId ?? t.reference_id ?? "");
  if (!orderId) return json({ ok: true, ignored: "no reference" });

  const { data: order } = await admin
    .from("orders").select("order_number,total,status").eq("order_number", orderId).maybeSingle();
  if (!order) return json({ ok: true, ignored: "unknown order" }); // e.g. a test notification

  const status = Number(t.Status ?? t.status);
  // the amount comes only from iPaymu's verified answer, never from the notification body (QA fix OBS-29);
  // no amount there = NaN = treated as a mismatch below
  const paidAmount = Math.round(Number(t.Amount ?? t.amount ?? t.Total ?? t.total));
  const via = String(n.via ?? t.Via ?? t.PaymentMethod ?? "").toLowerCase();
  const method = METHOD[via] ?? (via || null);

  // Cashflow: the environment that sent this notification (Sandbox = Mock order). Idempotent.
  const { error: tagErr } = await admin.rpc("tag_order_payment_env", {
    p_order_number: orderId, p_env: IS_PROD ? "production" : "sandbox",
  });
  if (tagErr) console.error("tag_order_payment_env failed", tagErr.message);

  let result = "unchanged";
  // 1 = berhasil, 6 = berhasil (settlement processed later), 7 = berhasil, held in escrow by iPaymu
  if (status === 1 || status === 6 || status === 7) {
    if (!Number.isFinite(paidAmount) || paidAmount < order.total) {
      console.error(`Amount mismatch for ${orderId}: paid ${paidAmount}, expected ${order.total}`);
      return json({ ok: true, ignored: "amount mismatch" });
    }
    const { data, error } = await admin.rpc("mark_order_paid", {
      p_order_number: orderId, p_payment_ref: trxId, p_payment_method: method,
    });
    if (error) return json({ error: error.message }, 500); // iPaymu will retry
    result = data;
  } else if (status === -2) {
    const { data, error } = await admin.rpc("release_order", { p_order_number: orderId, p_status: "expired" });
    if (error) return json({ error: error.message }, 500);
    result = data;
  }
  // 0 = pending, anything else: no automatic change (check the iPaymu dashboard)

  return json({ ok: true, order: orderId, ipaymu_status: status, result });
});
