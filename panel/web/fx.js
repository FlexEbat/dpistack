// Background field of slow drifting points joined by faint lines. It sits
// behind the content, stays dim, stops when the tab is hidden and draws one
// still frame under prefers-reduced-motion.
(() => {
  const canvas = document.getElementById("fx");
  const ctx = canvas && canvas.getContext("2d");
  if (!ctx) return;
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const LINK = 150;
  let w = 0, h = 0, dpr = 1, nodes = [], raf = 0;

  function seed() {
    dpr = Math.min(devicePixelRatio || 1, 2);
    w = innerWidth; h = innerHeight;
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const n = Math.max(24, Math.min(70, Math.round((w * h) / 24000)));
    nodes = Array.from({ length: n }, () => ({
      x: Math.random() * w, y: Math.random() * h,
      vx: (Math.random() - 0.5) * 0.12, vy: (Math.random() - 0.5) * 0.12,
      r: 0.6 + Math.random() * 1.2, p: Math.random() * 6.28, d: 0.4 + Math.random() * 0.6,
    }));
  }

  function frame(t) {
    ctx.clearRect(0, 0, w, h);
    for (const a of nodes) {
      if (!still) {
        a.x += a.vx * a.d; a.y += a.vy * a.d;
        if (a.x < -20) a.x = w + 20; else if (a.x > w + 20) a.x = -20;
        if (a.y < -20) a.y = h + 20; else if (a.y > h + 20) a.y = -20;
      }
    }
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j], dx = a.x - b.x, dy = a.y - b.y, d2 = dx * dx + dy * dy;
        if (d2 < LINK * LINK) {
          ctx.strokeStyle = `rgba(140,180,255,${(1 - Math.sqrt(d2) / LINK) * 0.16})`;
          ctx.lineWidth = 0.6;
          ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
        }
      }
    }
    for (const a of nodes) {
      const pulse = still ? 0.6 : 0.45 + 0.25 * Math.sin(t / 2600 + a.p);
      ctx.fillStyle = `rgba(190,215,255,${pulse * a.d})`;
      ctx.beginPath(); ctx.arc(a.x, a.y, a.r, 0, 6.28); ctx.fill();
    }
    if (!still) raf = requestAnimationFrame(frame);
  }

  function start() { cancelAnimationFrame(raf); seed(); raf = requestAnimationFrame(frame); }
  let timer = 0;
  addEventListener("resize", () => { clearTimeout(timer); timer = setTimeout(start, 200); });
  document.addEventListener("visibilitychange", () => {
    if (still) return;
    if (document.hidden) cancelAnimationFrame(raf); else raf = requestAnimationFrame(frame);
  });
  start();
})();
