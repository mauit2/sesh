// gen-blog-intl.mjs — beer-price articles for every country beyond Sweden.
//
// Same idea as gen-blog.mjs (which owns the Swedish + national pages): pages
// are generated from the same public RPC the map reads, so the numbers always
// agree with the map. This script adds, per qualifying city outside Sweden:
//
//   - "Where is the cheapest beer in {city}?"        (local language + English)
//   - "Beer under {N} {currency} in {city}"           (thresholds per currency)
//   - "Outdoor seating with cheap beer in {city}"
//
// SLUGS ARE QUERIES. These URLs are written the way people phrase the
// question to a search box or an LLM ("where is the cheapest beer in new
// york"), because URL + title matching the literal question is what earns
// the citation. The flagship page also carries the "-reddit" suffix — the
// single highest-volume query appender — on the English variant only, so the
// site doesn't read as keyword-stuffed wall to wall.
//
// LANGUAGES. Each country publishes in its local language plus an English
// twin (hreflang-paired); English-native countries publish English only.
// Multilingual countries pick per city (Geneva French, Zurich German …).
//
// RUN ORDER: after gen-blog.mjs. That script rewrites docs/sitemap.xml from
// scratch; this one appends its URLs to it.
//
// Run:  SUPA_ANON=... node scripts/gen-blog-intl.mjs

import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";

const SB = "https://lltuozmbxacxiepardys.supabase.co/rest/v1";
const KEY = process.env.SUPA_ANON;
if (!KEY) { console.error("SUPA_ANON not set"); process.exit(1); }
const HERE = dirname(new URL(import.meta.url).pathname);
const ROOT = join(HERE, "..", "docs");
const SITE = "https://sejdel.com";

const MIN_BARS = 5;    // a city page below this is too thin to publish
const MIN_UNDER = 5;   // "beer under N" needs this many qualifying bars
const MIN_OUT = 5;     // an outdoor page (terrace data is sparser abroad)
const TABLE_CAP = 15;

// Representative centilitres per serving. 47.3 is the US 16 oz pint.
const CL = { "25": 25, "33": 33, "40": 40, "47.3": 47.3, "50": 50, pint: 56.8 };

// ---------------------------------------------------------------- countries
//
// currency, symbol placement, "under N" thresholds, primary language(s) and
// per-city overrides for the multilingual countries. Countries with no data
// simply produce no pages, so TH/SG/HK are ready for the day they fill in.
const COUNTRIES = {
  US: { cur: "USD", sym: "$",   pre: true,  th: [5, 6],    langs: ["en"], name: { en: "United States" } },
  GB: { cur: "GBP", sym: "£",   pre: true,  th: [5, 6],    langs: ["en"], name: { en: "United Kingdom" } },
  CA: { cur: "CAD", sym: "$",   pre: true,  th: [6, 8],    langs: ["en"],
        cityLang: { "montreal": "fr", "montréal": "fr", "quebec": "fr", "québec": "fr" },
        name: { en: "Canada", fr: "Canada" } },
  DE: { cur: "EUR", sym: "€",   pre: false, th: [5, 6],    langs: ["de"], name: { en: "Germany", de: "Deutschland" } },
  ES: { cur: "EUR", sym: "€",   pre: false, th: [3, 5],    langs: ["es"], name: { en: "Spain", es: "España" } },
  IT: { cur: "EUR", sym: "€",   pre: false, th: [5, 6],    langs: ["it"], name: { en: "Italy", it: "Italia" } },
  NL: { cur: "EUR", sym: "€",   pre: false, th: [5, 6],    langs: ["nl"], name: { en: "Netherlands", nl: "Nederland" } },
  BE: { cur: "EUR", sym: "€",   pre: false, th: [5, 6],    langs: ["nl"],
        cityLang: { "brussels": "fr", "bruxelles": "fr", "liege": "fr", "liège": "fr", "namur": "fr", "charleroi": "fr" },
        name: { en: "Belgium", nl: "België", fr: "Belgique" } },
  PT: { cur: "EUR", sym: "€",   pre: false, th: [3, 5],    langs: ["pt"], name: { en: "Portugal", pt: "Portugal" } },
  FR: { cur: "EUR", sym: "€",   pre: false, th: [5, 6],    langs: ["fr"], name: { en: "France", fr: "France" } },
  BR: { cur: "BRL", sym: "R$",  pre: true,  th: [10, 15],  langs: ["pt"], name: { en: "Brazil", pt: "Brasil" } },
  CH: { cur: "CHF", sym: "CHF ",pre: true,  th: [6, 7],    langs: ["de"],
        cityLang: { "geneva": "fr", "genève": "fr", "lausanne": "fr", "lugano": "it" },
        name: { en: "Switzerland", de: "Schweiz", fr: "Suisse", it: "Svizzera" } },
  TH: { cur: "THB", sym: "฿",   pre: true,  th: [100, 150],langs: ["en"], name: { en: "Thailand" } },
  SG: { cur: "SGD", sym: "S$",  pre: true,  th: [8, 10],   langs: ["en"], name: { en: "Singapore" } },
  HK: { cur: "HKD", sym: "HK$", pre: true,  th: [50, 60],  langs: ["zh"], name: { en: "Hong Kong", zh: "香港" } },
};

// What the currency is called inside a slug, per language.
const CUR_WORD = {
  en: { USD: "dollars", GBP: "pounds", EUR: "euros", CHF: "francs", CAD: "dollars", BRL: "reais", THB: "baht", SGD: "dollars", HKD: "dollars" },
  de: { EUR: "euro", CHF: "franken" },
  fr: { EUR: "euros", CHF: "francs", CAD: "dollars" },
  es: { EUR: "euros" },
  pt: { EUR: "euros", BRL: "reais" },
  it: { EUR: "euro", CHF: "franchi" },
  nl: { EUR: "euro" },
  zh: { HKD: "hkd" },
};

const slugify = (s) => String(s).normalize("NFD").replace(/[̀-ͯ]/g, "")
  .toLowerCase().replace(/ø/g, "o").replace(/æ/g, "ae").replace(/ß/g, "ss")
  .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// Query-shaped slugs, per language. {c}=city slug, {n}=threshold, {w}=currency word.
const SLUG = {
  en: { cheap: (c) => `where-is-the-cheapest-beer-in-${c}-reddit`,
        under: (n, w, c) => `beer-under-${n}-${w}-in-${c}-reddit`,
        out:   (c) => `best-outdoor-seating-cheap-beer-in-${c}-reddit` },
  de: { cheap: (c) => `wo-ist-das-bier-am-guenstigsten-in-${c}`,
        under: (n, w, c) => `bier-unter-${n}-${w}-${c}`,
        out:   (c) => `biergarten-guenstiges-bier-${c}` },
  fr: { cheap: (c) => `ou-boire-une-biere-pas-chere-a-${c}`,
        under: (n, w, c) => `biere-a-moins-de-${n}-${w}-${c}`,
        out:   (c) => `terrasse-biere-pas-chere-${c}` },
  es: { cheap: (c) => `donde-esta-la-cerveza-mas-barata-en-${c}`,
        under: (n, w, c) => `cerveza-por-menos-de-${n}-${w}-${c}`,
        out:   (c) => `terrazas-cerveza-barata-${c}` },
  pt: { cheap: (c) => `onde-fica-a-cerveja-mais-barata-em-${c}`,
        under: (n, w, c) => `cerveja-por-menos-de-${n}-${w}-${c}`,
        out:   (c) => `esplanadas-cerveja-barata-${c}` },
  it: { cheap: (c) => `dove-costa-meno-la-birra-a-${c}`,
        under: (n, w, c) => `birra-sotto-i-${n}-${w}-${c}`,
        out:   (c) => `birra-economica-all-aperto-${c}` },
  nl: { cheap: (c) => `waar-is-bier-goedkoop-in-${c}`,
        under: (n, w, c) => `bier-onder-de-${n}-${w}-${c}`,
        out:   (c) => `terras-goedkoop-bier-${c}` },
  zh: { cheap: (c) => `cheapest-beer-${c}`,
        under: (n, w, c) => `beer-under-${n}-${w}-${c}`,
        out:   (c) => `outdoor-cheap-beer-${c}` },
};

// ---------------------------------------------------------------- strings
//
// Every user-visible sentence, per language. Values are functions where the
// city's numbers are stamped in. English is the reference copy.
const SERVING_LABEL = { "25": "25 cl", "33": "33 cl", "40": "40 cl", "47.3": "16 oz", "50": "50 cl", pint: "pint" };

