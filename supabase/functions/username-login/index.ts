// username-login — sign in with a @username instead of an email.
//
// The client never sees the email. This function resolves username -> email
// SERVER-SIDE (service role, via the email_for_username RPC which is granted
// only to service_role), then performs a normal password sign-in against
// GoTrue and returns just the session tokens. A wrong username OR wrong
// password both return a uniform 400 so neither can be enumerated.
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

  // Resolve the username to an email server-side (never returned to client).
  const admin = createClient(url, service);
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
