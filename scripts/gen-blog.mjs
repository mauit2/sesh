// gen-blog.mjs — generate the beer-price articles from live data.
//
// WHY GENERATED AND NOT WRITTEN. Twenty-six pages (13 cities x 2 languages)
// hand-written would be stale within a week and inconsistent from the start.
// These read the same public RPC the website map reads, so the numbers on an
// article always agree with the map a reader clicks through to — and a rerun
// refreshes every page. Freshness is also the one ranking signal we can honestly
// earn here: nobody else publishes Swedish beer prices per centilitre at all.
//
// Run:  SUPA_ANON=... node scripts/gen-blog.mjs
//
// Writes docs/blogg/** (Swedish), docs/blog/** (English) and rewrites
// docs/sitemap.xml. Pure static HTML, no client JS, strict CSP.

import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

const SB = "https://lltuozmbxacxiepardys.supabase.co/rest/v1";
const KEY = process.env.SUPA_ANON;
if (!KEY) { console.error("SUPA_ANON not set"); process.exit(1); }
const ROOT = join(dirname(new URL(import.meta.url).pathname), "..", "docs");
const SITE = "https://sejdel.com";

// Minimum priced bars before a city gets its own page. Below this the table is
// too short to be worth a reader's click, and thin pages drag a whole site down.
const MIN_BARS = 10;

// Representative centilitres. 'pint' is the imperial 568 ml (see migration 082).
const CL = { "25": 25, "33": 33, "40": 40, "50": 50, pint: 56.8 };
const SERVING_LABEL = { "25": "25 cl", "33": "33 cl", "40": "40 cl", "50": "50 cl", pint: "pint" };

// English exonyms where they differ. Malmö and Lund keep their spelling in both.
const EN_NAME = { "Göteborg": "Gothenburg" };
const slugify = (s) => s.toLowerCase()
  .replace(/å|ä|â/g, "a").replace(/ö|ø|ô/g, "o").replace(/é|è/g, "e")
  .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

