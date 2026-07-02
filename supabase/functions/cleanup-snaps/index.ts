// Purges group snaps older than 48h — storage objects first, then rows.
// Invoked daily by pg_cron via pg_net (see migration 034), authenticated
// with the same shared hook secret as send-push (PUSH_HOOK_SECRET).
// verify_jwt is off; we check the secret ourselves.

import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const secret = (req.headers.get("authorization") ?? "").replace("Bearer ", "");
  if (!secret || secret !== Deno.env.get("PUSH_HOOK_SECRET")) {
    return new Response("unauthorized", { status: 401 });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const cutoff = new Date(Date.now() - 48 * 3600 * 1000).toISOString();
  let totalDeleted = 0;

  // Batch so a huge backlog can't blow the function's time budget.
  for (let i = 0; i < 10; i++) {
    const { data: rows, error } = await admin
      .from("session_snaps")
      .select("id, storage_path")
      .lt("created_at", cutoff)
      .limit(200);
    if (error) return new Response(error.message, { status: 500 });
    if (!rows || rows.length === 0) break;

    const { error: rmErr } = await admin.storage
      .from("session-snaps")
      .remove(rows.map((r) => r.storage_path));
    // Missing objects are fine (already gone); real errors stop the run
    // WITHOUT deleting rows, so nothing orphans silently.
    if (rmErr) return new Response(rmErr.message, { status: 500 });

    const { error: delErr } = await admin
      .from("session_snaps")
      .delete()
      .in("id", rows.map((r) => r.id));
    if (delErr) return new Response(delErr.message, { status: 500 });

    totalDeleted += rows.length;
    if (rows.length < 200) break;
  }

  return Response.json({ deleted: totalDeleted });
});
