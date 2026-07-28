/* seshapp.xyz — the pint.
 *
 * One fixed canvas behind the page. The beer level tracks scroll (a sip at the
 * top, brim-full at the bottom) and the surface is a 1-D spring lattice, so the
 * pointer stirs real waves that travel and bounce off the edges. Bubbles rise
 * and nudge the surface when they pop. One rAF loop, no dependencies.
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
  const DAMP = 0.985;
  const SPREAD = 0.18;              // wave speed — must stay under .5 to be stable
  const CLAMP = 34;

  const REST = 0.055;               // level with the page at the very top
  let level = REST, target = REST;  // 0 = empty, 1 = full viewport
  let tilt = 0, tiltTarget = 0;     // liquid leaning toward the pointer
  let energy = 0;                   // recent agitation, drives wave size
  let t = 0;

  let W = 0, H = 0;
  let bubbles = [], foam = [];

  /* ---------- setup ---------- */
  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    seed();
    onScroll();
    if (reduce) draw();
  }

  function seed() {
    const nb = Math.round(Math.max(20, Math.min(54, W / 24)));
    bubbles = [];
    for (let i = 0; i < nb; i++) bubbles.push(newBubble(Math.random()));
    const nf = Math.round(Math.max(26, Math.min(80, W / 15)));
    foam = [];
    for (let i = 0; i < nf; i++) {
      foam.push({
        x: Math.random(),
        r: 1.6 + Math.random() * 5.2,
        o: 0.18 + Math.random() * 0.5,
        d: (Math.random() - 0.5) * 0.00013,   // slow drift
        y: Math.random() * 7
      });
    }
  }

  // depth = px above the bottom of the viewport
  function newBubble(seeded) {
    return {
      x: Math.random() * W,
      depth: seeded ? Math.random() * H : -Math.random() * 40,
      r: 1.1 + Math.random() * 3.1,
      sp: 14 + Math.random() * 46,          // px per second
      ph: Math.random() * Math.PI * 2,
      sw: 0.3 + Math.random() * 1.5         // sway
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
    const amb = (Math.sin(x * 0.0085 + t * 0.0011) * 2.1
               + Math.sin(x * 0.019 - t * 0.0017) * 1.15) * (1 + energy * 2.6);
    return baseY() + disp + lean + amb;
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

  function physics() {
    // travelling waves: discrete Laplacian, reflecting off the glass walls
    for (let i = 0; i < N; i++) {
      const l = h[i > 0 ? i - 1 : 0];
      const r = h[i < N - 1 ? i + 1 : N - 1];
      acc[i] = SPREAD * (l + r - 2 * h[i]);
    }
    for (let i = 0; i < N; i++) {
      vel[i] += acc[i] - K * h[i];
      vel[i] *= DAMP;
      h[i] += vel[i];
      if (h[i] > CLAMP) { h[i] = CLAMP; vel[i] *= -0.4; }
      else if (h[i] < -CLAMP) { h[i] = -CLAMP; vel[i] *= -0.4; }
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
    const doc = document.documentElement;
    const max = doc.scrollHeight - window.innerHeight;
    const p = max > 4 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
    target = REST + p * (1 - REST);
    const d = target - lastP;
    lastP = target;
    if (!reduce && Math.abs(d) > 0.0002) {
      // pouring in / tipping out rocks the whole surface
      const imp = Math.max(-7, Math.min(7, -d * 340));
      for (let i = 0; i < N; i++) {
        vel[i] += imp * (0.55 + 0.45 * Math.sin((i / (N - 1)) * Math.PI));
      }
      energy = Math.min(1, energy + Math.abs(d) * 7);
    }
  }

  let px = null, py = null;
  function onMove(e) {
    const x = e.clientX, y = e.clientY;
    if (x == null) return;
    if (px !== null) {
      const dx = x - px, dy = y - py;
      const speed = Math.hypot(dx, dy);
      tiltTarget = Math.max(-30, Math.min(30, tiltTarget + dx * 0.55));
      const sy = surfaceY(x);
      const near = y > sy - 190;                    // in or just above the beer
      const amp = Math.min(8, speed * 0.42) * (near ? 1 : 0.22);
      if (amp > 0.05) splash(x, amp * (dy > 0 ? 1 : 0.55), 3.4);
      energy = Math.min(1, energy + speed * 0.0035);
    }
    px = x; py = y;
  }

  function onDown(e) {
    if (e.clientX == null) return;
    splash(e.clientX, 13, 5.5);
    energy = Math.min(1, energy + 0.4);
  }

  /* ---------- paint ---------- */
  // one smoothed pass along the surface, left → right
  const SEGS = 64;
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

    // carbonation
    if (!reduce) {
      ctx.lineWidth = 1;
      for (const b of bubbles) {
        const bx = b.x + Math.sin(t * 0.0016 + b.ph) * b.sw * 7;
        const by = H - b.depth;
        ctx.beginPath();
        ctx.arc(bx, by, b.r, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(255,240,200,.22)";
        ctx.fill();
        ctx.strokeStyle = "rgba(255,246,214,.5)";
        ctx.stroke();
      }
    }
    ctx.restore();

    // the head — foam sitting on the surface
    if (level < 0.995) {
      ctx.save();
      for (const f of foam) {
        const fx = f.x * W;
        const fy = surfaceY(fx) + f.y - f.r * 0.35;
        ctx.beginPath();
        ctx.arc(fx, fy, f.r, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(255,243,220," + f.o * 0.5 + ")";
        ctx.fill();
      }
      // bright meniscus
      ctx.beginPath();
      ctx.moveTo(0, surfaceY(0));
      traceSurface();
      ctx.strokeStyle = "rgba(255,240,206,.5)";
      ctx.lineWidth = 1.6;
      ctx.shadowColor = "rgba(255,206,130,.55)";
      ctx.shadowBlur = 14;
      ctx.stroke();
      ctx.restore();
    }
  }

  /* ---------- loop ---------- */
  let last = 0;
  function frame(now) {
    const dt = Math.min(48, now - last || 16) / 1000;
    last = now;
    t = now;

    level += (target - level) * 0.075;

    physics();

    // bubbles rise, pop at the surface, respawn at the bottom
    for (const b of bubbles) {
      b.depth += b.sp * dt;
      const by = H - b.depth;
      const sy = surfaceY(b.x);
      if (by <= sy + b.r) {
        splash(b.x, -1.1 - b.r * 0.25, 2.2);
        Object.assign(b, newBubble(false));
      } else if (b.depth > H + 60) {
        Object.assign(b, newBubble(false));
      }
    }
    for (const f of foam) {
      f.x += f.d * (1 + energy * 5);
      if (f.x < -0.02) f.x = 1.02;
      else if (f.x > 1.02) f.x = -0.02;
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