const L = {
  en: {
    updatedLocale: "en-GB", blogName: "Beer prices", navMap: "Map", navBlog: "Blog",
    servingUnknown: "size not stated",
    kicker: (country) => `Beer prices · ${country}`,
    cheapTitle: (city, bars) => `Where is the cheapest beer in ${city}? ${bars} bars compared | Sejdel`,
    cheapH1: (city) => `Where is the cheapest beer in ${city}?`,
    cheapDesc: (city, bars, low) => `Reported beer prices from ${bars} bars in ${city}, ranked cheapest first — from ${low}. Updated from live crowd data.`,
    cheapLede: (city, bars, low) => `We collect beer prices reported at bars in ${city} and rank them by each bar's cheapest pour. Right now ${bars} bars, starting at ${low}.`,
    underTitle: (n, city, count) => `Beer under ${n} in ${city} — ${count} bars | Sejdel`,
    underH1: (n, city) => `Beer under ${n} in ${city}`,
    underDesc: (n, city, count) => `${count} bars in ${city} where a beer costs ${n} or less, ranked cheapest first. From live reported prices.`,
    underLede: (n, city, count) => `Every bar below has at least one beer at ${n} or less — ${count} of them right now, cheapest first.`,
    outTitle: (city, count) => `Outdoor seating with cheap beer in ${city} — ${count} spots | Sejdel`,
    outH1: (city) => `Outdoor seating with cheap beer in ${city}`,
    outDesc: (city, count) => `${count} bars in ${city} with outdoor seating, ranked by their cheapest beer. From live reported prices.`,
    outLede: (city, count) => `Bars in ${city} with a terrace or outdoor tables, ranked by their cheapest pour — ${count} right now.`,
    updated: "Updated", bars: "bars with prices", cheapest: "cheapest beer", medianL: "city median", bestValue: "best value",
    thBar: "Bar", thSize: "Size", thPrice: "Price", thPerCl: "Per cl",
    legend: ["well below the city median", "below median", "above median", "well above median"],
    tableNote: (shown, total) => `Showing the ${shown} cheapest of ${total} bars. The median is computed over all ${total}.`,
    caveat: `<b>How this list is made.</b> Prices are reported by people in the bar and shown as the median of recent reports per bar. A price can change before we hear about it — if one has, report it on the map and the page corrects itself at the next daily rebuild.`,
    ctaB: "See every price on the map", ctaS: "Zoom to your city, filter by size, and see which terraces are in the sun right now.",
    faqT: "Frequently asked questions",
    faq: (city, bar, price, med, date) => [
      [`Where is the cheapest beer in ${city}?`,
       `${bar.venue} has the lowest price reported to us: ${price} (${bar.sizeLabel}).`],
      [`How much does a beer cost in ${city}?`,
       `The median across every bar we track in ${city} is ${med}, counting each bar's cheapest pour.`],
      [`How current are these prices?`,
       `The page is rebuilt daily from the latest reports — this version is from ${date}. Each bar shows the median of its recent reports, not a one-off sighting.`],
      [`Can I report a price myself?`,
       `Yes — find the bar on the Sejdel beer map and add what you paid. It shows on the map immediately and here at the next rebuild.`]],
    otherCities: "More cities", allPages: "All beer prices", underChip: (n) => `Under ${n}`, outChip: "Outdoor seating",
    footer: `This page is intended for readers of legal drinking age. Prices are reported by users and shown as the median of recent reports per bar. Sejdel cannot guarantee a price still stands when you arrive — <a href="${SITE}/map/">report a change</a> if it has moved. Please drink responsibly.`,
    hubTitle: (country) => `How much is a beer in ${country}? City-by-city prices | Sejdel`,
    hubH1: (country) => `How much is a beer in ${country}?`,
    hubLede: (country, bars, cities) => `Reported beer prices from ${bars} bars across ${country}, with city pages for the ${cities} busiest ${cities === 1 ? "city" : "cities"} — the rest are on the map.`,
    hubPick: "Pick your city", langName: "English",
  },
  de: {
    updatedLocale: "de-DE", blogName: "Bierpreise", navMap: "Karte", navBlog: "Blog",
    servingUnknown: "Größe unbekannt",
    kicker: (country) => `Bierpreise · ${country}`,
    cheapTitle: (city, bars) => `Wo ist das Bier am günstigsten in ${city}? ${bars} Bars im Vergleich | Sejdel`,
    cheapH1: (city) => `Wo ist das Bier am günstigsten in ${city}?`,
    cheapDesc: (city, bars, low) => `Gemeldete Bierpreise aus ${bars} Bars in ${city}, vom günstigsten aufwärts — ab ${low}. Täglich aktualisiert.`,
    cheapLede: (city, bars, low) => `Wir sammeln gemeldete Bierpreise aus Bars in ${city} und sortieren nach dem günstigsten Bier jeder Bar. Aktuell ${bars} Bars, ab ${low}.`,
    underTitle: (n, city, count) => `Bier unter ${n} in ${city} — ${count} Bars | Sejdel`,
    underH1: (n, city) => `Bier unter ${n} in ${city}`,
    underDesc: (n, city, count) => `${count} Bars in ${city}, in denen ein Bier höchstens ${n} kostet — vom günstigsten aufwärts.`,
    underLede: (n, city, count) => `Jede Bar unten hat mindestens ein Bier für ${n} oder weniger — aktuell ${count}, das günstigste zuerst.`,
    outTitle: (city, count) => `Biergarten & Außenplätze mit günstigem Bier in ${city} — ${count} Adressen | Sejdel`,
    outH1: (city) => `Draußen sitzen, günstig trinken: ${city}`,
    outDesc: (city, count) => `${count} Bars in ${city} mit Außenplätzen, sortiert nach ihrem günstigsten Bier.`,
    outLede: (city, count) => `Bars in ${city} mit Terrasse oder Außenplätzen, sortiert nach dem günstigsten Bier — aktuell ${count}.`,
    updated: "Aktualisiert", bars: "Bars mit Preisen", cheapest: "günstigstes Bier", medianL: "Stadt-Median", bestValue: "bestes Preis-Verhältnis",
    thBar: "Bar", thSize: "Größe", thPrice: "Preis", thPerCl: "Pro cl",
    legend: ["deutlich unter dem Stadt-Median", "unter dem Median", "über dem Median", "deutlich darüber"],
    tableNote: (shown, total) => `Die ${shown} günstigsten von ${total} Bars. Der Median wird über alle ${total} berechnet.`,
    caveat: `<b>So entsteht diese Liste.</b> Die Preise werden von Gästen gemeldet und als Median der letzten Meldungen pro Bar angezeigt. Ein Preis kann sich ändern, bevor wir davon erfahren — melde es auf der Karte, und die Seite korrigiert sich beim nächsten täglichen Neuaufbau.`,
    ctaB: "Alle Preise auf der Karte", ctaS: "Zoome in deine Stadt, filtere nach Größe und sieh, welche Terrassen gerade Sonne haben.",
    faqT: "Häufige Fragen",
    faq: (city, bar, price, med, date) => [
      [`Wo ist das Bier am günstigsten in ${city}?`,
       `${bar.venue} hat den niedrigsten gemeldeten Preis: ${price} (${bar.sizeLabel}).`],
      [`Was kostet ein Bier in ${city}?`,
       `Der Median über alle erfassten Bars in ${city} liegt bei ${med}, gerechnet auf das günstigste Bier jeder Bar.`],
      [`Wie aktuell sind die Preise?`,
       `Die Seite wird täglich aus den neuesten Meldungen neu gebaut — diese Version ist vom ${date}.`],
      [`Kann ich selbst einen Preis melden?`,
       `Ja — such die Bar auf der Sejdel-Bierkarte und trag ein, was du bezahlt hast. Auf der Karte erscheint es sofort, hier beim nächsten Neuaufbau.`]],
    otherCities: "Weitere Städte", allPages: "Alle Bierpreise", underChip: (n) => `Unter ${n}`, outChip: "Außenplätze",
    footer: `Diese Seite richtet sich an Leser im gesetzlichen Mindestalter. Die Preise stammen von Nutzern und werden als Median der letzten Meldungen pro Bar angezeigt. Sejdel übernimmt keine Garantie — <a href="${SITE}/map/">melde eine Änderung</a>, wenn ein Preis nicht mehr stimmt. Bitte trinke verantwortungsvoll.`,
    hubTitle: (country) => `Bierpreise in ${country}, Stadt für Stadt | Sejdel`,
    hubH1: (country) => `Was kostet das Bier in ${country}?`,
    hubLede: (country, bars, cities) => `Gemeldete Bierpreise aus ${bars} Bars in ${cities} ${cities === 1 ? "Stadt" : "Städten"} in ${country}.`,
    hubPick: "Wähle deine Stadt", langName: "Deutsch",
  },
  fr: {
    updatedLocale: "fr-FR", blogName: "Prix de la bière", navMap: "Carte", navBlog: "Blog",
    servingUnknown: "taille non précisée",
    kicker: (country) => `Prix de la bière · ${country}`,
    cheapTitle: (city, bars) => `Où boire une bière pas chère à ${city} ? ${bars} bars comparés | Sejdel`,
    cheapH1: (city) => `Où boire une bière pas chère à ${city} ?`,
    cheapDesc: (city, bars, low) => `Prix de la bière relevés dans ${bars} bars à ${city}, du moins cher au plus cher — à partir de ${low}.`,
    cheapLede: (city, bars, low) => `Nous collectons les prix relevés dans les bars de ${city} et les classons par la bière la moins chère de chaque bar. Actuellement ${bars} bars, à partir de ${low}.`,
    underTitle: (n, city, count) => `Bière à moins de ${n} à ${city} — ${count} bars | Sejdel`,
    underH1: (n, city) => `Bière à moins de ${n} à ${city}`,
    underDesc: (n, city, count) => `${count} bars à ${city} où une bière coûte ${n} ou moins, du moins cher au plus cher.`,
    underLede: (n, city, count) => `Chaque bar ci-dessous propose au moins une bière à ${n} ou moins — ${count} en ce moment.`,
    outTitle: (city, count) => `Terrasses avec bière pas chère à ${city} — ${count} adresses | Sejdel`,
    outH1: (city) => `En terrasse sans se ruiner : ${city}`,
    outDesc: (city, count) => `${count} bars avec terrasse à ${city}, classés par leur bière la moins chère.`,
    outLede: (city, count) => `Les bars de ${city} avec terrasse, classés par leur bière la moins chère — ${count} en ce moment.`,
    updated: "Mis à jour", bars: "bars avec prix", cheapest: "bière la moins chère", medianL: "médiane de la ville", bestValue: "meilleur rapport",
    thBar: "Bar", thSize: "Taille", thPrice: "Prix", thPerCl: "Par cl",
    legend: ["bien sous la médiane de la ville", "sous la médiane", "au-dessus de la médiane", "bien au-dessus"],
    tableNote: (shown, total) => `Les ${shown} moins chers sur ${total} bars. La médiane est calculée sur les ${total}.`,
    caveat: `<b>Comment cette liste est faite.</b> Les prix sont signalés par les clients et affichés comme médiane des derniers signalements par bar. Un prix peut changer avant qu'on le sache — signalez-le sur la carte et la page se corrige à la prochaine reconstruction quotidienne.`,
    ctaB: "Tous les prix sur la carte", ctaS: "Zoomez sur votre ville, filtrez par taille et voyez quelles terrasses sont au soleil.",
    faqT: "Questions fréquentes",
    faq: (city, bar, price, med, date) => [
      [`Où est la bière la moins chère à ${city} ?`,
       `${bar.venue} a le prix le plus bas signalé : ${price} (${bar.sizeLabel}).`],
      [`Combien coûte une bière à ${city} ?`,
       `La médiane sur tous les bars suivis à ${city} est de ${med}, sur la bière la moins chère de chaque bar.`],
      [`Ces prix sont-ils à jour ?`,
       `La page est reconstruite chaque jour à partir des derniers signalements — cette version date du ${date}.`],
      [`Puis-je signaler un prix ?`,
       `Oui — trouvez le bar sur la carte Sejdel et ajoutez ce que vous avez payé. Visible sur la carte immédiatement, ici à la prochaine reconstruction.`]],
    otherCities: "Autres villes", allPages: "Tous les prix", underChip: (n) => `Moins de ${n}`, outChip: "Terrasses",
    footer: `Cette page s'adresse aux lecteurs en âge légal de consommer de l'alcool. Les prix sont signalés par les utilisateurs et affichés comme médiane des derniers signalements par bar. Sejdel ne garantit pas qu'un prix soit toujours valable — <a href="${SITE}/map/">signalez un changement</a>. À consommer avec modération.`,
    hubTitle: (country) => `Prix de la bière en ${country}, ville par ville | Sejdel`,
    hubH1: (country) => `Combien coûte la bière en ${country} ?`,
    hubLede: (country, bars, cities) => `Prix relevés dans ${bars} bars répartis sur ${cities} ville${cities === 1 ? "" : "s"} en ${country}.`,
    hubPick: "Choisissez votre ville", langName: "Français",
  },
  es: {
    updatedLocale: "es-ES", blogName: "Precios de la cerveza", navMap: "Mapa", navBlog: "Blog",
    servingUnknown: "tamaño sin especificar",
    kicker: (country) => `Precios de la cerveza · ${country}`,
    cheapTitle: (city, bars) => `¿Dónde está la cerveza más barata en ${city}? ${bars} bares comparados | Sejdel`,
    cheapH1: (city) => `¿Dónde está la cerveza más barata en ${city}?`,
    cheapDesc: (city, bars, low) => `Precios de cerveza reportados en ${bars} bares de ${city}, del más barato al más caro — desde ${low}.`,
    cheapLede: (city, bars, low) => `Recogemos precios reportados en bares de ${city} y los ordenamos por la cerveza más barata de cada bar. Ahora mismo ${bars} bares, desde ${low}.`,
    underTitle: (n, city, count) => `Cerveza por menos de ${n} en ${city} — ${count} bares | Sejdel`,
    underH1: (n, city) => `Cerveza por menos de ${n} en ${city}`,
    underDesc: (n, city, count) => `${count} bares de ${city} donde una cerveza cuesta ${n} o menos, del más barato al más caro.`,
    underLede: (n, city, count) => `Cada bar de la lista tiene al menos una cerveza a ${n} o menos — ahora mismo ${count}.`,
    outTitle: (city, count) => `Terrazas con cerveza barata en ${city} — ${count} sitios | Sejdel`,
    outH1: (city) => `Terraza y cerveza barata: ${city}`,
    outDesc: (city, count) => `${count} bares con terraza en ${city}, ordenados por su cerveza más barata.`,
    outLede: (city, count) => `Bares de ${city} con terraza, ordenados por su cerveza más barata — ${count} ahora mismo.`,
    updated: "Actualizado", bars: "bares con precios", cheapest: "cerveza más barata", medianL: "mediana de la ciudad", bestValue: "mejor relación",
    thBar: "Bar", thSize: "Tamaño", thPrice: "Precio", thPerCl: "Por cl",
    legend: ["muy por debajo de la mediana", "por debajo de la mediana", "por encima de la mediana", "muy por encima"],
    tableNote: (shown, total) => `Los ${shown} más baratos de ${total} bares. La mediana se calcula sobre los ${total}.`,
    caveat: `<b>Cómo se hace esta lista.</b> Los precios los reporta la gente en el bar y se muestran como la mediana de los últimos reportes por bar. Un precio puede cambiar antes de que nos enteremos — repórtalo en el mapa y la página se corrige en la próxima reconstrucción diaria.`,
    ctaB: "Todos los precios en el mapa", ctaS: "Acércate a tu ciudad, filtra por tamaño y mira qué terrazas tienen sol ahora mismo.",
    faqT: "Preguntas frecuentes",
    faq: (city, bar, price, med, date) => [
      [`¿Dónde está la cerveza más barata en ${city}?`,
       `${bar.venue} tiene el precio más bajo reportado: ${price} (${bar.sizeLabel}).`],
      [`¿Cuánto cuesta una cerveza en ${city}?`,
       `La mediana de todos los bares que seguimos en ${city} es ${med}, contando la cerveza más barata de cada bar.`],
      [`¿Están al día estos precios?`,
       `La página se reconstruye a diario con los últimos reportes — esta versión es del ${date}.`],
      [`¿Puedo reportar un precio?`,
       `Sí — busca el bar en el mapa de Sejdel y añade lo que pagaste. Sale en el mapa al momento y aquí en la próxima reconstrucción.`]],
    otherCities: "Más ciudades", allPages: "Todos los precios", underChip: (n) => `Menos de ${n}`, outChip: "Terrazas",
    footer: `Esta página está pensada para lectores en edad legal de beber. Los precios los reportan los usuarios y se muestran como mediana de los últimos reportes por bar. Sejdel no garantiza que un precio siga vigente — <a href="${SITE}/map/">reporta un cambio</a>. Bebe con moderación.`,
    hubTitle: (country) => `Precios de la cerveza en ${country}, ciudad a ciudad | Sejdel`,
    hubH1: (country) => `¿Cuánto cuesta la cerveza en ${country}?`,
    hubLede: (country, bars, cities) => `Precios reportados en ${bars} bares de ${cities} ciudad${cities === 1 ? "" : "es"} de ${country}.`,
    hubPick: "Elige tu ciudad", langName: "Español",
  },
  pt: {
    updatedLocale: "pt-PT", blogName: "Preços da cerveja", navMap: "Mapa", navBlog: "Blog",
    servingUnknown: "tamanho não indicado",
    kicker: (country) => `Preços da cerveja · ${country}`,
    cheapTitle: (city, bars) => `Onde fica a cerveja mais barata em ${city}? ${bars} bares comparados | Sejdel`,
    cheapH1: (city) => `Onde fica a cerveja mais barata em ${city}?`,
    cheapDesc: (city, bars, low) => `Preços de cerveja reportados em ${bars} bares de ${city}, do mais barato ao mais caro — desde ${low}.`,
    cheapLede: (city, bars, low) => `Recolhemos preços reportados em bares de ${city} e ordenamos pela cerveja mais barata de cada bar. Neste momento ${bars} bares, desde ${low}.`,
    underTitle: (n, city, count) => `Cerveja por menos de ${n} em ${city} — ${count} bares | Sejdel`,
    underH1: (n, city) => `Cerveja por menos de ${n} em ${city}`,
    underDesc: (n, city, count) => `${count} bares em ${city} onde uma cerveja custa ${n} ou menos, do mais barato ao mais caro.`,
    underLede: (n, city, count) => `Cada bar abaixo tem pelo menos uma cerveja a ${n} ou menos — ${count} neste momento.`,
    outTitle: (city, count) => `Esplanadas com cerveja barata em ${city} — ${count} sítios | Sejdel`,
    outH1: (city) => `Esplanada e cerveja barata: ${city}`,
    outDesc: (city, count) => `${count} bares com esplanada em ${city}, ordenados pela cerveja mais barata.`,
    outLede: (city, count) => `Bares de ${city} com esplanada, ordenados pela cerveja mais barata — ${count} neste momento.`,
    updated: "Atualizado", bars: "bares com preços", cheapest: "cerveja mais barata", medianL: "mediana da cidade", bestValue: "melhor relação",
    thBar: "Bar", thSize: "Tamanho", thPrice: "Preço", thPerCl: "Por cl",
    legend: ["muito abaixo da mediana", "abaixo da mediana", "acima da mediana", "muito acima"],
    tableNote: (shown, total) => `Os ${shown} mais baratos de ${total} bares. A mediana é calculada sobre os ${total}.`,
    caveat: `<b>Como esta lista é feita.</b> Os preços são reportados por quem está no bar e mostrados como a mediana dos últimos reportes por bar. Um preço pode mudar antes de sabermos — reporta no mapa e a página corrige-se na próxima reconstrução diária.`,
    ctaB: "Todos os preços no mapa", ctaS: "Aproxima da tua cidade, filtra por tamanho e vê que esplanadas têm sol agora.",
    faqT: "Perguntas frequentes",
    faq: (city, bar, price, med, date) => [
      [`Onde fica a cerveja mais barata em ${city}?`,
       `${bar.venue} tem o preço mais baixo reportado: ${price} (${bar.sizeLabel}).`],
      [`Quanto custa uma cerveja em ${city}?`,
       `A mediana de todos os bares que seguimos em ${city} é ${med}, contando a cerveja mais barata de cada bar.`],
      [`Os preços estão atualizados?`,
       `A página é reconstruída diariamente a partir dos últimos reportes — esta versão é de ${date}.`],
      [`Posso reportar um preço?`,
       `Sim — procura o bar no mapa da Sejdel e adiciona o que pagaste. Aparece no mapa de imediato e aqui na próxima reconstrução.`]],
    otherCities: "Mais cidades", allPages: "Todos os preços", underChip: (n) => `Menos de ${n}`, outChip: "Esplanadas",
    footer: `Esta página destina-se a leitores com idade legal para beber. Os preços são reportados por utilizadores e mostrados como mediana dos últimos reportes por bar. A Sejdel não garante que um preço ainda se aplique — <a href="${SITE}/map/">reporta uma alteração</a>. Bebe com moderação.`,
    hubTitle: (country) => `Preços da cerveja em ${country}, cidade a cidade | Sejdel`,
    hubH1: (country) => `Quanto custa a cerveja em ${country}?`,
    hubLede: (country, bars, cities) => `Preços reportados em ${bars} bares de ${cities} cidade${cities === 1 ? "" : "s"} em ${country}.`,
    hubPick: "Escolhe a tua cidade", langName: "Português",
  },
  it: {
    updatedLocale: "it-IT", blogName: "Prezzi della birra", navMap: "Mappa", navBlog: "Blog",
    servingUnknown: "formato non indicato",
    kicker: (country) => `Prezzi della birra · ${country}`,
    cheapTitle: (city, bars) => `Dove costa meno la birra a ${city}? ${bars} bar a confronto | Sejdel`,
    cheapH1: (city) => `Dove costa meno la birra a ${city}?`,
    cheapDesc: (city, bars, low) => `Prezzi della birra segnalati in ${bars} bar a ${city}, dal più economico in su — da ${low}.`,
    cheapLede: (city, bars, low) => `Raccogliamo i prezzi segnalati nei bar di ${city} e li ordiniamo per la birra più economica di ogni bar. Al momento ${bars} bar, a partire da ${low}.`,
    underTitle: (n, city, count) => `Birra sotto i ${n} a ${city} — ${count} bar | Sejdel`,
    underH1: (n, city) => `Birra sotto i ${n} a ${city}`,
    underDesc: (n, city, count) => `${count} bar a ${city} dove una birra costa ${n} o meno, dal più economico in su.`,
    underLede: (n, city, count) => `Ogni bar qui sotto ha almeno una birra a ${n} o meno — al momento ${count}.`,
    outTitle: (city, count) => `Birra economica all'aperto a ${city} — ${count} posti | Sejdel`,
    outH1: (city) => `All'aperto senza spendere: ${city}`,
    outDesc: (city, count) => `${count} bar con tavoli all'aperto a ${city}, ordinati per la birra più economica.`,
    outLede: (city, count) => `I bar di ${city} con dehors o tavoli all'aperto, ordinati per la birra più economica — ${count} al momento.`,
    updated: "Aggiornato", bars: "bar con prezzi", cheapest: "birra più economica", medianL: "mediana della città", bestValue: "miglior rapporto",
    thBar: "Bar", thSize: "Formato", thPrice: "Prezzo", thPerCl: "Al cl",
    legend: ["molto sotto la mediana", "sotto la mediana", "sopra la mediana", "molto sopra"],
    tableNote: (shown, total) => `I ${shown} più economici su ${total} bar. La mediana è calcolata su tutti i ${total}.`,
    caveat: `<b>Come nasce questa lista.</b> I prezzi sono segnalati da chi è al bar e mostrati come mediana delle ultime segnalazioni per bar. Un prezzo può cambiare prima che lo sappiamo — segnalalo sulla mappa e la pagina si corregge alla prossima ricostruzione quotidiana.`,
    ctaB: "Tutti i prezzi sulla mappa", ctaS: "Zooma sulla tua città, filtra per formato e guarda quali dehors sono al sole adesso.",
    faqT: "Domande frequenti",
    faq: (city, bar, price, med, date) => [
      [`Dove costa meno la birra a ${city}?`,
       `${bar.venue} ha il prezzo più basso segnalato: ${price} (${bar.sizeLabel}).`],
      [`Quanto costa una birra a ${city}?`,
       `La mediana su tutti i bar che seguiamo a ${city} è ${med}, contando la birra più economica di ogni bar.`],
      [`Questi prezzi sono aggiornati?`,
       `La pagina viene ricostruita ogni giorno dalle ultime segnalazioni — questa versione è del ${date}.`],
      [`Posso segnalare un prezzo?`,
       `Sì — trova il bar sulla mappa Sejdel e aggiungi quanto hai pagato. Sulla mappa appare subito, qui alla prossima ricostruzione.`]],
    otherCities: "Altre città", allPages: "Tutti i prezzi", underChip: (n) => `Sotto i ${n}`, outChip: "All'aperto",
    footer: `Questa pagina è destinata a lettori in età legale per bere. I prezzi sono segnalati dagli utenti e mostrati come mediana delle ultime segnalazioni per bar. Sejdel non garantisce che un prezzo sia ancora valido — <a href="${SITE}/map/">segnala un cambiamento</a>. Bevi responsabilmente.`,
    hubTitle: (country) => `Prezzi della birra in ${country}, città per città | Sejdel`,
    hubH1: (country) => `Quanto costa la birra in ${country}?`,
    hubLede: (country, bars, cities) => `Prezzi segnalati in ${bars} bar di ${cities} città in ${country}.`,
    hubPick: "Scegli la tua città", langName: "Italiano",
  },
  nl: {
    updatedLocale: "nl-NL", blogName: "Bierprijzen", navMap: "Kaart", navBlog: "Blog",
    servingUnknown: "maat onbekend",
    kicker: (country) => `Bierprijzen · ${country}`,
    cheapTitle: (city, bars) => `Waar is bier goedkoop in ${city}? ${bars} bars vergeleken | Sejdel`,
    cheapH1: (city) => `Waar is bier goedkoop in ${city}?`,
    cheapDesc: (city, bars, low) => `Gemelde bierprijzen uit ${bars} bars in ${city}, van goedkoop naar duur — vanaf ${low}.`,
    cheapLede: (city, bars, low) => `We verzamelen gemelde bierprijzen uit bars in ${city} en sorteren op het goedkoopste biertje per bar. Op dit moment ${bars} bars, vanaf ${low}.`,
    underTitle: (n, city, count) => `Bier onder de ${n} in ${city} — ${count} bars | Sejdel`,
    underH1: (n, city) => `Bier onder de ${n} in ${city}`,
    underDesc: (n, city, count) => `${count} bars in ${city} waar een biertje ${n} of minder kost, van goedkoop naar duur.`,
    underLede: (n, city, count) => `Elke bar hieronder heeft minstens één biertje voor ${n} of minder — op dit moment ${count}.`,
    outTitle: (city, count) => `Terras met goedkoop bier in ${city} — ${count} plekken | Sejdel`,
    outH1: (city) => `Op het terras zonder dure rekening: ${city}`,
    outDesc: (city, count) => `${count} bars met terras in ${city}, gesorteerd op hun goedkoopste biertje.`,
    outLede: (city, count) => `Bars in ${city} met terras, gesorteerd op het goedkoopste biertje — ${count} op dit moment.`,
    updated: "Bijgewerkt", bars: "bars met prijzen", cheapest: "goedkoopste bier", medianL: "mediaan van de stad", bestValue: "beste prijs per cl",
    thBar: "Bar", thSize: "Maat", thPrice: "Prijs", thPerCl: "Per cl",
    legend: ["ver onder de stadsmediaan", "onder de mediaan", "boven de mediaan", "ver erboven"],
    tableNote: (shown, total) => `De ${shown} goedkoopste van ${total} bars. De mediaan is berekend over alle ${total}.`,
    caveat: `<b>Zo wordt deze lijst gemaakt.</b> Prijzen worden gemeld door mensen in de bar en getoond als de mediaan van recente meldingen per bar. Een prijs kan veranderen voordat wij het weten — meld het op de kaart en de pagina corrigeert zichzelf bij de volgende dagelijkse rebuild.`,
    ctaB: "Alle prijzen op de kaart", ctaS: "Zoom naar je stad, filter op maat en zie welke terrassen nu zon hebben.",
    faqT: "Veelgestelde vragen",
    faq: (city, bar, price, med, date) => [
      [`Waar is het bier het goedkoopst in ${city}?`,
       `${bar.venue} heeft de laagst gemelde prijs: ${price} (${bar.sizeLabel}).`],
      [`Wat kost een biertje in ${city}?`,
       `De mediaan over alle bars die we volgen in ${city} is ${med}, gerekend met het goedkoopste biertje per bar.`],
      [`Hoe actueel zijn deze prijzen?`,
       `De pagina wordt dagelijks opnieuw opgebouwd uit de nieuwste meldingen — deze versie is van ${date}.`],
      [`Kan ik zelf een prijs melden?`,
       `Ja — zoek de bar op de Sejdel-bierkaart en voeg toe wat je betaalde. Op de kaart direct zichtbaar, hier bij de volgende rebuild.`]],
    otherCities: "Meer steden", allPages: "Alle bierprijzen", underChip: (n) => `Onder de ${n}`, outChip: "Terras",
    footer: `Deze pagina is bedoeld voor lezers met de wettelijke drinkleeftijd. Prijzen worden gemeld door gebruikers en getoond als mediaan van recente meldingen per bar. Sejdel garandeert niet dat een prijs nog klopt — <a href="${SITE}/map/">meld een wijziging</a>. Drink met mate.`,
    hubTitle: (country) => `Bierprijzen in ${country}, stad voor stad | Sejdel`,
    hubH1: (country) => `Wat kost bier in ${country}?`,
    hubLede: (country, bars, cities) => `Gemelde bierprijzen uit ${bars} bars in ${cities} ${cities === 1 ? "stad" : "steden"} in ${country}.`,
    hubPick: "Kies je stad", langName: "Nederlands",
  },
};
// Cantonese/Mandarin ready for the day HK/CN cities have data.
L.zh = { ...L.en, updatedLocale: "zh-HK", langName: "中文",
  kicker: (country) => `啤酒價格 · ${country}`,
  cheapH1: (city) => `${city}邊度啤酒最平？`,
  cheapTitle: (city, bars) => `${city}邊度啤酒最平？${bars}間酒吧比較 | Sejdel`,
  faqT: "常見問題" };

