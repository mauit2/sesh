// sun-horizon — compute a venue's shading horizon from building heights.
//
// GEOMETRY — exact ray casting, not point sampling. The first version walked
// each footprint edge in ~3 m steps and binned the sampled points, which leaves
// GAPS: a bin only got a value if a sample happened to land in it, so profiles
// came out as isolated 60-70 deg spikes between 11 deg lows. Two visible bugs
// fell out of that — venues read sunnier than they are, and the sun flickered
// on/off every few minutes as its azimuth crossed in and out of the spikes.
// Now we cast a ray every RAY_STEP degrees and intersect it with every wall
// segment: gap-free by construction, and exact.
//
// WHERE WE STAND — the sunniest facade. A venue's pin normally sits INSIDE its
// building, and a point inside a building sees no sky at all, so the pin itself
// is not a usable vantage point. But standing 2.5 m from a long wall blocks
// half the sky, so the answer depends entirely on WHICH facade you pick — and
// picking the nearest one is a coin flip. It made a courtyard venue read as "no
// sun at all" purely because its pin sat closest to the north wall. So we try
// candidate points spread around the host footprint and keep the one most open
// toward the equator: a venue with a terrace puts it where the sun is, so this
// is both the physically meaningful answer and the useful one ("can I sit in
// the sun here?"). The host building is kept in the geometry throughout, so it
// blocks the sky behind you — and for a venue on an inner courtyard the
// enclosing walls stay in the model.
//
// HEIGHT SOURCE — Mapbox vector tiles, OSM as fallback. We read the raw .mvt
// rather than the Tilequery API because Tilequery only returns a representative
// POINT per building; the horizon needs whole outlines or sun leaks through
// walls. `confidence` and `source` record what backed the profile.
//
// RATE LIMITING — metered in VENUES, not requests. See migration 083: a batch
// request may carry 1 venue or 120, and it is the venue count that spends
// Mapbox quota (nine vector tiles apiece), so counting requests both throttled
// legitimate backfills and failed to bound actual spend.
//
// Attribution: (c) Mapbox, (c) OpenStreetMap contributors.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import Pbf from "https://esm.sh/pbf@3.2.1";
import { VectorTile } from "https://esm.sh/@mapbox/vector-tile@1.3.1";

const RADIUS_M = 160;      // beyond this, a normal building blocks < ~6 deg
const BINS = 72;           // 5 deg per bin
const RAY_STEP = 1;        // degrees between cast rays; binned by max
const MIN_D = 2.0;         // metres - floor so atan can't blow up
const FACADE_OUT = 2.5;    // metres out from the wall we assume tables sit
const FACADE_SPAN = 12;    // metres between candidate facade points
const FACADE_MAX = 12;     // cap on candidates, to bound the work
const LEVEL_M = 3.2;       // metres per storey
const FALLBACK_LEVELS = 4;
const TILE_Z = 16;

const PER_USER_HOUR = 60;
const PER_IP_HOUR = 120;
const GLOBAL_DAY = 4000;
const BATCH_MAX = 120;          // venues per batch request
const BACKFILL_PER_HOUR = 40;   // batch requests per hour, all callers
// Venue budgets — the limits that actually bound Mapbox spend — live entirely
// in the database (rate_limit_ceiling, migrations 083/085), so the hourly and
// daily ceilings can be retuned without redeploying this function.

const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
];

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

type Footprint = { rings: [number, number][][]; height: number | null };

function levelsToMetres(v: unknown): number | null {
  if (v == null) return null;
  const n = parseFloat(String(v).replace(/[^\d.]/g, ""));
  if (!isFinite(n) || n < 1 || n >= 200) return null;
  return n * LEVEL_M;
}

function metres(v: unknown): number | null {
  if (v == null) return null;
  const n = parseFloat(String(v).replace(/[^\d.]/g, ""));
  if (!isFinite(n) || n <= 1 || n > 900) return null;
  return n;
}

