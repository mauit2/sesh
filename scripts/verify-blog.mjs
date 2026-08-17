// verify-blog.mjs — fail the build if a generated page disagrees with the
// database it claims to summarise.
//
// Silverkällan taught the lesson: the generators silently read a truncated
// result for weeks and every list was subtly wrong, discovered only because
// one reader knew one bar. This script recomputes the headline bar count for
// every international city page straight from the paged RPC and compares it
// with the number printed on the page. Any mismatch exits non-zero, which
// stops the daily workflow BEFORE the commit — a stale page stays up, a
// wrong one never ships.
//
// Runs after gen-blog.mjs + gen-blog-intl.mjs:
//   SUPA_ANON=... node scripts/verify-blog.mjs

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";

const SB = "https://lltuozmbxacxiepardys.supabase.co/rest/v1";
const KEY = process.env.SUPA_ANON;
if (!KEY) { console.error("SUPA_ANON not set"); process.exit(1); }
const HERE = dirname(new URL(import.meta.url).pathname);
const ROOT = join(HERE, "..", "docs");

// Keep in lockstep with gen-blog-intl.mjs (country -> currency + en slug).
const CUR = { US: "USD", GB: "GBP", CA: "CAD", DE: "EUR", ES: "EUR", IT: "EUR",
              NL: "EUR", BE: "EUR", PT: "EUR", FR: "EUR", BR: "BRL", CH: "CHF",
              TH: "THB", SG: "SGD", HK: "HKD" };
const MIN_BARS = 5;

const slugify = (s) => String(s).normalize("NFD").replace(/[̀-ͯ]/g, "")
  .toLowerCase().replace(/ø/g, "o").replace(/æ/g, "ae").replace(/ß/g, "ss")
  .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const JUNK = new Set(["unitedkingdom", "unitedstates", "england", "scotland",
  "wales", "uk", "usa"]);
const cleanCity = (c) => {
  if (!c) return null;
  const name = String(c).split(",")[0].trim();
  return JUNK.has(slugify(name).replace(/-/g, "")) ? null : name;
};

async function rpc(fn, body) {
  const r = await fetch(`${SB}/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: KEY, Authorization: `Bearer ${KEY}` },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${fn}: HTTP ${r.status}`);
  return r.json();
}
async function paged(fn) {
  const out = [];
  for (let off = 0; ; off += 1000) {
    const page = await rpc(fn, { p_limit: 1000, p_offset: off });
    out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}
async function venues() {
  const out = [];
  for (let off = 0; ; off += 1000) {
    const r = await fetch(`${SB}/venues?select=id,city,country&order=id&offset=${off}&limit=1000`,
      { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
    if (!r.ok) throw new Error(`venues: HTTP ${r.status}`);
    const page = await r.json();
    out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}

const [prices, vs] = await Promise.all([paged("public_beer_prices"), venues()]);
const vInfo = new Map(vs.map((v) => [v.id, v]));

// distinct priced venues per (country, city), currency-matched — the same
// number gen-blog-intl.mjs prints as "N bars with prices".
const byCityVenues = new Map();
for (const p of prices) {
  const v = vInfo.get(p.venue_id) || {};
  const city = cleanCity(v.city);
  if (!city || !v.country || v.country === "SE") continue;
  if (p.currency !== CUR[v.country]) continue;
  const key = `${v.country}|${city}`;
  if (!byCityVenues.has(key)) byCityVenues.set(key, new Set());
  byCityVenues.get(key).add(p.venue_id);
}

// The generated page for a city (English flagship carries the count fig).
const pagePath = (city) =>
  join(ROOT, "blog", `where-is-the-cheapest-beer-in-${slugify(city)}-reddit`, "index.html");
const barsOnPage = (html) => {
  const m = html.match(/title="(\d+)">\1<\/b><span>bars with prices<\/span>/);
  return m ? Number(m[1]) : null;
};

let checked = 0, failed = 0;
for (const [key, ids] of byCityVenues) {
  if (ids.size < MIN_BARS) continue;
  const city = key.split("|")[1];
  const file = pagePath(city);
  if (!existsSync(file)) {
    console.error(`MISSING PAGE: ${key} has ${ids.size} bars but no page at ${file}`);
    failed++;
    continue;
  }
  const got = barsOnPage(readFileSync(file, "utf8"));
  if (got !== ids.size) {
    console.error(`MISMATCH: ${key} page says ${got} bars, database says ${ids.size}`);
    failed++;
  }
  checked++;
}

console.log(`verified ${checked} city pages, ${failed} problem(s)`);
if (failed) process.exit(1);