const esc = (s) => String(s ?? "").replace(/[&<>"']/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const kr = (n) => `${Math.round(n)} kr`;
const perCl = (n) => `${n.toFixed(2)} kr/cl`;

async function rpc(fn, body = {}) {
  const r = await fetch(`${SB}/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: KEY, Authorization: `Bearer ${KEY}` },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${fn}: HTTP ${r.status}`);
  return r.json();
}

// PostgREST caps any response at 1000 rows; page until a short page.
async function rpcPaged(fn) {
  const out = [];
  for (let off = 0; ; off += 1000) {
    const page = await rpc(fn, { p_limit: 1000, p_offset: off });
    out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}

async function allVenues() {
  const out = [];
  for (let off = 0; ; off += 1000) {
    const r = await fetch(`${SB}/venues?select=id,name,city&order=id&offset=${off}&limit=1000`,
      { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
    if (!r.ok) throw new Error(`venues: HTTP ${r.status}`);
    const page = await r.json();
    out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}

// ---------------------------------------------------------------- data

const [prices, venues, happyRaw] = await Promise.all([
  rpcPaged("public_beer_prices"), allVenues(), rpc("public_happy_hour_prices"),
]);
const cityOf = new Map(venues.map((v) => [v.id, v.city]));

const rows = prices
  .map((p) => ({
    venue: p.venue_name,
    id: p.venue_id,
    city: cityOf.get(p.venue_id) || null,
    lat: p.lat, lon: p.lon,
    serving: p.serving,
    price: Number(p.price),
    cl: CL[p.serving] ?? null,
    reports: p.report_count,
    currency: p.currency,
    outdoor: p.outdoor === true,
  }))
  // Only SEK, only servings we can express per-centilitre. Mixing currencies
  // into one "cheapest" table would be meaningless.
  .filter((r) => r.city && r.currency === "SEK" && r.cl && Number.isFinite(r.price));

const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

const byCity = new Map();
for (const r of rows) {
  if (!byCity.has(r.city)) byCity.set(r.city, []);
  byCity.get(r.city).push(r);
}

function summarise(list) {
  const bars = new Set(list.map((r) => r.venue)).size;
  // Mean position of the priced bars — where a "see this on the map" link
  // should land. Good enough for a city frame; no need for a real centroid.
  const lat = list.reduce((a, r) => a + (r.lat || 0), 0) / (list.length || 1);
  const lon = list.reduce((a, r) => a + (r.lon || 0), 0) / (list.length || 1);
  const at40 = list.filter((r) => r.serving === "40");
  const rates = list.map((r) => r.price / r.cl);
  return {
    bars, lat, lon,
    prices: list.length,
    cheapest40: at40.length ? Math.min(...at40.map((r) => r.price)) : null,
    median40: median(at40.map((r) => r.price)),
    bestRate: Math.min(...rates),
    medianRate: median(rates),
    worstRate: Math.max(...rates),
    // Cheapest 40 cl — the "stor stark" table, which is the number people quote.
    top40: [...at40].sort((a, b) => a.price - b.price).slice(0, 12),
    all40: [...at40].sort((a, b) => a.price - b.price),
    // Best value per centilitre, any size — the angle nobody else publishes.
    topValue: [...list].sort((a, b) => a.price / a.cl - b.price / b.cl).slice(0, 8),
  };
}

const cities = [...byCity.entries()]
  .map(([city, list]) => ({ city, ...summarise(list) }))
  .filter((c) => c.bars >= MIN_BARS)
  .sort((a, b) => b.bars - a.bars);

// Volume gates for the variant pages, in one place so the generators, the hub
// and the per-city link rows can never disagree about which pages exist.
const MIN_UNDER = 5;   // "öl under N kr" needs this many qualifying bars
const MIN_HH = 5;      // a city happy hour page
const MIN_OUT = 8;     // an outdoor seating page

const happy = (happyRaw || [])
  .map((r) => ({
    id: r.venue_id, venue: r.venue_name, city: r.city,
    lat: r.lat, lon: r.lon, serving: r.serving,
    price: Number(r.price), cl: CL[r.serving], beer: r.beer,
  }))
  // "unknown" serving has no centilitre count, so it cannot be ranked per cl
  // and cannot be compared to anything. One row, dropped rather than guessed.
  .filter((r) => Number.isFinite(r.price) && r.cl)
  .sort((a, b) => a.price / a.cl - b.price / b.cl);

const happyByCity = new Map();
for (const r of happy) {
  if (!happyByCity.has(r.city)) happyByCity.set(r.city, []);
  happyByCity.get(r.city).push(r);
}

// Which variant pages exist per city — THE single source of truth. A page is
// only linked if the same predicate that generates it says it exists.
const variantOf = new Map(cities.map((c) => [c.city, {
  u50: c.all40.filter((r) => r.price <= 50).length >= MIN_UNDER,
  u60: c.all40.filter((r) => r.price <= 60).length >= MIN_UNDER,
  out: c.all40.filter((r) => r.outdoor).length >= MIN_OUT,
  hh:  (happyByCity.get(c.city) || []).length >= MIN_HH,
}]));

/// Chip links to every page a city has. `current` marks the page being viewed
/// (so it renders highlighted, not as a link to itself).
function variantLinks(lang, city, current) {
  const sv = lang === "sv";
  const en = EN_NAME[city] || city;
  const v = variantOf.get(city);
  if (!v) return "";
  const items = [
    ["prices", sv ? "Alla ölpriser" : "All beer prices",
     sv ? `${SITE}/blogg/billig-ol-${slugify(city)}/` : `${SITE}/blog/cheapest-beer-${slugify(en)}/`, true],
    ["u50", sv ? "Under 50 kr" : "Under 50 kr",
     sv ? `${SITE}/blogg/ol-under-50-kr-${slugify(city)}/` : `${SITE}/blog/beer-under-50-kr-${slugify(en)}/`, v.u50],
    ["u60", sv ? "Under 60 kr" : "Under 60 kr",
     sv ? `${SITE}/blogg/ol-under-60-kr-${slugify(city)}/` : `${SITE}/blog/beer-under-60-kr-${slugify(en)}/`, v.u60],
    ["out", sv ? "Uteserveringar" : "Outdoor seating",
     sv ? `${SITE}/blogg/uteservering-billig-ol-${slugify(city)}/` : `${SITE}/blog/outdoor-seating-cheap-beer-${slugify(en)}/`, v.out],
    ["hh", "Happy hour",
     sv ? `${SITE}/blogg/happy-hour-${slugify(city)}/` : `${SITE}/blog/happy-hour-${slugify(en)}/`, v.hh],
  ].filter(([, , , exists]) => exists);
  if (items.length < 2) return "";
  return `<ul class="chips">${items.map(([key, label, href]) =>
    key === current
      ? `<li><span class="chip-on">${esc(label)}</span></li>`
      : `<li><a href="${href}">${esc(label)}</a></li>`).join("")}</ul>`;
}

const national = summarise(rows);
const updated = new Date().toISOString().slice(0, 10);
const updatedSv = new Date().toLocaleDateString("sv-SE", { year: "numeric", month: "long", day: "numeric" });
const updatedEn = new Date().toLocaleDateString("en-GB", { year: "numeric", month: "long", day: "numeric" });

// ---------------------------------------------------------------- shell

function page({ lang, title, desc, canonical, altHref, altLang, h1, kicker, body, jsonld, switcher }) {
  return `<!DOCTYPE html>
<html lang="${lang}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; base-uri 'none'; form-action 'none'" />
<meta name="referrer" content="no-referrer" />
<meta name="color-scheme" content="dark" />
<meta name="theme-color" content="#140f0b" />
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}" />
<link rel="canonical" href="${canonical}" />
<link rel="alternate" hreflang="${lang}" href="${canonical}" />
<link rel="alternate" hreflang="${altLang}" href="${altHref}" />
<link rel="alternate" hreflang="x-default" href="${altLang === "en" ? altHref : canonical}" />
<meta property="og:type" content="article" />
<meta property="og:title" content="${esc(title)}" />
<meta property="og:description" content="${esc(desc)}" />
<meta property="og:url" content="${canonical}" />
<meta property="og:site_name" content="Sejdel" />
<meta name="twitter:card" content="summary" />
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%23140f0b'/%3E%3Cpath d='M19 14h3.5a3.5 3.5 0 0 1 3.5 3.5v2a3.5 3.5 0 0 1-3.5 3.5H19' fill='none' stroke='%23e8843c' stroke-width='2.4'/%3E%3Cpath d='M6 11h13v12a3 3 0 0 1-3 3H9a3 3 0 0 1-3-3z' fill='%23e8843c'/%3E%3Crect x='8.6' y='14' width='1.6' height='9' rx='0.8' fill='%23c96a2c'/%3E%3Crect x='11.7' y='14' width='1.6' height='9' rx='0.8' fill='%23c96a2c'/%3E%3Crect x='14.8' y='14' width='1.6' height='9' rx='0.8' fill='%23c96a2c'/%3E%3Crect x='6' y='8.5' width='13' height='4' rx='2' fill='%23f3e9d8'/%3E%3C/svg%3E" />
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400..900;1,9..144,400..600&family=Hanken+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet" />
<style>
  :root{
    --bg:#140f0b; --bg-elev:#1d1610; --cream:#f3e9d8; --cream-dim:#cdbfa8;
    --whiskey:#e8843c; --bronze:#b3895a; --line:rgba(243,233,216,.10);
    --mono:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;
  }
  *{box-sizing:border-box;}
  body{
    margin:0;
    background:
      radial-gradient(120% 90% at 85% -10%, rgba(232,132,60,.16), transparent 55%),
      radial-gradient(90% 70% at -10% 0%, rgba(179,137,90,.09), transparent 50%),
      var(--bg);
    color:var(--cream);
    font-family:"Hanken Grotesk",system-ui,sans-serif;
    -webkit-font-smoothing:antialiased;
    line-height:1.65;
  }
  a{color:var(--whiskey);}
  .wrap{max-width:760px;margin:0 auto;padding:clamp(20px,5vw,44px) clamp(18px,4.5vw,28px) 80px;}
  .top{display:flex;align-items:center;gap:12px;margin-bottom:clamp(26px,6vw,46px);}
  .brand{font-family:"Fraunces",Georgia,serif;font-weight:800;font-size:23px;letter-spacing:-.01em;color:var(--cream);text-decoration:none;}
  .brand span{color:var(--whiskey);}
  .top nav{margin-left:auto;display:flex;gap:14px;font-size:13.5px;font-weight:600;}
  .kicker{font-family:var(--mono);font-size:10.5px;letter-spacing:.22em;text-transform:uppercase;color:var(--bronze);margin:0 0 10px;}
  h1{font-family:"Fraunces",Georgia,serif;font-weight:900;font-size:clamp(30px,6.4vw,46px);line-height:1.04;letter-spacing:-.025em;margin:0 0 14px;}
  h2{font-family:"Fraunces",Georgia,serif;font-weight:800;font-size:clamp(21px,3.6vw,27px);letter-spacing:-.015em;margin:44px 0 12px;}
  h3{font-size:16px;font-weight:700;margin:28px 0 8px;}
  .lede{font-size:clamp(16.5px,2.4vw,18.5px);color:var(--cream-dim);margin:0 0 8px;}
  .stamp{font-family:var(--mono);font-size:11px;color:var(--bronze);margin:0 0 30px;}
  p{margin:0 0 15px;}
  .figs{display:grid;grid-template-columns:repeat(auto-fit,minmax(132px,1fr));gap:10px;margin:26px 0 8px;}
  .fig{background:var(--bg-elev);border:1px solid var(--line);border-radius:15px;padding:14px 15px;}
  /* The value must never wrap or overflow, and the page ships NO JavaScript
     (the CSP has no script-src at all), so it cannot be fit at runtime. The
     generator picks a step from the string length instead — "Gothenburg" needs
     a smaller size than "12" and both have to sit in the same card. */
  .fig b{display:block;font-family:"Fraunces",Georgia,serif;font-weight:900;
    letter-spacing:-.02em;line-height:1.15;white-space:nowrap;
    overflow:hidden;text-overflow:ellipsis;}
  .fig b.s1{font-size:clamp(22px,5.2vw,28px);}   /* up to 4 chars: "12", "30 kr" */
  .fig b.s2{font-size:clamp(19px,4.4vw,24px);}   /* to 8:  "1.75 kr/cl" */
  .fig b.s3{font-size:clamp(16px,3.6vw,20px);}   /* to 11: "Gothenburg" */
  .fig b.s4{font-size:clamp(14px,3vw,17px);}     /* longer: "Skellefteå" + */
  .fig span{font-family:var(--mono);font-size:9.5px;letter-spacing:.13em;text-transform:uppercase;color:var(--bronze);}
  .tw{overflow-x:auto;-webkit-overflow-scrolling:touch;margin:16px 0 6px;border:1px solid var(--line);border-radius:15px;background:var(--bg-elev);}
  table{width:100%;border-collapse:collapse;font-size:14.5px;min-width:420px;}
  th,td{text-align:left;padding:11px 14px;border-bottom:1px solid var(--line);}
  th{font-family:var(--mono);font-size:9.5px;letter-spacing:.13em;text-transform:uppercase;color:var(--bronze);font-weight:400;white-space:nowrap;}
  tr:last-child td{border-bottom:0;}
  td.n{font-family:var(--mono);white-space:nowrap;}
  td.p{font-weight:700;color:var(--whiskey);font-family:var(--mono);white-space:nowrap;}
  .rank{color:var(--bronze);font-family:var(--mono);width:1%;}
  .note{font-size:13px;color:var(--bronze);margin:10px 0 0;}
  .caveat{margin:24px 0;padding:15px 18px;border-left:2px solid var(--whiskey);
    background:var(--bg-elev);border-radius:0 13px 13px 0;font-size:14.5px;color:var(--cream-dim);}
  .caveat b{color:var(--cream);}
  /* Price bands. A table of twelve numbers is hard to scan; a colour per band
     makes "is this cheap" answerable at a glance, which is the actual question.
     Thresholds are relative to the national median, so they stay meaningful as
     prices drift rather than being frozen constants. */
  td.p.b1{color:#7ec96b;} td.p.b2{color:#e8c34a;} td.p.b3{color:#e8843c;} td.p.b4{color:#e07a6a;}
  .legend{display:flex;flex-wrap:wrap;gap:12px;margin:14px 0 0;font-family:var(--mono);font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--bronze);}
  .legend i{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:5px;vertical-align:middle;}
  .switch{display:flex;flex-wrap:wrap;gap:7px;margin:0 0 26px;padding:0;list-style:none;}
  .switch a{display:inline-block;font-size:12.5px;font-weight:600;text-decoration:none;color:var(--cream-dim);
    background:var(--bg-elev);border:1px solid var(--line);border-radius:999px;padding:5px 11px;}
  .switch a.on{background:var(--whiskey);border-color:var(--whiskey);color:#241503;}
  .crumbs{font-family:var(--mono);font-size:10.5px;letter-spacing:.09em;text-transform:uppercase;color:var(--bronze);margin:0 0 14px;}
  .crumbs a{color:var(--bronze);text-decoration:none;}
  .crumbs span{color:var(--cream-dim);}
  .cta{display:block;margin:34px 0;padding:19px 22px;background:var(--bg-elev);border:1px solid rgba(232,132,60,.34);border-radius:17px;text-decoration:none;color:var(--cream);}
  .cta b{display:block;font-family:"Fraunces",Georgia,serif;font-size:19px;font-weight:800;margin-bottom:3px;}
  .cta span{font-size:14px;color:var(--cream-dim);}
  .chips{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0 0;padding:0;list-style:none;}
  .chips .chip-on{display:inline-block;font-size:13.5px;font-weight:600;color:#241503;
    background:var(--whiskey);border:1px solid var(--whiskey);border-radius:999px;padding:7px 13px;}
  /* The hub's city directory: one card per city, its variant pages as chips.
     This IS the navigation the hub exists for, so it gets real presence. */
  .citygrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:10px;margin:18px 0 0;}
  .citycard{background:var(--bg-elev);border:1px solid var(--line);border-radius:15px;padding:15px 16px;}
  .citycard h3{margin:0 0 2px;font-family:"Fraunces",Georgia,serif;font-size:19px;font-weight:800;letter-spacing:-.015em;}
  .citycard .cityname{color:var(--cream);text-decoration:none;}
  .citycard .cityname:hover{color:var(--whiskey);}
  .citycard .meta{font-family:var(--mono);font-size:9.5px;letter-spacing:.13em;text-transform:uppercase;color:var(--bronze);margin:0 0 4px;}
  .citycard .chips{margin-top:8px;gap:5px;}
  .citycard .chips a,.citycard .chips .chip-on{font-size:11.5px;padding:4px 10px;}
  .chips a{display:inline-block;font-size:13.5px;font-weight:600;text-decoration:none;color:var(--cream);
    background:var(--bg-elev);border:1px solid var(--line);border-radius:999px;padding:7px 13px;}
  footer{margin-top:56px;padding-top:22px;border-top:1px solid var(--line);font-size:12.5px;color:var(--bronze);}
  footer a{color:var(--bronze);}

  /* Fluid-interface pass (apple-design), within this page's constraint of
     ZERO JavaScript: press feedback on pointer-down, a visible keyboard
     focus everywhere, Fraunces' optical-size axis actually enabled, and
     fallbacks for reduced motion and raised contrast. */
  h1,h2,.brand,.fig b,.cta b{font-optical-sizing:auto;}
  .chips a,.switch a,.cta,.top nav a{transition:transform .1s ease-out;display:inline-block;}
  .cta{display:block;}
  .chips a:hover,.switch a:hover:not(.on){border-color:rgba(243,233,216,.3);}
  .cta:hover{border-color:rgba(232,132,60,.6);}
  .top nav a:hover{color:var(--whiskey);}
  .chips a:active,.switch a:active{transform:scale(.96);}
  .cta:active{transform:scale(.99);}
  .tw a:hover{text-decoration:underline;}
  a:focus-visible,button:focus-visible{outline:2px solid var(--whiskey);outline-offset:2px;border-radius:4px;}
  @media (prefers-reduced-motion: reduce){
    .chips a,.switch a,.cta,.top nav a{transition:none;}
    .chips a:active,.switch a:active,.cta:active{transform:none;}
  }
  @media (prefers-contrast: more){
    :root{--line:rgba(243,233,216,.4);--cream-dim:#e6dcc8;--bronze:#cdb896;}
  }

  /* sejdel dimples — concave pressed glass, two depth layers */
  .dimples{position:fixed;inset:-260px;pointer-events:none;z-index:-1;
    background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='204'%3E%3Cdefs%3E%3CradialGradient id='g' cx='63%' cy='67%' r='75%'%3E%3Cstop offset='0%' stop-color='%23f0c084' stop-opacity='.55'/%3E%3Cstop offset='35%' stop-color='%23c98136' stop-opacity='.28'/%3E%3Cstop offset='75%' stop-color='%23120a04' stop-opacity='.6'/%3E%3Cstop offset='100%' stop-color='%23120a04' stop-opacity='0'/%3E%3C/radialGradient%3E%3C/defs%3E%3Cg fill='none' stroke-linecap='round'%3E%3Ccircle cx='45' cy='51' r='34' fill='url(%23g)'/%3E%3Cpath d='M14.1 53.7A31 31 0 0 1 62.8 25.6' stroke='%230a0603' stroke-opacity='.65' stroke-width='3'/%3E%3Cpath d='M75.9 48.4A31 31 0 0 1 32.3 78.2' stroke='%23f3e0c0' stroke-opacity='.42' stroke-width='1.6'/%3E%3Ccircle cx='135' cy='153' r='34' fill='url(%23g)'/%3E%3Cpath d='M104.1 155.7A31 31 0 0 1 152.8 127.6' stroke='%230a0603' stroke-opacity='.65' stroke-width='3'/%3E%3Cpath d='M165.9 150.4A31 31 0 0 1 122.3 180.2' stroke='%23f3e0c0' stroke-opacity='.42' stroke-width='1.6'/%3E%3C/g%3E%3C/svg%3E");will-change:transform;}
  .dim-far{opacity:.10;background-size:176px 200px;filter:blur(1.8px);
    animation:dimpledriftf 84s linear infinite;}
  .dim-near{opacity:.24;background-size:300px 341px;
    animation:dimpledriftn 44s linear infinite;}
  @keyframes dimpledriftf{from{transform:translate3d(0,0,0)}to{transform:translate3d(-176px,-200px,0)}}
  @keyframes dimpledriftn{from{transform:translate3d(0,0,0)}to{transform:translate3d(-300px,-341px,0)}}
  @media (prefers-reduced-motion: reduce){.dimples{animation:none}}
  /* readability: feathered pool of ink behind every text container */
  .wrap{background:rgba(20,15,11,.55);box-shadow:0 0 70px 55px rgba(20,15,11,.55);border-radius:26px;}
</style>
${jsonld ? (Array.isArray(jsonld) ? jsonld : [jsonld])
    .map((d) => `<script type="application/ld+json">${JSON.stringify(d)}</script>`).join("\n") : ""}
</head>
<body><div class="dimples dim-far" aria-hidden="true"></div><div class="dimples dim-near" aria-hidden="true"></div>
<div class="wrap">
  <header class="top">
    <a class="brand" href="${SITE}/">Sejdel<span>.</span></a>
    <nav>
      <a href="${SITE}/map/">${lang === "sv" ? "Kartan" : "Map"}</a>
      <a href="${lang === "sv" ? SITE + "/blogg/" : SITE + "/blog/"}">${lang === "sv" ? "Blogg" : "Blog"}</a>
      <a href="${altHref}">${altLang === "sv" ? "Svenska" : "English"}</a>
    </nav>
  </header>
  <p class="kicker">${esc(kicker)}</p>
  <h1>${esc(h1)}</h1>
${switcher || ""}
${body}
  <footer>
    ${lang === "sv"
      ? `Sidan är avsedd för dig som är över 18 år. Priserna är inrapporterade av användare och visas som medianen av de senaste rapporterna per bar och storlek. Sejdel ger ingen garanti för att ett pris gäller när du kommer dit — <a href="${SITE}/map/">rapportera gärna en ändring</a>. Drick måttfullt.`
      : `This page is intended for readers of legal drinking age. Prices are reported by users and shown as the median of recent reports per bar and size. Sejdel cannot guarantee a price still stands when you arrive — <a href="${SITE}/map/">report a change</a> if it has moved. Please drink responsibly.`}
    <br /><br />
    <a href="${SITE}/">Sejdel</a> · <a href="${SITE}/map/">${lang === "sv" ? "Ölkartan" : "Beer map"}</a>
    · <a href="${SITE}/privacy/">${lang === "sv" ? "Integritet" : "Privacy"}</a>
  </footer>
</div>
</body>
</html>
`;
}

/// Band a rate against the national median: well under, under, over, well over.
function band(rate) {
  const m = national.medianRate;
  if (rate <= m * 0.75) return "b1";
  if (rate <= m) return "b2";
  if (rate <= m * 1.25) return "b3";
  return "b4";
}

function legend(lang) {
  const m = national.medianRate;
  const items = lang === "sv"
    ? [["b1", `under ${perCl(m * 0.75)}`], ["b2", "under riksmedian"],
       ["b3", "över riksmedian"], ["b4", `över ${perCl(m * 1.25)}`]]
    : [["b1", `under ${perCl(m * 0.75)}`], ["b2", "below national median"],
       ["b3", "above national median"], ["b4", `over ${perCl(m * 1.25)}`]];
  const col = { b1: "#7ec96b", b2: "#e8c34a", b3: "#e8843c", b4: "#e07a6a" };
  return `<div class="legend">${items.map(([b, t]) =>
    `<span><i style="background:${col[b]}"></i>${esc(t)}</span>`).join("")}</div>`;
}

function priceTable(list, lang, showSize) {
  const head = lang === "sv"
    ? `<tr><th></th><th>Krog</th>${showSize ? "<th>Storlek</th>" : ""}<th>Pris</th><th>Per cl</th></tr>`
    : `<tr><th></th><th>Bar</th>${showSize ? "<th>Size</th>" : ""}<th>Price</th><th>Per cl</th></tr>`;
  const body = list.map((r, i) => {
    const rate = r.price / r.cl;
    // Each row links to the bar on the map. The article should feed the map,
    // not dead-end in a table.
    // v + s so the map opens THIS bar's card at THIS serving. Without the
    // serving the map would sit on its 40 cl default and a 50 cl-only bar
    // would have no pin to select.
    const href = `${SITE}/map/?lat=${(r.lat ?? 0).toFixed(5)}&lon=${(r.lon ?? 0).toFixed(5)}`
      + `&v=${encodeURIComponent(r.id)}&s=${encodeURIComponent(r.serving)}&city=${encodeURIComponent(r.city)}`;
    return `<tr>
      <td class="rank">${i + 1}</td>
      <td><a href="${href}">${esc(r.venue)}</a></td>
      ${showSize ? `<td class="n">${SERVING_LABEL[r.serving]}</td>` : ""}
      <td class="p ${band(rate)}">${kr(r.price)}</td>
      <td class="n">${perCl(rate)}</td>
    </tr>`;
  }).join("\n");
  return `<div class="tw"><table>${head}\n${body}</table></div>` + legend(lang);
}

/// When a table is capped, say so right under it — a median computed over 67
/// bars above a table showing the 30 cheapest reads as a discrepancy, and the
/// reader has no way to know it isn't one.
function tableNote(lang, shown, total, medianTxt) {
  if (shown >= total) return "";
  return `<p class="note">${lang === "sv"
    ? `Visar de ${shown} billigaste av ${total} ställen. Medianen${medianTxt ? ` (${medianTxt})` : ""} räknas över alla ${total}.`
    : `Showing the ${shown} cheapest of ${total} places. The median${medianTxt ? ` (${medianTxt})` : ""} is computed over all ${total}.`}</p>`;
}

function figs(items) {
  const step = (v) => {
    const n = String(v).length;
    return n <= 5 ? "s1" : n <= 8 ? "s2" : n <= 11 ? "s3" : "s4";
  };
  return `<div class="figs">${items.map(([v, l]) =>
    `<div class="fig"><b class="${step(v)}" title="${esc(v)}">${esc(v)}</b><span>${esc(l)}</span></div>`).join("")}</div>`;
}

const cityLinks = (lang, exclude) => `<ul class="chips">${cities
  .filter((c) => c.city !== exclude)
  .map((c) => {
    const nm = lang === "sv" ? c.city : (EN_NAME[c.city] || c.city);
    const href = lang === "sv"
      ? `${SITE}/blogg/billig-ol-${slugify(c.city)}/`
      : `${SITE}/blog/cheapest-beer-${slugify(EN_NAME[c.city] || c.city)}/`;
    return `<li><a href="${href}">${esc(nm)}</a></li>`;
  }).join("")}</ul>`;

// FAQ. Real questions people type, answered with this city's actual numbers —
// and marked up as FAQPage, which is the one structured-data type on these pages
// that can earn extra space in the results.
function faq(lang, c) {
  const nm = lang === "sv" ? c.city : (EN_NAME[c.city] || c.city);
  const cheapestBar = c.top40[0] || c.topValue[0];
  const bestValue = c.topValue[0];
  const qs = lang === "sv" ? [
    [`Var är ölen billigast i ${nm}?`,
     `${esc(cheapestBar.venue)} har det lägsta priset vi har inrapporterat, ${kr(cheapestBar.price)} för ${SERVING_LABEL[cheapestBar.serving]}. Räknat per centiliter är ${esc(bestValue.venue)} bäst på ${perCl(bestValue.price / bestValue.cl)}.`],
    [`Vad kostar en stor stark i ${nm}?`,
     `Medianen för 40 cl ligger på ${kr(c.median40 ?? 0)}. Billigast vi sett är ${kr(c.cheapest40 ?? c.median40)}.`],
    [`Vad är literpriset på öl i ${nm}?`,
     `Medianen motsvarar ${Math.round(c.medianRate * 100)} kr per liter, alltså ${perCl(c.medianRate)}. Bästa literpriset i stan är ${Math.round(c.bestRate * 100)} kr/l.`],
    ["Varför jämför ni per centiliter?",
     "Eftersom glasstorlekarna skiljer sig. En 33 cl för 49 kr är dyrare per öl än en 50 cl för 65 kr, även om siffran på menyn är lägre. Per centiliter blir jämförelsen rättvis."],
    ["Hur ofta uppdateras priserna?",
     `Sidan byggs om från de senaste rapporterna — den här versionen är från ${updatedSv}. Vi visar medianen av de senaste rapporterna per bar och storlek, inte det senaste priset.`],
    ["Kan jag rapportera ett pris själv?",
     "Ja. Sök upp baren på ölkartan och lägg in priset, eller gör det i Sejdel-appen. Det syns på kartan direkt och på den här sidan nästa gång den byggs."],
  ] : [
    [`Where is beer cheapest in ${nm}?`,
     `${esc(cheapestBar.venue)} has the lowest price reported to us, ${kr(cheapestBar.price)} for ${SERVING_LABEL[cheapestBar.serving]}. Per centilitre, ${esc(bestValue.venue)} is best value at ${perCl(bestValue.price / bestValue.cl)}.`],
    [`How much is a beer in ${nm}?`,
     `The median for a 40 cl draught is ${kr(c.median40 ?? 0)}, and the cheapest we have seen is ${kr(c.cheapest40 ?? c.median40)}.`],
    [`What is the price per litre of beer in ${nm}?`,
     `The median works out at ${Math.round(c.medianRate * 100)} kr per litre, or ${perCl(c.medianRate)}. The best rate in the city is ${Math.round(c.bestRate * 100)} kr/l.`],
    ["Why compare per centilitre?",
     "Because glass sizes differ. A 33 cl at 49 kr costs more per unit of beer than a 50 cl at 65 kr, even though the menu price is lower. Per centilitre makes the comparison fair."],
    ["How often are prices updated?",
     `The page is rebuilt from the latest reports — this version is from ${updatedEn}. We show the median of recent reports per bar and size rather than the most recent price.`],
    ["Can I report a price myself?",
     "Yes. Find the bar on the beer map and add the price, or do it in the Sejdel app. It shows on the map immediately and on this page the next time it is built."],
  ];
  const html = `<h2>${lang === "sv" ? "Vanliga frågor" : "Frequently asked questions"}</h2>`
    + qs.map(([q, a]) => `<h3>${esc(q)}</h3>\n  <p>${a}</p>`).join("\n  ");
  const ld = {
    "@context": "https://schema.org", "@type": "FAQPage",
    mainEntity: qs.map(([q, a]) => ({
      "@type": "Question", name: q,
      acceptedAnswer: { "@type": "Answer", text: a.replace(/<[^>]+>/g, "") },
    })),
  };
  return { html, ld };
}

function crumbs(lang, leaf) {
  const hub = lang === "sv" ? `${SITE}/blogg/` : `${SITE}/blog/`;
  const hubName = lang === "sv" ? "Ölpriser" : "Beer prices";
  return {
    html: `<p class="crumbs"><a href="${SITE}/">Sejdel</a> › <a href="${hub}">${hubName}</a> › <span>${esc(leaf)}</span></p>`,
    ld: {
      "@context": "https://schema.org", "@type": "BreadcrumbList",
      itemListElement: [
        { "@type": "ListItem", position: 1, name: "Sejdel", item: `${SITE}/` },
        { "@type": "ListItem", position: 2, name: hubName, item: hub },
        { "@type": "ListItem", position: 3, name: leaf },
      ],
    },
  };
}

const switcher = (lang, current) => `<ul class="switch">${cities.map((c) => {
  const nm = lang === "sv" ? c.city : (EN_NAME[c.city] || c.city);
  const href = lang === "sv"
    ? `${SITE}/blogg/billig-ol-${slugify(c.city)}/`
    : `${SITE}/blog/cheapest-beer-${slugify(EN_NAME[c.city] || c.city)}/`;
  return `<li><a class="${c.city === current ? "on" : ""}" href="${href}">${esc(nm)}</a></li>`;
}).join("")}</ul>`;

// A city's centre is optional: the national pages want the same card without
// pinning the camera to one town, so a caller with no coordinates gets the
// plain map link rather than a crash.
const mapCta = (lang, c) => {
  const pinned = c && Number.isFinite(c.lat) && Number.isFinite(c.lon);
  const q = pinned
    ? `?lat=${c.lat.toFixed(5)}&lon=${c.lon.toFixed(5)}&city=${encodeURIComponent(c.city)}`
    : "";
  return `<a class="cta" href="${SITE}/map/${q}">
    <b>${lang === "sv" ? "Se alla priser på kartan" : "See every price on the map"}</b>
    <span>${lang === "sv"
      ? "Zooma in på din stad, filtrera på storlek och se vilka barer som har sol just nu."
      : "Zoom to your city, filter by size, and see which bars are in the sun right now."}</span>
  </a>`;
};

// Declared here, not down in the national section: the city pages link to them,
// and a const is not hoisted — referencing it earlier is a TDZ error at runtime.
const svNatUrl = `${SITE}/blogg/billig-ol-sverige/`;
const enNatUrl = `${SITE}/blog/beer-prices-sweden/`;

// ---------------------------------------------------------------- city pages

const written = [];
function write(rel, html) {
  const full = join(ROOT, rel, "index.html");
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, html);
  written.push(`${SITE}/${rel}/`);
}

for (const c of cities) {
  const en = EN_NAME[c.city] || c.city;
  const svSlug = `blogg/billig-ol-${slugify(c.city)}`;
  const enSlug = `blog/cheapest-beer-${slugify(en)}`;
  const svUrl = `${SITE}/${svSlug}/`;
  const enUrl = `${SITE}/${enSlug}/`;
  const vsNat = ((c.medianRate / national.medianRate - 1) * 100);
  const vsNatTxt = (lang) => {
    const pct = Math.abs(vsNat).toFixed(0);
    if (Math.abs(vsNat) < 3) return lang === "sv" ? "i linje med riksmedianen" : "in line with the national median";
    return lang === "sv"
      ? (vsNat < 0 ? `${pct} % under riksmedianen` : `${pct} % över riksmedianen`)
      : (vsNat < 0 ? `${pct}% below the national median` : `${pct}% above the national median`);
  };

  const ld = (name, url, desc) => ({
    "@context": "https://schema.org",
    "@type": "Article",
    headline: name,
    description: desc,
    dateModified: updated,
    inLanguage: url === svUrl ? "sv-SE" : "en",
    mainEntityOfPage: { "@type": "WebPage", "@id": url },
    publisher: { "@type": "Organization", name: "Sejdel", url: SITE },
    about: { "@type": "Place", name: url === svUrl ? c.city : en },
  });

  // ---- Swedish
  write(svSlug, page({
    lang: "sv", altLang: "en", altHref: enUrl, canonical: svUrl,
    title: `Billigaste ölen i ${c.city} ${new Date().getFullYear()} – stor stark från ${Math.round(c.cheapest40 ?? c.median40)} kr`,
    // Kept under ~160 chars so Google doesn't truncate it mid-sentence; the
    // Swedish wording ran long once the date was appended.
    desc: `Var är ölen billigast i ${c.city}? ${c.bars} barer med inrapporterade priser, stor stark från ${Math.round(c.cheapest40 ?? c.median40)} kr och topplista på pris per centiliter.`,
    kicker: `Ölpriser · ${c.city}`,
    h1: `Billigaste ölen i ${c.city}`,
    switcher: crumbs("sv", c.city).html + switcher("sv", c.city),
    jsonld: [ld(`Billigaste ölen i ${c.city}`, svUrl, `Ölpriser i ${c.city}`),
             faq("sv", c).ld, crumbs("sv", c.city).ld],
    body: `
  <p class="lede">Vi har inrapporterade ölpriser från <strong>${c.bars} barer</strong> i ${c.city}. Här är var stor starken är billigast — och var du får mest öl för pengarna räknat per centiliter.</p>
  <p class="stamp">Uppdaterad ${updatedSv} · ${c.prices} priser</p>
  ${figs([
    [kr(c.cheapest40 ?? c.median40), "billigaste stor stark"],
    [kr(c.median40 ?? 0), "median, 40 cl"],
    [perCl(c.bestRate), "bästa pris per cl"],
    [String(c.bars), "barer med pris"],
  ])}
  <p>Medianpriset i ${c.city} ligger på <strong>${perCl(c.medianRate)}</strong> (literpris ${Math.round(c.medianRate * 100)} kr/l), vilket är ${vsNatTxt("sv")}. Skillnaden mellan billigaste och dyraste ölen i stan är ${(c.worstRate / c.bestRate).toFixed(1)} gånger — det är alltså värt att veta vart man går.</p>

  <h2>Billigaste stor stark i ${c.city}</h2>
  <p>Stor stark betyder oftast 40 cl fatöl. Det är måttet folk jämför, så vi listar det separat.</p>
  ${priceTable(c.top40, "sv", false)}
  <p class="note">Priser i kronor, median av de senaste rapporterna per bar.</p>

  <h2>Mest öl för pengarna – pris per centiliter</h2>
  <p>En billig öl i ett litet glas är inte billig. Räknar man om alla storlekar till kronor per centiliter ändras ordningen ofta helt: en 50 cl för 65 kr (${perCl(65 / 50)}) slår en 33 cl för 49 kr (${perCl(49 / 33)}).</p>
  ${priceTable(c.topValue, "sv", true)}

  ${mapCta("sv", c)}

  ${faq("sv", c).html}

  <h2>Så räknar vi</h2>
  <p>Priserna kommer från användare i Sejdel-appen och på ölkartan. För varje bar och storlek visar vi <em>medianen</em> av de senaste rapporterna, inte det senaste priset — ett enstaka felinmatat pris ska inte kunna styra listan. Bara priser i kronor och i storlekar vi kan räkna om per centiliter räknas med. Pint tolkas som 56,8 cl.</p>
  <p>Priser ändras och happy hour räknas inte in. Ser du ett pris som inte stämmer kan du <a href="${SITE}/map/">rapportera det på kartan</a> — det uppdaterar den här sidan nästa gång den byggs.</p>

  <h2>Mer om ölen i ${c.city}</h2>
  ${variantLinks("sv", c.city, "prices")}
  <h2>Ölpriser i andra städer</h2>
  <p>Se även <a href="${svNatUrl}">billigaste ölen i Sverige</a>, med alla städer rangordnade efter literpris.</p>
  ${cityLinks("sv", c.city)}
`,
  }));

  // ---- English
  write(enSlug, page({
    lang: "en", altLang: "sv", altHref: svUrl, canonical: enUrl,
    title: `Cheapest Beer in ${en} ${new Date().getFullYear()} — From ${Math.round(c.cheapest40 ?? c.median40)} kr`,
    desc: `Where is beer cheapest in ${en}? Reported prices from ${c.bars} bars, a large draught from ${Math.round(c.cheapest40 ?? c.median40)} kr, plus a ranking by price per centilitre. Updated ${updatedEn}.`,
    kicker: `Beer prices · ${en}`,
    h1: `Cheapest beer in ${en}`,
    switcher: crumbs("en", en).html + switcher("en", c.city),
    jsonld: [ld(`Cheapest beer in ${en}`, enUrl, `Beer prices in ${en}`),
             faq("en", c).ld, crumbs("en", en).ld],
    body: `
  <p class="lede">We have user-reported beer prices from <strong>${c.bars} bars</strong> in ${en}. Here is where a large draught costs least — and where you get the most beer for your money per centilitre.</p>
  <p class="stamp">Updated ${updatedEn} · ${c.prices} prices</p>
  ${figs([
    [kr(c.cheapest40 ?? c.median40), "cheapest 40 cl"],
    [kr(c.median40 ?? 0), "median, 40 cl"],
    [perCl(c.bestRate), "best price per cl"],
    [String(c.bars), "bars with a price"],
  ])}
  <p>The median in ${en} is <strong>${perCl(c.medianRate)}</strong>, ${vsNatTxt("en")}. The gap between the cheapest and the most expensive beer in the city is ${(c.worstRate / c.bestRate).toFixed(1)}×, so it genuinely pays to know where you are going.</p>

  <h2>Cheapest large draught in ${en}</h2>
  <p>A Swedish "stor stark" is usually 40 cl of draught lager — the measure locals compare — so it gets its own table.</p>
  ${priceTable(c.top40, "en", false)}
  <p class="note">Prices in Swedish kronor, median of recent reports per bar.</p>

  <h2>Best value — price per centilitre</h2>
  <p>A cheap beer in a small glass is not cheap. Converting every size to kronor per centilitre often reorders the list completely: a 50 cl at 65 kr (${perCl(65 / 50)}) beats a 33 cl at 49 kr (${perCl(49 / 33)}).</p>
  ${priceTable(c.topValue, "en", true)}

  ${mapCta("en", c)}

  ${faq("en", c).html}

  <h2>How we work it out</h2>
  <p>Prices come from Sejdel users in the app and on the beer map. For each bar and size we show the <em>median</em> of recent reports rather than the latest one, so a single mistyped price cannot swing a table. Only prices in kronor, in sizes we can convert per centilitre, are included; a pint is treated as 56.8 cl.</p>
  <p>Prices change, and happy hour is not counted. If something looks wrong you can <a href="${SITE}/map/">report it on the map</a>, which updates this page the next time it is built.</p>

  <h2>More on beer in ${en}</h2>
  ${variantLinks("en", c.city, "prices")}
  <h2>Beer prices in other cities</h2>
  <p>See also <a href="${enNatUrl}">beer prices across Sweden</a>, with every city ranked by price per litre.</p>
  ${cityLinks("en", c.city)}
`,
  }));
}

// ---------------------------------------------------------------- national

const ranked = [...cities].sort((a, b) => a.medianRate - b.medianRate);
function natTable(lang) {
  const head = lang === "sv"
    ? `<tr><th></th><th>Stad</th><th>Median /cl</th><th>Billigaste 40 cl</th><th>Barer</th></tr>`
    : `<tr><th></th><th>City</th><th>Median /cl</th><th>Cheapest 40 cl</th><th>Bars</th></tr>`;
  const body = ranked.map((c, i) => {
    const nm = lang === "sv" ? c.city : (EN_NAME[c.city] || c.city);
    const href = lang === "sv"
      ? `${SITE}/blogg/billig-ol-${slugify(c.city)}/`
      : `${SITE}/blog/cheapest-beer-${slugify(EN_NAME[c.city] || c.city)}/`;
    return `<tr><td class="rank">${i + 1}</td><td><a href="${href}">${esc(nm)}</a></td>
      <td class="p">${perCl(c.medianRate)}</td>
      <td class="n">${c.cheapest40 ? kr(c.cheapest40) : "—"}</td>
      <td class="n">${c.bars}</td></tr>`;
  }).join("\n");
  return `<div class="tw"><table>${head}\n${body}</table></div>`;
}

const cheapCity = ranked[0], dearCity = ranked[ranked.length - 1];

write("blogg/billig-ol-sverige", page({
  lang: "sv", altLang: "en", altHref: enNatUrl, canonical: svNatUrl,
  title: `Billigaste ölen i Sverige ${new Date().getFullYear()} – stad för stad`,
  desc: `Vad kostar en öl i Sverige? ${national.bars} barer i ${cities.length} städer, pris per centiliter och vilken stad som är billigast. Uppdaterad ${updatedSv}.`,
  kicker: "Ölpriser · Sverige",
  h1: "Billigaste ölen i Sverige",
  jsonld: {
    "@context": "https://schema.org", "@type": "Article",
    headline: "Billigaste ölen i Sverige", dateModified: updated, inLanguage: "sv-SE",
    mainEntityOfPage: { "@type": "WebPage", "@id": svNatUrl },
    publisher: { "@type": "Organization", name: "Sejdel", url: SITE },
  },
  body: `
  <p class="lede">Inrapporterade ölpriser från <strong>${national.bars} barer</strong> i ${cities.length} svenska städer, jämförda på det enda sätt som är rättvist: kronor per centiliter.</p>
  <p class="stamp">Uppdaterad ${updatedSv} · ${national.prices} priser</p>
  ${figs([
    [perCl(national.medianRate), "riksmedian"],
    [kr(Math.min(...cities.map((c) => c.cheapest40 ?? Infinity))), "billigaste stor stark"],
    [cheapCity.city, "billigaste staden"],
    [String(cities.length), "städer"],
  ])}
  <p><strong>${cheapCity.city}</strong> är billigast av städerna vi täcker på ${perCl(cheapCity.medianRate)} i median, mot ${perCl(dearCity.medianRate)} i ${dearCity.city} — ${((dearCity.medianRate / cheapCity.medianRate - 1) * 100).toFixed(0)} % dyrare för samma mängd öl.</p>

  <h2>Ölpriser per stad</h2>
  <p>Sorterat efter medianpris per centiliter, billigast först.</p>
  ${natTable("sv")}

  ${mapCta("sv")}

  <h2>Vad kostar en öl i Sverige?</h2>
  <p>Medianen i vårt underlag är ${perCl(national.medianRate)}, alltså runt ${kr(national.medianRate * 40)} för en stor stark på 40 cl. Spannet är stort: från ${perCl(national.bestRate)} till ${perCl(national.worstRate)}, en skillnad på ${(national.worstRate / national.bestRate).toFixed(1)} gånger mellan billigaste och dyraste ölen i landet.</p>

  <h2>Så räknar vi</h2>
  <p>Priserna rapporteras av användare i Sejdel. Per bar och storlek visas medianen av de senaste rapporterna. Bara priser i kronor räknas med, och pint tolkas som 56,8 cl. Städer med färre än ${MIN_BARS} barer får ingen egen sida — underlaget blir för tunt för att vara användbart.</p>

  <h2>Städer</h2>
  ${cityLinks("sv", null)}
`,
}));

write("blog/beer-prices-sweden", page({
  lang: "en", altLang: "sv", altHref: svNatUrl, canonical: enNatUrl,
  title: `Beer Prices in Sweden ${new Date().getFullYear()} — Cheapest Cities Ranked`,
  desc: `How much is a beer in Sweden? ${national.bars} bars across ${cities.length} cities, compared by price per centilitre, cheapest city first. Updated ${updatedEn}.`,
  kicker: "Beer prices · Sweden",
  h1: "Beer prices in Sweden",
  jsonld: {
    "@context": "https://schema.org", "@type": "Article",
    headline: "Beer prices in Sweden", dateModified: updated, inLanguage: "en",
    mainEntityOfPage: { "@type": "WebPage", "@id": enNatUrl },
    publisher: { "@type": "Organization", name: "Sejdel", url: SITE },
  },
  body: `
  <p class="lede">User-reported beer prices from <strong>${national.bars} bars</strong> across ${cities.length} Swedish cities, compared the only way that is fair: kronor per centilitre.</p>
  <p class="stamp">Updated ${updatedEn} · ${national.prices} prices</p>
  ${figs([
    [perCl(national.medianRate), "national median"],
    [kr(Math.min(...cities.map((c) => c.cheapest40 ?? Infinity))), "cheapest 40 cl"],
    [EN_NAME[cheapCity.city] || cheapCity.city, "cheapest city"],
    [String(cities.length), "cities"],
  ])}
  <p><strong>${EN_NAME[cheapCity.city] || cheapCity.city}</strong> is the cheapest city we cover at a median of ${perCl(cheapCity.medianRate)}, against ${perCl(dearCity.medianRate)} in ${EN_NAME[dearCity.city] || dearCity.city}, the most expensive — ${((dearCity.medianRate / cheapCity.medianRate - 1) * 100).toFixed(0)}% more for the same amount of beer.</p>

  <h2>Beer prices by city</h2>
  <p>Ranked by median price per centilitre, cheapest first.</p>
  ${natTable("en")}

  ${mapCta("en")}

  <h2>How much is a beer in Sweden?</h2>
  <p>The median across our data is ${perCl(national.medianRate)} — about ${kr(national.medianRate * 40)} for a 40 cl "stor stark", the standard large draught. The range is wide: ${perCl(national.bestRate)} to ${perCl(national.worstRate)}, a ${(national.worstRate / national.bestRate).toFixed(1)}× difference between the cheapest and the most expensive beer in the country.</p>

  <h2>How we work it out</h2>
  <p>Prices are reported by Sejdel users. For each bar and size we show the median of recent reports. Only prices in kronor are included, and a pint is treated as 56.8 cl. Cities with fewer than ${MIN_BARS} bars do not get their own page — the sample is too thin to be useful.</p>

  <h2>Cities</h2>
  ${cityLinks("en", null)}
`,
}));

// ---------------------------------------------------- "under N kr" pages
//
// Long-tail intent: someone typing "öl under 50 kr göteborg" wants a list, not
// an essay. One page per city per threshold — BUT ONLY WHERE THE DATA SUPPORTS
// ONE.
//
// This is the part worth being strict about. Kalmar's cheapest 40 cl is 55 kr,
// so "öl under 50 kr i Kalmar" would be a page whose entire content is "there
// are none". Landskrona's cheapest is exactly 60. Publishing those is the
// classic doorway-page mistake: it targets a query the site cannot answer, and
// a cluster of near-empty pages drags the ranking of the good ones down with
// it. So a threshold page needs MIN_UNDER qualifying bars or it is not written,
// and the city page — which does answer "where is it cheapest" — carries that
// traffic instead.
const THRESHOLDS = [50, 60];
const underPages = [];

for (const c of cities) {
  for (const t of THRESHOLDS) {
    const hits = c.all40.filter((r) => r.price <= t);
    if (hits.length < MIN_UNDER) { underPages.push([c.city, t, hits.length, false]); continue; }
    underPages.push([c.city, t, hits.length, true]);

    const en = EN_NAME[c.city] || c.city;
    const svSlug = `blogg/ol-under-${t}-kr-${slugify(c.city)}`;
    const enSlug = `blog/beer-under-${t}-kr-${slugify(en)}`;
    const svU = `${SITE}/${svSlug}/`, enU = `${SITE}/${enSlug}/`;
    const svCity = `${SITE}/blogg/billig-ol-${slugify(c.city)}/`;
    const enCity = `${SITE}/blog/cheapest-beer-${slugify(en)}/`;
    const share = ((hits.length / c.all40.length) * 100).toFixed(0);
    const cheapest = hits[0];

    const ldFor = (headline, url, lang) => ([
      { "@context": "https://schema.org", "@type": "Article", headline,
        dateModified: updated, inLanguage: lang === "sv" ? "sv-SE" : "en",
        mainEntityOfPage: { "@type": "WebPage", "@id": url },
        publisher: { "@type": "Organization", name: "Sejdel", url: SITE } },
      { "@context": "https://schema.org", "@type": "ItemList",
        name: headline, numberOfItems: hits.length,
        itemListElement: hits.slice(0, 20).map((r, i) => ({
          "@type": "ListItem", position: i + 1, name: r.venue })) },
    ]);

    write(svSlug, page({
      lang: "sv", altLang: "en", altHref: enU, canonical: svU,
      title: `Öl under ${t} kr i ${c.city} – ${hits.length} ställen`,
      desc: `${hits.length} barer i ${c.city} med stor stark för ${t} kr eller mindre. Billigast just nu: ${esc(cheapest.venue)}, ${kr(cheapest.price)}. Uppdaterad ${updatedSv}.`,
      kicker: `Under ${t} kr · ${c.city}`,
      h1: `Öl under ${t} kr i ${c.city}`,
      switcher: crumbs("sv", `Under ${t} kr i ${c.city}`).html,
      jsonld: [...ldFor(`Öl under ${t} kr i ${c.city}`, svU, "sv"),
               crumbs("sv", `Under ${t} kr i ${c.city}`).ld],
      body: `
  <p class="lede">Vi har <strong>${hits.length} barer</strong> i ${c.city} där en stor stark kostar ${t} kr eller mindre — ${share} % av alla vi har pris på. Billigast är ${esc(cheapest.venue)} på ${kr(cheapest.price)}.</p>
  <p class="stamp">Uppdaterad ${updatedSv}</p>
  ${figs([[String(hits.length), `ställen under ${t} kr`], [kr(cheapest.price), "billigast"],
          [`${share} %`, "av stadens barer"], [kr(c.median40 ?? 0), "median i stan"]])}
  <h2>${hits.length > 30 ? `Billigaste ställena under ${t} kr` : `Alla ställen under ${t} kr`}</h2>
  ${priceTable(hits.slice(0, 30), "sv", false)}
  ${tableNote("sv", Math.min(30, hits.length), hits.length, null)}
  ${mapCta("sv", c)}
  <h2>Är ${t} kr billigt i ${c.city}?</h2>
  <p>Medianen för en stor stark i ${c.city} ligger på ${kr(c.median40 ?? 0)}, så ${t} kr är ${((c.median40 ?? t) > t) ? "under" : "kring"} vad man normalt betalar. Räknat per centiliter motsvarar ${t} kr för 40 cl ${perCl(t / 40)}, mot stadens median på ${perCl(c.medianRate)}.</p>
  <p>Vill du se hela listan, inklusive andra glasstorlekar, finns den på <a href="${svCity}">billigaste ölen i ${c.city}</a>.</p>
  <h2>Andra städer</h2>
  ${cityLinks("sv", c.city)}
`,
    }));

    write(enSlug, page({
      lang: "en", altLang: "sv", altHref: svU, canonical: enU,
      title: `Beer Under ${t} kr in ${en} — ${hits.length} Places`,
      desc: `${hits.length} bars in ${en} serving a large draught for ${t} kr or less. Cheapest right now: ${esc(cheapest.venue)} at ${kr(cheapest.price)}. Updated ${updatedEn}.`,
      kicker: `Under ${t} kr · ${en}`,
      h1: `Beer under ${t} kr in ${en}`,
      switcher: crumbs("en", `Under ${t} kr in ${en}`).html,
      jsonld: [...ldFor(`Beer under ${t} kr in ${en}`, enU, "en"),
               crumbs("en", `Under ${t} kr in ${en}`).ld],
      body: `
  <p class="lede">We have <strong>${hits.length} bars</strong> in ${en} where a large draught costs ${t} kr or less — ${share}% of every bar we hold a price for. The cheapest is ${esc(cheapest.venue)} at ${kr(cheapest.price)}.</p>
  <p class="stamp">Updated ${updatedEn}</p>
  ${figs([[String(hits.length), `places under ${t} kr`], [kr(cheapest.price), "cheapest"],
          [`${share}%`, "of the city's bars"], [kr(c.median40 ?? 0), "city median"]])}
  <h2>${hits.length > 30 ? `The cheapest places under ${t} kr` : `Every place under ${t} kr`}</h2>
  ${priceTable(hits.slice(0, 30), "en", false)}
  ${tableNote("en", Math.min(30, hits.length), hits.length, null)}
  ${mapCta("en", c)}
  <h2>Is ${t} kr cheap in ${en}?</h2>
  <p>The median large draught in ${en} is ${kr(c.median40 ?? 0)}, so ${t} kr sits ${((c.median40 ?? t) > t) ? "below" : "around"} what you would normally pay. Per centilitre, ${t} kr for 40 cl works out at ${perCl(t / 40)} against the city median of ${perCl(c.medianRate)}.</p>
  <p>For the full list including other glass sizes, see <a href="${enCity}">cheapest beer in ${en}</a>.</p>
  <h2>Other cities</h2>
  ${cityLinks("en", c.city)}
`,
    }));
  }
}

console.log("\n\"under N kr\" pages:");
for (const [city, t, n, made] of underPages) {
  console.log(`  ${made ? "written " : "SKIPPED"}  under ${t} kr in ${city}: ${n} bars${made ? "" : ` (< ${MIN_UNDER}, would be a near-empty page)`}`);
}

// ------------------------------------------------------ happy hour pages
//
// WHAT THIS PAGE CAN AND CANNOT SAY.
//
// We hold 37 happy-hour PRICES and zero happy-hour TIMES. Not one row carries
// an hour, and venue_offers — the table that has start_minute/end_minute — has
// a single row in it, a quiz night. So "happy hour in Gothenburg is 16-19"
// would be a sentence about a named real business that no data of ours
// supports. These pages therefore publish the price, say plainly that the
// hours are not ours to state, and point at the bar. The day users report
// hours, this is where they go.
//
// Volume gate as elsewhere: Gothenburg (16 bars) and Stockholm (12) clear it;
// Malmo has 3 and five other cities have 1-2, so they get no page of their own
// and appear in the national roundup instead.


// Happy-hour table: same bands and map links as the price tables, plus the
// beer, which is the one extra fact we genuinely have for these rows.
function hhTable(list, lang) {
  const head = lang === "sv"
    ? `<tr><th></th><th>Krog</th><th>Öl</th><th>Storlek</th><th>Pris</th><th>Per cl</th></tr>`
    : `<tr><th></th><th>Bar</th><th>Beer</th><th>Size</th><th>Price</th><th>Per cl</th></tr>`;
  const rows = list.map((r, i) => {
    const rate = r.price / r.cl;
    const href = `${SITE}/map/?lat=${(r.lat ?? 0).toFixed(5)}&lon=${(r.lon ?? 0).toFixed(5)}`
      + `&v=${encodeURIComponent(r.id)}&s=${encodeURIComponent(r.serving)}&city=${encodeURIComponent(r.city)}`;
    return `<tr>
      <td class="rank">${i + 1}</td>
      <td><a href="${href}">${esc(r.venue)}</a></td>
      <td>${esc(r.beer || "—")}</td>
      <td class="n">${SERVING_LABEL[r.serving]}</td>
      <td class="p ${band(rate)}">${kr(r.price)}</td>
      <td class="n">${perCl(rate)}</td>
    </tr>`;
  }).join("\n");
  return `<div class="tw"><table>${head}\n${rows}</table></div>` + legend(lang);
}

const hhCaveat = (lang) => lang === "sv"
  ? `<p class="caveat"><b>Vi publicerar priset, inte klockslaget.</b> Våra
     happy hour-rapporter innehåller vad ölen kostar — inte vilka timmar som
     gäller. Tiderna varierar per krog och ändras ofta, och vi vill inte skriva
     ut ett klockslag för en namngiven bar som vi inte har belägg för. Ring
     stället, eller <a href="${SITE}/map/">rapportera tiden i appen</a> så
     lägger vi upp den här.</p>`
  : `<p class="caveat"><b>We publish the price, not the hours.</b> Our happy
     hour reports say what the beer costs — not which hours it runs. Hours vary
     by bar and change often, and we will not print a time for a named bar we
     cannot back up. Check with the venue, or
     <a href="${SITE}/map/">report the hours in the app</a> and they will
     appear here.</p>`;

/// The happy-hour median used in every "how much do you save" comparison.
/// 40 cl ONLY: the city median it is compared against is a 40 cl number, and
/// mixing pints and 50 cl into one side of the comparison quietly skews it.
/// Falls back to null (no claim) when there are too few 40 cl rows to stand on.
function hhMedian40(list) {
  const at40 = list.filter((r) => r.serving === "40").map((r) => r.price);
  return at40.length >= 3 ? median(at40) : null;
}

function hhFaq(lang, nm, list, cityMedian) {
  // "Cheapest" in prose = lowest absolute price. list[0] is the per-cl best,
  // which is a different bar whenever a large glass out-values a small one.
  const lo = [...list].sort((a, b) => a.price - b.price)[0];
  const hhMed = hhMedian40(list);
  const qs = lang === "sv" ? [
    [`Vilka tider är happy hour i ${nm}?`,
     `Det varierar från krog till krog. I Sverige ligger happy hour oftast på tidig kvällstid på vardagar, men varje ställe sätter sina egna timmar och ändrar dem ofta. Vi listar vilka barer som har happy hour och vad ölen kostar — tiderna publicerar vi inte förrän de är inrapporterade, eftersom ett felaktigt klockslag är värre än inget.`],
    [`Var är happy hour billigast i ${nm}?`,
     `${esc(lo.venue)} har det lägsta happy hour-priset vi har, ${kr(lo.price)} för ${SERVING_LABEL[lo.serving]} — ${perCl(lo.price / lo.cl)}.`],
    [`Hur mycket sparar man på happy hour?`,
     (cityMedian && hhMed)
       ? `Medianen bland happy hour-priserna för stor stark (40 cl) i ${nm} är ${kr(hhMed)}, mot ${kr(cityMedian)} för en vanlig stor stark i staden. Det är ungefär ${Math.max(0, Math.round((1 - hhMed / cityMedian) * 100))} % lägre.`
       : `Vi har ännu för få 40 cl-priser under happy hour i ${nm} för att ge en rättvis jämförelse — tabellen ovan visar de priser vi har.`],
    [`Hur många krogar har happy hour i ${nm}?`,
     `Vi har happy hour-pris för ${list.length} krogar i ${nm}. Det är de vi har rapporter på, inte alla som finns — hittar du en till, lägg in den i appen.`],
  ] : [
    [`What time is happy hour in ${nm}?`,
     `It varies by bar. In Sweden happy hour usually falls in the early evening on weekdays, but each venue sets its own hours and changes them often. We list which bars run one and what the beer costs — we do not publish the hours until they are reported, because a wrong time is worse than none.`],
    [`Where is happy hour cheapest in ${nm}?`,
     `${esc(lo.venue)} has the lowest happy hour price we hold, ${kr(lo.price)} for ${SERVING_LABEL[lo.serving]} — ${perCl(lo.price / lo.cl)}.`],
    [`How much does happy hour save you?`,
     (cityMedian && hhMed)
       ? `The median happy hour price for a large draught (40 cl) in ${nm} is ${kr(hhMed)}, against ${kr(cityMedian)} for an ordinary one — roughly ${Math.max(0, Math.round((1 - hhMed / cityMedian) * 100))}% less.`
       : `We hold too few 40 cl happy hour prices in ${nm} yet for a fair comparison — the table above shows what we have.`],
    [`How many bars run happy hour in ${nm}?`,
     `We hold a happy hour price for ${list.length} bars in ${nm}. That is the ones we have reports for, not every bar that runs one — if you find another, add it in the app.`],
  ];
  const html = `<h2>${lang === "sv" ? "Vanliga frågor" : "Common questions"}</h2>`
    + qs.map(([q, a]) => `<h3>${esc(q)}</h3><p>${a}</p>`).join("\n");
  return { html, ld: {
    "@context": "https://schema.org", "@type": "FAQPage",
    mainEntity: qs.map(([q, a]) => ({
      "@type": "Question", name: q,
      acceptedAnswer: { "@type": "Answer", text: a.replace(/<[^>]+>/g, "") } })),
  } };
}

const hhCities = [...happyByCity.entries()].filter(([, l]) => l.length >= MIN_HH);
const hhSkipped = [...happyByCity.entries()].filter(([, l]) => l.length < MIN_HH);

// --- one page per qualifying city
for (const [city, list] of hhCities) {
  const en = EN_NAME[city] || city;
  const c = cities.find((x) => x.city === city);
  const cityMedian = c?.median40 ?? null;
  const svU = `${SITE}/blogg/happy-hour-${slugify(city)}/`;
  const enU = `${SITE}/blog/happy-hour-${slugify(en)}/`;
  // Lowest price on the door — NOT list[0], which is the per-cl winner.
  const lo = [...list].sort((a, b) => a.price - b.price)[0];
  const hhMed = hhMedian40(list);   // 40 cl only — comparable to cityMedian
  const saving = (cityMedian && hhMed) ? Math.max(0, Math.round((1 - hhMed / cityMedian) * 100)) : 0;

  const artLd = (headline, url, lang) => ([
    { "@context": "https://schema.org", "@type": "Article", headline,
      dateModified: updated, inLanguage: lang === "sv" ? "sv-SE" : "en",
      mainEntityOfPage: { "@type": "WebPage", "@id": url },
      publisher: { "@type": "Organization", name: "Sejdel", url: SITE } },
    { "@context": "https://schema.org", "@type": "ItemList", name: headline,
      numberOfItems: list.length,
      itemListElement: list.slice(0, 20).map((r, i) => ({
        "@type": "ListItem", position: i + 1, name: r.venue })) },
  ]);

  const svFaq = hhFaq("sv", city, list, cityMedian);
  write(`blogg/happy-hour-${slugify(city)}`, page({
    lang: "sv", altLang: "en", altHref: enU, canonical: svU,
    title: `Happy hour i ${city} – priser på ${list.length} krogar`,
    desc: `Happy hour-priser för ${list.length} krogar i ${city}. Billigast: ${esc(lo.venue)}, ${kr(lo.price)} för ${SERVING_LABEL[lo.serving]}. Uppdaterad ${updatedSv}.`,
    kicker: `Happy hour · ${city}`,
    h1: `Happy hour i ${city}`,
    switcher: crumbs("sv", `Happy hour i ${city}`).html,
    jsonld: [...artLd(`Happy hour i ${city}`, svU, "sv"), svFaq.ld,
             crumbs("sv", `Happy hour i ${city}`).ld],
    body: `
  <p class="lede">Vi har happy hour-pris för <strong>${list.length} krogar</strong> i ${city}. Billigast är ${esc(lo.venue)} med ${kr(lo.price)} för ${SERVING_LABEL[lo.serving]}${lo.beer ? ` (${esc(lo.beer)})` : ""}.</p>
  <p class="stamp">Uppdaterad ${updatedSv}</p>
  ${figs([[String(list.length), "krogar med happy hour"], [kr(lo.price), "billigast"],
          [hhMed ? kr(hhMed) : "—", "median stor stark, hh"],
          [(cityMedian && hhMed) ? `${saving} %` : "—", "under stadens median"]])}
  ${hhCaveat("sv")}
  <h2>Happy hour-priser i ${city}</h2>
  ${hhTable(list, "sv")}
  ${(cityMedian && hhMed) ? `<h2>Är det värt det?</h2>
  <p>En vanlig stor stark i ${city} har medianpriset ${kr(cityMedian)}. Happy hour-medianen för samma storlek är ${kr(hhMed)} — alltså ungefär ${saving} % lägre. Skillnaden är störst i innerstaden, där grundpriset är högst.</p>` : ""}
  ${mapCta("sv", c || { city })}
  <p>Se även <a href="${SITE}/blogg/billig-ol-${slugify(city)}/">billigaste ölen i ${city}</a> och <a href="${SITE}/blogg/happy-hour-sverige/">happy hour i hela Sverige</a>.</p>
  ${svFaq.html}
  <h2>Andra städer</h2>
  ${cityLinks("sv", city)}
`,
  }));

  const enFaq = hhFaq("en", en, list, cityMedian);
  write(`blog/happy-hour-${slugify(en)}`, page({
    lang: "en", altLang: "sv", altHref: svU, canonical: enU,
    title: `Happy Hour in ${en} — Prices at ${list.length} Bars`,
    desc: `Happy hour beer prices for ${list.length} bars in ${en}. Cheapest: ${esc(lo.venue)} at ${kr(lo.price)} for ${SERVING_LABEL[lo.serving]}. Updated ${updatedEn}.`,
    kicker: `Happy hour · ${en}`,
    h1: `Happy hour in ${en}`,
    switcher: crumbs("en", `Happy hour in ${en}`).html,
    jsonld: [...artLd(`Happy hour in ${en}`, enU, "en"), enFaq.ld,
             crumbs("en", `Happy hour in ${en}`).ld],
    body: `
  <p class="lede">We hold happy hour prices for <strong>${list.length} bars</strong> in ${en}. The cheapest is ${esc(lo.venue)} at ${kr(lo.price)} for ${SERVING_LABEL[lo.serving]}${lo.beer ? ` (${esc(lo.beer)})` : ""}.</p>
  <p class="stamp">Updated ${updatedEn}</p>
  ${figs([[String(list.length), "bars with happy hour"], [kr(lo.price), "cheapest"],
          [hhMed ? kr(hhMed) : "—", "median 40 cl, hh"],
          [(cityMedian && hhMed) ? `${saving}%` : "—", "below city median"]])}
  ${hhCaveat("en")}
  <h2>Happy hour prices in ${en}</h2>
  ${hhTable(list, "en")}
  ${(cityMedian && hhMed) ? `<h2>Is it worth it?</h2>
  <p>An ordinary large draught in ${en} has a median price of ${kr(cityMedian)}. The happy hour median for the same size is ${kr(hhMed)} — roughly ${saving}% less. The gap is widest in the centre, where the base price is highest.</p>` : ""}
  ${mapCta("en", c || { city })}
  <p>See also <a href="${SITE}/blog/cheapest-beer-${slugify(en)}/">cheapest beer in ${en}</a> and <a href="${SITE}/blog/happy-hour-sweden/">happy hour across Sweden</a>.</p>
  ${enFaq.html}
  <h2>Other cities</h2>
  ${cityLinks("en", city)}
`,
  }));
}

// --- national roundup: every city, including the ones too thin for their own page
{
  const svU = `${SITE}/blogg/happy-hour-sverige/`;
  const enU = `${SITE}/blog/happy-hour-sweden/`;
  // Same distinction nationally: the headline "cheapest" is the lowest price.
  const lo = [...happy].sort((a, b) => a.price - b.price)[0];
  const hhMed = hhMedian40(happy);
  const nCities = happyByCity.size;
  const top = happy.slice(0, 25);
  const cityRow = (lang) => `<div class="tw"><table>
    <tr><th>${lang === "sv" ? "Stad" : "City"}</th><th>${lang === "sv" ? "Krogar" : "Bars"}</th><th>${lang === "sv" ? "Billigast" : "Cheapest"}</th></tr>
    ${[...happyByCity.entries()].sort((a, b) => b[1].length - a[1].length).map(([city, l]) => {
      const nm = lang === "sv" ? city : (EN_NAME[city] || city);
      const has = hhCities.some(([c2]) => c2 === city);
      const href = lang === "sv"
        ? `${SITE}/blogg/happy-hour-${slugify(city)}/`
        : `${SITE}/blog/happy-hour-${slugify(EN_NAME[city] || city)}/`;
      const cheapest = [...l].sort((a, b) => a.price - b.price)[0];
      return `<tr><td>${has ? `<a href="${href}">${esc(nm)}</a>` : esc(nm)}</td>
        <td class="n">${l.length}</td><td class="p">${kr(cheapest.price)}</td></tr>`;
    }).join("\n")}</table></div>`;

  const svFaq = hhFaq("sv", "Sverige", happy, national.median40);
  write("blogg/happy-hour-sverige", page({
    lang: "sv", altLang: "en", altHref: enU, canonical: svU,
    title: `Happy hour i Sverige – billigaste ölen timme för timme`,
    desc: `Happy hour-priser från ${happy.length} krogar i ${nCities} städer. Billigast: ${esc(lo.venue)} i ${esc(lo.city)}, ${kr(lo.price)}. Uppdaterad ${updatedSv}.`,
    kicker: "Happy hour · Sverige",
    h1: "Happy hour i Sverige",
    switcher: crumbs("sv", "Happy hour i Sverige").html,
    jsonld: [{ "@context": "https://schema.org", "@type": "Article",
      headline: "Happy hour i Sverige", dateModified: updated, inLanguage: "sv-SE",
      mainEntityOfPage: { "@type": "WebPage", "@id": svU },
      publisher: { "@type": "Organization", name: "Sejdel", url: SITE } },
      svFaq.ld, crumbs("sv", "Happy hour i Sverige").ld],
    body: `
  <p class="lede">Vi har happy hour-priser från <strong>${happy.length} krogar</strong> i ${nCities} städer. Billigast i landet är ${esc(lo.venue)} i ${esc(lo.city)}: ${kr(lo.price)} för ${SERVING_LABEL[lo.serving]}, ${perCl(lo.price / lo.cl)}.</p>
  <p class="stamp">Uppdaterad ${updatedSv}</p>
  ${figs([[String(happy.length), "happy hour-priser"], [String(nCities), "städer"],
          [kr(lo.price), "billigast i landet"], [hhMed ? kr(hhMed) : "—", "median stor stark"]])}
  ${hhCaveat("sv")}
  <h2>Städer</h2>
  ${cityRow("sv")}
  <h2>Billigaste happy hour i landet</h2>
  <p>Sorterat på literpris, så att 50 cl för 48 kr rankas före 40 cl för 45 kr.</p>
  ${hhTable(top, "sv")}
  ${tableNote("sv", top.length, happy.length, null)}
  ${mapCta("sv", { city: "Sverige" })}
  <p>Se även <a href="${SITE}/blogg/billig-ol-sverige/">billig öl i Sverige</a>.</p>
  ${svFaq.html}
  <h2>Städer med egna prissidor</h2>
  ${cityLinks("sv", null)}
`,
  }));

  const enFaq = hhFaq("en", "Sweden", happy, national.median40);
  write("blog/happy-hour-sweden", page({
    lang: "en", altLang: "sv", altHref: svU, canonical: enU,
    title: `Happy Hour in Sweden — Where the Beer Is Cheapest`,
    desc: `Happy hour prices from ${happy.length} bars across ${nCities} Swedish cities. Cheapest: ${esc(lo.venue)} in ${esc(lo.city)} at ${kr(lo.price)}. Updated ${updatedEn}.`,
    kicker: "Happy hour · Sweden",
    h1: "Happy hour in Sweden",
    switcher: crumbs("en", "Happy hour in Sweden").html,
    jsonld: [{ "@context": "https://schema.org", "@type": "Article",
      headline: "Happy hour in Sweden", dateModified: updated, inLanguage: "en",
      mainEntityOfPage: { "@type": "WebPage", "@id": enU },
      publisher: { "@type": "Organization", name: "Sejdel", url: SITE } },
      enFaq.ld, crumbs("en", "Happy hour in Sweden").ld],
    body: `
  <p class="lede">We hold happy hour prices from <strong>${happy.length} bars</strong> across ${nCities} cities. The cheapest in the country is ${esc(lo.venue)} in ${esc(lo.city)}: ${kr(lo.price)} for ${SERVING_LABEL[lo.serving]}, ${perCl(lo.price / lo.cl)}.</p>
  <p class="stamp">Updated ${updatedEn}</p>
  ${figs([[String(happy.length), "happy hour prices"], [String(nCities), "cities"],
          [kr(lo.price), "cheapest in Sweden"], [hhMed ? kr(hhMed) : "—", "median 40 cl"]])}
  ${hhCaveat("en")}
  <h2>Cities</h2>
  ${cityRow("en")}
  <h2>Cheapest happy hour in the country</h2>
  <p>Ranked by price per centilitre, so 50 cl at 48 kr beats 40 cl at 45 kr.</p>
  ${hhTable(top, "en")}
  ${tableNote("en", top.length, happy.length, null)}
  ${mapCta("en", { city: "Sweden" })}
  <p>See also <a href="${SITE}/blog/beer-prices-sweden/">beer prices in Sweden</a>.</p>
  ${enFaq.html}
  <h2>Cities with their own price pages</h2>
  ${cityLinks("en", null)}
`,
  }));
}

console.log("\nhappy hour pages:");
for (const [city, l] of hhCities) console.log(`  written   happy hour in ${city}: ${l.length} bars`);
for (const [city, l] of hhSkipped) console.log(`  SKIPPED  happy hour in ${city}: ${l.length} bars (< ${MIN_HH}; in the national roundup instead)`);
console.log(`  written   happy hour in Sweden (national): ${happy.length} prices, ${happyByCity.size} cities`);
console.log("  NOTE: no page states an hour — the dataset has 0 rows with a time.");

// ------------------------------------------------- outdoor seating pages
//
// "Uteservering med billig öl" — the one query where our two datasets stack:
// which bars HAVE a terrace (venues.outdoor_seating, 1583 true / 1069 false /
// 0 unknown) and what the beer COSTS there. The flag is tri-state by intent:
// only TRUE means a terrace; a bar missing from these pages has not been
// checked, and the page says so rather than implying the rest are indoor-only.
const outCities = [];
const outSkipped = [];
for (const c of cities) {
  const hits = c.all40.filter((r) => r.outdoor);
  (hits.length >= MIN_OUT ? outCities : outSkipped).push([c, hits]);
}

for (const [c, hits] of outCities) {
  const en = EN_NAME[c.city] || c.city;
  const svU = `${SITE}/blogg/uteservering-billig-ol-${slugify(c.city)}/`;
  const enU = `${SITE}/blog/outdoor-seating-cheap-beer-${slugify(en)}/`;
  const lo = hits[0];                       // all40 is already price-ascending
  const outMed = median(hits.map((r) => r.price));
  const share = ((hits.length / c.all40.length) * 100).toFixed(0);

  const ldFor = (headline, url, lang) => ([
    { "@context": "https://schema.org", "@type": "Article", headline,
      dateModified: updated, inLanguage: lang === "sv" ? "sv-SE" : "en",
      mainEntityOfPage: { "@type": "WebPage", "@id": url },
      publisher: { "@type": "Organization", name: "Sejdel", url: SITE } },
    { "@context": "https://schema.org", "@type": "ItemList", name: headline,
      numberOfItems: hits.length,
      itemListElement: hits.slice(0, 20).map((r, i) => ({
        "@type": "ListItem", position: i + 1, name: r.venue })) },
  ]);

  const svCaveat = `<p class="caveat"><b>Listan är inte komplett.</b> Vi vet att
    de här ${hits.length} barerna har uteservering — men en bar som saknas här
    är inte kontrollerad, inte terrasslös. Vet du en till?
    <a href="${SITE}/map/">Lägg in den i appen.</a></p>`;
  const enCaveat = `<p class="caveat"><b>This list is not exhaustive.</b> We
    know these ${hits.length} bars have outdoor seating — a bar missing from
    the list is unchecked, not terrace-free. Know another?
    <a href="${SITE}/map/">Add it in the app.</a></p>`;

  write(`blogg/uteservering-billig-ol-${slugify(c.city)}`, page({
    lang: "sv", altLang: "en", altHref: enU, canonical: svU,
    title: `Uteservering med billig öl i ${c.city} – ${hits.length} ställen`,
    desc: `${hits.length} barer i ${c.city} med uteservering och inrapporterat ölpris. Billigast: ${esc(lo.venue)}, ${kr(lo.price)} för stor stark. Uppdaterad ${updatedSv}.`,
    kicker: `Uteservering · ${c.city}`,
    h1: `Uteservering med billig öl i ${c.city}`,
    switcher: crumbs("sv", `Uteservering i ${c.city}`).html,
    jsonld: [...ldFor(`Uteservering med billig öl i ${c.city}`, svU, "sv"),
             crumbs("sv", `Uteservering i ${c.city}`).ld],
    body: `
  <p class="lede">Sol i ansiktet och en stor stark som inte kostar skjortan: vi har <strong>${hits.length} barer</strong> i ${c.city} med uteservering och ett inrapporterat 40 cl-pris. Billigast är ${esc(lo.venue)} på ${kr(lo.price)}.</p>
  <p class="stamp">Uppdaterad ${updatedSv}</p>
  ${figs([[String(hits.length), "barer med uteservering"], [kr(lo.price), "billigast"],
          [kr(outMed ?? 0), "median ute"], [`${share} %`, "av stadens prissatta barer"]])}
  ${svCaveat}
  <h2>Billigast öl med uteservering i ${c.city}</h2>
  ${priceTable(hits.slice(0, 25), "sv", false)}
  ${tableNote("sv", Math.min(25, hits.length), hits.length, kr(outMed ?? 0))}
  ${mapCta("sv", c)}
  <h2>Kostar det mer att sitta ute?</h2>
  <p>${outMed && c.median40
    ? (Math.abs(outMed - c.median40) < 2
       ? `Nej — medianen bland uteserveringsbarerna är ${kr(outMed)}, i praktiken samma som stadens median på ${kr(c.median40)}. Uteservering är ingen prispremie i ${c.city}.`
       : outMed > c.median40
         ? `Något: medianen bland barerna med uteservering är ${kr(outMed)}, mot ${kr(c.median40)} för staden i stort — ${kr(outMed - c.median40)} mer.`
         : `Faktiskt tvärtom: medianen bland uteserveringsbarerna är ${kr(outMed)}, ${kr(c.median40 - outMed)} under stadens median på ${kr(c.median40)}.`)
    : `Vi har för få prisrapporter för att svara säkert ännu.`}</p>
  <p>Vill du veta om terrassen har sol just nu? <a href="${SITE}/map/">Solkartan</a> räknar ut var solen står och vilka uteserveringar som ligger i den, timme för timme.</p>
  <p>Se även <a href="${SITE}/blogg/billig-ol-${slugify(c.city)}/">billigaste ölen i ${c.city}</a>.</p>
  <h2>Andra städer</h2>
  ${cityLinks("sv", c.city)}
`,
  }));

  write(`blog/outdoor-seating-cheap-beer-${slugify(en)}`, page({
    lang: "en", altLang: "sv", altHref: svU, canonical: enU,
    title: `Outdoor Seating and Cheap Beer in ${en} — ${hits.length} Places`,
    desc: `${hits.length} bars in ${en} with outdoor seating and a reported beer price. Cheapest: ${esc(lo.venue)} at ${kr(lo.price)} for a large draught. Updated ${updatedEn}.`,
    kicker: `Outdoor seating · ${en}`,
    h1: `Outdoor seating and cheap beer in ${en}`,
    switcher: crumbs("en", `Outdoor seating in ${en}`).html,
    jsonld: [...ldFor(`Outdoor seating and cheap beer in ${en}`, enU, "en"),
             crumbs("en", `Outdoor seating in ${en}`).ld],
    body: `
  <p class="lede">Sun on your face and a pint that doesn't sting: we have <strong>${hits.length} bars</strong> in ${en} with outdoor seating and a reported 40 cl price. The cheapest is ${esc(lo.venue)} at ${kr(lo.price)}.</p>
  <p class="stamp">Updated ${updatedEn}</p>
  ${figs([[String(hits.length), "bars with outdoor seating"], [kr(lo.price), "cheapest"],
          [kr(outMed ?? 0), "median outdoors"], [`${share}%`, "of the city's priced bars"]])}
  ${enCaveat}
  <h2>Cheapest beer with outdoor seating in ${en}</h2>
  ${priceTable(hits.slice(0, 25), "en", false)}
  ${tableNote("en", Math.min(25, hits.length), hits.length, kr(outMed ?? 0))}
  ${mapCta("en", c)}
  <h2>Does sitting outside cost more?</h2>
  <p>${outMed && c.median40
    ? (Math.abs(outMed - c.median40) < 2
       ? `No — the median among terrace bars is ${kr(outMed)}, effectively the same as the city median of ${kr(c.median40)}. Outdoor seating carries no price premium in ${en}.`
       : outMed > c.median40
         ? `Slightly: the median among bars with outdoor seating is ${kr(outMed)}, against ${kr(c.median40)} citywide — ${kr(outMed - c.median40)} more.`
         : `The opposite, in fact: the median among terrace bars is ${kr(outMed)}, ${kr(c.median40 - outMed)} under the city median of ${kr(c.median40)}.`)
    : `We hold too few reports to answer confidently yet.`}</p>
  <p>Want to know whether the terrace is in the sun right now? The <a href="${SITE}/map/">sun map</a> computes where the sun stands and which terraces sit in it, hour by hour.</p>
  <p>See also <a href="${SITE}/blog/cheapest-beer-${slugify(en)}/">cheapest beer in ${en}</a>.</p>
  <h2>Other cities</h2>
  ${cityLinks("en", c.city)}
`,
  }));
}

console.log('\noutdoor seating pages:');
for (const [c, hits] of outCities) console.log(`  written   outdoor in ${c.city}: ${hits.length} bars`);
for (const [c, hits] of outSkipped) console.log(`  SKIPPED  outdoor in ${c.city}: ${hits.length} bars (< ${MIN_OUT})`);

// ---------------------------------------------------------------- hubs

for (const lang of ["sv", "en"]) {
  const sv = lang === "sv";
  const url = sv ? `${SITE}/blogg/` : `${SITE}/blog/`;
  const alt = sv ? `${SITE}/blog/` : `${SITE}/blogg/`;
  write(sv ? "blogg" : "blog", page({
    lang, altLang: sv ? "en" : "sv", altHref: alt, canonical: url,
    title: sv ? "Ölpriser i Sverige – stad för stad | Sejdel" : "Beer prices in Sweden, city by city | Sejdel",
    desc: sv
      ? `Vad kostar ölen där du bor? Inrapporterade priser från ${national.bars} barer i ${cities.length} städer.`
      : `What does beer cost where you are? Reported prices from ${national.bars} bars across ${cities.length} Swedish cities.`,
    kicker: sv ? "Blogg" : "Blog",
    h1: sv ? "Vad kostar ölen?" : "What does beer cost?",
    jsonld: null,
    body: `
  <p class="lede">${sv
    ? `Vi samlar in ölpriser från barer i hela Sverige och jämför dem per centiliter, inte per glas. Just nu ${national.bars} barer i ${cities.length} städer.`
    : `We collect beer prices from bars across Sweden and compare them per centilitre rather than per glass. Currently ${national.bars} bars across ${cities.length} cities.`}</p>
  <p class="stamp">${sv ? "Uppdaterad" : "Updated"} ${sv ? updatedSv : updatedEn}</p>
  <h2>${sv ? "Hela Sverige" : "All of Sweden"}</h2>
  <ul class="chips">
    <li><a href="${sv ? svNatUrl : enNatUrl}">${sv ? "Billigaste ölen i Sverige" : "Beer prices in Sweden"}</a></li>
    <li><a href="${sv ? `${SITE}/blogg/happy-hour-sverige/` : `${SITE}/blog/happy-hour-sweden/`}">${sv ? "Happy hour i Sverige" : "Happy hour in Sweden"}</a></li>
  </ul>
  <h2>${sv ? "Välj din stad" : "Pick your city"}</h2>
  <p>${sv
    ? "Varje stad har sin egen prissida. Städer med tillräckligt mycket data har också listor för öl under 50 och 60 kr, uteserveringar med billig öl och happy hour."
    : "Every city has its own price page. Cities with enough data also get lists for beer under 50 and 60 kr, outdoor seating with cheap beer, and happy hour."}</p>
  <div class="citygrid">
    ${cities.map((c) => {
      const nm = sv ? c.city : (EN_NAME[c.city] || c.city);
      const cityHref = sv ? `${SITE}/blogg/billig-ol-${slugify(c.city)}/`
                          : `${SITE}/blog/cheapest-beer-${slugify(EN_NAME[c.city] || c.city)}/`;
      const meta = sv
        ? `${c.bars} barer · från ${kr(c.cheapest40 ?? c.median40)}`
        : `${c.bars} bars · from ${kr(c.cheapest40 ?? c.median40)}`;
      const links = variantLinks(lang, c.city, null)
        || `<ul class="chips"><li><a href="${cityHref}">${sv ? "Alla ölpriser" : "All beer prices"}</a></li></ul>`;
      return `<div class="citycard">
      <h3><a class="cityname" href="${cityHref}">${esc(nm)}</a></h3>
      <p class="meta">${esc(meta)}</p>
      ${links}
    </div>`;
    }).join("\n")}
  </div>
  <!--INTL:START--><!--INTL:END-->
  ${mapCta(lang)}
`,
  }));
}


// ------------------------------------------------- homepage stats block
//
// The homepage teases these figures, and hand-written they drifted from the
// articles the moment a price changed. The generator owns them now.
{
  const idx = join(ROOT, "index.html");
  let html = readFileSync(idx, "utf8");
  const byRate = [...cities].sort((a, b) => a.medianRate - b.medianRate);
  const cheapest = byRate[0];
  const stockholm = cities.find((c) => c.city === "Stockholm");
  const widest = [...cities].sort((a, b) => b.worstRate / b.bestRate - a.worstRate / a.bestRate)[0];
  const names = cities.map((c) => EN_NAME[c.city] || c.city).join(", ");
  const vsRef = stockholm && stockholm !== cheapest
    ? ` against ${EN_NAME[stockholm.city] || stockholm.city}'s ${perCl(stockholm.medianRate)} — about ${(((stockholm.medianRate / cheapest.medianRate) - 1) * 100).toFixed(0)}% less for the same beer.`
    : ".";
  const block = `<!--BEERSTATS:START-->
        <ul class="plist">
          <li><b>${esc(EN_NAME[cheapest.city] || cheapest.city)} is the cheapest city we cover.</b> <span>A median of ${perCl(cheapest.medianRate)}${vsRef}</span></li>
          <li><b>${esc(EN_NAME[widest.city] || widest.city)} has the widest spread.</b> <span>${perCl(widest.bestRate)} to ${perCl(widest.worstRate)}, so where you drink matters more than which city you are in.</span></li>
          <li><b>${cities.length} cities, both languages.</b> <span>${esc(names)}.</span></li>
          <li><b><a href="./blog/what-does-beer-cost-around-the-world-reddit/">What does beer cost around the world? →</a></b> <span>The same comparison for every country we cover, in the local language and English.</span></li>
        </ul>
        <!--BEERSTATS:END-->`;
  const re = /<!--BEERSTATS:START-->[\s\S]*?<!--BEERSTATS:END-->/;
  if (re.test(html)) {
    writeFileSync(idx, html.replace(re, block));
    console.log("homepage stats block refreshed");
  } else {
    console.warn("WARNING: BEERSTATS markers not found in docs/index.html — homepage figures NOT refreshed");
  }
}

// ---------------------------------------------------------------- sitemap

const base = [
  `${SITE}/`, `${SITE}/map/`, `${SITE}/calculator/`,
  `${SITE}/pricing/`, `${SITE}/privacy/`, `${SITE}/terms/`,
];
const urls = [...base, ...written];
writeFileSync(join(ROOT, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n`
  + urls.map((u) => `  <url><loc>${u}</loc><lastmod>${updated}</lastmod></url>`).join("\n")
  + `\n</urlset>\n`);

console.log(`cities: ${cities.length} (>= ${MIN_BARS} bars)`);
console.log(`pages : ${written.length}`);
console.log(`sitemap: ${urls.length} urls`);
console.log(`\ncheapest: ${cheapCity.city} ${perCl(cheapCity.medianRate)}   dearest: ${dearCity.city} ${perCl(dearCity.medianRate)}`);
console.log(`national median: ${perCl(national.medianRate)} (~${kr(national.medianRate * 40)} per 40 cl)`);