function lonLatToTile(lon: number, lat: number, z: number) {
  const n = Math.pow(2, z);
  const latRad = (lat * Math.PI) / 180;
  return {
    x: Math.floor(((lon + 180) / 360) * n),
    y: Math.floor(
      ((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * n,
    ),
  };
}

function tileToLonLat(
  px: number, py: number, extent: number, tx: number, ty: number, z: number,
) {
  const n = Math.pow(2, z);
  const lon = ((tx + px / extent) / n) * 360 - 180;
  const yMerc = (ty + py / extent) / n;
  const lat = (Math.atan(Math.sinh(Math.PI * (1 - 2 * yMerc))) * 180) / Math.PI;
  return [lon, lat] as [number, number];
}

async function fromMapbox(lat: number, lon: number, token: string): Promise<Footprint[]> {
  const centre = lonLatToTile(lon, lat, TILE_Z);
  const jobs: Promise<Footprint[]>[] = [];
  for (let dx = -1; dx <= 1; dx++) {
    for (let dy = -1; dy <= 1; dy++) {
      jobs.push(oneTile(centre.x + dx, centre.y + dy, token));
    }
  }
  return (await Promise.all(jobs)).flat();
}

async function oneTile(tx: number, ty: number, token: string): Promise<Footprint[]> {
  const url = `https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/${TILE_Z}/${tx}/${ty}.mvt`
    + `?access_token=${encodeURIComponent(token)}`;
  const res = await fetch(url);
  if (res.status === 404) return [];
  if (!res.ok) throw new Error("tiles_" + res.status);
  const buf = new Uint8Array(await res.arrayBuffer());
  if (buf.length === 0) return [];

  const tile = new VectorTile(new Pbf(buf));
  const layer = tile.layers["building"];
  if (!layer) return [];

  const out: Footprint[] = [];
  for (let i = 0; i < layer.length; i++) {
    const f = layer.feature(i);
    const p = f.properties ?? {};
    const h = metres(p.height) ?? levelsToMetres(p["levels"]);
    // Keep a feature's rings TOGETHER: outer ring plus any holes, so the
    // even-odd test can tell "inside the building" from "in its courtyard".
    const rings = f.loadGeometry()
      .filter((r: { x: number; y: number }[]) => r.length >= 3)
      .map((r: { x: number; y: number }[]) =>
        r.map((pt) => tileToLonLat(pt.x, pt.y, layer.extent, tx, ty, TILE_Z)));
    if (rings.length) out.push({ rings, height: h });
  }
  return out;
}

async function fromOSM(lat: number, lon: number): Promise<Footprint[]> {
  const q = `[out:json][timeout:25];way["building"](around:${RADIUS_M},${lat},${lon});out geom;`;
  for (const host of OVERPASS) {
    try {
      const res = await fetch(host, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "data=" + encodeURIComponent(q),
      });
      if (!res.ok) continue;
      const body = await res.json().catch(() => null);
      if (!body?.elements) continue;
      const out: Footprint[] = [];
      for (const w of body.elements) {
        if (!w.geometry || w.geometry.length < 3) continue;
        const tags = w.tags ?? {};
        out.push({
          rings: [w.geometry.map((p: { lat: number; lon: number }) =>
            [p.lon, p.lat] as [number, number])],
          height: metres(tags.height) ?? levelsToMetres(tags["building:levels"]),
        });
      }
      return out;
    } catch { /* next mirror */ }
  }
  throw new Error("overpass_unavailable");
}

/** Even-odd containment of the ORIGIN across every ring of one feature. */
function containsOrigin(ringsXY: [number, number][][]): boolean {
  let inside = false;
  for (const ring of ringsXY) {
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const [xi, yi] = ring[i];
      const [xj, yj] = ring[j];
      if ((yi > 0) !== (yj > 0)) {
        const x = xi + ((0 - yi) / (yj - yi)) * (xj - xi);
        if (x > 0) inside = !inside;
      }
    }
  }
  return inside;
}

type Wall = { ax: number; ay: number; bx: number; by: number; h: number };