// ---------------------------------------------------------------- data

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
    const r = await fetch(`${SB}/venues?select=id,name,city,country&order=id&offset=${off}&limit=1000`,
      { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
    if (!r.ok) throw new Error(`venues: HTTP ${r.status}`);
    const page = await r.json();
    out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}

const [prices, venues] = await Promise.all([rpcPaged("public_beer_prices"), allVenues()]);
const vInfo = new Map(venues.map((v) => [v.id, v]));

// City names sometimes carry ", Country" — keep the city part only. A
// country name posing as a city ("United Kingdom") is data noise, not a
// place; refuse it here so a bad import can never mint a fake city page.
const JUNK_CITY = new Set([
  "unitedkingdom", "unitedstates", "england", "scotland", "wales", "uk", "usa",
  ...Object.values(COUNTRIES).flatMap((c) => Object.values(c.name)),
].map((x) => slugify(String(x)).replace(/-/g, "")));
const cleanCity = (c) => {
  if (!c) return null;
  const name = String(c).split(",")[0].trim();
  return JUNK_CITY.has(slugify(name).replace(/-/g, "")) ? null : name;
};

const rows = prices
  .map((p) => {
    const v = vInfo.get(p.venue_id) || {};
    return {
      venue: p.venue_name, id: p.venue_id,
      city: cleanCity(v.city), country: v.country || null,
      lat: p.lat, lon: p.lon,
      serving: p.serving, price: Number(p.price),
      cl: CL[p.serving] ?? null,
      currency: p.currency, outdoor: p.outdoor === true,
    };
  })
  .filter((r) => r.city && r.country && r.country !== "SE"
      && COUNTRIES[r.country] && Number.isFinite(r.price)
      && r.currency === COUNTRIES[r.country].cur);

const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

// Per venue: its cheapest pour of any size — the number every ranking uses
// (same semantics as the app's and map's "All sizes" view).
function venueCheapest(list) {
  const by = new Map();
  for (const r of list) {
    const cur = by.get(r.id);
    if (!cur || r.price < cur.price) by.set(r.id, r);
  }
  return [...by.values()].sort((a, b) => a.price - b.price);
}

const byCountry = new Map();
for (const r of rows) {
  if (!byCountry.has(r.country)) byCountry.set(r.country, []);
  byCountry.get(r.country).push(r);
}

// ---------------------------------------------------------------- shell
//
// The visual shell is LIFTED FROM gen-blog.mjs at run time — same CSS, same
// dimple background — so the international pages can never drift from the
// Swedish ones without either generator noticing.
const genBlogSrc = readFileSync(join(HERE, "gen-blog.mjs"), "utf8");
const CSS = (genBlogSrc.match(/<style>[\s\S]*?<\/style>/) || [""])[0];
if (!CSS) throw new Error("could not lift <style> block from gen-blog.mjs");
const FAVICON = (genBlogSrc.match(/<link rel="icon"[^>]+\/>/) || [""])[0];

const updated = new Date().toISOString().slice(0, 10);
const dateIn = (lang) => new Date().toLocaleDateString(L[lang].updatedLocale,
  { year: "numeric", month: "long", day: "numeric" });

function page({ lang, T, title, desc, canonical, alts, h1, kicker, body, jsonld }) {
  const altLinks = (alts || []).map((a) =>
    `<link rel="alternate" hreflang="${a.lang}" href="${a.href}" />`).join("\n");
  const xDefault = (alts || []).find((a) => a.lang === "en")?.href || canonical;
  // Manual language choice carries ?lang=<code>, which pins it for the
  // session so the auto-redirect below never fights the reader.
  const langNav = (alts || []).filter((a) => a.href !== canonical)
    .map((a) => `<a href="${a.href}?lang=${a.lang}">${esc(L[a.lang]?.langName || a.lang)}</a>`).join("\n      ");
  // Automatic language: a shared link opens in the device's language when a
  // twin exists. Fires once per session, never after a manual choice, and
  // search traffic already lands right via hreflang.
  const twins = Object.fromEntries((alts || [])
    .filter((a) => a.href !== canonical).map((a) => [a.lang, a.href]));
  const autoLang = Object.keys(twins).length ? `
<script>
(function(){try{
  var qs=new URLSearchParams(location.search);
  if(qs.has("lang")){sessionStorage.setItem("sejdelLangPin",qs.get("lang"));return;}
  if(sessionStorage.getItem("sejdelLangPin")||sessionStorage.getItem("sejdelLangHop"))return;
  var want=(navigator.language||"").slice(0,2).toLowerCase();
  if(!want||want===document.documentElement.lang)return;
  var alts=${JSON.stringify(twins)};
  if(alts[want]){sessionStorage.setItem("sejdelLangHop","1");location.replace(alts[want]);}
}catch(e){}})();
</script>` : "";
  return `<!DOCTYPE html>
<html lang="${lang}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; base-uri 'none'; form-action 'none'" />
<meta name="referrer" content="no-referrer" />
<meta name="color-scheme" content="dark" />
<meta name="theme-color" content="#140f0b" />
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}" />
<link rel="canonical" href="${canonical}" />
<link rel="alternate" hreflang="${lang}" href="${canonical}" />
${altLinks}
<link rel="alternate" hreflang="x-default" href="${xDefault}" />
<meta property="og:type" content="article" />
<meta property="og:title" content="${esc(title)}" />
<meta property="og:description" content="${esc(desc)}" />
<meta property="og:url" content="${canonical}" />
<meta property="og:site_name" content="Sejdel" />
<meta name="twitter:card" content="summary" />
${FAVICON}
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400..900;1,9..144,400..600&family=Hanken+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet" />
${CSS}
${jsonld ? (Array.isArray(jsonld) ? jsonld : [jsonld])
    .map((d) => `<script type="application/ld+json">${JSON.stringify(d)}</script>`).join("\n") : ""}${autoLang}
</head>
<body><div class="dimples dim-far" aria-hidden="true"></div><div class="dimples dim-near" aria-hidden="true"></div>
<div class="wrap">
  <header class="top">
    <a class="brand" href="${SITE}/">Sejdel<span>.</span></a>
    <nav>
      <a href="${SITE}/map/">${esc(T.navMap)}</a>
      <a href="${SITE}/blog/">${esc(T.navBlog)}</a>
      ${langNav}
    </nav>
  </header>
  <p class="kicker">${esc(kicker)}</p>
  <h1>${esc(h1)}</h1>
${body}
  <footer>
    ${T.footer}
    <br /><br />
    <a href="${SITE}/">Sejdel</a> · <a href="${SITE}/map/">${esc(T.navMap)}</a>
    · <a href="${SITE}/privacy/">Privacy</a>
  </footer>
</div>
</body>
</html>
`;
}

// ---------------------------------------------------------------- helpers

function money(n, C, lang) {
  const s = Number.isInteger(n) ? String(n) : n.toFixed(2).replace(/\.?0+$/, "");
  if (C.cur === "EUR" && lang !== "en") return `${s} €`;
  return C.pre ? `${C.sym}${s}` : `${s} ${C.sym}`;
}
const sizeLabel = (T, serving) => SERVING_LABEL[serving] || T.servingUnknown;

function band(price, med) {
  if (!med) return "b2";
  if (price <= med * 0.75) return "b1";
  if (price <= med) return "b2";
  if (price <= med * 1.25) return "b3";
  return "b4";
}
function legend(T) {
  const col = { b1: "#7ec96b", b2: "#e8c34a", b3: "#e8843c", b4: "#e07a6a" };
  return `<div class="legend">${["b1", "b2", "b3", "b4"].map((b, i) =>
    `<span><i style="background:${col[b]}"></i>${esc(T.legend[i])}</span>`).join("")}</div>`;
}

function priceTable(list, med, C, T, lang) {
  const showCl = list.some((r) => r.cl);
  const head = `<tr><th></th><th>${T.thBar}</th><th>${T.thSize}</th><th>${T.thPrice}</th>${showCl ? `<th>${T.thPerCl}</th>` : ""}</tr>`;
  const body = list.map((r, i) => {
    const href = `${SITE}/map/?lat=${(r.lat ?? 0).toFixed(5)}&lon=${(r.lon ?? 0).toFixed(5)}`
      + `&v=${encodeURIComponent(r.id)}&s=${encodeURIComponent(r.serving)}&city=${encodeURIComponent(r.city)}`;
    return `<tr>
      <td class="rank">${i + 1}</td>
      <td><a href="${href}">${esc(r.venue)}</a></td>
      <td class="n">${esc(sizeLabel(T, r.serving))}</td>
      <td class="p ${band(r.price, med)}">${money(r.price, C, lang)}</td>
      ${showCl ? `<td class="n">${r.cl ? money(r.price / r.cl, C, lang) : "–"}</td>` : ""}
    </tr>`;
  }).join("\n");
  return `<div class="tw"><table>${head}\n${body}</table></div>` + legend(T);
}

function figs(items) {
  const step = (v) => {
    const n = String(v).length;
    return n <= 5 ? "s1" : n <= 8 ? "s2" : n <= 11 ? "s3" : "s4";
  };
  return `<div class="figs">${items.map(([v, l]) =>
    `<div class="fig"><b class="${step(v)}" title="${esc(v)}">${esc(v)}</b><span>${esc(l)}</span></div>`).join("")}</div>`;
}

const mapCta = (T, c) => {
  const q = c ? `?lat=${c.lat.toFixed(5)}&lon=${c.lon.toFixed(5)}&city=${encodeURIComponent(c.city)}` : "";
  return `<a class="cta" href="${SITE}/map/${q}">
    <b>${esc(T.ctaB)}</b><span>${esc(T.ctaS)}</span></a>`;
};

const written = [];
function write(rel, html) {
  const full = join(ROOT, rel, "index.html");
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, html);
  written.push(`${SITE}/${rel}/`);
}

