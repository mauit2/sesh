// send-push — sends an APNs push to all of a user's registered devices.
//
// Invoked only by the database (pg_net triggers in migration 028) with a
// shared-secret bearer (PUSH_HOOK_SECRET) — verify_jwt is off and we check the
// secret ourselves. Signs an APNs auth JWT (ES256) with the .p8 key, sends to
// production APNs and falls back to sandbox on BadDeviceToken (dev builds), and
// prunes tokens APNs reports as gone (410).
//
// Secrets required: APNS_KEY (.p8 contents), APNS_KEY_ID, APNS_TEAM_ID,
// PUSH_HOOK_SECRET, optional APNS_BUNDLE_ID (defaults to Mau.sesh-app).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlStr(s: string): string {
  return b64url(new TextEncoder().encode(s));
}
function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
  const bin = atob(body);
  const der = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}

let cached: { jwt: string; at: number } | null = null;
async function apnsJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.at < 2400) return cached.jwt; // reuse up to 40 min
  const header = { alg: "ES256", kid: Deno.env.get("APNS_KEY_ID")! };
  const claims = { iss: Deno.env.get("APNS_TEAM_ID")!, iat: now };
  const input = b64urlStr(JSON.stringify(header)) + "." + b64urlStr(JSON.stringify(claims));
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToDer(Deno.env.get("APNS_KEY")!),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)),
  );
  const jwt = input + "." + b64url(sig);
  cached = { jwt, at: now };
  return jwt;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  if (req.headers.get("Authorization") !== `Bearer ${Deno.env.get("PUSH_HOOK_SECRET")}`) {
    return new Response("unauthorized", { status: 401 });
  }

  let user_id = "", title = "", body = "";
  let data: Record<string, unknown> = {};
  try {
    const j = await req.json();
    user_id = String(j.user_id ?? "");
    title = String(j.title ?? "sesh");
    body = String(j.body ?? "");
    data = (j.data ?? {}) as Record<string, unknown>;
  } catch {
    return new Response("bad_request", { status: 400 });
  }
  if (!user_id) return new Response("bad_request", { status: 400 });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: tokens } = await admin.from("device_tokens").select("token").eq("user_id", user_id);
  if (!tokens || tokens.length === 0) return new Response(JSON.stringify({ sent: 0 }), { status: 200 });

  const bundle = Deno.env.get("APNS_BUNDLE_ID") ?? "Mau.sesh-app";
  const jwt = await apnsJWT();
  const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, ...data });

  let sent = 0;
  for (const row of tokens) {
    const tok = (row as { token: string }).token;
    const send = (host: string) =>
      fetch(`https://${host}/3/device/${tok}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": bundle,
          "apns-push-type": "alert",
          "content-type": "application/json",
        },
        body: payload,
      });
    let resp = await send("api.push.apple.com");
    if (resp.status === 400) {
      const txt = await resp.text();
      if (txt.includes("BadDeviceToken")) resp = await send("api.sandbox.push.apple.com");
    }
    if (resp.ok) sent++;
    else if (resp.status === 410) await admin.from("device_tokens").delete().eq("token", tok);
  }
  return new Response(JSON.stringify({ sent }), { status: 200, headers: { "content-type": "application/json" } });
});
