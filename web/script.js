/* =========================================================
   Kitty — landing page script
   - Pot: live wave motion + scroll-coupled fill
   - Ledger tape: autonomous streaming rows
   - Problem counter: eased count-up on reveal
   - IntersectionObserver reveals
   ========================================================= */

(() => {
  const prefersReducedMotion =
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------------------------------------------------
     1. THE POT — wavy liquid top
     --------------------------------------------------------- */
  const liquid = document.querySelector(".liquid-path");
  const liquidFront = document.querySelector(".liquid-front");
  const root = document.documentElement;

  // Build a sine-wave path along the TOP of the liquid rectangle.
  // Bottom is fixed well below the bowl. We animate d over time.
  const W = 400;
  const STEP = 8;
  let t = 0;

  function buildWavePath(amp, phase, freq, offset) {
    const points = [];
    for (let x = 0; x <= W; x += STEP) {
      const y = offset + Math.sin((x / W) * Math.PI * freq + phase) * amp;
      points.push([x, y]);
    }
    let d = `M 0 ${520} L 0 ${points[0][1].toFixed(2)}`;
    for (const [x, y] of points) d += ` L ${x} ${y.toFixed(2)}`;
    d += ` L ${W} ${520} Z`;
    return d;
  }

  function animatePot() {
    if (!liquid) return;
    t += 0.018;
    liquid.setAttribute("d", buildWavePath(5.5, t, 4.2, 6));
    if (liquidFront)
      liquidFront.setAttribute(
        "d",
        buildWavePath(4.2, t * 1.3 + 1.5, 3.6, 16)
      );
    requestAnimationFrame(animatePot);
  }

  if (liquid && !prefersReducedMotion) requestAnimationFrame(animatePot);

  // Initial fill: starts at 0.35, settles to 0.72 a beat after load
  root.style.setProperty("--pot-fill", "0");
  window.addEventListener("load", () => {
    setTimeout(() => {
      root.style.setProperty("--pot-fill", "0.72");
    }, 350);
  });

  // Scroll couples the fill between 0.72 and 0.92 as user scrolls the hero
  let scrollRaf = 0;
  function onScroll() {
    if (scrollRaf) return;
    scrollRaf = requestAnimationFrame(() => {
      scrollRaf = 0;
      const progress = Math.min(1, window.scrollY / 900);
      // gentle ease
      const eased = 0.72 + (1 - Math.cos(progress * Math.PI)) * 0.1;
      root.style.setProperty("--pot-fill", eased.toFixed(3));
    });
  }
  window.addEventListener("scroll", onScroll, { passive: true });


  /* ---------------------------------------------------------
     2. LEDGER TAPE — autonomous row streamer
     --------------------------------------------------------- */
  const tape = document.getElementById("tape-live");

  const names = ["Asha", "Tunde", "Priya", "Malik", "Amina", "Kofi"];
  const pool = { v: 4500 };

  const scripts = [
    // [type, actor, message, amount, amountClass]
    () => {
      const n = pick(names);
      return {
        type: "contribute.staged",
        evt: "contribute.staged",
        actor: n.toLowerCase(),
        msg: `linked pair staged · bunq→gateway · pool ${pool.v}/1500`,
        amt: "+€250",
        cls: "amt--info",
      };
    },
    () => {
      const n = pick(names);
      pool.v = Math.min(pool.v + 250, 6000);
      return {
        type: "contribute.posted",
        evt: "contribute.posted",
        actor: n.toLowerCase(),
        msg: `bunq webhook · PAYMENT.CREATED · tb batch ok`,
        amt: "+€250",
        cls: "amt--pos",
      };
    },
    () => ({
      type: "reminder.sent",
      evt: "reminder.sent",
      actor: "coby",
      msg: `tone=gentle → tunde · day 3 · "no sweat, we've got you"`,
      amt: "-",
      cls: "amt--info",
    }),
    () => ({
      type: "mediator.verdict",
      evt: "mediator.verdict",
      actor: "moti",
      msg: `read TB · read bunq · verdict=verified_paid · correction posted`,
      amt: "Δ 0",
      cls: "amt--info",
    }),
    () => ({
      type: "charter.signed",
      evt: "charter.signed",
      actor: "connie",
      msg: `cycle 4 charter · 6/6 co-signed · FaceID ok`,
      amt: "✓",
      cls: "amt--info",
    }),
    () => {
      pool.v = Math.max(pool.v - 750, 0);
      return {
        type: "emergency.executed",
        evt: "emergency.executed",
        actor: "ella",
        msg: `priya exit · buyout computed · linked batch atomic`,
        amt: "-€750",
        cls: "amt--neg",
      };
    },
    () => {
      pool.v = 0;
      return {
        type: "payout.posted",
        evt: "payout.posted",
        actor: "kalu",
        msg: `cycle 4 → tunde · pool→gateway→member_received · posted`,
        amt: "-€1,500",
        cls: "amt--neg",
      };
    },
    () => ({
      type: "passport.issued",
      evt: "passport.issued",
      actor: "ray",
      msg: `6 signed reputation events · median Δ+14 · passports synced`,
      amt: "✓",
      cls: "amt--info",
    }),
  ];

  function pick(arr) {
    return arr[Math.floor(Math.random() * arr.length)];
  }

  function now() {
    const d = new Date();
    return [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((n) => String(n).padStart(2, "0"))
      .join(":");
  }

  function makeRow({ type, evt, actor, msg, amt, cls }) {
    const row = document.createElement("div");
    row.className = "tape-row";
    row.dataset.type = type;
    row.innerHTML = `
      <span class="time">${now()}</span>
      <span class="evt">${evt}</span>
      <span class="actor">${actor}</span>
      <span class="msg">${msg}</span>
      <span class="amt ${cls}">${amt}</span>
    `;
    return row;
  }

  function prunePastHeight() {
    if (!tape) return;
    // keep tape element at its container height — remove rows that
    // have scrolled out of view (top-most children)
    while (tape.children.length > 20) tape.removeChild(tape.firstChild);
  }

  let cursor = 0;
  function streamRow() {
    if (!tape) return;
    // choose which event next — weight towards contributes
    const weights = [2, 3, 1, 0.5, 0.3, 0.3, 0.4, 0.5];
    let r = Math.random() * weights.reduce((a, b) => a + b, 0);
    let idx = 0;
    for (let i = 0; i < weights.length; i++) {
      if ((r -= weights[i]) <= 0) {
        idx = i;
        break;
      }
    }
    const data = scripts[idx]();
    const row = makeRow(data);
    tape.appendChild(row);
    row.scrollIntoView({ block: "end", behavior: "smooth" });
    prunePastHeight();
  }

  // seed initial rows so the tape isn't empty
  function seedTape() {
    if (!tape) return;
    // drop a plausible cycle recap as seed
    const seed = [
      { type: "charter.signed", evt: "charter.signed", actor: "connie", msg: "lagos_crew charter sealed · 6/6 signed · FaceID ok", amt: "✓", cls: "amt--info" },
      { type: "contribute.posted", evt: "contribute.posted", actor: "asha",   msg: "bunq→gateway posted · tb linked batch", amt: "+€250", cls: "amt--pos" },
      { type: "contribute.posted", evt: "contribute.posted", actor: "tunde",  msg: "bunq→gateway posted · tb linked batch", amt: "+€250", cls: "amt--pos" },
      { type: "reminder.sent",     evt: "reminder.sent",     actor: "coby",   msg: "tone=gentle → malik · day 3", amt: "-", cls: "amt--info" },
      { type: "contribute.posted", evt: "contribute.posted", actor: "malik",  msg: "bunq→gateway posted · tb linked batch", amt: "+€250", cls: "amt--pos" },
      { type: "contribute.posted", evt: "contribute.posted", actor: "amina",  msg: "bunq→gateway posted · tb linked batch", amt: "+€250", cls: "amt--pos" },
      { type: "mediator.verdict",  evt: "mediator.verdict",  actor: "moti",   msg: "read tb + bunq · verdict=verified_paid cycle 3", amt: "Δ 0", cls: "amt--info" },
      { type: "contribute.posted", evt: "contribute.posted", actor: "priya",  msg: "bunq→gateway posted · tb linked batch", amt: "+€250", cls: "amt--pos" },
    ];
    seed.forEach((d, i) => {
      setTimeout(() => {
        tape.appendChild(makeRow(d));
      }, i * 40);
    });
  }

  // start streaming only when ledger section is in view
  const tapeSection = document.querySelector(".ledger");
  if (tape && tapeSection && "IntersectionObserver" in window) {
    let started = false;
    let interval = null;
    const obs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting && !started) {
            started = true;
            seedTape();
            setTimeout(() => {
              if (!prefersReducedMotion) {
                interval = setInterval(streamRow, 2400);
              }
            }, 600);
          } else if (!e.isIntersecting && interval) {
            clearInterval(interval);
            interval = null;
            started = false;
          }
        }
      },
      { threshold: 0.2 }
    );
    obs.observe(tapeSection);
  }


  /* ---------------------------------------------------------
     3. Big number count-up
     --------------------------------------------------------- */
  const numEls = document.querySelectorAll(".huge-num[data-target]");
  numEls.forEach((el) => {
    const target = parseFloat(el.dataset.target);
    let done = false;
    const startCount = () => {
      if (done) return;
      done = true;
      const duration = 1600;
      const start = performance.now();
      function tick(now) {
        const p = Math.min(1, (now - start) / duration);
        const eased = 1 - Math.pow(1 - p, 3);
        el.textContent = Math.round(target * eased);
        if (p < 1) requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    };
    if ("IntersectionObserver" in window) {
      const io = new IntersectionObserver(
        (entries) => {
          for (const e of entries) if (e.isIntersecting) startCount();
        },
        { threshold: 0.4 }
      );
      io.observe(el);
    } else startCount();
  });


  /* ---------------------------------------------------------
     4. Reveal-on-scroll for section content
     --------------------------------------------------------- */
  const revealTargets = document.querySelectorAll(
    ".section-head, .plane, .how-step, .agent-card, .safety-list li, .stat-card"
  );
  revealTargets.forEach((el) => el.classList.add("reveal"));

  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            e.target.classList.add("in");
            io.unobserve(e.target);
          }
        }
      },
      { threshold: 0.15, rootMargin: "0px 0px -40px 0px" }
    );
    revealTargets.forEach((el) => io.observe(el));
  } else {
    revealTargets.forEach((el) => el.classList.add("in"));
  }
})();