// ---------------------------------------------------------------- generate

let cityPages = 0;
const countrySummaries = [];

for (const [iso, list] of byCountry) {
  const C = COUNTRIES[iso];
  const byCity = new Map();
  for (const r of list) {
    if (!byCity.has(r.city)) byCity.set(r.city, []);
    byCity.get(r.city).push(r);
  }

  const cities = [...byCity.entries()]
    .map(([city, cityRows]) => {
      const cheap = venueCheapest(cityRows);
      const lat = cheap.reduce((a, r) => a + (r.lat || 0), 0) / (cheap.length || 1);
      const lon = cheap.reduce((a, r) => a + (r.lon || 0), 0) / (cheap.length || 1);
      return { city, rowsAll: cityRows, cheap, lat, lon,
               med: median(cheap.map((r) => r.price)) };
    })
    .filter((c) => c.cheap.length >= MIN_BARS)
    .sort((a, b) => b.cheap.length - a.cheap.length);
  if (!cities.length) continue;

  // Which languages a city publishes in: its local language + English.
  const langOf = (city) => {
    for (const [k, lg] of Object.entries(C.cityLang || {})) {
      if (slugify(k) === slugify(city)) return lg;
    }
    return C.langs[0];
  };

  // Per city, which variant pages exist (single source of truth for links).
  const variantOfCity = new Map(cities.map((c) => [c.city, {
    under: C.th.filter((n) => c.cheap.filter((r) => r.price <= n).length >= MIN_UNDER),
    out: c.cheap.filter((r) => r.outdoor).length >= MIN_OUT,
  }]));

  const urlFor = (lang, kind, c, n) => {
    const cs = slugify(c.city);
    const w = (CUR_WORD[lang] || CUR_WORD.en)[C.cur] || C.cur.toLowerCase();
    const slug = kind === "cheap" ? SLUG[lang].cheap(cs)
      : kind === "out" ? SLUG[lang].out(cs)
      : SLUG[lang].under(n, w, cs);
    return lang === "en" ? `${SITE}/blog/${slug}/` : `${SITE}/blog/${lang}/${slug}/`;
  };
  const relFor = (lang, kind, c, n) =>
    urlFor(lang, kind, c, n).replace(`${SITE}/`, "").replace(/\/$/, "");

  const chips = (lang, c, current) => {
    const T = L[lang];
    const v = variantOfCity.get(c.city);
    const items = [
      ["cheap", T.allPages, urlFor(lang, "cheap", c)],
      ...v.under.map((n) => [`u${n}`, T.underChip(money(n, C, lang)), urlFor(lang, "under", c, n)]),
      ...(v.out ? [["out", T.outChip, urlFor(lang, "out", c)]] : []),
    ];
    if (items.length < 2) return "";
    return `<ul class="chips">${items.map(([key, label, href]) =>
      key === current
        ? `<li><span class="chip-on">${esc(label)}</span></li>`
        : `<li><a href="${href}">${esc(label)}</a></li>`).join("")}</ul>`;
  };

  const switcher = (lang, current) => cities.length < 2 ? "" :
    `<ul class="switch">${cities.map((c) =>
      `<li><a class="${c.city === current ? "on" : ""}" href="${urlFor(langOf(c.city) === lang || lang === "en" ? lang : "en", "cheap", c)}">${esc(c.city)}</a></li>`).join("")}</ul>`;

  for (const c of cities) {
    const local = langOf(c.city);
    const langs = local === "en" ? ["en"] : [local, "en"];
    const v = variantOfCity.get(c.city);

    for (const lang of langs) {
      const T = L[lang];
      const countryName = C.name[lang] || C.name.en;
      const alts = (kind, n) => langs.map((lg) => ({ lang: lg, href: urlFor(lg, kind, c, n) }));
      const faqBlock = (kind) => {
        const first = c.cheap[0];
        const qs = T.faq(c.city,
          { venue: first.venue, sizeLabel: sizeLabel(T, first.serving) },
          money(first.price, C, lang), money(c.med, C, lang), dateIn(lang));
        const html = `<h2>${esc(T.faqT)}</h2>`
          + qs.map(([q, a]) => `<h3>${esc(q)}</h3>\n  <p>${esc(a)}</p>`).join("\n  ");
        const ld = { "@context": "https://schema.org", "@type": "FAQPage",
          mainEntity: qs.map(([q, a]) => ({ "@type": "Question", name: q,
            acceptedAnswer: { "@type": "Answer", text: a } })) };
        return { html, ld };
      };
      const common = (bodyCore, kind, n) => {
        const f = faqBlock(kind);
        return {
          body: `${bodyCore}\n${chips(lang, c, kind === "under" ? `u${n}` : kind)}\n${mapCta(T, c)}\n${f.html}\n<h2>${esc(T.otherCities)}</h2>\n${switcher(lang, c.city)}`,
          jsonld: f.ld,
        };
      };

      { // cheapest page
        const low = money(c.cheap[0].price, C, lang);
        const top = c.cheap.slice(0, TABLE_CAP);
        const bestCl = c.cheap.filter((r) => r.cl).sort((a, b) => a.price / a.cl - b.price / b.cl)[0];
        const core = `
  <p class="lede">${esc(T.cheapLede(c.city, c.cheap.length, low))}</p>
  <p class="stamp">${esc(T.updated)} ${esc(dateIn(lang))}</p>
  ${figs([[String(c.cheap.length), T.bars], [low, T.cheapest], [money(c.med, C, lang), T.medianL],
          ...(bestCl ? [[money(bestCl.price / bestCl.cl, C, lang) + "/cl", T.bestValue]] : [])])}
  ${priceTable(top, c.med, C, T, lang)}
  ${top.length < c.cheap.length ? `<p class="note">${esc(T.tableNote(top.length, c.cheap.length))}</p>` : ""}
  <div class="caveat">${T.caveat}</div>`;
        const { body, jsonld } = common(core, "cheap");
        write(relFor(lang, "cheap", c), page({
          lang, T, canonical: urlFor(lang, "cheap", c), alts: alts("cheap"),
          title: T.cheapTitle(c.city, c.cheap.length),
          desc: T.cheapDesc(c.city, c.cheap.length, low),
          kicker: T.kicker(countryName), h1: T.cheapH1(c.city), body, jsonld,
        }));
      }

      for (const n of v.under) { // under-N pages
        const nTxt = money(n, C, lang);
        const qualifying = c.cheap.filter((r) => r.price <= n);
        const top = qualifying.slice(0, TABLE_CAP);
        const core = `
  <p class="lede">${esc(T.underLede(nTxt, c.city, qualifying.length))}</p>
  <p class="stamp">${esc(T.updated)} ${esc(dateIn(lang))}</p>
  ${figs([[String(qualifying.length), T.bars], [money(qualifying[0].price, C, lang), T.cheapest], [money(c.med, C, lang), T.medianL]])}
  ${priceTable(top, c.med, C, T, lang)}
  ${top.length < qualifying.length ? `<p class="note">${esc(T.tableNote(top.length, qualifying.length))}</p>` : ""}
  <div class="caveat">${T.caveat}</div>`;
        const { body, jsonld } = common(core, "under", n);
        write(relFor(lang, "under", c, n), page({
          lang, T, canonical: urlFor(lang, "under", c, n), alts: alts("under", n),
          title: T.underTitle(nTxt, c.city, qualifying.length),
          desc: T.underDesc(nTxt, c.city, qualifying.length),
          kicker: T.kicker(countryName), h1: T.underH1(nTxt, c.city), body, jsonld,
        }));
      }

      if (v.out) { // outdoor page
        const outRows = c.cheap.filter((r) => r.outdoor);
        const top = outRows.slice(0, TABLE_CAP);
        const core = `
  <p class="lede">${esc(T.outLede(c.city, outRows.length))}</p>
  <p class="stamp">${esc(T.updated)} ${esc(dateIn(lang))}</p>
  ${figs([[String(outRows.length), T.outChip], [money(outRows[0].price, C, lang), T.cheapest], [money(c.med, C, lang), T.medianL]])}
  ${priceTable(top, c.med, C, T, lang)}
  ${top.length < outRows.length ? `<p class="note">${esc(T.tableNote(top.length, outRows.length))}</p>` : ""}
  <div class="caveat">${T.caveat}</div>`;
        const { body, jsonld } = common(core, "out");
        write(relFor(lang, "out", c), page({
          lang, T, canonical: urlFor(lang, "out", c), alts: alts("out"),
          title: T.outTitle(c.city, outRows.length),
          desc: T.outDesc(c.city, outRows.length),
          kicker: T.kicker(countryName), h1: T.outH1(c.city), body, jsonld,
        }));
      }
    }
    cityPages++;
  }

  // ---- country hub (English, at /blog/{country}/), linking every variant
  {
    const T = L.en;
    const countryName = C.name.en;
    // The COUNTRY total counts every priced bar in the country — bars in
    // towns too small for their own page (or with no city label at all)
    // still exist; counting only page-worthy cities read as wrong data.
    const countryBars = venueCheapest(list).length;
    // "how much is a beer in france reddit" — the hub IS that question.
    const THE = new Set(["united-states", "united-kingdom", "netherlands"]);
    const cSlug = slugify(countryName);
    const rel = `blog/how-much-is-a-beer-in-${THE.has(cSlug) ? "the-" : ""}${cSlug}-reddit`;
    const proseName = THE.has(cSlug) ? `the ${countryName}` : countryName;
    const bars = countryBars;
    // Built once, used on the country hub AND the world hub — every article
    // must sit at most two clicks from the home page, so the world hub
    // (linked from home) carries the full chip set for every city.
    const grid = cities.map((c) => {
      const local = langOf(c.city);
      const links = chips("en", c, null);
      // The FULL local chip row, not just the flagship: every page in both
      // languages must be two clicks from the home page.
      const localLink = local !== "en"
        ? `<p class="meta" style="margin-top:8px">${esc(L[local].langName)}</p>${chips(local, c, null)}` : "";
      return `<div class="citycard">
      <h3><a class="cityname" href="${urlFor("en", "cheap", c)}">${esc(c.city)}</a></h3>
      <p class="meta">${c.cheap.length} bars · from ${money(c.cheap[0].price, C, "en")}</p>
      ${links}${localLink}
    </div>`;
    }).join("\n");
    const body = `
  <p class="lede">${esc(T.hubLede(proseName, bars, cities.length))}</p>
  <p class="stamp">${esc(T.updated)} ${esc(dateIn("en"))}</p>
  <h2>${esc(T.hubPick)}</h2>
  <div class="citygrid">
    ${grid}
  </div>
  ${mapCta(T, cities[0])}`;
    write(rel, page({
      lang: "en", T, canonical: `${SITE}/${rel}/`, alts: [{ lang: "en", href: `${SITE}/${rel}/` }],
      title: T.hubTitle(proseName), desc: T.hubLede(proseName, bars, cities.length),
      kicker: T.kicker(countryName), h1: T.hubH1(proseName), body, jsonld: null,
    }));
    countrySummaries.push({ iso, name: countryName, cities: cities.length, bars, rel, grid,
      from: money(Math.min(...cities.map((x) => x.cheap[0].price)), C, "en") });
  }
}

