// Supabase Edge Function: admin-users
// Shop admin actions on customer accounts. Only callers whose profile role is 'admin' are allowed.
//   POST { action: "reset_password", user_id, password }  set a new password (e.g. forgotten, number accounts)
//   POST { action: "delete_user", user_id }               delete an account (not yourself, not another admin);
//                                                         its orders are kept, unlinked like guest orders
//   POST { action: "create_admin", name, phone, password } make a new account (WhatsApp number login) that is
//                                                         an admin straight away; PHONE_TAKEN if the number exists
// The website sends the public anon key in Authorization and the admin's login token in x-user-token.
// Secrets used: ALLOWED_ORIGINS. "Verify JWT" can stay ON.

const PHONE_DOMAIN = "phone.camilanika.invalid";
function normalizePhone(raw: string) {
  let d = String(raw ?? "").replace(/\D/g, "");
  if (d.startsWith("0")) d = "62" + d.slice(1);
  else if (d.startsWith("8")) d = "62" + d;
  return /^62\d{8,13}$/.test(d) ? d : null;
}

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
  if (b?.action === "delete_user") {
    const userId = String(b.user_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(userId)) return reply({ error: "BAD_USER" }, 400);
    if (userId === caller.user.id) return reply({ error: "CANNOT_DELETE_SELF" }, 400);
    const { data: target } = await admin.from("profiles").select("role").eq("id", userId).maybeSingle();
    if (target?.role === "admin") return reply({ error: "REMOVE_ADMIN_FIRST" }, 400);
    // orders stay (unlinked, like guest orders); profile is removed with the account
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) { console.error("delete failed", error.message); return reply({ error: "DELETE_FAILED" }, 400); }
    return reply({ ok: true });
  }
  if (b?.action === "create_admin") {
    const name = String(b.name ?? "").trim().slice(0, 100);
    const phone = normalizePhone(b.phone);
    const password = String(b.password ?? "");
    if (!name) return reply({ error: "NAME_REQUIRED" }, 400);
    if (!phone) return reply({ error: "PHONE_INVALID" }, 400);
    if (password.length < 8) return reply({ error: "PASSWORD_TOO_SHORT" }, 400);
    const display = "0" + phone.slice(2);
    const { data: created, error } = await admin.auth.admin.createUser({
      email: `${phone}@${PHONE_DOMAIN}`, password, email_confirm: true,
      user_metadata: { full_name: name, phone: display, signup: "admin" },
    });
    if (error) {
      if (/already|registered|exists/i.test(error.message)) return reply({ error: "PHONE_TAKEN" }, 409);
      console.error("create admin failed", error.message);
      return reply({ error: "CREATE_FAILED" }, 400);
    }
    const uid = created.user.id;
    // the profile row is made by a trigger when the account is created; set name, number and role
    const { data: upd, error: pErr } = await admin.from("profiles").update({ full_name: name, phone: display, role: "admin" }).eq("id", uid).select("id");
    if (pErr || !upd?.length) {
      console.error("make admin failed", pErr?.message ?? "no profile row");
      await admin.auth.admin.deleteUser(uid);
      return reply({ error: "CREATE_FAILED" }, 400);
    }
    return reply({ ok: true, user_id: uid, phone: display });
  }
  return reply({ error: "UNKNOWN_ACTION" }, 400);
});
