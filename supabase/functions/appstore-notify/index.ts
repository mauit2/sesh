// appstore-notify — App Store Server Notifications V2.
//
// Apple posts here when a subscription renews, lapses, is cancelled or
// refunded, and when a consumable is refunded. We never act on the body: it
// only tells us WHICH transaction moved. We then ask Apple for that
// transaction's current state and act on the answer, so a forged POST can at
// worst make us re-check something we already knew.
//
// This is the authoritative path. The app's own report (business_sync_
// subscription) is verified the same way but only covers the moment of
// purchase; renewals and refunds only ever arrive here.
//
// Deployed with verify_jwt = false — Apple has no Supabase token to send.
// Apple retries a non-2xx for up to 3 days, so we answer 200 once the work is
// done or the notification is one we deliberately ignore, and 500 only when we
// genuinely could not finish.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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

async function appleBearer(): Promise<string> {
  const kid = Deno.env.get("APPLE_IAP_KEY_ID");
  const iss = Deno.env.get("APPLE_IAP_ISSUER_ID");
  if (!kid || !iss) throw new Error("missing_apple_key_ids");
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid, typ: "JWT" }));
  const body = b64url(JSON.stringify({
    iss,
    iat: now,
    exp: now + 1800,
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

/// Claims out of a signed payload. Unverified on purpose for the incoming
/// notification (we only read the ids from it); verified by provenance for
/// anything Apple hands back over TLS.
function claimsOf(jws: string): Record<string, unknown> {
  const part = jws.split(".")[1];
  if (!part) throw new Error("bad_jws");
  const bin = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

async function appleGet(
  path: string,
): Promise<{ body: Record<string, unknown>; sandbox: boolean } | null> {
  const token = await appleBearer();
  for (const host of HOSTS) {
    const res = await fetch(host.url + path, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.ok) return { body: await res.json(), sandbox: host.sandbox };
    if (res.status === 404) continue;
    const text = await res.text();
    throw new Error(`apple_${res.status}: ${text.slice(0, 300)}`);
  }
  return null;
}

function flatten(t: Record<string, unknown>, sandbox: boolean) {
  return {
    transaction_id: t.transactionId ?? null,
    original_transaction_id: t.originalTransactionId ?? null,
    product_id: t.productId ?? null,
    type: t.type ?? null,
    app_account_token: t.appAccountToken ?? null,
    bundle_id: t.bundleId ?? null,
    purchased_at: t.purchaseDate ? new Date(Number(t.purchaseDate)).toISOString() : null,
    expires_at: t.expiresDate ? new Date(Number(t.expiresDate)).toISOString() : null,
    revoked_at: t.revocationDate ? new Date(Number(t.revocationDate)).toISOString() : null,
    revocation_reason: t.revocationReason ?? null,
    sandbox,
  };
}

/// Apple's subscription status codes: 1 active, 2 expired, 3 in billing retry,
/// 4 in billing grace, 5 revoked. 3 and 4 still count as paid — the bar keeps
/// its pin while Apple retries the card.
const PAID_STATUS = new Set([1, 3, 4]);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let signedPayload = "";
  try {
    const body = await req.json();
    signedPayload = String(body.signedPayload ?? "");
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (!signedPayload) return json({ error: "bad_request" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const note = claimsOf(signedPayload);
    const type = String(note.notificationType ?? "");
    const subtype = String(note.subtype ?? "");
    const data = (note.data ?? {}) as Record<string, unknown>;

    // The ids are all we take from the body.
    let originalTransactionId = String(
      (data.originalTransactionId as string | undefined) ?? "",
    );
    let transactionId = "";
    if (typeof data.signedTransactionInfo === "string") {
      const t = claimsOf(data.signedTransactionInfo);
      originalTransactionId ||= String(t.originalTransactionId ?? "");
      transactionId = String(t.transactionId ?? "");
    }

    if (type === "TEST") {
      // The "Request a Test Notification" button in App Store Connect. Nothing
      // to apply; answering 200 is what proves the URL is wired up.
      console.log("test notification received");
      return json({ ok: true, test: true }, 200);
    }

    if (!originalTransactionId && !transactionId) {
      return json({ ok: true, ignored: "no_transaction" }, 200);
    }

    // Ask Apple what is actually true right now.
    let fact: ReturnType<typeof flatten> | null = null;
    let status: number | null = null;

    if (originalTransactionId) {
      const sub = await appleGet(`/inApps/v1/subscriptions/${originalTransactionId}`);
      const groups = (sub?.body.data ?? []) as Array<Record<string, unknown>>;
      for (const g of groups) {
        for (const last of (g.lastTransactions ?? []) as Array<Record<string, unknown>>) {
          if (String(last.originalTransactionId ?? "") !== originalTransactionId) continue;
          status = Number(last.status ?? 0);
          if (typeof last.signedTransactionInfo === "string") {
            fact = flatten(claimsOf(last.signedTransactionInfo), sub!.sandbox);
          }
        }
      }
    }
    // Consumables (boosts, cards, pushes) have no subscription record.
    if (!fact && transactionId) {
      const one = await appleGet(`/inApps/v1/transactions/${transactionId}`);
      const signed = one?.body.signedTransactionInfo as string | undefined;
      if (signed) fact = flatten(claimsOf(signed), one!.sandbox);
    }

    if (!fact) return json({ ok: true, ignored: "apple_has_no_record" }, 200);
    if (fact.bundle_id !== BUNDLE_ID) {
      return json({ ok: true, ignored: "wrong_bundle" }, 200);
    }

    const paid = status === null ? fact.revoked_at === null : PAID_STATUS.has(status);
    const { data: applied, error } = await admin.rpc("appstore_apply", {
      p_fact: fact,
      p_status: status,
      p_paid: paid,
      p_notification: `${type}${subtype ? "/" + subtype : ""}`,
    });
    if (error) throw new Error(`apply_failed: ${error.message}`);

    return json({ ok: true, applied }, 200);
  } catch (e) {
    console.error("notify failed", e);
    // A 500 makes Apple retry, which is what we want for a transient failure.
    return json({ error: "failed", detail: String(e).slice(0, 300) }, 500);
  }
});