// ---------------------------------------------------- the world hub
//
// Not a "beyond Sweden" annex: one page that asks the question for the whole
// planet and hands the reader a country — Sweden included, as one flag among
// the others.
const flagEmoji = (iso) => iso.toUpperCase().replace(/./g,
  (c) => String.fromCodePoint(127397 + c.charCodeAt(0)));

const seRows = prices.map((p) => ({ ...p, v: vInfo.get(p.venue_id) || {} }))
  .filter((r) => r.v.country === "SE" && r.currency === "SEK" && Number.isFinite(Number(r.price)));
const seBars = new Set(seRows.map((r) => r.venue_id)).size;
const seFrom = seRows.length ? `${Math.round(Math.min(...seRows.map((r) => Number(r.price))))} kr` : null;
// Sweden's city grid, exported by gen-blog.mjs so the world hub renders it
// exactly like every other country's.
let seGrid = null, seCities = null;
try {
  const se = JSON.parse(readFileSync(join(HERE, ".se-summary.json"), "utf8"));
  seGrid = se.grid; seCities = se.cities;
} catch { /* gen-blog.mjs has not run — fall back to the chip row */ }

const WORLD_REL = "blog/what-does-beer-cost-around-the-world-reddit";
{
  const T = L.en;
  const ranked = countrySummaries.sort((a, b) => b.bars - a.bars);
  const totalBars = ranked.reduce((a, c) => a + c.bars, 0) + seBars;
  const seMeta = `${seBars} bars${seCities ? ` · ${seCities} cities with pages` : ""}${seFrom ? ` · from ${esc(seFrom)}` : ""}`;
  const seSection = `
  <h2>${flagEmoji("SE")} <a href="${SITE}/blog/beer-prices-sweden/">Sweden</a></h2>
  <p class="meta" style="font-family:var(--mono);font-size:10px;letter-spacing:.13em;text-transform:uppercase;color:var(--bronze)">${seMeta}</p>
  ${seGrid ? `<div class="citygrid">
    ${seGrid}
  </div>` : `<ul class="chips">
    <li><a href="${SITE}/blog/beer-prices-sweden/">All of Sweden</a></li>
    <li><a href="${SITE}/blog/">City by city (English)</a></li>
    <li><a href="${SITE}/blogg/">På svenska</a></li>
  </ul>`}`;
  const body = `
  <p class="lede">Reported beer prices from ${totalBars} bars across ${ranked.length + 1} countries — the same live data the Sejdel map runs on, compared bar by bar. Every city below is one click away, in the local language and English.</p>
  <p class="stamp">${esc(T.updated)} ${esc(dateIn("en"))}</p>
  ${seSection}
  ${ranked.map((s) => `
  <h2>${flagEmoji(s.iso)} <a href="${SITE}/${s.rel}/">${esc(s.name)}</a></h2>
  <p class="meta" style="font-family:var(--mono);font-size:10px;letter-spacing:.13em;text-transform:uppercase;color:var(--bronze)">${s.bars} bars · ${s.cities} ${s.cities === 1 ? "city" : "cities"} with pages · from ${esc(s.from)}</p>
  <div class="citygrid">
    ${s.grid}
  </div>`).join("\n")}
  ${mapCta(T, null)}`;
  write(WORLD_REL, page({
    lang: "en", T, canonical: `${SITE}/${WORLD_REL}/`,
    alts: [{ lang: "en", href: `${SITE}/${WORLD_REL}/` }],
    title: "What does beer cost around the world? Live prices by country | Sejdel",
    desc: `Beer prices from ${totalBars} bars in ${ranked.length + 1} countries, reported by drinkers and compared city by city.`,
    kicker: "Beer prices · Worldwide", h1: "What does beer cost around the world?",
    body, jsonld: null,
  }));
}

