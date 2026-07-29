// delete-account — permanently delete the calling user's account.
//
// App Store guideline 5.1.1(v) requires in-app account deletion. Direct SQL
// deletes on storage.objects are blocked by Supabase's protect_delete
// trigger, so this function does the file cleanup through the Storage API,
// then removes every row via the service_role-only delete_account_rows RPC
// (auth.users -> profiles -> everything, ON DELETE CASCADE).
//
// The caller can only ever delete themselves: the uid comes from the verified
// JWT, never from the request body.

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

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "unauthorized" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, service);

  const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
  const uid = userData?.user?.id;
  if (userErr || !uid) return json({ error: "unauthorized" }, 401);

  // 1. Files first (avatars, snaps, stories, recap photos, event covers) —
  //    must go through the Storage API, SQL deletes are blocked.
  const { data: files, error: listErr } = await admin.rpc("user_files", { p_uid: uid });
  if (listErr) return json({ error: "cleanup_failed" }, 500);

  const byBucket = new Map<string, string[]>();
  for (const f of files ?? []) {
    const list = byBucket.get(f.bucket_id) ?? [];
    list.push(f.name);
    byBucket.set(f.bucket_id, list);
  }
  for (const [bucket, names] of byBucket) {
    for (let i = 0; i < names.length; i += 100) {
      const { error } = await admin.storage.from(bucket).remove(names.slice(i, i + 100));
      if (error) return json({ error: "storage_failed" }, 500);
    }
  }

  // 2. Rows + the auth user itself. After this the JWT is orphaned.
  const { error: delErr } = await admin.rpc("delete_account_rows", { p_uid: uid });
  if (delErr) return json({ error: "delete_failed" }, 500);

  return json({ ok: true }, 200);
});
