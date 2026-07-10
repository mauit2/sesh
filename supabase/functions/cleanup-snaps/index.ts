// Purges ephemeral photo content:
//   • squad schnaps whose session has ENDED (members had their window to
//     save them / build the group recap) or that are older than 48h —
//     EXCEPT snaps from event-linked sessions (events.live_session_id):
//     those live on inside the event's night report on the PLAN tab, so
//     they follow the event's lifetime instead of the 48h window.
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

// Session ids owned by events — their schnaps are permanent (they feed
// the event's night report), so every session_snaps purge skips them.
async function eventSessionIds(admin: SupabaseAdmin): Promise<string[]> {
  const { data, error } = await admin
    .from("events")
    .select("live_session_id")
    .not("live_session_id", "is", null);
  if (error) throw new Error(`events: ${error.message}`);
  return (data ?? [])
    .map((r) => (r as { live_session_id: string }).live_session_id)
    .filter(Boolean);
}

// Rows older than maxAgeHours (optionally sparing given session ids).
async function purgeAged(
  admin: SupabaseAdmin,
  table: string,
  bucket: string,
  maxAgeHours: number,
  spareSessionIds: string[] = [],
): Promise<number> {
  const cutoff = new Date(Date.now() - maxAgeHours * 3600 * 1000).toISOString();
  let total = 0;
  for (let i = 0; i < 10; i++) {
    let q = admin
      .from(table)
      .select("id, storage_path")
      .lt("created_at", cutoff)
      .limit(200);
    if (spareSessionIds.length > 0) {
      q = q.not("session_id", "in", `(${spareSessionIds.join(",")})`);
    }
    const { data, error } = await q;
    if (error) throw new Error(`${table}: ${error.message}`);
    const rows = (data ?? []) as Row[];
    if (rows.length === 0) break;
    await deleteBatch(admin, table, bucket, rows);
    total += rows.length;
    if (rows.length < 200) break;
  }
  return total;
}

// Squad schnaps whose live session has been ended (event sessions spared).
async function purgeEndedSessionSnaps(
  admin: SupabaseAdmin,
  spareSessionIds: string[],
): Promise<number> {
  let total = 0;
  for (let i = 0; i < 10; i++) {
    let q = admin
      .from("session_snaps")
      .select("id, storage_path, sessions!inner(active_live)")
      .eq("sessions.active_live", false)
      .limit(200);
    if (spareSessionIds.length > 0) {
      q = q.not("session_id", "in", `(${spareSessionIds.join(",")})`);
    }
    const { data, error } = await q;
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
    const spare = await eventSessionIds(admin);
    const ended = await purgeEndedSessionSnaps(admin, spare);
    const aged = await purgeAged(admin, "session_snaps", "session-snaps", 48, spare);
    const stories = await purgeAged(admin, "live_stories", "stories", 24);
    return Response.json({ deleted: ended + aged, stories_deleted: stories });
  } catch (e) {
    return new Response((e as Error).message, { status: 500 });
  }
});