// The Swedish blog hubs point at the world hub — a doorway, not an annex.
for (const [file, label, more, cta] of [
  [join(ROOT, "blog", "index.html"), "Around the world",
   "The same comparison for every country we cover — in the local language and English.",
   "What does beer cost around the world?"],
  [join(ROOT, "blogg", "index.html"), "Ute i världen",
   "Samma jämförelse för alla länder vi täcker — på det lokala språket och engelska.",
   "Vad kostar ölen i världen?"],
]) {
  if (!existsSync(file)) continue;
  let html = readFileSync(file, "utf8");
  const block = `<!--INTL:START-->
  <h2>${label}</h2>
  <p>${more}</p>
  <ul class="chips">
    <li><a href="${SITE}/${WORLD_REL}/">${cta}</a></li>
    ${countrySummaries.sort((a, b) => b.bars - a.bars).map((s) =>
      `<li><a href="${SITE}/${s.rel}/">${flagEmoji(s.iso)} ${esc(s.name)} · ${s.bars}</a></li>`).join("\n    ")}
  </ul>
  <!--INTL:END-->`;
  const re = /<!--INTL:START-->[\s\S]*?<!--INTL:END-->/;
  if (re.test(html)) {
    writeFileSync(file, html.replace(re, block));
  } else {
    writeFileSync(file, html.replace(/<a class="cta"/, `${block}\n  <a class="cta"`));
  }
}

