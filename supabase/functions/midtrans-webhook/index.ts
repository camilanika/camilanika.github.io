// Supabase Edge Function: midtrans-webhook
// Midtrans calls this URL whenever a payment changes status.
// Set it in Midtrans Dashboard → Settings → Payment → Notification URL:
//   https://<project-ref>.supabase.co/functions/v1/midtrans-webhook
//
// Secrets: MIDTRANS_SERVER_KEY, MIDTRANS_IS_PRODUCTION (same as create-payment).
// Deploy with "Verify JWT" turned OFF (Midtrans doesn't send a Supabase token);
// every call is verified with Midtrans' signature and re-checked against the Midtrans API.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SERVER_KEY = Deno.env.get("MIDTRANS_SERVER_KEY") ?? "";
const IS_PROD = Deno.env.get("MIDTRANS_IS_PRODUCTION") === "true";
const API_BASE = IS_PROD ? "https://api.midtrans.com" : "https://api.sandbox.midtrans.com";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

async function sha512(text: string) {
  const buf = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!SERVER_KEY) return json({ error: "NOT_CONFIGURED" }, 500);

  let n: any;
  try { n = await req.json(); } catch { return json({ error: "BAD_REQUEST" }, 400); }

  const orderId = String(n?.order_id ?? "");
  const expected = await sha512(`${orderId}${n?.status_code ?? ""}${n?.gross_amount ?? ""}${SERVER_KEY}`);
  if (!orderId || !timingSafeEqual(expected, String(n?.signature_key ?? ""))) {
    return json({ error: "INVALID_SIGNATURE" }, 401);
  }

  // Ask Midtrans directly for the current status (don't rely only on the notification body)
  const res = await fetch(`${API_BASE}/v2/${encodeURIComponent(orderId)}/status`, {
    headers: { Accept: "application/json", Authorization: "Basic " + btoa(SERVER_KEY + ":") },
  });
  const st = await res.json().catch(() => null);
  if (!res.ok || !st || String(st.status_code) === "404") return json({ ok: true, ignored: "unknown transaction" });

  const { data: order } = await admin
    .from("orders").select("order_number,total,status").eq("order_number", orderId).maybeSingle();
  if (!order) return json({ ok: true, ignored: "unknown order" }); // e.g. Midtrans "test notification"

  const status = String(st.transaction_status);
  const fraud = String(st.fraud_status ?? "accept");
  const paidAmount = Math.round(Number(st.gross_amount));

  let result = "unchanged";
  if (status === "settlement" || (status === "capture" && fraud === "accept")) {
    if (paidAmount !== order.total) {
      console.error(`Amount mismatch for ${orderId}: paid ${paidAmount}, expected ${order.total}`);
      return json({ ok: true, ignored: "amount mismatch" });
    }
    const { data, error } = await admin.rpc("mark_order_paid", {
      p_order_number: orderId,
      p_payment_ref: st.transaction_id ?? null,
      p_payment_method: st.payment_type ?? null,
    });
    if (error) return json({ error: error.message }, 500); // Midtrans will retry
    result = data;
  } else if (["deny", "cancel", "expire", "failure"].includes(status)) {
    const map: Record<string, string> = { deny: "failed", failure: "failed", cancel: "cancelled", expire: "expired" };
    const { data, error } = await admin.rpc("release_order", { p_order_number: orderId, p_status: map[status] });
    if (error) return json({ error: error.message }, 500);
    result = data;
  }
  // pending / capture+challenge / refund: no automatic change

  return json({ ok: true, order: orderId, midtrans_status: status, result });
});
