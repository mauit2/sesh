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
const SITE = "https://seshapp.xyz";

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

const [prices, venues] = await Promise.all([rpc("public_beer_prices"), allVenues()]);
const cityOf = new Map(venues.map((v) => [v.id, v.city]));

const rows = prices
  .map((p) => ({
    venue: p.venue_name,
    city: cityOf.get(p.venue_id) || null,
    lat: p.lat, lon: p.lon,
    serving: p.serving,
    price: Number(p.price),
    cl: CL[p.serving] ?? null,
    reports: p.report_count,
    currency: p.currency,
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
    // Best value per centilitre, any size — the angle nobody else publishes.
    topValue: [...list].sort((a, b) => a.price / a.cl - b.price / b.cl).slice(0, 8),
  };
}

const cities = [...byCity.entries()]
  .map(([city, list]) => ({ city, ...summarise(list) }))
  .filter((c) => c.bars >= MIN_BARS)
  .sort((a, b) => b.bars - a.bars);

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
<meta property="og:site_name" content="Sesh" />
<meta name="twitter:card" content="summary" />
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%23140f0b'/%3E%3Cpath d='M9 11h14v13a3 3 0 0 1-3 3h-8a3 3 0 0 1-3-3z' fill='%23e8843c'/%3E%3Crect x='9' y='9' width='14' height='4' rx='2' fill='%23f3e9d8'/%3E%3C/svg%3E" />
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
  /* nowrap + a clamped size: "0.91 kr/cl" wrapped onto two lines at 26px and
     knocked the card grid out of alignment. */
  .fig b{display:block;font-family:"Fraunces",Georgia,serif;font-size:clamp(19px,4.4vw,26px);
    font-weight:900;letter-spacing:-.02em;line-height:1.15;white-space:nowrap;}
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
  .cta{display:block;margin:34px 0;padding:19px 22px;background:var(--bg-elev);border:1px solid rgba(232,132,60,.34);border-radius:17px;text-decoration:none;color:var(--cream);}
  .cta b{display:block;font-family:"Fraunces",Georgia,serif;font-size:19px;font-weight:800;margin-bottom:3px;}
  .cta span{font-size:14px;color:var(--cream-dim);}
  .chips{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0 0;padding:0;list-style:none;}
  .chips a{display:inline-block;font-size:13.5px;font-weight:600;text-decoration:none;color:var(--cream);
    background:var(--bg-elev);border:1px solid var(--line);border-radius:999px;padding:7px 13px;}
  footer{margin-top:56px;padding-top:22px;border-top:1px solid var(--line);font-size:12.5px;color:var(--bronze);}
  footer a{color:var(--bronze);}
</style>
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld)}</script>` : ""}
</head>
<body>
<div class="wrap">
  <header class="top">
    <a class="brand" href="${SITE}/">Sesh<span>.</span></a>
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
      ? `Sidan är avsedd för dig som är över 18 år. Priserna är inrapporterade av användare och visas som medianen av de senaste rapporterna per bar och storlek. Sesh ger ingen garanti för att ett pris gäller när du kommer dit — <a href="${SITE}/map/">rapportera gärna en ändring</a>. Drick måttfullt.`
      : `This page is intended for readers of legal drinking age. Prices are reported by users and shown as the median of recent reports per bar and size. Sesh cannot guarantee a price still stands when you arrive — <a href="${SITE}/map/">report a change</a> if it has moved. Please drink responsibly.`}
    <br /><br />
    <a href="${SITE}/">Sesh</a> · <a href="${SITE}/map/">${lang === "sv" ? "Ölkartan" : "Beer map"}</a>
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
    const href = `${SITE}/map/?lat=${(r.lat ?? 0).toFixed(5)}&lon=${(r.lon ?? 0).toFixed(5)}&city=${encodeURIComponent(r.city)}`;
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

function figs(items) {
  return `<div class="figs">${items.map(([v, l]) =>
    `<div class="fig"><b>${esc(v)}</b><span>${esc(l)}</span></div>`).join("")}</div>`;
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

const switcher = (lang, current) => `<ul class="switch">${cities.map((c) => {
  const nm = lang === "sv" ? c.city : (EN_NAME[c.city] || c.city);
  const href = lang === "sv"
    ? `${SITE}/blogg/billig-ol-${slugify(c.city)}/`
    : `${SITE}/blog/cheapest-beer-${slugify(EN_NAME[c.city] || c.city)}/`;
  return `<li><a class="${c.city === current ? "on" : ""}" href="${href}">${esc(nm)}</a></li>`;
}).join("")}</ul>`;

const mapCta = (lang, c) => `<a class="cta" href="${SITE}/map/${c ? `?lat=${c.lat.toFixed(5)}&lon=${c.lon.toFixed(5)}&city=${encodeURIComponent(c.city)}` : ""}">
    <b>${lang === "sv" ? "Se alla priser på kartan" : "See every price on the map"}</b>
    <span>${lang === "sv"
      ? "Zooma in på din stad, filtrera på storlek och se vilka barer som har sol just nu."
      : "Zoom to your city, filter by size, and see which bars are in the sun right now."}</span>
  </a>`;

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
    publisher: { "@type": "Organization", name: "Sesh", url: SITE },
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
    switcher: switcher("sv", c.city),
    jsonld: ld(`Billigaste ölen i ${c.city}`, svUrl, `Ölpriser i ${c.city}`),
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

  <h2>Så räknar vi</h2>
  <p>Priserna kommer från användare i Sesh-appen och på ölkartan. För varje bar och storlek visar vi <em>medianen</em> av de senaste rapporterna, inte det senaste priset — ett enstaka felinmatat pris ska inte kunna styra listan. Bara priser i kronor och i storlekar vi kan räkna om per centiliter räknas med. Pint tolkas som 56,8 cl.</p>
  <p>Priser ändras och happy hour räknas inte in. Ser du ett pris som inte stämmer kan du <a href="${SITE}/map/">rapportera det på kartan</a> — det uppdaterar den här sidan nästa gång den byggs.</p>

  <h2>Ölpriser i andra städer</h2>
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
    switcher: switcher("en", c.city),
    jsonld: ld(`Cheapest beer in ${en}`, enUrl, `Beer prices in ${en}`),
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

  <h2>How we work it out</h2>
  <p>Prices come from Sesh users in the app and on the beer map. For each bar and size we show the <em>median</em> of recent reports rather than the latest one, so a single mistyped price cannot swing a table. Only prices in kronor, in sizes we can convert per centilitre, are included; a pint is treated as 56.8 cl.</p>
  <p>Prices change, and happy hour is not counted. If something looks wrong you can <a href="${SITE}/map/">report it on the map</a>, which updates this page the next time it is built.</p>

  <h2>Beer prices in other cities</h2>
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
const svNatUrl = `${SITE}/blogg/billig-ol-sverige/`;
const enNatUrl = `${SITE}/blog/beer-prices-sweden/`;

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
    publisher: { "@type": "Organization", name: "Sesh", url: SITE },
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
  <p>Priserna rapporteras av användare i Sesh. Per bar och storlek visas medianen av de senaste rapporterna. Bara priser i kronor räknas med, och pint tolkas som 56,8 cl. Städer med färre än ${MIN_BARS} barer får ingen egen sida — underlaget blir för tunt för att vara användbart.</p>

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
    publisher: { "@type": "Organization", name: "Sesh", url: SITE },
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
  <p>Prices are reported by Sesh users. For each bar and size we show the median of recent reports. Only prices in kronor are included, and a pint is treated as 56.8 cl. Cities with fewer than ${MIN_BARS} bars do not get their own page — the sample is too thin to be useful.</p>

  <h2>Cities</h2>
  ${cityLinks("en", null)}
`,
}));

// ---------------------------------------------------------------- hubs

for (const lang of ["sv", "en"]) {
  const sv = lang === "sv";
  const url = sv ? `${SITE}/blogg/` : `${SITE}/blog/`;
  const alt = sv ? `${SITE}/blog/` : `${SITE}/blogg/`;
  write(sv ? "blogg" : "blog", page({
    lang, altLang: sv ? "en" : "sv", altHref: alt, canonical: url,
    title: sv ? "Ölpriser i Sverige – stad för stad | Sesh" : "Beer prices in Sweden, city by city | Sesh",
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
  <h2>${sv ? "Hela landet" : "Nationwide"}</h2>
  <ul class="chips"><li><a href="${sv ? svNatUrl : enNatUrl}">${sv ? "Billigaste ölen i Sverige" : "Beer prices in Sweden"}</a></li></ul>
  <h2>${sv ? "Städer" : "Cities"}</h2>
  ${cityLinks(lang, null)}
  ${mapCta(lang)}
`,
  }));
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
