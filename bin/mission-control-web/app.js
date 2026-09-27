// app.js - Mission Control's public page: draws snapshot.json as the office and three views.
// bin/fm_mission_control_web.py owns what snapshot.json may contain; this file only
// draws it. The office's movement (typing, z's, screens, walks, helpers coming and
// going) happens here, in the visitor's browser, between snapshots. Every value from
// the snapshot is written with textContent or drawn on the canvas, never as markup.
(function () {
  "use strict";

  // ---------- small helpers ----------
  const $ = (id) => document.getElementById(id);
  const HEX = /^#[0-9a-fA-F]{6}$/;
  const colour = (c, fallback) => (typeof c === "string" && HEX.test(c) ? c : fallback || "#7f8995");
  const str = (v) => (v === undefined || v === null ? "" : String(v));
  const num = (v) => (typeof v === "number" && isFinite(v) ? v : 0);
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }
  function mix(a, b, t) {
    const pa = parseInt(a.slice(1), 16), pb = parseInt(b.slice(1), 16);
    const r = Math.round(((pa >> 16) & 255) * (1 - t) + ((pb >> 16) & 255) * t);
    const g = Math.round(((pa >> 8) & 255) * (1 - t) + ((pb >> 8) & 255) * t);
    const bl = Math.round((pa & 255) * (1 - t) + (pb & 255) * t);
    return "#" + ((1 << 24) | (r << 16) | (g << 8) | bl).toString(16).slice(1);
  }
  const plural = (n, one, many) => n + " " + (n === 1 ? one : many || one + "s");

  // ---------- views and locks ----------
  const PUBLIC = ["office", "projects", "calendar", "team"];
  const LOCKED = { tasks: "Tasks", approvals: "Approvals", memory: "Memory", docs: "Docs", system: "System" };
  const ORDER = ["office", "tasks", "approvals", "projects", "calendar", "team", "memory", "docs", "system"];
  let view = "office";
  const toast = $("toast");
  function note(text) {
    toast.textContent = text;
    clearTimeout(note.t);
    note.t = setTimeout(() => { toast.textContent = ""; }, 4000);
  }
  function setView(v, fromHash) {
    if (PUBLIC.indexOf(v) < 0 && !LOCKED[v]) v = "office";
    view = v;
    document.querySelectorAll("#tabs button").forEach((b) => {
      if (b.dataset.view === v) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current");
    });
    PUBLIC.forEach((p) => { $("view-" + p).hidden = p !== v; });
    $("view-locked").hidden = !LOCKED[v];
    if (LOCKED[v]) drawLocked(v);
    endTalk();
    if (!fromHash && location.hash !== "#" + v) history.replaceState(null, "", "#" + v);
    drawView();
    running();
  }
  document.querySelectorAll("#tabs button").forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));
  window.addEventListener("hashchange", () => setView(location.hash.slice(1), true));

  // ---------- the snapshot ----------
  let snap = null;
  let fetchedAt = 0;
  const byKey = (list, key) => (list || []).find((x) => x.key === key);
  const proj = (k) => byKey(snap && snap.projects, k);
  const agent = (k) => byKey(snap && snap.agents, k);

  function ago(iso) {
    const t = Date.parse(iso);
    if (!isFinite(t)) return null;
    const m = Math.max(0, Math.floor((Date.now() - t) / 60000));
    if (m < 1) return { text: "just now", m };
    if (m < 60) return { text: plural(m, "minute") + " ago", m };
    const h = Math.floor(m / 60);
    if (h < 48) return { text: plural(h, "hour") + " ago", m };
    return { text: plural(Math.floor(h / 24), "day") + " ago", m };
  }
  function drawUpdated() {
    const u = $("updated");
    u.textContent = "";
    if (!snap) { u.textContent = fetchedAt ? "the latest snapshot could not be loaded" : "loading"; return; }
    const a = ago(snap.generated_at);
    const every = Math.max(1, num(snap.every_minutes) || 5);
    u.append("checked every " + plural(every, "minute") + " · updated ");
    u.append(el("b", "", a ? a.text : "at an unknown time"));
    const heartbeat = Math.max(every, num(snap.heartbeat_minutes) || 60);
    u.classList.toggle("stale", !a || a.m > heartbeat + Math.max(30, every * 3));
  }

  function load() {
    fetchedAt = Date.now();
    return fetch("snapshot.json?t=" + fetchedAt, { cache: "no-store" })
      .then((r) => { if (!r.ok) throw new Error(String(r.status)); return r.json(); })
      .then((data) => {
        if (!data || typeof data !== "object" || !Array.isArray(data.agents)) throw new Error("bad snapshot");
        const first = !snap;
        snap = data;
        officeFrom(first);
        drawUpdated();
        drawView();
      })
      .catch(() => { drawUpdated(); });
  }
  function everyMs() { return Math.max(1, num(snap && snap.every_minutes) || 5) * 60000; }
  setInterval(() => { if (!document.hidden && Date.now() - fetchedAt >= everyMs()) load(); }, 30000);
  setInterval(drawUpdated, 30000);
  const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  function drawClock() {
    const d = new Date();
    $("clock").textContent = DAYS[d.getDay()] + " " + String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  }
  drawClock();
  setInterval(drawClock, 15000);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && Date.now() - fetchedAt >= everyMs()) load();
    running();
  });

  // ---------- the office: geometry ----------
  const OW = 96, S = 10, BAND = 24;
  const P = {
    floorA: "#14171d", floorB: "#171b22", wall: "#1a2030", wallEdge: "#2a3348", desk: "#3b4250", deskTop: "#4a5364",
    deskD: "#262b34", frame: "#07090c", chair: "#232830", skin: "#e2b48f", wood: "#5a3e2b", woodD: "#3e2a1d",
    plant: "#3f9d5a", plantD: "#2c7443", pot: "#7a4a33", paper: "#e9e4d8", paperD: "#bdb6a6", rack: "#1d2129",
    table: "#4a3a2e", tableTop: "#5c493a", zzz: "#8fa3c7", label: "#6b7582", amber: "#ffb454", green: "#35d07f",
  };
  const cv = $("office");
  const ctx = cv.getContext("2d");
  const off = document.createElement("canvas");
  const octx = off.getContext("2d");
  let OH = 60, band = 0, walkY = 50, desks = {}, actors = [], upstairs = 0;
  let tick = 0, timers = [], paused = false, nextAmbient = 60;
  let PX = [], mask = null, texts = [];
  const reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) paused = true;

  function seat(d) { return { x: d.x + Math.floor(d.w / 2) - 3, y: d.y + 3 }; }
  function homeOf(a) {
    if (a.spot) return { x: a.spot.x, feet: a.spot.feet };
    const s = seat(a.desk);
    return { x: s.x, feet: s.y + 9 };
  }
  const DOOR = () => ({ x: 97, feet: walkY });
  const SPOTS = {
    cooler: () => ({ x: 19, feet: 21 }),
    shelf: () => ({ x: 75, feet: 17 }),
    tableL: () => ({ x: 30, feet: 57 + band }),
    tableR: () => ({ x: 57, feet: 57 + band }),
  };

  function route(p, q) {
    const top = (pt) => pt.feet < 30;
    const lane = (pt) => (pt.x < 60 ? 23 : 81);
    if (top(p) && top(q)) return [[p.x, 27], [q.x, 27], [q.x, q.feet]];
    const pts = [];
    if (top(p)) pts.push([p.x, 27], [lane(p), 27], [lane(p), walkY]); else pts.push([p.x, walkY]);
    if (top(q)) pts.push([lane(q), walkY], [lane(q), 27], [q.x, 27], [q.x, q.feet]);
    else pts.push([q.x, walkY], [q.x, q.feet]);
    return pts;
  }
  function at(dt, fn) { timers.push({ t: tick + dt, fn }); }
  function walk(a, to, cb) {
    if (a.talking) { a.pending = [to, cb]; return; }
    a.state = "walk";
    a.route = route({ x: a.x, feet: a.feet }, to);
    a.cb = cb || null;
  }
  function settle(a) {
    const h = homeOf(a);
    a.x = h.x; a.feet = h.feet;
    a.state = a.want;
  }
  function goHome(a, cb) { walk(a, homeOf(a), () => { settle(a); if (cb) cb(); }); }

  function officeFrom(first) {
    const agents = snap.agents || [];
    const mates = agents.filter((a) => a.kind === "mate");
    const helpers = agents.filter((a) => a.kind === "helper");
    const mateSig = mates.map((m) => m.key + "|" + m.name).join(",");
    if (first || mateSig !== officeFrom.sig) {
      officeFrom.sig = mateSig;
      buildOffice(agents, mates, helpers, first);
      return;
    }
    // Same desks: wake, sleep, and let helpers come and go.
    actors.filter((a) => !a.helper).forEach((a) => {
      const d = agents.find((x) => x.key === a.data.key);
      if (!d) return;
      const was = a.want;
      a.data = d;
      a.want = d.state === "working" ? "work" : "sleep";
      if (a.state === "work" || a.state === "sleep") {
        if (was === "sleep" && a.want === "work") { a.bang = 14; at(14, () => { if (a.state === "sleep") a.state = "work"; }); }
        else a.state = a.want;
      }
    });
    const sig = (h) => h.lead + "|" + h.name;
    const stay = [];
    const incoming = helpers.slice();
    actors.filter((a) => a.helper && a.state !== "gone").forEach((a) => {
      const i = incoming.findIndex((h) => sig(h) === sig(a.data));
      if (i >= 0) {
        const h = incoming.splice(i, 1)[0];
        a.data = h;
        a.want = h.state === "working" ? "work" : "idle";
        if (a.state === "work" || a.state === "idle") a.state = a.want;
        stay.push(a);
      } else {
        a.leaving = true;
        walk(a, DOOR(), () => { a.state = "gone"; });
      }
    });
    incoming.forEach((h) => { const a = helperActor(h, stay); if (a) enter(a, 0); });
  }

  function buildOffice(agents, mates, helpers, first) {
    const nHelpers = (m) => helpers.filter((h) => h.lead === m.key).length;
    let down = mates;
    if (mates.length > 6) {
      down = mates.slice().sort((a, b) => (a.state !== "working") - (b.state !== "working") || nHelpers(b) - nHelpers(a))
        .slice(0, 6);
      down = mates.filter((m) => down.indexOf(m) >= 0);
    }
    upstairs = mates.length - down.length;
    const rows = down.length > 3 ? 2 : 1;
    band = BAND * (rows - 1);
    OH = 60 + band;
    walkY = 50 + band;
    desks = {};
    const fm = agents.find((a) => a.kind === "first");
    if (fm) desks[fm.key] = { x: 34, y: 13, w: 21, two: true, cap: 4 };
    down.forEach((m, i) => {
      const row = Math.floor(i / 3), col = i % 3;
      desks[m.key] = { x: 1 + 29 * col, y: 33 + BAND * row, w: 13, two: false, cap: col === 2 ? 3 : 2 };
    });
    actors = [];
    timers = [];
    if (!talk.hidden) { talk.hidden = true; talker = null; }
    [fm].concat(down).filter(Boolean).forEach((d) => {
      const a = { data: d, desk: desks[d.key], trail: [], bang: 0, bubble: "" };
      a.want = d.state === "working" ? "work" : "sleep";
      settle(a);
      actors.push(a);
    });
    helpers.forEach((h, i) => {
      const a = helperActor(h, []);
      if (!a) return;
      if (first && !reduce) enter(a, 6 + i * 18); else settle(a);
    });
    const w = OW * S, h = OH * S;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    cv.width = w * dpr; cv.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    off.width = OW; off.height = OH;
    nextAmbient = tick + 40;
    render();
  }

  function helperActor(h, taken) {
    const lead = actors.find((a) => !a.helper && a.data.key === h.lead);
    if (!lead) return null;
    const d = lead.desk;
    const used = new Set(actors.filter((a) => a.helper && a.lead === lead && a.state !== "gone" && !a.leaving).map((a) => a.slot)
      .concat(taken.filter((a) => a.lead === lead).map((a) => a.slot)));
    let slot = 0;
    while (used.has(slot)) slot++;
    if (slot >= d.cap) return null;
    const a = {
      data: h, helper: true, lead, slot, trail: [], bang: 0, bubble: "",
      spot: { x: d.x + d.w + 1 + 7 * slot, feet: d.y + 11 },
    };
    a.want = h.state === "working" ? "work" : "idle";
    a.x = 97; a.feet = walkY; a.state = "gone";
    actors.push(a);
    return a;
  }
  function enter(a, delay) {
    a.state = "wait";
    at(delay, () => { a.x = 97; a.feet = walkY; goHome(a); });
  }

  // ---------- the office: movement ----------
  function stepWalkers() {
    actors.forEach((a) => {
      if (a.state !== "walk" || !a.route) return;
      const tgt = a.route[0];
      if (!tgt) { a.route = null; const cb = a.cb; a.cb = null; a.state = "stand"; if (cb) cb(); return; }
      if (a.x !== tgt[0]) a.x += Math.sign(tgt[0] - a.x); else if (a.feet !== tgt[1]) a.feet += Math.sign(tgt[1] - a.feet);
      a.trail.push([a.x + 3, a.feet]);
      if (a.trail.length > 90) a.trail.shift();
      if (a.x === tgt[0] && a.feet === tgt[1]) a.route.shift();
    });
    actors.forEach((a) => { if (a.state !== "walk" && a.trail.length && tick % 2 === 0) a.trail.shift(); });
  }
  const free = (a) => a.state === "work" && !a.leaving;
  function ambient() {
    // Only people who are really working get up; sleepers stay asleep.
    const sitters = actors.filter((a) => !a.helper && free(a));
    const standers = actors.filter((a) => a.helper && free(a));
    const pick = (list) => list[Math.floor(Math.random() * list.length)];
    const roll = Math.random();
    if (sitters.length >= 2 && roll < 0.35) {
      const a = pick(sitters), b = pick(sitters.filter((x) => x !== a));
      let met = 0;
      const sit = () => { if (++met < 2) return; [a, b].forEach((x) => { if (!x.talking) x.state = "meet"; }); at(70, () => { goHome(a); goHome(b); }); };
      walk(a, SPOTS.tableL(), sit);
      walk(b, SPOTS.tableR(), sit);
    } else if (sitters.length && roll < 0.8) {
      const a = pick(sitters);
      const to = Math.random() < 0.6 ? SPOTS.cooler() : SPOTS.shelf();
      walk(a, to, () => { a.state = "stand"; at(45, () => goHome(a)); });
    } else if (standers.length) {
      const a = pick(standers);
      walk(a, SPOTS.cooler(), () => { a.state = "stand"; at(35, () => goHome(a)); });
    }
  }
  function step() {
    tick++;
    actors.forEach((a) => { if (a.bang > 0) a.bang--; });
    const due = timers.filter((t) => t.t <= tick);
    timers = timers.filter((t) => t.t > tick);
    due.forEach((t) => t.fn());
    stepWalkers();
    if (tick >= nextAmbient) { ambient(); nextAmbient = tick + 160 + Math.floor(Math.random() * 200); }
  }

  // ---------- the office: drawing ----------
  function px(x, y, col, m) {
    x = Math.round(x); y = Math.round(y);
    if (x < 0 || y < 0 || x >= OW || y >= OH) return;
    PX[y * OW + x] = col;
    if (m) mask[y * OW + x] = 1;
  }
  function rect(x, y, w, h, col, m) { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) px(x + i, y + j, col, m); }
  function otext(x, y, s, fg, force, b) { texts.push({ x, y, s, fg, force, b }); }

  const LOCKS = [];
  function drawRoom() {
    for (let y = 0; y < OH; y++) for (let x = 0; x < OW; x++) PX[y * OW + x] = ((x >> 2) + (y >> 2)) % 2 ? P.floorA : P.floorB;
    rect(0, 0, OW, 7, P.wall); rect(0, 7, OW, 1, P.wallEdge);
    const hr = new Date().getHours(), day = hr >= 6 && hr < 18;
    // Alumni wall.
    rect(3, 1, 16, 5, "#151a26");
    for (let i = 0; i < 3; i++) { const fx = 4 + i * 5; rect(fx, 1, 4, 5, "#8a6d2b"); rect(fx + 1, 2, 2, 3, "#0f131b"); }
    otext(4, 8, "alumni", P.label);
    // Window: day sky, or a night sky that twinkles.
    rect(40, 1, 16, 5, "#10141d");
    for (let j = 0; j < 3; j++) for (let i = 0; i < 14; i++) {
      let c = day ? mix("#4f7fb8", "#7fa9d9", j / 3) : "#0d1628";
      if (!day && (i * 7 + j * 13 + 40) % 23 === 0 && ((tick >> 3) + i) % 5) c = "#c9d6ff";
      px(41 + i, 2 + j, c);
    }
    rect(48, 1, 1, 5, "#10141d");
    // Corkboard: the Tasks view, locked; its notes show what waits, what is in flight and what is done.
    rect(22, 1, 14, 5, "#6e5334"); rect(22, 1, 14, 1, "#8a6a43");
    const tot = (k) => (snap.projects || []).reduce((s, p) => s + num(p.counts && p.counts[k]), 0);
    [["#ffb454", num(snap.office && snap.office.inbox)], ["#35d07f", tot("in_flight")], ["#7f8995", tot("done_month")]].forEach(([c, n], i) => {
      const k = n === 0 ? 0 : Math.min(3, 1 + Math.floor(n / 12));
      for (let j = 0; j < k; j++) { px(24 + i * 4, 2 + j, c); px(25 + i * 4, 2 + j, c); }
    });
    otext(23, 8, "tasks", P.label);
    LOCKS.push([29, 8]);
    // Wall calendar: the Calendar view, open to everyone.
    rect(60, 1, 9, 6, P.paper); rect(60, 1, 9, 1, "#d0493f");
    for (let j = 0; j < 2; j++) for (let i = 0; i < 4; i++) px(61 + i * 2, 3 + j * 2, i === 2 && j === 1 ? "#d0493f" : "#9aa0aa");
    otext(60, 8, "plan", P.label);
    // Bookshelf: Memory and Docs, locked.
    rect(72, 1, 13, 6, P.woodD); rect(72, 3, 13, 1, "#2a1c13");
    const books = ["#3fb6c9", "#7b93ff", "#e6b422", "#c678dd", "#2fbf71", "#d0493f", "#e9e4d8"];
    for (let i = 0; i < 11; i++) {
      px(73 + i, 1, books[i % 7]); px(73 + i, 2, books[(i + 3) % 7]); px(73 + i, 4, books[(i + 5) % 7]); px(73 + i, 5, books[(i + 1) % 7]);
    }
    otext(73, 8, "memory", P.label);
    LOCKS.push([80, 8]);
    rect(57, 2, 2, 2, P.paper); px(57, 2, "#1b1b1b");
    rect(28, 50 + band, 38, 10, "#191620"); rect(28, 50 + band, 38, 1, "#241f2e");
    [[2, 11], [84, 50 + band]].forEach(([x, y]) => {
      rect(x + 1, y, 3, 3, P.plant); px(x, y + 1, P.plantD); px(x + 4, y + 1, P.plantD); rect(x + 1, y + 3, 3, 3, P.pot);
    });
    // Server rack: the System view, locked.
    rect(88, 9, 7, 16, P.rack); rect(88, 9, 7, 1, "#2a303b");
    for (let j = 0; j < 6; j++) {
      const on = ((tick >> 2) + j * 3) % 7 !== 0;
      px(90, 11 + j * 2, on ? "#35d07f" : "#1f5a3a");
      px(92, 11 + j * 2, j === 2 && (tick >> 3) % 2 ? "#ffb454" : "#1f5a3a");
    }
    otext(87, 26, "system", P.label);
    LOCKS.push([94, 26]);
    // Water cooler.
    rect(28, 10, 3, 3, "#5aa6d6"); rect(27, 13, 5, 5, "#c8ccd4"); px(29, 15, "#3b82c4");
    // The captain's door and the inbox: Approvals, locked.
    rect(1, 49 + band, 8, 11, P.wood); rect(1, 49 + band, 8, 1, P.woodD); px(7, 55 + band, "#e6b422");
    otext(1, 50 + band, "CAPTAIN", P.amber, false, true);
    const inbox = num(snap.office && snap.office.inbox);
    rect(10, 59 + band, 7, 1, "#6b7280");
    for (let j = 0; j < Math.min(8, Math.ceil(inbox / 8)); j++) rect(11, 58 + band - j, 5, 1, j % 2 ? P.paperD : P.paper);
    const lbl = "inbox " + inbox;
    otext(18, 56 + band, lbl, P.amber, false, true);
    LOCKS.push([18 + lbl.length + 1, 56 + band]);
    // The visitor door, where helpers come and go.
    rect(95, 48 + band, 1, 10, "#0a0c10"); rect(94, 47 + band, 2, 1, P.wallEdge); rect(94, 58 + band, 2, 1, P.wallEdge);
    for (let y = -2; y <= 2; y++) for (let x = -10; x <= 10; x++) {
      if ((x * x) / 100 + (y * y) / 5.2 <= 1) px(46 + x, 55 + band + y, y < 0 ? P.tableTop : P.table);
    }
    [[38, 51], [46, 51], [54, 51], [40, 59], [52, 59]].forEach(([x, y]) => rect(x, y + band, 3, 1, P.chair));
    if (upstairs > 0) otext(62, 28, "+" + upstairs + " upstairs", P.label);
    // Helpers beyond a desk's places are counted beside it.
    actors.filter((a) => !a.helper).forEach((a) => {
      const n = (snap.agents || []).filter((h) => h.kind === "helper" && h.lead === a.data.key).length - a.desk.cap;
      if (n > 0) otext(a.desk.x + a.desk.w + 1 + 7 * a.desk.cap, a.desk.y + 4, "+" + n, "#aab3be");
    });
  }

  function drawDesk(a) {
    const d = a.desk, working = a.state === "work", c = colour(a.data.color, "#2fbf71");
    const mons = d.two ? [d.x + 1, d.x + d.w - 11] : [d.x + Math.floor(d.w / 2) - 4];
    mons.forEach((mx) => {
      rect(mx, d.y - 6, 9, 5, P.frame); rect(mx + 4, d.y - 1, 1, 1, P.frame);
      for (let j = 0; j < 3; j++) for (let i = 0; i < 7; i++) {
        let k = "#101319";
        if (working) { const len = 3 + ((j * 5 + (tick >> 1) + mx) % 5); k = i < len ? mix(c, "#0c1f18", 0.35 + 0.2 * ((i + j + (tick >> 1)) % 2)) : "#0c1a14"; }
        px(mx + 1 + i, d.y - 5 + j, k);
      }
      if (!working) px(mx + 7, d.y - 3, (tick >> 4) % 2 ? "#6b4b1f" : "#2a2012");
    });
    rect(d.x, d.y, d.w, 1, P.deskTop); rect(d.x, d.y + 1, d.w, 1, P.desk); rect(d.x, d.y + 2, d.w, 1, P.deskD);
    rect(d.x, d.y + 3, 1, 2, P.deskD); rect(d.x + d.w - 1, d.y + 3, 1, 2, P.deskD);
    const s = seat(d);
    rect(s.x - 1, s.y + 4, 9, 4, P.chair); rect(s.x, s.y + 8, 1, 2, P.chair); rect(s.x + 6, s.y + 8, 1, 2, P.chair);
  }

  function figure(put, x, y, body, hair, stride) {
    const sh = mix(body, "#000000", 0.3), skin = P.skin, leg = "#2a2f3a";
    const r = (xx, yy, w, h, c) => { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) put(xx + i, yy + j, c); };
    r(x + 2, y, 3, 1, hair); r(x + 1, y + 1, 5, 1, hair); put(x + 1, y + 2, hair); put(x + 5, y + 2, hair);
    r(x + 2, y + 2, 3, 2, skin); put(x + 2, y + 2, "#1b1b1b"); put(x + 4, y + 2, "#1b1b1b");
    r(x + 1, y + 4, 5, 3, body); r(x, y + 4, 1, 3, sh); r(x + 6, y + 4, 1, 3, sh);
    put(x, y + 7, skin); put(x + 6, y + 7, skin); r(x + 2, y + 7, 3, 1, sh);
    const legs = stride ? [[1, 8], [5, 8], [2, 9], [4, 9]] : [[2, 8], [4, 8], [2, 9], [4, 9]];
    legs.forEach(([i, j]) => put(x + i, y + j, leg));
  }

  function drawAgent(a) {
    if (a.state === "gone" || a.state === "wait") return;
    const body = colour(a.data.color, "#2fbf71"), hair = colour(a.data.hair, "#3b2a20");
    const sh = mix(body, "#000000", 0.3), skin = P.skin;
    if ((a.state === "work" || a.state === "sleep") && !a.helper) {
      const s = seat(a.desk), x = s.x, y = s.y;
      if (a.state === "work") {
        rect(x + 2, y, 3, 1, hair, 1); rect(x + 1, y + 1, 5, 2, hair, 1); rect(x + 2, y + 3, 3, 1, skin, 1);
        rect(x + 1, y + 4, 5, 3, body, 1); rect(x, y + 5, 1, 2, sh, 1); rect(x + 6, y + 5, 1, 2, sh, 1);
        const f = (tick >> 1) % 2; px(x + 1 + f, a.desk.y + 2, skin, 1); px(x + 5 - f, a.desk.y + 2, skin, 1);
      } else {
        rect(x, a.desk.y + 2, 7, 1, sh, 1);
        rect(x + 1, y + 1, 5, 3, hair, 1);
        rect(x + 1, y + 4, 5, 3, body, 1); rect(x, y + 4, 1, 2, sh, 1); rect(x + 6, y + 4, 1, 2, sh, 1);
        if (a.bang > 0) otext(x + 3, y - 4, "!", P.amber, true, true);
        else for (let k = 0; k < 3; k++) {
          const ph = ((tick >> 2) + k * 4) % 12;
          if (ph < 9) otext(x + 6 + k, y - 1 - Math.floor(ph / 3) * 2 - k, k === 2 ? "Z" : "z", P.zzz, true);
        }
      }
      return;
    }
    const x = a.x, y = a.feet - 9, moving = a.state === "walk";
    figure((i, j, c) => px(i, j, c, 1), x, y, body, hair, moving ? (tick >> 1) % 2 : 0);
    if (a.state === "meet" && ((tick >> 3) + (a === actors[0] ? 0 : 1)) % 2) otext(x + 2, y - 3, "...", "#e9e4d8", true);
    if (a.state === "talk") otext(x + 3, y - 3, (tick >> 3) % 2 ? "!" : " ", P.amber, true, true);
    if (a.bubble) otext(x - 1, y - 3, a.bubble, P.amber, true, true);
    if (a.helper && (a.state === "work" || a.state === "idle" || (a.state === "talk" && a.talking && a.talking.state !== "walk"))) {
      rect(x + 1, y + 6, 5, 1, "#9aa3af", 1);
      const lit = a.state === "work" ? mix(colour(a.lead.data.color), "#0c1f18", 0.3 + 0.3 * ((tick >> 2) % 2)) : "#1a1f27";
      rect(x + 2, y + 5, 3, 1, lit, 1);
    }
  }

  function drawTrails() {
    actors.forEach((a) => a.trail.forEach(([x, y], i) => {
      if (i % 3 === 0) px(x, y, mix(colour(a.data.color), "#14171d", 0.35 + 0.45 * (1 - i / Math.max(1, a.trail.length))));
    }));
  }

  function labels() {
    actors.filter((a) => !a.helper).forEach((a) => {
      const d = a.desk, cx = d.x + Math.floor(d.w / 2);
      const name = str(a.data.name).slice(0, d.w + 8);
      const st = a.state === "work" ? "working" : a.state === "sleep" ? "asleep" : a.state === "meet" ? "meeting" : a.state === "talk" ? "saying hello" : "up and about";
      const stc = a.state === "work" ? P.green : a.state === "sleep" ? P.zzz : P.amber;
      otext(cx - Math.floor(name.length / 2), d.y + 12, name, colour(a.data.color), false, true);
      otext(cx - Math.floor(st.length / 2), d.y + 14, st, stc);
    });
  }

  const img = { data: null };
  function render() {
    if (!snap) return;
    PX = new Array(OW * OH);
    mask = new Uint8Array(OW * OH);
    texts = [];
    LOCKS.length = 0;
    drawRoom();
    actors.filter((a) => !a.helper).forEach(drawDesk);
    drawTrails();
    actors.filter((a) => !a.helper).forEach(drawAgent);
    actors.filter((a) => a.helper).forEach(drawAgent);
    labels();
    // Text sits in whole cells two pixels tall; a cell behind a letter takes the blend of its two pixels.
    const cells = [];
    texts.forEach((o) => {
      const py = Math.floor(o.y / 2) * 2;
      for (let i = 0; i < o.s.length; i++) {
        const c = o.x + i;
        if (c < 0 || c >= OW || o.s[i] === " " || py + 1 >= OH) continue;
        if (!o.force && (mask[py * OW + c] || mask[(py + 1) * OW + c])) continue;
        const bg = mix(PX[py * OW + c], PX[(py + 1) * OW + c], 0.5);
        PX[py * OW + c] = bg; PX[(py + 1) * OW + c] = bg;
        cells.push({ c, py, ch: o.s[i], fg: o.fg, b: o.b });
      }
    });
    if (!img.data || img.data.width !== OW || img.data.height !== OH) img.data = octx.createImageData(OW, OH);
    const d = img.data.data;
    for (let k = 0; k < OW * OH; k++) {
      const v = parseInt(PX[k].slice(1), 16);
      d[k * 4] = (v >> 16) & 255; d[k * 4 + 1] = (v >> 8) & 255; d[k * 4 + 2] = v & 255; d[k * 4 + 3] = 255;
    }
    octx.putImageData(img.data, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(off, 0, 0, OW * S, OH * S);
    ctx.textBaseline = "middle";
    ctx.textAlign = "center";
    cells.forEach((t) => {
      ctx.font = (t.b ? "700 " : "") + Math.round(S * 1.45) + "px ui-monospace, Menlo, Consolas, monospace";
      ctx.fillStyle = t.fg;
      ctx.fillText(t.ch, t.c * S + S / 2, t.py * S + S + 1, S * 1.1);
    });
    LOCKS.forEach(([c, y]) => drawLock(c * S + 1, Math.floor(y / 2) * 2 * S + 4));
  }
  function drawLock(x, y) {
    ctx.strokeStyle = P.label; ctx.fillStyle = P.label; ctx.lineWidth = 1.6;
    ctx.beginPath(); ctx.arc(x + 4, y + 5, 2.6, Math.PI, 0); ctx.stroke();
    ctx.fillRect(x, y + 5, 8, 7);
  }

  // ---------- the office: taps ----------
  const OBJECTS = [
    { r: () => [22, 0, 14, 10], go: () => setView("tasks") },
    { r: () => [60, 0, 9, 10], go: () => setView("calendar") },
    { r: () => [72, 0, 13, 10], go: () => setView("memory") },
    { r: () => [87, 8, 8, 20], go: () => setView("system") },
    { r: () => [10, 54 + band, 18, 7], go: () => setView("approvals") },
    { r: () => [1, 49 + band, 8, 11], go: () => note("The captain's door. Only the captain can talk to the crew.") },
  ];
  const inside = (x, y, [rx, ry, rw, rh]) => x >= rx && x < rx + rw && y >= ry && y < ry + rh;
  function boxOf(a) {
    if ((a.state === "work" || a.state === "sleep") && !a.helper) {
      const s = seat(a.desk);
      return [a.desk.x, a.desk.y - 6, a.desk.w, 22].concat([s.x + 3, s.y]);
    }
    return [a.x, a.feet - 10, 7, 11, a.x + 3, a.feet - 10];
  }
  function hit(e) {
    const b = cv.getBoundingClientRect();
    const x = ((e.clientX - b.left) / b.width) * OW, y = ((e.clientY - b.top) / b.height) * OH;
    const who = actors.slice().reverse().find((a) => a.state !== "gone" && a.state !== "wait" && inside(x, y, boxOf(a)));
    if (who) return { who };
    const obj = OBJECTS.find((o) => inside(x, y, o.r()));
    return obj ? { obj } : null;
  }
  cv.addEventListener("click", (e) => {
    if (!snap) return;
    const h = hit(e);
    if (!h) { endTalk(); return; }
    if (h.who) showTalk(h.who.data, h.who); else { endTalk(); h.obj.go(); }
  });
  cv.addEventListener("mousemove", (e) => { cv.style.cursor = snap && hit(e) ? "pointer" : "default"; });

  // ---------- talking to an agent, like a game character ----------
  // A tapped agent stands up and says one line built only from the snapshot's
  // allow-listed fields (its name, role, activity, projects and their counts) or a
  // fun fact from the fixed list below. "Open chat" is locked here and does nothing.
  const FACTS = [
    "Fun fact: octopuses have three hearts.",
    "Fun fact: honey found in ancient tombs was still good to eat.",
    "Fun fact: a group of flamingos is called a flamboyance.",
    "Fun fact: bananas are berries, but strawberries are not.",
    "Fun fact: sea otters hold hands while they sleep.",
    "Fun fact: a day on Venus is longer than its year.",
    "Fun fact: the Eiffel Tower grows a little taller on hot summer days.",
    "Fun fact: a bug found in a 1947 computer log was a real moth.",
    "Fun fact: wombats make cube-shaped droppings.",
    "Fun fact: there are more possible chess games than atoms in the known universe.",
  ];
  const talk = $("talk");
  let talker = null, talkStep = 0;
  function projectNames(d) {
    return (d.projects || []).map((k) => proj(k)).filter(Boolean);
  }
  function greeting(d) {
    const name = str(d.name);
    const asleep = d.state !== "working";
    if (d.kind === "first") return asleep ? "Hello! I'm " + name + ", the first mate. All quiet right now, I'm standing by."
      : "Hi, I'm " + name + ", the first mate. I keep the whole crew on course. Right now I'm " + str(d.activity) + ".";
    if (d.kind === "helper") return asleep ? "I'm a " + name + ". I'm between steps at the moment."
      : "I'm a " + name + ", here for one job. Right now I'm " + str(d.activity) + ".";
    return asleep ? "Zzz... oh, hello! I'm " + name + ". I'm asleep right now, come back later!"
      : "Hi, I'm " + name + ". I'm " + str(d.activity) + ".";
  }
  function more(d) {
    // Every other answer is a count from the snapshot, the rest are fun facts.
    const stats = [];
    projectNames(d).forEach((p) => {
      const c = p.counts || {};
      const nm = str(p.short || p.name);
      if (num(c.done_week)) stats.push(nm + " finished " + plural(num(c.done_week), "job") + " this week.");
      else if (num(c.done_month)) stats.push(nm + " finished " + plural(num(c.done_month), "job") + " this month.");
      if (num(c.in_flight)) stats.push(nm + " has " + plural(num(c.in_flight), "job") + " in flight.");
    });
    talkStep++;
    if (stats.length && talkStep % 2 === 1) return stats[Math.floor(talkStep / 2) % stats.length];
    return FACTS[Math.floor(Math.random() * FACTS.length)];
  }
  function say(line) {
    $("talk-line").textContent = line;
  }
  function standUp(a) {
    if (!a || a.talking) return;
    a.talking = { state: a.state, x: a.x, feet: a.feet };
    if ((a.state === "work" || a.state === "sleep") && !a.helper) { const h = homeOf(a); a.x = h.x; a.feet = h.feet; }
    a.state = "talk";
  }
  function sitDown(a) {
    if (!a || !a.talking) return;
    const was = a.talking;
    a.talking = null;
    if (a.pending) { const [to, cb] = a.pending; a.pending = null; walk(a, to, cb); return; }
    if (was.state === "walk" && a.route) { a.state = "walk"; return; }
    if (was.state === "work" || was.state === "sleep" || was.state === "idle") { settle(a); return; }
    a.state = was.state;
  }
  function showTalk(d, a) {
    endTalk();
    talker = a || null;
    talkStep = 0;
    standUp(talker);
    const nm = $("talk-name");
    nm.textContent = str(d.name);
    nm.style.color = colour(d.color, "#d9e0e8");
    $("talk-role").textContent = str(d.role);
    say(greeting(d));
    talk.hidden = false;
    talk.dataset.agent = str(d.key);
    render();
    $("talk-nice").focus({ preventScroll: true });
  }
  function endTalk() {
    if (talk.hidden) return;
    talk.hidden = true;
    sitDown(talker);
    talker = null;
    render();
  }
  $("talk-nice").addEventListener("click", endTalk);
  $("talk-more").addEventListener("click", () => { const d = agent(talk.dataset.agent); if (d) say(more(d)); });
  $("talk-chat").addEventListener("click", () => note("\u{1F512} Only the captain can chat with the crew."));
  document.addEventListener("click", (e) => {
    if (!talk.hidden && !talk.contains(e.target) && e.target !== cv && !e.target.closest("#roster")) endTalk();
  });

  // ---------- running and pausing ----------
  let timer = null;
  function running() {
    const want = !paused && !document.hidden && view === "office" && !!snap;
    if (want && !timer) timer = setInterval(() => { step(); render(); }, 125);
    if (!want && timer) { clearInterval(timer); timer = null; }
  }
  function togglePause() { paused = !paused; running(); render(); }
  document.addEventListener("keydown", (e) => {
    if (e.target && /INPUT|TEXTAREA/.test(e.target.tagName)) return;
    if (e.key >= "1" && e.key <= "9") setView(ORDER[Number(e.key) - 1]);
    else if (e.key === "p" && view === "office") togglePause();
    else if (e.key === "Escape") endTalk();
  });

  // ---------- live activity and the team list ----------
  function hhmm(d) { return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); }
  function drawFeed() {
    const feed = $("feed");
    feed.textContent = "";
    const colours = {};
    (snap.projects || []).forEach((p) => { colours[str(p.short).toLowerCase()] = p.color; });
    (snap.agents || []).forEach((a) => { colours[str(a.name).toLowerCase()] = a.color; });
    const line = (time, who, what) => {
      const li = el("li");
      const b = el("b", "", str(who));
      b.style.color = colour(colours[str(who).toLowerCase()], "#d9e0e8");
      const txt = el("span");
      txt.append(b, " " + str(what));
      li.append(el("time", "", time), txt);
      feed.append(li);
    };
    const events = Array.isArray(snap.events) ? snap.events : [];
    events.slice(0, 14).forEach((e) => {
      const t = new Date(Date.parse(e.at));
      line(isFinite(t.getTime()) ? hhmm(t) : "", e.who, e.what);
    });
    if (!events.length) (snap.agents || []).forEach((a) => line("now", a.name, a.activity));
  }
  function waitingFor(d) {
    // What waits on the captain in this agent's projects; the first mate answers for the rest.
    const owned = new Set();
    (snap.agents || []).filter((a) => a.kind === "mate").forEach((a) => (a.projects || []).forEach((k) => owned.add(k)));
    const keys = d.kind === "first" ? (snap.projects || []).map((p) => p.key).filter((k) => !owned.has(k)) : d.projects || [];
    return keys.reduce((n, k) => n + num(proj(k) && proj(k).counts && proj(k).counts.waiting), 0);
  }
  function drawRoster() {
    const body = $("roster");
    body.textContent = "";
    (snap.agents || []).forEach((d) => {
      const tr = el("tr");
      const working = d.state === "working";
      const helper = d.kind === "helper";
      const g = el("td", "g " + (working ? "working" : helper ? "idle" : "asleep"), working ? "●" : helper ? "○" : "z");
      const nm = el("td", "nm", helper ? "helper" : str(d.name));
      nm.style.color = colour(d.color, "#d9e0e8");
      const role = str(d.role);
      let doing = str(d.activity);
      const w = helper ? 0 : waitingFor(d);
      if (w) doing += ", " + w + " waiting on the captain";
      const names = (d.projects || []).map((k) => proj(k)).filter(Boolean).map((p) => str(p.short || p.name));
      tr.append(g, nm, el("td", "rl", role), el("td", "dn" + (working ? " on" : ""), doing),
        el("td", "pj", d.kind === "first" ? "every project" : names.join(", ")));
      tr.addEventListener("click", () => {
        const a = actors.find((x) => x.data.key === d.key && x.state !== "gone");
        showTalk(d, a);
      });
      body.append(tr);
    });
  }

  // ---------- locked views ----------
  // A locked view is a dark shade and a padlock over blurred placeholder shapes that
  // stand for the view's layout; nothing from the records is drawn under it.
  const SHAPES = {
    tasks: [4, [3, 5, 4, 6, 3, 5]],
    approvals: [1, [2, 1, 1, 2, 1, 1, 2, 1]],
    memory: [2, [1, 6, 1, 1, 1, 4]],
    docs: [2, [1, 1, 1, 6, 1, 1, 3]],
    system: [3, [4, 4, 3, 4, 4, 3]],
  };
  const PADLOCK = [
    "...#######...",
    "..#.......#..",
    "..#.......#..",
    "..#.......#..",
    "..#.......#..",
    "#############",
    "#ooooooooooo#",
    "#ooookkkoooo#",
    "#ooookkkoooo#",
    "#oooookooooo#",
    "#oooookooooo#",
    "#ooooooooooo#",
    "#############",
  ];
  function drawLocked(v) {
    const [cols, rows] = SHAPES[v] || SHAPES.tasks;
    const ph = $("placeholder");
    ph.textContent = "";
    ph.style.gridTemplateColumns = "repeat(" + cols + ", minmax(0, 1fr))";
    for (let c = 0; c < cols; c++) {
      const col = el("div", "col");
      rows.forEach((h, i) => {
        const b = el("div", "blk");
        b.style.height = 16 * h + "px";
        b.style.width = 60 + ((c * 17 + i * 23) % 40) + "%";
        col.append(b);
      });
      ph.append(col);
    }
    const g = $("padlock").getContext("2d");
    g.clearRect(0, 0, 13, 13);
    PADLOCK.forEach((row, y) => row.split("").forEach((ch, x) => {
      if (ch === ".") return;
      g.fillStyle = y < 5 ? "#aab3be" : ch === "#" ? "#c98a2e" : ch === "k" ? "#2a1c08" : "#ffb454";
      g.fillRect(x, y, 1, 1);
    }));
  }

  // ---------- projects ----------
  const PILLS = { active: "Active", parked: "Parked", quiet: "Quiet" };
  function drawProjects() {
    const grid = $("projects");
    grid.textContent = "";
    (snap.projects || []).forEach((p) => {
      const c = p.counts || {};
      const box = el("article", "proj");
      box.style.setProperty("--c", colour(p.color));
      const hd = el("div", "hd");
      const status = PILLS[p.status] ? p.status : "quiet";
      hd.append(el("div", "nm", str(p.name)), el("span", "pill " + status, PILLS[status]));
      const stats = el("div", "stats");
      [["waiting", "waiting on the captain"], ["in_flight", "in flight"], ["done_week", "done this week"], ["done_month", "done this month"]]
        .forEach(([k, label]) => { const s = el("div", "stat"); s.append(el("b", "", String(num(c[k]))), el("span", "", label)); stats.append(s); });
      const lead = agent(p.lead);
      box.append(hd, stats);
      if (lead && lead.kind === "first") box.append(el("div", "ld", "Looked after by " + str(lead.name) + ", the first mate"));
      else if (lead) box.append(el("div", "ld", "Looked after by the " + str(lead.name) + " second mate"));
      grid.append(box);
    });
  }

  // ---------- calendar ----------
  let calMonth = null;
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const parseDay = (s) => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(str(s)); return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null; };
  const iso = (d) => d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
  function drawCalendar() {
    const cal = snap.calendar || {};
    const today = parseDay(snap.today) || new Date();
    const from = parseDay(cal.from) || new Date(today.getFullYear(), today.getMonth(), 1);
    const to = parseDay(cal.to) || today;
    if (!calMonth) calMonth = new Date(today.getFullYear(), today.getMonth(), 1);
    const first = new Date(from.getFullYear(), from.getMonth(), 1), last = new Date(to.getFullYear(), to.getMonth(), 1);
    if (calMonth < first) calMonth = first;
    if (calMonth > last) calMonth = last;
    $("cal-title").textContent = MONTHS[calMonth.getMonth()] + " " + calMonth.getFullYear();
    $("cal-prev").disabled = calMonth <= first;
    $("cal-next").disabled = calMonth >= last;
    $("cal-today").hidden = calMonth.getMonth() === today.getMonth() && calMonth.getFullYear() === today.getFullYear();
    const legend = $("cal-legend");
    legend.textContent = "";
    (snap.projects || []).forEach((p) => {
      const s = el("span");
      const i = el("i");
      i.style.background = colour(p.color);
      s.append(i, str(p.short || p.name));
      legend.append(s);
    });
    const days = {};
    (cal.days || []).forEach((d) => { days[str(d.date)] = d; });
    const grid = $("cal-grid");
    grid.textContent = "";
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].forEach((n) => grid.append(el("div", "dow", n)));
    const start = new Date(calMonth);
    start.setDate(1 - start.getDay());
    for (let i = 0; i < 42; i++) {
      const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
      if (i >= 35 && d.getMonth() !== calMonth.getMonth()) break;
      const out = d.getMonth() !== calMonth.getMonth();
      const rec = days[iso(d)];
      const cell = el("div", "day" + (out ? " out" : "") + (iso(d) === iso(today) ? " today" : "") + (rec ? "" : " empty"));
      const label = out ? String(d.getDate()) : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()] + " " + d.getDate();
      cell.append(el("div", "dn", label));
      if (rec) {
        [["due", "due"], ["done", "done"]].forEach(([k, word]) => {
          Object.keys(rec[k] || {}).forEach((pk) => {
            const p = proj(pk);
            const chip = el("div", "chip " + k);
            const i = el("i");
            i.style.background = colour(p && p.color);
            const b = el("b", "", str(p ? p.short || p.name : "a project"));
            chip.append(i, b, " " + num(rec[k][pk]) + " " + word);
            cell.append(chip);
          });
        });
      }
      grid.append(cell);
    }
  }
  $("cal-prev").addEventListener("click", () => { calMonth = new Date(calMonth.getFullYear(), calMonth.getMonth() - 1, 1); drawCalendar(); });
  $("cal-next").addEventListener("click", () => { calMonth = new Date(calMonth.getFullYear(), calMonth.getMonth() + 1, 1); drawCalendar(); });
  $("cal-today").addEventListener("click", () => { calMonth = null; drawCalendar(); });

  // ---------- team ----------
  function portrait(d) {
    const c = el("canvas");
    c.width = 7; c.height = 10;
    const g = c.getContext("2d");
    figure((x, y, col) => { g.fillStyle = col; g.fillRect(x, y, 1, 1); }, 0, 0, colour(d.color, "#2fbf71"), colour(d.hair, "#3b2a20"), 0);
    return c;
  }
  function whoCard(d) {
    const box = el("div", "who-card");
    const txt = el("div");
    const nm = el("div", "nm", str(d.name));
    nm.style.color = colour(d.color, "#d9e0e8");
    const working = d.state === "working";
    txt.append(nm, el("div", "rl", str(d.role)), el("div", "st " + (working ? "working" : "asleep"), (working ? "● " : "z ") + str(d.activity)));
    const names = (d.projects || []).map((k) => proj(k)).filter(Boolean).map((p) => str(p.short || p.name));
    if (d.kind === "first") txt.append(el("div", "pj", "Every project"));
    else if (names.length && names.join(", ") !== str(d.name)) txt.append(el("div", "pj", names.join(", ")));
    box.append(portrait(d), txt);
    const helpers = (snap.agents || []).filter((a) => a.kind === "helper" && a.lead === d.key);
    if (helpers.length) {
      const h = el("div", "helpers");
      helpers.forEach((x) => h.append(el("div", "", (x.state === "working" ? "● " : "· ") + str(x.name) + ": " + str(x.activity))));
      box.append(h);
    }
    return box;
  }
  function drawTeam() {
    const org = $("team");
    org.textContent = "";
    org.append(el("div", "captain", "The captain"), el("div", "wire"));
    const fm = (snap.agents || []).find((a) => a.kind === "first");
    if (fm) { const row = el("div", "row"); row.append(whoCard(fm)); org.append(row); }
    const mates = (snap.agents || []).filter((a) => a.kind === "mate");
    if (mates.length) {
      org.append(el("div", "wire"));
      const row = el("div", "row");
      mates.forEach((m) => row.append(whoCard(m)));
      org.append(row);
    }
  }

  function drawView() {
    if (!snap) return;
    drawFeed();
    drawRoster();
    if (view === "projects") drawProjects();
    else if (view === "calendar") drawCalendar();
    else if (view === "team") drawTeam();
    else render();
  }

  const start = location.hash.slice(1);
  setView(PUBLIC.indexOf(start) >= 0 ? start : "office", true);
  load().then(running);
})();