/** Points ~FACADE_OUT metres outside the host footprint, spread around it. */
function facadeCandidates(
  hosts: { ringsXY: [number, number][][] }[],
): [number, number][] {
  const out: [number, number][] = [];
  const insideAny = (x: number, y: number) =>
    hosts.some((h) => containsOrigin(h.ringsXY.map((r) =>
      r.map(([px, py]) => [px - x, py - y] as [number, number]))));

  for (const h of hosts) {
    for (const ring of h.ringsXY) {
      let carried = 0;
      for (let i = 0; i < ring.length; i++) {
        const [ax, ay] = ring[i];
        const j = (i + 1) % ring.length;
        const [bx, by] = ring[j];
        const ex = bx - ax, ey = by - ay;
        const len = Math.hypot(ex, ey);
        if (len < 0.01) continue;
        for (let d = FACADE_SPAN - carried; d < len; d += FACADE_SPAN) {
          const t = d / len;
          const px = ax + ex * t, py = ay + ey * t;
          // Both edge normals; keep whichever lands outside the building.
          const nx = ey / len, ny = -ex / len;
          for (const s of [1, -1]) {
            const cx = px + nx * s * FACADE_OUT;
            const cy = py + ny * s * FACADE_OUT;
            if (!insideAny(cx, cy)) { out.push([cx, cy]); break; }
          }
          if (out.length >= FACADE_MAX) return out;
        }
        carried = (carried + len) % FACADE_SPAN;
      }
    }
  }
  return out.length ? out : [[0, 0]];
}

/** 72-bin blocked-elevation profile seen from (ox, oy). Degrees. */
function horizonAt(walls: Wall[], ox: number, oy: number): number[] {
  const horizon = new Array(BINS).fill(0);
  const rays = Math.round(360 / RAY_STEP);
  for (let r = 0; r < rays; r++) {
    const azDeg = r * RAY_STEP;
    const azRad = (azDeg * Math.PI) / 180;
    // Compass bearing: x is east, y is north.
    const dx = Math.sin(azRad);
    const dy = Math.cos(azRad);

    let best = 0;
    for (const w of walls) {
      const ax = w.ax - ox, ay = w.ay - oy;
      const ex = w.bx - w.ax, ey = w.by - w.ay;
      const denom = dx * ey - dy * ex;
      if (Math.abs(denom) < 1e-12) continue;      // parallel
      const s = (ax * ey - ay * ex) / denom;      // distance along the ray
      if (s <= 0 || s > RADIUS_M) continue;       // behind us, or too far
      const u = (ax * dy - ay * dx) / denom;      // position along the wall
      if (u < 0 || u > 1) continue;               // misses the segment
      const elev = (Math.atan2(w.h, Math.max(s, MIN_D)) * 180) / Math.PI;
      if (elev > best) best = elev;
    }
    const bin = Math.floor(azDeg / 5) % BINS;
    if (best > horizon[bin]) horizon[bin] = best;
  }
  return horizon;
}

/** Mean blocking across the half of the sky the sun actually crosses. */
function equatorFacingBlock(hz: number[], lat: number): number {
  let sum = 0, n = 0;
  for (let b = 0; b < BINS; b++) {
    const az = b * 5 + 2.5;
    const facing = lat >= 0 ? (az >= 90 && az <= 270) : (az <= 90 || az >= 270);
    if (facing) { sum += hz[b]; n++; }
  }
  return n ? sum / n : 0;
}

function computeHorizon(lat: number, lon: number, prints: Footprint[]) {
  const known = prints
    .map((p) => p.height)
    .filter((h): h is number => h !== null)
    .sort((a, b) => a - b);
  const median = known.length
    ? known[Math.floor(known.length / 2)]
    : FALLBACK_LEVELS * LEVEL_M;

  const mLat = 111320;
  const mLon = 111320 * Math.cos((lat * Math.PI) / 180);

  const projected = prints.map((p) => ({
    height: p.height,
    ringsXY: p.rings.map((ring) =>
      ring.map(([plon, plat]) =>
        [(plon - lon) * mLon, (plat - lat) * mLat] as [number, number])),
  }));

  const walls: Wall[] = [];
  let used = 0;
  for (const p of projected) {
    const h = p.height ?? median;
    let contributed = false;
    for (const ring of p.ringsXY) {
      for (let i = 0; i < ring.length; i++) {
        const [ax, ay] = ring[i];
        const j = (i + 1) % ring.length;
        const [bx, by] = ring[j];
        const lim = RADIUS_M + FACADE_SPAN * 2;
        if (Math.hypot(ax, ay) > lim && Math.hypot(bx, by) > lim) continue;
        walls.push({ ax, ay, bx, by, h });
        contributed = true;
      }
    }
    if (contributed) used++;
  }

  const hosts = projected.filter((p) => containsOrigin(p.ringsXY));
  const candidates: [number, number][] = hosts.length
    ? facadeCandidates(hosts)
    : [[0, 0]];

  let bestHz: number[] | null = null;
  let bestScore = Infinity;
  let bestAt: [number, number] = [0, 0];
  for (const [ox, oy] of candidates) {
    const hz = horizonAt(walls, ox, oy);
    const score = equatorFacingBlock(hz, lat);
    if (score < bestScore) { bestScore = score; bestHz = hz; bestAt = [ox, oy]; }
  }
  const horizon = bestHz ?? new Array(BINS).fill(0);

  const confidence = used === 0 ? 0 : Math.min(1, known.length / used);
  const packed = horizon.map((d) => Math.round(Math.min(89.9, Math.max(0, d)) * 10));
  return {
    horizon: packed, confidence, buildings: used,
    withHeight: known.length, hostSkipped: hosts.length, walls: walls.length,
    movedM: Math.round(Math.hypot(bestAt[0], bestAt[1]) * 10) / 10,
    facades: candidates.length,
  };
}

