// venue-import — bulk-import bars, pubs, restaurants and clubs from OSM.
//
// Point it at a bounding box and it pulls every NAMED venue of the requested
// amenity kinds from Overpass and inserts the ones we don't already have.
// Written as a function rather than a one-off SQL script so it is re-runnable
// for any city, and so the only service key involved is the one already in this
// function's own environment.
//
// IDEMPOTENT, with two guards — both kinds of duplicate actually happened here:
//   * exact re-import: skip anything whose OSM id we already stored;
//   * same place from another source: skip when a venue of the same name already
//     exists within DEDUPE_M metres. This is how the app's own MapKit-resolved
//     rows and an OSM row would otherwise both land.
// Deliberately NOT deduped on name alone — two branches of one chain are two
// venues (Port Du Soleil has a real second location 1 km from the first).
//
// Attribution: (c) OpenStreetMap contributors (ODbL).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const DEDUPE_M = 150;
const KINDS_DEFAULT = ["bar", "pub", "nightclub", "biergarten", "restaurant"];
const MAX_INSERT = 4000;
const IMPORTS_PER_HOUR = 6;

const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
];

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json" },
  });
}

function metresBetween(aLat: number, aLon: number, bLat: number, bLon: number) {
  const R = 6371000;
  const p1 = (aLat * Math.PI) / 180, p2 = (bLat * Math.PI) / 180;
  const dp = p2 - p1, dl = ((bLon - aLon) * Math.PI) / 180;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

async function overpass(query: string) {
  for (const host of OVERPASS) {
    try {
      const res = await fetch(host, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "data=" + encodeURIComponent(query),
      });
      if (!res.ok) continue;
      const body = await res.json().catch(() => null);
      if (body?.elements) return body.elements as Record<string, unknown>[];
    } catch { /* next mirror */ }
  }
  throw new Error("overpass_unavailable");
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  // bbox: [south, west, north, east]
  const bbox = body.bbox as number[] | undefined;
  if (!Array.isArray(bbox) || bbox.length !== 4 || bbox.some((n) => typeof n !== "number")) {
    return json({ error: "bbox_required" }, 400);
  }
  const [s, w, n, e] = bbox;
  // A runaway bbox would be a huge Overpass query and a huge insert.
  if (n - s > 1.5 || e - w > 1.5) return json({ error: "bbox_too_large" }, 400);

  const kinds = Array.isArray(body.kinds) && body.kinds.length
    ? (body.kinds as string[]).filter((k) => /^[a-z_]{2,20}$/.test(k))
    : KINDS_DEFAULT;
  const dryRun = body.dry_run === true;

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // An import is expensive for Overpass and for us; cap it regardless of caller.
  const { data: allowed, error: rlErr } = await admin.rpc("rate_limit_hit", {
    p_bucket: "venue_import", p_key: "all",
    p_limit: IMPORTS_PER_HOUR, p_window: "1 hour",
  });
  if (rlErr) return json({ error: "rate_limit_unavailable" }, 503);
  if (allowed === false) return json({ error: "rate_limited" }, 429);

  const filter = `^(${kinds.join("|")})$`;
  const q = `[out:json][timeout:180];`
    + `(node["amenity"~"${filter}"]["name"](${s},${w},${n},${e});`
    + `way["amenity"~"${filter}"]["name"](${s},${w},${n},${e});)`
    + `;out center tags;`;

  let elements: Record<string, unknown>[];
  try {
    elements = await overpass(q);
  } catch (err) {
    return json({ error: String(err) }, 503);
  }

  // Existing venues, for the proximity guard.
  const { data: existing, error: exErr } = await admin
    .from("venues").select("name, lat, lon, external_id");
  if (exErr) return json({ error: "venues_query_failed" }, 500);

  const haveExt = new Set(
    (existing ?? []).map((v: { external_id: string | null }) => v.external_id)
      .filter((x): x is string => !!x),
  );
  const byName = new Map<string, { lat: number; lon: number }[]>();
  for (const v of existing ?? []) {
    const k = String(v.name ?? "").trim().toLowerCase();
    if (!byName.has(k)) byName.set(k, []);
    byName.get(k)!.push({ lat: v.lat, lon: v.lon });
  }

  type Row = {
    name: string; address: string | null; city: string;
    lat: number; lon: number; source: string; external_id: string;
  };
  const rows: Row[] = [];
  let skippedExt = 0, skippedNear = 0, skippedBad = 0;

  for (const el of elements) {
    const tags = (el.tags ?? {}) as Record<string, string>;
    const name = (tags.name ?? "").trim();
    const centre = el.center as { lat: number; lon: number } | undefined;
    const lat = (el.lat as number) ?? centre?.lat;
    const lon = (el.lon as number) ?? centre?.lon;
    if (!name || name.length > 120 || lat == null || lon == null) { skippedBad++; continue; }

    const ext = `osm:${el.type}/${el.id}`;
    if (haveExt.has(ext)) { skippedExt++; continue; }

    const key = name.toLowerCase();
    const near = (byName.get(key) ?? []).some((p) =>
      metresBetween(p.lat, p.lon, lat, lon) <= DEDUPE_M);
    if (near) { skippedNear++; continue; }

    const street = tags["addr:street"];
    const num = tags["addr:housenumber"];
    rows.push({
      name,
      address: street ? `${street}${num ? " " + num : ""}` : null,
      city: tags["addr:city"] ?? (String(body.city ?? "") || "Unknown"),
      lat, lon, source: "osm", external_id: ext,
    });
    // Guard against importing the same new place twice within one run.
    haveExt.add(ext);
    if (!byName.has(key)) byName.set(key, []);
    byName.get(key)!.push({ lat, lon });
  }

  if (rows.length > MAX_INSERT) rows.length = MAX_INSERT;

  if (dryRun) {
    return json({
      ok: true, dry_run: true, found: elements.length,
      would_insert: rows.length,
      skipped: { already_imported: skippedExt, too_close: skippedNear, unusable: skippedBad },
      sample: rows.slice(0, 5).map((r) => r.name),
    }, 200);
  }

  let inserted = 0;
  const errors: string[] = [];
  for (let i = 0; i < rows.length; i += 200) {
    const { error } = await admin.from("venues").insert(rows.slice(i, i + 200));
    if (error) { if (errors.length < 5) errors.push(error.message); }
    else inserted += Math.min(200, rows.length - i);
  }

  return json({
    ok: true, found: elements.length, inserted,
    skipped: { already_imported: skippedExt, too_close: skippedNear, unusable: skippedBad },
    errors,
  }, 200);
});
