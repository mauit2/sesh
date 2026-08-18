// username-login — sign in with a @username instead of an email.
//
// The client never sees the email. This function resolves username -> email
// SERVER-SIDE (service role, via the email_for_username RPC which is granted
// only to service_role), then performs a normal password sign-in against
// GoTrue and returns just the session tokens. A wrong username OR wrong
// password both return a uniform 400 so neither can be enumerated.
//
// BRUTE-FORCE PROTECTION: this endpoint proxies the password grant to GoTrue
// from the edge runtime's own IP, so GoTrue's per-IP throttle can't see the
// real caller. We enforce our own limits here — by client IP AND by the
// submitted username — using the same rate_limit_hit() the web RPCs use.
//
// Deployed with verify_jwt = false: this runs before the user has a session,
// and it implements its own auth (the password check below).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let username = "";
  let password = "";
  try {
    const body = await req.json();
    username = String(body.username ?? "").trim();
    password = String(body.password ?? "");
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (!username || !password) return json({ error: "bad_request" }, 400);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, service);

  // Throttle before doing any work. Two independent buckets: a per-IP cap
  // stops a single host hammering many accounts; a per-username cap stops a
  // botnet hammering one account from many IPs. Either tripping is a 429.
  // Keyed on the submitted username (lowercased) so it throttles equally
  // whether or not the account exists — no enumeration signal.
  const ip = (req.headers.get("x-forwarded-for") ?? "")
    .split(",")[0].trim() || "unknown";
  const uname = username.toLowerCase();
  try {
    const [ipOk, userOk] = await Promise.all([
      admin.rpc("rate_limit_hit",
        { p_bucket: "login_ip", p_key: ip, p_limit: 30, p_window: "15 minutes" }),
      admin.rpc("rate_limit_hit",
        { p_bucket: "login_user", p_key: uname, p_limit: 10, p_window: "15 minutes" }),
    ]);
    if (ipOk.data === false || userOk.data === false) {
      return json({ error: "too_many_attempts" }, 429);
    }
    // ipOk.error/userOk.error → fail open (don't lock out logins if the
    // limiter itself is unavailable), but the DB path is the same one the
    // web RPCs rely on, so this is a last-resort safety net.
  } catch {
    // fail open — availability over strictness for the limiter itself.
  }

  // Resolve the username to an email server-side (never returned to client).
  const { data: email, error } = await admin.rpc("email_for_username", {
    p_username: username,
  });
  if (error || !email) return json({ error: "invalid_credentials" }, 400);

  // Password sign-in via GoTrue. Returns tokens on success.
  const resp = await fetch(`${url}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: anon },
    body: JSON.stringify({ email, password }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok || !data.access_token || !data.refresh_token) {
    return json({ error: "invalid_credentials" }, 400);
  }
  return json(
    { access_token: data.access_token, refresh_token: data.refresh_token },
    200,
  );
});
