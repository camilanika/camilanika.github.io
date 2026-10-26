// Supabase Edge Function: phone-signup
// Creates a customer account from a WhatsApp number + password, ready to log in immediately.
// No SMS is sent. Behind the scenes the login is a private address <number>@phone.camilanika.invalid
// (".invalid" can never receive email, so nobody can take over these accounts by email).
//
// Secrets used: ALLOWED_ORIGINS (same as create-payment). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are automatic.
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

  const email = `${phone}@${PHONE_DOMAIN}`;
  const display = "0" + phone.slice(2); // 0812...
  const { error } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { full_name: name, phone: display, signup: "phone" },
  });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) return reply({ error: "PHONE_TAKEN" }, 409);
    console.error("createUser failed", error.message);
    return reply({ error: "SIGNUP_FAILED" }, 400);
  }
  return reply({ ok: true, login: email });
});
