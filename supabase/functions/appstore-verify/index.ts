// appstore-verify — is this App Store transaction real?
//
// The app reports its own purchases (business_sync_subscription,
// business_mark_paid, business_boost_paid). A phone can lie, so the database
// calls this before it grants anything: we ask APPLE about the transaction id,
// over TLS, with a request signed by our own In-App Purchase key. Whatever
// Apple answers is the truth and the values the client sent are ignored.
//
// We do not verify Apple's JWS signature by hand (no x5c chain walking). We
// don't need to: the payload came back on an authenticated connection to
// Apple's own server, so it is Apple's word by construction.
//
// Deployed with verify_jwt = false. The caller proves itself with the shared
// secret in x-sejdel-secret, which Postgres reads out of private.app_config.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const BUNDLE_ID = "Mau.sesh-app";
const HOSTS = [
  { url: "https://api.storekit.itunes.apple.com", sandbox: false },
  { url: "https://api.storekit-sandbox.itunes.apple.com", sandbox: true },
];

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function b64url(input: Uint8Array | string): string {
  const bin = typeof input === "string"
    ? input
    : Array.from(input, (b) => String.fromCharCode(b)).join("");
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// The .p8 as a WebCrypto signing key. Cached for the life of the instance.
let cachedKey: CryptoKey | null = null;
async function signingKey(): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  const pem = Deno.env.get("APPLE_IAP_PRIVATE_KEY");
  if (!pem) throw new Error("missing_APPLE_IAP_PRIVATE_KEY");
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  cachedKey = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return cachedKey;
}

/// The App Store Server API bearer token. ES256 over our issuer + key id.
async function appleBearer(): Promise<string> {
  const kid = Deno.env.get("APPLE_IAP_KEY_ID");
  const iss = Deno.env.get("APPLE_IAP_ISSUER_ID");
  if (!kid || !iss) throw new Error("missing_apple_key_ids");
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid, typ: "JWT" }));
  const body = b64url(JSON.stringify({
    iss,
    iat: now,
    exp: now + 1800, // Apple caps the token at 60 minutes.
    aud: "appstoreconnect-v1",
    bid: BUNDLE_ID,
  }));
  const signed = `${head}.${body}`;
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey(),
    new TextEncoder().encode(signed),
  ));
  return `${signed}.${b64url(sig)}`;
}

/// The claims inside one of Apple's signed payloads. Reading without checking
/// the signature is safe here — Apple handed us the string directly.
function claimsOf(jws: string): Record<string, unknown> {
  const part = jws.split(".")[1];
  if (!part) throw new Error("bad_jws");
  const bin = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

/// Production first, then sandbox — Apple's own recommended order. null when
/// neither environment has ever heard of it.
async function appleGet(
  path: string,
): Promise<{ body: Record<string, unknown>; sandbox: boolean } | null> {
  const token = await appleBearer();
  for (const host of HOSTS) {
    const res = await fetch(host.url + path, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.ok) return { body: await res.json(), sandbox: host.sandbox };
    if (res.status === 404) continue; // Try the other environment.
    const text = await res.text();
    throw new Error(`apple_${res.status}: ${text.slice(0, 300)}`);
  }
  return null;
}

/// Apple's transaction, flattened to what the database cares about.
function flatten(
  t: Record<string, unknown>,
  sandbox: boolean,
): Record<string, unknown> {
  return {
    transaction_id: t.transactionId ?? null,
    original_transaction_id: t.originalTransactionId ?? null,
    product_id: t.productId ?? null,
    type: t.type ?? null,
    app_account_token: t.appAccountToken ?? null,
    bundle_id: t.bundleId ?? null,
    quantity: t.quantity ?? 1,
    purchased_at: t.purchaseDate ? new Date(Number(t.purchaseDate)).toISOString() : null,
    expires_at: t.expiresDate ? new Date(Number(t.expiresDate)).toISOString() : null,
    revoked_at: t.revocationDate ? new Date(Number(t.revocationDate)).toISOString() : null,
    revocation_reason: t.revocationReason ?? null,
    sandbox,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const want = Deno.env.get("SEJDEL_INTERNAL_SECRET");
  if (!want || req.headers.get("x-sejdel-secret") !== want) {
    return json({ error: "forbidden" }, 403);
  }

  let transactionId = "";
  try {
    const body = await req.json();
    transactionId = String(body.transaction_id ?? "").trim();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (!/^[0-9]{1,30}$/.test(transactionId)) {
    return json({ ok: false, reason: "bad_transaction_id" }, 200);
  }

  try {
    const found = await appleGet(`/inApps/v1/transactions/${transactionId}`);
    if (!found) return json({ ok: false, reason: "unknown_transaction" }, 200);

    const signed = found.body.signedTransactionInfo as string | undefined;
    if (!signed) return json({ ok: false, reason: "no_transaction_info" }, 200);

    const t = flatten(claimsOf(signed), found.sandbox);
    // A transaction for someone else's app is not ours to honour.
    if (t.bundle_id !== BUNDLE_ID) {
      return json({ ok: false, reason: "wrong_bundle" }, 200);
    }
    return json({ ok: true, transaction: t }, 200);
  } catch (e) {
    console.error("verify failed", e);
    return json({ ok: false, reason: "apple_unreachable", detail: String(e).slice(0, 200) }, 200);
  }
});
