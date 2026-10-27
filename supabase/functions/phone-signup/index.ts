// Supabase Edge Function: phone-signup
// Creates a customer account from a WhatsApp number + password, ready to log in immediately.
// No SMS is sent. Behind the scenes the login is a private address <number>@phone.camilanika.invalid
// (".invalid" can never receive email, so nobody can take over these accounts by email).
//
// Optional "referral_code": a campaign code made in the admin page. A valid code gives the new
// account a one-time voucher (checked and issued in the database, once per account).
// Sign-ups are rate limited per network (limits in shop_settings, set in the admin page).
//
// Secrets used: ALLOWED_ORIGINS (same as create-payment). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are automatic.
// Optional SIGNUP_SALT: any random text, used to hash IP addresses (raw IPs are never stored).
// "Verify JWT" can stay ON: the website sends the public anon key.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const PHONE_DOMAIN = "phone.camilanika.invalid";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ?? "https://camilanika.github.io").split(",").map((s) => s.trim()).filter(Boolean);

function cors(origin: string | null) {
  return {
    "Access-Control-Allow-Origin": origin && ALLOWED.includes(origin) ? origin : ALLOWED[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

// 0812-3456-7890 / +62 812 3456 7890 / 62812... -> 6281234567890
function normalizePhone(raw: string) {
  let d = String(raw ?? "").replace(/\D/g, "");
  if (d.startsWith("0")) d = "62" + d.slice(1);
  else if (d.startsWith("8")) d = "62" + d;
  return /^62\d{8,13}$/.test(d) ? d : null;
}

const SALT = Deno.env.get("SIGNUP_SALT") ?? (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "").slice(-16);
async function hashIp(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "unknown";
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(SALT + "|" + ip));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);

  let b: any;
  try { b = await req.json(); } catch { return reply({ error: "BAD_REQUEST" }, 400); }

  const name = String(b?.name ?? "").trim().slice(0, 100);
  const phone = normalizePhone(b?.phone);
  const password = String(b?.password ?? "");
  if (!name) return reply({ error: "NAME_REQUIRED" }, 400);
  if (!phone) return reply({ error: "PHONE_INVALID" }, 400);
  if (password.length < 8) return reply({ error: "PASSWORD_TOO_SHORT" }, 400);
  const referral = String(b?.referral_code ?? "").trim().toUpperCase().slice(0, 24);

  // rate limit per network
  const ipHash = await hashIp(req);
  const { data: guard, error: gErr } = await admin.rpc("signup_guard", { p_ip_hash: ipHash, p_phone: phone });
  if (gErr) { console.error("signup_guard", gErr.message); return reply({ error: "SIGNUP_FAILED" }, 500); }
  if (!guard?.ok) return reply({ error: "RATE_LIMITED" }, 429);

  // a typed referral code must be valid before the account is made, so the customer can fix it
  if (referral) {
    const { data: pv, error: pErr } = await admin.rpc("referral_preview", { p_code: referral });
    if (pErr) { console.error("referral_preview", pErr.message); return reply({ error: "SIGNUP_FAILED" }, 500); }
    if (!pv?.ok) return reply({ error: pv?.error ?? "REFERRAL_INVALID" }, 400);
  }

  const email = `${phone}@${PHONE_DOMAIN}`;
  const display = "0" + phone.slice(2); // 0812...
  const { data: created, error } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { full_name: name, phone: display, signup: "phone" },
  });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) return reply({ error: "PHONE_TAKEN" }, 409);
    console.error("createUser failed", error.message);
    return reply({ error: "SIGNUP_FAILED" }, 400);
  }
  // referral voucher (the database enforces one per account and the campaign limits)
  let reward: unknown = null;
  if (referral && created?.user?.id) {
    const { data: rw, error: rErr } = await admin.rpc("referral_reward", { p_user: created.user.id, p_code: referral, p_ip_hash: ipHash });
    if (rErr) console.error("referral_reward", rErr.message);
    reward = rErr ? { rewarded: false, reason: "ERROR" } : rw;
  }
  return reply({ ok: true, login: email, referral: reward });
});