/** Read the JWT payload Supabase already verified for us. */
function jwtClaims(auth: string | null): { sub?: string; role?: string } {
  if (!auth?.startsWith("Bearer ")) return {};
  const parts = auth.slice(7).split(".");
  if (parts.length !== 3) return {};
  try {
    const pad = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(pad + "=".repeat((4 - pad.length % 4) % 4)));
  } catch { return {}; }
}

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("cf-connecting-ip") ?? "unknown";
}

/** Compute and store one venue's profile. Shared by single and batch modes. */
async function processVenue(
  admin: ReturnType<typeof createClient>,
  venue: { id: string; lat: number; lon: number },
  token: string | undefined,
) {
  let prints: Footprint[] = [];
  let source = "osm";
  let note: string | undefined;
  if (token) {
    try {
      prints = await fromMapbox(venue.lat, venue.lon, token);
      source = "mapbox";
    } catch (e) {
      note = String(e);
    }
  }
  if (prints.length === 0) {
    prints = await fromOSM(venue.lat, venue.lon);
    source = "osm";
  }

  const r = computeHorizon(venue.lat, venue.lon, prints);
  const { error } = await admin.from("venue_sun").upsert({
    venue_id: venue.id,
    horizon: r.horizon,
    confidence: r.confidence,
    source,
    computed_at: new Date().toISOString(),
  }, { onConflict: "venue_id" });
  if (error) throw new Error("save_failed: " + error.message);
  return { ...r, source, note };
}

