// Purges ephemeral photo content: group snaps older than 48h and live
// stories older than 24h — storage objects first, then rows. Invoked
// daily by pg_cron via pg_net (see migrations 034/036), authenticated
// with the same shared hook secret as send-push (PUSH_HOOK_SECRET).
// verify_jwt is off; we check the secret ourselves.

import { createClient } from "npm:@supabase/supabase-js@2";

type SupabaseAdmin = ReturnType<typeof createClient>;

// Deletes expired rows + their storage objects in batches. Returns the
// number of rows removed, or throws a Response-able error message.
async function purge(
  admin: SupabaseAdmin,
  table: string,
  bucket: string,
  maxAgeHours: number,
): Promise<number> {
  const cutoff = new Date(Date.now() - maxAgeHours * 3600 * 1000).toISOString();
  let total = 0;
  for (let i = 0; i < 10; i++) {
    const { data: rows, error } = await admin
      .from(table)
      .select("id, storage_path")
      .lt("created_at", cutoff)
      .limit(200);
    if (error) throw new Error(`${table}: ${error.message}`);
    if (!rows || rows.length === 0) break;

    const { error: rmErr } = await admin.storage
      .from(bucket)
      .remove(rows.map((r) => r.storage_path as string));
    // Missing objects are fine (already gone); real errors stop the run
    // WITHOUT deleting rows, so nothing orphans silently.
    if (rmErr) throw new Error(`${bucket}: ${rmErr.message}`);

    const { error: delErr } = await admin
      .from(table)
      .delete()
      .in("id", rows.map((r) => r.id as string));
    if (delErr) throw new Error(`${table}: ${delErr.message}`);

    total += rows.length;
    if (rows.length < 200) break;
  }
  return total;
}

Deno.serve(async (req) => {
  const secret = (req.headers.get("authorization") ?? "").replace("Bearer ", "");
  if (!secret || secret !== Deno.env.get("PUSH_HOOK_SECRET")) {
    return new Response("unauthorized", { status: 401 });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const snaps = await purge(admin, "session_snaps", "session-snaps", 48);
    const stories = await purge(admin, "live_stories", "stories", 24);
    return Response.json({ deleted: snaps, stories_deleted: stories });
  } catch (e) {
    return new Response((e as Error).message, { status: 500 });
  }
});
