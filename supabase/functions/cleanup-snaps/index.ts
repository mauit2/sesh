// Purges ephemeral photo content:
//   • squad schnaps whose session has ENDED (members had their window to
//     save them / build the group recap) or that are older than 48h
//   • live stories older than 24h
// Storage objects first, then rows. Invoked daily by pg_cron via pg_net
// (see migrations 034/036), authenticated with the same shared hook
// secret as send-push (PUSH_HOOK_SECRET). verify_jwt is off; we check
// the secret ourselves.

import { createClient } from "npm:@supabase/supabase-js@2";

type SupabaseAdmin = ReturnType<typeof createClient>;
type Row = { id: string; storage_path: string };

async function deleteBatch(
  admin: SupabaseAdmin,
  table: string,
  bucket: string,
  rows: Row[],
): Promise<void> {
  if (rows.length === 0) return;
  const { error: rmErr } = await admin.storage
    .from(bucket)
    .remove(rows.map((r) => r.storage_path));
  // Missing objects are fine (already gone); real errors stop the run
  // WITHOUT deleting rows, so nothing orphans silently.
  if (rmErr) throw new Error(`${bucket}: ${rmErr.message}`);
  const { error: delErr } = await admin
    .from(table)
    .delete()
    .in("id", rows.map((r) => r.id));
  if (delErr) throw new Error(`${table}: ${delErr.message}`);
}

// Rows older than maxAgeHours.
async function purgeAged(
  admin: SupabaseAdmin,
  table: string,
  bucket: string,
  maxAgeHours: number,
): Promise<number> {
  const cutoff = new Date(Date.now() - maxAgeHours * 3600 * 1000).toISOString();
  let total = 0;
  for (let i = 0; i < 10; i++) {
    const { data, error } = await admin
      .from(table)
      .select("id, storage_path")
      .lt("created_at", cutoff)
      .limit(200);
    if (error) throw new Error(`${table}: ${error.message}`);
    const rows = (data ?? []) as Row[];
    if (rows.length === 0) break;
    await deleteBatch(admin, table, bucket, rows);
    total += rows.length;
    if (rows.length < 200) break;
  }
  return total;
}

// Squad schnaps whose live session has been ended.
async function purgeEndedSessionSnaps(admin: SupabaseAdmin): Promise<number> {
  let total = 0;
  for (let i = 0; i < 10; i++) {
    const { data, error } = await admin
      .from("session_snaps")
      .select("id, storage_path, sessions!inner(active_live)")
      .eq("sessions.active_live", false)
      .limit(200);
    if (error) throw new Error(`session_snaps(ended): ${error.message}`);
    const rows = (data ?? []) as unknown as Row[];
    if (rows.length === 0) break;
    await deleteBatch(admin, "session_snaps", "session-snaps", rows);
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
    const ended = await purgeEndedSessionSnaps(admin);
    const aged = await purgeAged(admin, "session_snaps", "session-snaps", 48);
    const stories = await purgeAged(admin, "live_stories", "stories", 24);
    return Response.json({ deleted: ended + aged, stories_deleted: stories });
  } catch (e) {
    return new Response((e as Error).message, { status: 500 });
  }
});