/** Process venues a few at a time so one slow tile fetch can't stall the lot. */
async function runBatch(
  admin: ReturnType<typeof createClient>,
  venues: { id: string; lat: number; lon: number }[],
  token: string | undefined,
) {
  let ok = 0, failed = 0;
  const errors: string[] = [];
  const CONCURRENCY = 4;
  for (let i = 0; i < venues.length; i += CONCURRENCY) {
    const slice = venues.slice(i, i + CONCURRENCY);
    const out = await Promise.allSettled(
      slice.map((v) => processVenue(admin, v, token)),
    );
    for (const r of out) {
      if (r.status === "fulfilled") ok++;
      else { failed++; if (errors.length < 5) errors.push(String(r.reason)); }
    }
  }
  return { processed: venues.length, ok, failed, errors };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const venueId = String(body.venue_id ?? "");
  const batch = Math.min(Number(body.batch ?? 0) || 0, BATCH_MAX);
  const recompute = body.recompute === true;
  if (!venueId && !batch) return json({ error: "venue_id_required" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const claims = jwtClaims(req.headers.get("Authorization"));
  const ip = clientIp(req);
  const token = Deno.env.get("MAPBOX_TOKEN");

  async function charge(): Promise<string | null> {
    if (claims.role === "service_role") return null;
    const checks: [string, string, number, string][] = [
      ["sun_horizon_user", claims.sub ?? "anon", PER_USER_HOUR, "1 hour"],
      ["sun_horizon_ip", ip, PER_IP_HOUR, "1 hour"],
      ["sun_horizon_global", "all", GLOBAL_DAY, "1 day"],
    ];
    for (const [bucket, key, limit, window] of checks) {
      const { data: ok, error } = await admin.rpc("rate_limit_hit", {
        p_bucket: bucket, p_key: key, p_limit: limit, p_window: window,
      });
      // Fail CLOSED: if the limiter itself is broken we would rather refuse
      // than leave the Mapbox spend unguarded.
      if (error) return "rate_limit_unavailable";
      if (ok === false) return bucket;
    }
    return null;
  }

  /** Take up to n venue-units against the hour AND day budgets, in one atomic
   *  step (migration 085). null means the limiter failed -> refuse. */
  async function takeBudget(n: number): Promise<number | null> {
    const { data, error } = await admin.rpc("sun_venue_budget_take", { p_n: n });
    if (error) return null;   // fail closed
    return Number(data ?? 0);
  }

  if (batch) {
    const gate = await charge();
    if (gate) return json({ error: "rate_limited", bucket: gate }, 429);
    if (claims.role !== "service_role") {
      const { data: ok } = await admin.rpc("rate_limit_hit", {
        p_bucket: "sun_backfill", p_key: "all", p_limit: BACKFILL_PER_HOUR,
        p_window: "1 hour",
      });
      if (ok === false) return json({ error: "rate_limited", bucket: "sun_backfill" }, 429);
    }

    // WHICH VENUES STILL NEED WORK — decided in SQL. The previous version read
    // the whole venues table and the whole venue_sun table through PostgREST
    // and diffed them here, and BOTH reads were silently capped at 1000 rows.
    // With 2149 venues and 1067 done, that meant venues past the first 1000
    // were unreachable and finished ones kept being reconsidered. A set
    // difference in the database has no such cap, and can also put priced bars
    // first — those are the ones the app promises a sun/shade icon for.
    let todo: { id: string; lat: number; lon: number }[] = [];
    if (recompute) {
      const { data, error } = await admin
        .from("venues").select("id, lat, lon")
        .not("lat", "is", null)
        .order("id")
        .limit(batch);
      if (error) return json({ error: "venues_query_failed" }, 500);
      todo = (data ?? []) as typeof todo;
    } else {
      const { data, error } = await admin.rpc("venues_needing_sun", { p_limit: batch });
      if (error) return json({ error: "venues_query_failed", detail: error.message }, 500);
      todo = (data ?? []) as typeof todo;
    }

    // CHARGE PER VENUE. This is the limit that means anything: one venue is
    // nine Mapbox tile fetches, so a request-count limit could not bound spend.
    // A partial grant TRIMS the batch rather than refusing it, so a caller with
    // 30 venues of budget left does 30 rather than nothing.
    let allowed = todo.length;
    if (claims.role !== "service_role" && allowed > 0) {
      // ONE atomic reservation against both windows. Taking from them in two
      // steps leaked budget: once the hourly allowance ran out, every retry
      // still charged the daily bucket its full request before the hourly check
      // refused it, so a client backing off and retrying burned the day's
      // allowance without computing anything. A refused call now costs nothing.
      const grant = await takeBudget(allowed);
      if (grant === null) return json({ error: "rate_limit_unavailable" }, 503);
      allowed = grant;
      if (allowed === 0) {
        return json({ error: "rate_limited", bucket: "sun_horizon_venues" }, 429);
      }
    }
    todo = todo.slice(0, allowed);

    const res = await runBatch(admin, todo, token);
    return json({
      ok: true, mode: recompute ? "recompute" : "fill",
      granted: allowed, ...res,
    }, 200);
  }

  const gate = await charge();
  if (gate === "rate_limit_unavailable") return json({ error: gate }, 503);
  if (gate) {
    return new Response(
      JSON.stringify({ error: "rate_limited", bucket: gate }),
      { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "3600" } },
    );
  }

  const { data: venue, error: vErr } = await admin
    .from("venues")
    .select("id, lat, lon")
    .eq("id", venueId)
    .maybeSingle();
  if (vErr || !venue) return json({ error: "venue_not_found" }, 404);

  try {
    const r = await processVenue(admin, venue, token);
    return json({
      ok: true, source: r.source, buildings: r.buildings,
      with_height: r.withHeight, confidence: r.confidence,
      hosts: r.hostSkipped, moved_m: r.movedM, facades: r.facades,
      walls: r.walls, note: r.note,
    }, 200);
  } catch (e) {
    return json({ error: String(e) }, 503);
  }
});
