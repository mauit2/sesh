/* sejdel.com — the pint.
 *
 * One fixed canvas behind the page. The beer level tracks scroll (a sip at the
 * top, brim-full at the bottom). Realism comes from four layered motions:
 *
 *  - a 1-D spring lattice for ripples that travel and reflect off the walls,
 *    with a light neighbour blur so fine chop dies fast and long waves glide
 *    (viscosity damps high frequencies first, like real liquid);
 *  - the container's fundamental slosh mode — the whole surface rocks as
 *    cos(πx/W) on a damped ~2.3 s oscillator, which is the motion you actually
 *    see when you knock a glass;
 *  - a foam head: a thickness field riding the surface that fattens where the
 *    liquid is agitated and where bubbles pop, then diffuses and relaxes;
 *  - carbonation streams from fixed nucleation points, bubbles accelerating as
 *    they rise (buoyancy) and feeding the head when they burst.
 *
 * Dragging the pointer through the beer ploughs a wake (pushed ahead, lifted
 * behind) and feeds the rocking mode. Scrolling up leaves lacing rings on the
 * glass as the level recedes. One rAF loop, no dependencies.
 */
(() => {
  "use strict";

  // Progressive enhancement: only hide the reveal targets once we know we can
  // bring them back. If this file never loads, the page just renders plainly.
  document.documentElement.classList.add("js");

  const canvas = document.getElementById("beer");
  if (!canvas || !canvas.getContext) return;
  const ctx = canvas.getContext("2d");
  const reduce = window.matchMedia
    && matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- surface lattice ---------- */
  const N = 150;                    // sample points across the glass
  const h = new Float32Array(N);    // vertical displacement (px, + = down)
  const vel = new Float32Array(N);  // velocity
  const acc = new Float32Array(N);  // scratch: neighbour pull
  const K = 0.02;                   // stiffness back to rest
  const DAMP = 0.986;
  const SPREAD = 0.24;              // wave speed — must stay under .5 to be stable
  const CLAMP = 24;
  const BLUR = 0.12;                // surface tension: short chop dies, round waves live

  /* ---------- the slosh mode ---------- */
  // First mode of a rocked container: surface shape cos(πx/W), one damped
  // oscillator for the whole glass. ω² = SLOSH_K → ~2.3 s period.
  const SLOSH_K = 7.5, SLOSH_C = 0.85;
  let sloshP = 0, sloshV = 0;

  const REST = 0.055;               // level with the page at the very top
  let level = REST, target = REST;  // 0 = empty, 1 = full viewport
  let tilt = 0, tiltTarget = 0;     // liquid leaning toward the pointer
  let energy = 0;                   // recent agitation, drives wave size
  let t = 0;

  let W = 0, H = 0;
  let mobile = false;
  let SEGS = 56;                    // surface samples per paint, set in resize()
  let bubbles = [], streams = [], laces = [], foamBits = [];
  let grain = null;                 // pre-rendered speckle for the liquid
  const FOAM_BASE = 7.2;
  const foamH = new Float32Array(N).fill(FOAM_BASE);  // head thickness (px)
  let laceAnchor = 0;

  /* ---------- setup ---------- */
  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    mobile = W < 720;
    SEGS = mobile ? 40 : 56;
    const dpr = Math.min(window.devicePixelRatio || 1, mobile ? 1.25 : 1.5);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // haze in the liquid: a tiny speckle tile, stretched by the ctx transform
    const gc = document.createElement("canvas");
    gc.width = gc.height = 96;
    const g2 = gc.getContext("2d");
    for (let i = 0; i < 340; i++) {
      g2.fillStyle = Math.random() < 0.5
        ? "rgba(255,235,190," + (0.05 + Math.random() * 0.1) + ")"
        : "rgba(90,40,10," + (0.05 + Math.random() * 0.09) + ")";
      const r = Math.random() * 1.4;
      g2.beginPath();
      g2.arc(Math.random() * 96, Math.random() * 96, r, 0, Math.PI * 2);
      g2.fill();
    }
    grain = ctx.createPattern(gc, "repeat");
    seed();
    onScroll();
    laceAnchor = baseY();
    if (reduce) draw();
  }

  function seed() {
    const nb = Math.round(Math.max(14, Math.min(40, W / (mobile ? 40 : 30))));
    bubbles = [];
    for (let i = 0; i < nb; i++) bubbles.push(newBubble(true));
    // nucleation sites — the spots a real glass streams from
    const ns = Math.round(Math.max(3, Math.min(9, W / (mobile ? 230 : 170))));
    streams = [];
    for (let i = 0; i < ns; i++) {
      streams.push({
        x: W * (0.06 + 0.88 * ((i + 0.2 + Math.random() * 0.6) / ns)),
        w: 7 + Math.random() * 12,
        glow: 0.03 + Math.random() * 0.05,
        next: Math.random() * 0.8,
        rate: 0.22 + Math.random() * 0.55
      });
    }
    foamH.fill(FOAM_BASE);
    foamBits = [];
    const nfb = Math.round(Math.max(30, Math.min(100, W / (mobile ? 17 : 12))));
    for (let i = 0; i < nfb; i++) {
      foamBits.push({
        x: Math.random(),
        yf: Math.random(),                    // 0 = lip, 1 = waterline
        r: 0.8 + Math.random() * 2.6,
        o: 0.25 + Math.random() * 0.45,
        d: (Math.random() - 0.5) * 0.00011
      });
    }
    laces = [];
  }

  // depth = px above the bottom of the viewport
  function newBubble(seeded, atX) {
    return {
      x: atX != null ? atX + (Math.random() - 0.5) * 6 : Math.random() * W,
      depth: seeded ? Math.random() * H : -Math.random() * 30,
      r: atX != null ? 0.7 + Math.random() * 1.4 : 1.0 + Math.random() * 2.6,
      sp: 10 + Math.random() * 22,          // px per second, grows with buoyancy
      ph: Math.random() * Math.PI * 2,
      wf: 0.8 + Math.random() * 1.6,        // wobble frequency
      sw: 0.3 + Math.random() * 1.3         // sway
    };
  }

  /* ---------- height field ---------- */
  function baseY() { return H - level * H; }

  function surfaceY(x) {
    const f = (x / Math.max(W, 1)) * (N - 1);
    const i = Math.max(0, Math.min(N - 2, Math.floor(f)));
    const k = f - i;
    const disp = h[i] + (h[i + 1] - h[i]) * k;
    const lean = (x / Math.max(W, 1) - 0.5) * tilt;
    const rock = sloshP * Math.cos(Math.PI * x / Math.max(W, 1));
    const amb = (Math.sin(x * 0.0085 + t * 0.0011) * 2.1
               + Math.sin(x * 0.019 - t * 0.0017) * 1.15) * (1 + energy * 1.6)
               + Math.sin(x * 0.0031 + t * 0.00042) * 2.4;
    // meniscus: a wetting liquid climbs a little at the walls
    const climb = 3.0 * (Math.exp(-x / 30) + Math.exp(-(W - x) / 30));
    return baseY() + disp + lean + rock + amb - climb;
  }

  function foamAt(x) {
    const f = (x / Math.max(W, 1)) * (N - 1);
    const i = Math.max(0, Math.min(N - 2, Math.floor(f)));
    const k = f - i;
    return foamH[i] + (foamH[i + 1] - foamH[i]) * k;
  }

  function splash(px, power, width) {
    const c = (px / Math.max(W, 1)) * (N - 1);
    const w = width || 4;
    for (let i = Math.floor(c - w); i <= Math.ceil(c + w); i++) {
      if (i < 0 || i >= N) continue;
      const d = Math.abs(i - c) / w;
      if (d > 1) continue;
      vel[i] += power * (0.5 + 0.5 * Math.cos(d * Math.PI));
    }
  }

  function physics(dt) {
    // travelling waves: discrete Laplacian, reflecting off the glass walls
    for (let i = 0; i < N; i++) {
      const l = h[i > 0 ? i - 1 : 0];
      const r = h[i < N - 1 ? i + 1 : N - 1];
      acc[i] = SPREAD * (l + r - 2 * h[i]);
    }
    for (let i = 0; i < N; i++) {
      vel[i] += acc[i] - K * h[i];
      vel[i] *= DAMP;
      if (vel[i] > 3.2) vel[i] = 3.2; else if (vel[i] < -3.2) vel[i] = -3.2;
      h[i] += vel[i];
      if (h[i] > CLAMP) { h[i] = CLAMP; vel[i] *= -0.4; }
      else if (h[i] < -CLAMP) { h[i] = -CLAMP; vel[i] *= -0.4; }
    }
    // viscosity: fine chop bleeds away, long waves keep rolling
    let prev = h[0];
    for (let i = 1; i < N - 1; i++) {
      const cur = h[i];
      h[i] = cur + (prev + h[i + 1] - 2 * cur) * BLUR;
      prev = cur;
    }
    // the rocking mode
    sloshV += (-SLOSH_K * sloshP - SLOSH_C * sloshV) * dt;
    sloshP += sloshV * dt;
    if (sloshP > 18) sloshP = 18; else if (sloshP < -18) sloshP = -18;

    // the head: fatten over agitated water, diffuse, relax
    for (let i = 0; i < N; i++) {
      const want = FOAM_BASE + Math.min(11, Math.abs(vel[i]) * 2.2 + energy * 3.0);
      foamH[i] += (want - foamH[i]) * (want > foamH[i] ? 0.25 : 0.015);
    }
    prev = foamH[0];
    for (let i = 1; i < N - 1; i++) {
      const cur = foamH[i];
      foamH[i] = cur + (prev + foamH[i + 1] - 2 * cur) * 0.12;
      prev = cur;
    }

    tilt += (tiltTarget - tilt) * 0.045;
    tiltTarget *= 0.97;
    energy *= 0.94;
  }

  /* ---------- scroll reveals ---------- */
  // Driven off the scroll listener rather than IntersectionObserver: same
  // effect, but it also settles correctly on a page loaded mid-scroll (deep
  // link, restored position) and in browsers that throttle observers.
  const targets = [].slice.call(document.querySelectorAll(".r"));
  function sweep() {
    if (!targets.length) return;
    const line = window.innerHeight * 0.9;
    for (let i = targets.length - 1; i >= 0; i--) {
      const el = targets[i];
      if (el.getBoundingClientRect().top < line) {
        el.classList.add("in");
        targets.splice(i, 1);
      }
    }
  }

  /* ---------- input ---------- */
  let lastP = REST;

  function onScroll() {
    sweep();
    // the top menu only frosts once you've left the hero
    document.documentElement.classList.toggle("scrolled", window.scrollY > 40);
    const doc = document.documentElement;
    const max = doc.scrollHeight - window.innerHeight;
    const p = max > 4 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
    target = REST + p * (1 - REST);
    const d = target - lastP;
    lastP = target;
    if (!reduce && Math.abs(d) > 0.0002) {
      // pouring in / tipping out: some ripple, mostly a rock of the whole glass
      const imp = Math.max(-3.5, Math.min(3.5, -d * 180));
      for (let i = 0; i < N; i++) {
        vel[i] += imp * (0.55 + 0.45 * Math.sin((i / (N - 1)) * Math.PI));
      }
      sloshV += Math.max(-45, Math.min(45, -d * 1600));
      energy = Math.min(1, energy + Math.abs(d) * 4);
    }
  }

  let px = null, py = null;
  function onMove(e) {
    const x = e.clientX, y = e.clientY;
    if (x == null) return;
    if (px !== null) {
      const dx = x - px, dy = y - py;
      const speed = Math.hypot(dx, dy);
      tiltTarget = Math.max(-22, Math.min(22, tiltTarget + dx * 0.3));
      const sy = surfaceY(x);
      const near = y > sy - 190;                    // in or just above the beer
      const amp = Math.min(4.5, speed * 0.2) * (near ? 1 : 0.18);
      if (amp > 0.05) {
        // a wake: liquid piles up ahead of the drag and dips behind it
        splash(x + dx * 2.4, amp * (dy > 0 ? 1 : 0.6), 3.2);
        if (Math.abs(dx) > 2) splash(x - dx * 2.4, -amp * 0.45, 2.6);
      }
      // fast horizontal drags rock the whole glass
      sloshV += dx * (near ? 0.22 : 0.06);
      if (sloshV > 40) sloshV = 40; else if (sloshV < -40) sloshV = -40;
      energy = Math.min(1, energy + speed * 0.002);
    }
    px = x; py = y;
  }

  function onDown(e) {
    if (e.clientX == null) return;
    splash(e.clientX, 8, 5);
    sloshV += (e.clientX < W / 2 ? 1 : -1) * 5;
    energy = Math.min(1, energy + 0.25);
  }

  /* ---------- paint ---------- */
  // one smoothed pass along the surface, left → right
  function traceSurface() {
    const dx = W / SEGS;
    let xp = 0, yp = surfaceY(0);
    ctx.lineTo(0, yp);
    for (let i = 1; i <= SEGS; i++) {
      const x = i * dx, y = surfaceY(x);
      ctx.quadraticCurveTo(xp, yp, (xp + x) / 2, (yp + y) / 2);
      xp = x; yp = y;
    }
    ctx.lineTo(W, yp);
  }

  function draw() {
    ctx.clearRect(0, 0, W, H);
    const base = baseY();

    // lacing — broken foam residue left on the glass where the level receded
    ctx.fillStyle = "rgba(255,243,220,.55)";
    for (const l of laces) {
      let x = (l.seed % 47);
      let k = l.seed;
      while (x < W) {
        k = (k * 9301 + 49297) % 233280;          // cheap deterministic noise
        const seg = 14 + (k / 233280) * 46;
        k = (k * 9301 + 49297) % 233280;
        const gap = 18 + (k / 233280) * 70;
        ctx.globalAlpha = l.a * (0.55 + (k / 233280) * 0.45);
        ctx.fillRect(x, l.y + Math.sin(x * 0.02 + l.seed) * 1.4, seg, 1.1);
        x += seg + gap;
      }
    }
    ctx.globalAlpha = 1;

    // body of the beer
    ctx.beginPath();
    ctx.moveTo(0, H + 2);
    traceSurface();
    ctx.lineTo(W, H + 2);
    ctx.closePath();

    const g = ctx.createLinearGradient(0, base - 40, 0, H);
    g.addColorStop(0, "rgba(255,212,124,.66)");
    g.addColorStop(0.14, "rgba(249,176,64,.60)");
    g.addColorStop(0.46, "rgba(226,133,38,.54)");
    g.addColorStop(1, "rgba(150,76,20,.56)");
    ctx.fillStyle = g;
    ctx.fill();

    ctx.save();
    ctx.clip();

    // light raking through just under the surface
    const lit = ctx.createLinearGradient(0, base - 22, 0, base + 110);
    lit.addColorStop(0, "rgba(255,232,172,.34)");
    lit.addColorStop(1, "rgba(255,190,90,0)");
    ctx.fillStyle = lit;
    ctx.fillRect(0, base - 60, W, 190);

    // curvature — the glass darkens at the edges, lifts through the middle
    const cur = ctx.createLinearGradient(0, 0, W, 0);
    cur.addColorStop(0, "rgba(58,26,5,.34)");
    cur.addColorStop(0.13, "rgba(58,26,5,0)");
    cur.addColorStop(0.5, "rgba(255,228,164,.05)");
    cur.addColorStop(0.87, "rgba(58,26,5,0)");
    cur.addColorStop(1, "rgba(58,26,5,.34)");
    ctx.fillStyle = cur;
    ctx.fillRect(0, base - 30, W, H - base + 40);

    // texture: fine haze suspended in the liquid
    if (grain) {
      ctx.globalAlpha = 0.5;
      ctx.fillStyle = grain;
      ctx.fillRect(0, base - 20, W, H - base + 20);
      ctx.globalAlpha = 1;
    }
    // soft light columns where the bubble streams rise
    if (!reduce) {
      for (const s2 of streams) {
        const drift = Math.sin(t * 0.0005 + s2.x) * 8;
        const col = ctx.createLinearGradient(0, H, 0, base);
        col.addColorStop(0, "rgba(255,214,140," + s2.glow + ")");
        col.addColorStop(0.7, "rgba(255,224,160," + (s2.glow * 0.3) + ")");
        col.addColorStop(1, "rgba(255,230,170,0)");
        ctx.fillStyle = col;
        ctx.fillRect(s2.x + drift - s2.w / 2, base, s2.w, H - base);
      }
    }

    // carbonation
    if (!reduce) {
      ctx.lineWidth = 1;
      for (const b of bubbles) {
        const rise = Math.min(1, b.sp / 90);
        const bx = b.x + Math.sin(t * 0.002 * b.wf + b.ph) * b.sw * (3 + 9 * rise);
        const by = H - b.depth;
        ctx.beginPath();
        ctx.arc(bx, by, b.r, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(255,240,200,.20)";
        ctx.fill();
        ctx.strokeStyle = "rgba(255,246,214,.45)";
        ctx.stroke();
        // a glint on the shoulder of the bigger bubbles
        if (!mobile && b.r > 1.6) {
          ctx.beginPath();
          ctx.arc(bx - b.r * 0.35, by - b.r * 0.35, b.r * 0.3, 0, Math.PI * 2);
          ctx.fillStyle = "rgba(255,250,235,.5)";
          ctx.fill();
        }
      }
    }
    ctx.restore();

    if (level < 0.995) {
      // the head — a band of foam riding the surface
      const dx = W / SEGS;
      ctx.beginPath();
      ctx.moveTo(0, surfaceY(0) - foamAt(0));
      let xp = 0, yp = surfaceY(0) - foamAt(0);
      for (let i = 1; i <= SEGS; i++) {
        const x = i * dx;
        const y = surfaceY(x) - foamAt(x)
          - Math.sin(x * 0.045 + t * 0.0007) * 0.9;   // irregular top edge
        ctx.quadraticCurveTo(xp, yp, (xp + x) / 2, (yp + y) / 2);
        xp = x; yp = y;
      }
      ctx.lineTo(W, surfaceY(W) + 2);
      for (let i = SEGS; i >= 0; i--) {
        const x = i * dx;
        ctx.lineTo(x, surfaceY(x) + 2);
      }
      ctx.closePath();
      const fg = ctx.createLinearGradient(0, base - 22, 0, base + 4);
      fg.addColorStop(0, "rgba(255,249,234,.78)");
      fg.addColorStop(0.55, "rgba(255,242,214,.52)");
      fg.addColorStop(1, "rgba(255,234,198,.26)");
      ctx.fillStyle = fg;
      ctx.fill();
      ctx.save();
      ctx.clip();
      // bubble grain inside the head
      for (const fb of foamBits) {
        const fx = fb.x * W;
        const th = foamAt(fx);
        const fy = surfaceY(fx) - th + fb.yf * (th + 2);
        ctx.beginPath();
        ctx.arc(fx, fy, fb.r, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(255,250,236," + fb.o + ")";
        ctx.fill();
      }
      // a darker seam where foam meets beer
      ctx.beginPath();
      ctx.moveTo(0, surfaceY(0) + 1);
      traceSurface();
      ctx.strokeStyle = "rgba(140,72,22,.30)";
      ctx.lineWidth = 2.4;
      ctx.stroke();
      ctx.restore();
      // the bright lip along the top of the head
      ctx.beginPath();
      ctx.moveTo(0, surfaceY(0) - foamAt(0));
      for (let i = 1; i <= SEGS; i++) {
        const x = i * dx;
        ctx.lineTo(x, surfaceY(x) - foamAt(x) - Math.sin(x * 0.045 + t * 0.0007) * 0.9);
      }
      ctx.strokeStyle = "rgba(255,252,242,.55)";
      ctx.lineWidth = 1.3;
      ctx.stroke();

      // specular glints where the surface tilts toward the light
      if (!mobile) {
      ctx.lineWidth = 1.1;
      for (let i = 1; i <= SEGS; i++) {
        const x0 = (i - 1) * dx, x1 = i * dx;
        const y0 = surfaceY(x0), y1 = surfaceY(x1);
        const slope = (y1 - y0) / dx;
        if (slope < -0.05) {
          ctx.globalAlpha = Math.min(0.5, -slope * 1.8);
          ctx.beginPath();
          ctx.moveTo(x0, y0 + 2.2);
          ctx.lineTo(x1, y1 + 2.2);
          ctx.strokeStyle = "rgba(255,250,232,.85)";
          ctx.stroke();
        }
      }
      }
      ctx.globalAlpha = 1;

      // bright meniscus — glow faked with a wide soft under-stroke
      // (shadowBlur was the most expensive call in the whole frame)
      ctx.beginPath();
      ctx.moveTo(0, surfaceY(0));
      traceSurface();
      ctx.strokeStyle = "rgba(255,206,130,.16)";
      ctx.lineWidth = 7;
      ctx.stroke();
      ctx.strokeStyle = "rgba(255,240,206,.5)";
      ctx.lineWidth = 1.6;
      ctx.stroke();
    }
  }

  /* ---------- loop ---------- */
  let last = 0;
  function frame(now) {
    const dt = Math.min(48, now - last || 16) / 1000;
    last = now;
    t = now;

    level += (target - level) * 0.075;

    // lacing: as the level recedes, leave rings behind on the glass
    const base = baseY();
    if (base > laceAnchor + 24) {
      laces.push({
        y: laceAnchor + 2,
        a: 0.06 + Math.min(0.06, energy * 0.12),
        seed: Math.random() * 1000
      });
      if (laces.length > 12) laces.shift();
      laceAnchor = base;
    } else if (base < laceAnchor - 2) {
      laceAnchor = base;                      // filling again — reset the anchor
    }
    for (let i = laces.length - 1; i >= 0; i--) {
      const l = laces[i];
      l.a *= 0.997;
      if (l.a < 0.015 || l.y > baseY() - 2) laces.splice(i, 1);
    }

    physics(dt);

    // carbonation streams breathe new bubbles in from their nucleation points
    for (const s of streams) {
      s.next -= dt;
      if (s.next <= 0 && bubbles.length < (mobile ? 60 : 90)) {
        bubbles.push(newBubble(false, s.x));
        s.next = s.rate * (0.5 + Math.random());
      }
    }
    // bubbles accelerate as they rise, pop at the surface, feed the head
    for (let i = bubbles.length - 1; i >= 0; i--) {
      const b = bubbles[i];
      b.sp = Math.min(120, b.sp + (16 + b.r * 22) * dt);   // buoyancy
      b.depth += b.sp * dt;
      const by = H - b.depth;
      const sy = surfaceY(b.x);
      if (by <= sy + b.r) {
        splash(b.x, -0.9 - b.r * 0.25, 2.2);
        const fi = Math.round((b.x / Math.max(W, 1)) * (N - 1));
        if (fi >= 0 && fi < N) foamH[fi] = Math.min(20, foamH[fi] + 1.2 + b.r * 0.6);
        if (bubbles.length > 60) { bubbles.splice(i, 1); continue; }
        Object.assign(b, newBubble(false));
      } else if (b.depth > H + 60) {
        Object.assign(b, newBubble(false));
      }
    }

    for (const fb of foamBits) {
      fb.x += fb.d * (1 + energy * 4);
      if (fb.x < -0.02) fb.x = 1.02; else if (fb.x > 1.02) fb.x = -0.02;
    }

    draw();
    requestAnimationFrame(frame);
  }

  /* ---------- go ---------- */
  window.addEventListener("resize", resize, { passive: true });
  window.addEventListener("orientationchange", resize, { passive: true });
  window.addEventListener("scroll", onScroll, { passive: true });

  resize();
  // Landing part-way down the page (deep link, restored scroll) should start at
  // that level, not pour up from empty.
  if (target > REST + 0.02) level = target;
  laceAnchor = baseY();
  sweep();
  draw();                       // paint immediately — never a blank frame
  canvas.classList.add("lit");

  if (reduce) {
    // hold a still, level pint that only follows scroll
    window.addEventListener("scroll", () => { level = target; draw(); }, { passive: true });
  } else {
    window.addEventListener("pointermove", onMove, { passive: true });
    window.addEventListener("pointerdown", onDown, { passive: true });
    window.addEventListener("pointerleave", () => { px = py = null; }, { passive: true });
    requestAnimationFrame(frame);
  }
})();
