// Supabase Edge Function: admin-users
// Lets a shop admin set a new password for a customer (e.g. someone who registered with their
// WhatsApp number and forgot the password). Only callers whose profile role is 'admin' are allowed.
//
// Request: POST { action: "reset_password", user_id, password }
// The website sends the public anon key in Authorization and the admin's login token in x-user-token.
// Secrets used: ALLOWED_ORIGINS. "Verify JWT" can stay ON.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ?? "https://camilanika.github.io").split(",").map((s) => s.trim()).filter(Boolean);

function cors(origin: string | null) {
  return {
    "Access-Control-Allow-Origin": origin && ALLOWED.includes(origin) ? origin : ALLOWED[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-user-token",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  const headers = { ...cors(req.headers.get("origin")), "Content-Type": "application/json" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);

  // who is calling?
  const token = req.headers.get("x-user-token") ?? "";
  if (!token) return reply({ error: "NOT_ADMIN" }, 403);
  const { data: caller } = await admin.auth.getUser(token);
  if (!caller?.user) return reply({ error: "NOT_ADMIN" }, 403);
  const { data: prof } = await admin.from("profiles").select("role").eq("id", caller.user.id).maybeSingle();
  if (prof?.role !== "admin") return reply({ error: "NOT_ADMIN" }, 403);

  let b: any;
  try { b = await req.json(); } catch { return reply({ error: "BAD_REQUEST" }, 400); }

  if (b?.action === "reset_password") {
    const userId = String(b.user_id ?? "");
    const password = String(b.password ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(userId)) return reply({ error: "BAD_USER" }, 400);
    if (password.length < 8) return reply({ error: "PASSWORD_TOO_SHORT" }, 400);
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) { console.error("reset failed", error.message); return reply({ error: "RESET_FAILED" }, 400); }
    return reply({ ok: true });
  }
  return reply({ error: "UNKNOWN_ACTION" }, 400);
});