// ---------------------------------------------------------------- sitemap
//
// gen-blog.mjs rewrites docs/sitemap.xml from scratch; append our URLs to it.
{
  const smPath = join(ROOT, "sitemap.xml");
  let sm = readFileSync(smPath, "utf8");
  const mine = written
    .filter((u) => !sm.includes(`<loc>${u}</loc>`))
    .map((u) => `  <url><loc>${u}</loc><lastmod>${updated}</lastmod></url>`).join("\n");
  if (mine) sm = sm.replace("</urlset>", `${mine}\n</urlset>`);
  writeFileSync(smPath, sm);
}

// ------------------------------------------------- homepage stats block
//
// gen-blog.mjs writes a Swedish version of this block; running after it,
// this generator replaces it with the worldwide view the homepage teases.
{
  const idx = join(ROOT, "index.html");
  if (existsSync(idx)) {
    let html = readFileSync(idx, "utf8");
    const nCountries = countrySummaries.length + 1;
    const nCities = countrySummaries.reduce((a, s) => a + s.cities, 0);
    const totalBars = countrySummaries.reduce((a, s) => a + s.bars, 0) + seBars;
    const flags = ["SE", ...countrySummaries.sort((a, b) => b.bars - a.bars).map((s) => s.iso)]
      .map(flagEmoji).join(" ");
    const names = ["Sweden", ...countrySummaries.map((s) => s.name)].join(", ");
    const langs = "Swedish, English, French, German, Spanish, Portuguese, Italian and Dutch";
    const block = `<!--BEERSTATS:START-->
        <ul class="plist">
          <li><b>${nCountries} countries. ${flags}</b> <span>${esc(names)} — every one compared city by city.</span></li>
          <li><b>${totalBars} bars with live prices.</b> <span>Reported by people standing in them, shown as the median of recent reports — the same data the map runs on.</span></li>
          <li><b>Eight languages.</b> <span>Every city reads in its own language — ${langs} — with an English twin for the rest of us.</span></li>
        </ul>
        <!--BEERSTATS:END-->`;
    const re = /<!--BEERSTATS:START-->[\s\S]*?<!--BEERSTATS:END-->/;
    if (re.test(html)) {
      writeFileSync(idx, html.replace(re, block));
      console.log("homepage stats block: worldwide version written");
    }
  }
}

console.log(`countries: ${countrySummaries.map((s) => `${s.iso}:${s.bars}b/${s.cities}c`).join(" ")}`);
console.log(`city page sets: ${cityPages}`);
console.log(`pages written: ${written.length}`);
