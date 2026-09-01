/**
 * VirtualHub — Admin Console Real-Time Sync (v2)
 * ──────────────────────────────────────────────
 * Injects Supabase Realtime subscriptions into the admin page.
 * Listens for new payments, orders, profile changes, gold transactions,
 * booking code requests, and spin signals.
 * Shows toast notifications + browser alerts + audio pings.
 */
(function () {
  "use strict";

  const SUPABASE_URL = "https://buvpkpjgctdmynwtqwta.supabase.co";
  const SUPABASE_KEY = "sb_publishable_irh-8VOxfVpABFp5LZJ3iA_cMdxsYKa";

  /* ── Helpers ────────────────────────────────────────── */

  function loadScript(src) {
    return new Promise((res, rej) => {
      if (document.querySelector(`script[src="${src}"]`)) return res();
      const s = document.createElement("script");
      s.src = src;
      s.onload = res;
      s.onerror = rej;
      document.head.appendChild(s);
    });
  }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  function injectStyles() {
    if (document.getElementById("ve-rt-css")) return;
    const s = document.createElement("style");
    s.id = "ve-rt-css";
    s.textContent = `
      @keyframes veSlideIn{from{transform:translateX(110%);opacity:0}to{transform:translateX(0);opacity:1}}
      @keyframes vePulse{0%,100%{opacity:1}50%{opacity:.4}}
      #ve-toasts{position:fixed;top:80px;right:16px;z-index:99999;display:flex;flex-direction:column;gap:8px;max-width:380px;pointer-events:none}
      #ve-toasts>div{pointer-events:auto}
    `;
    document.head.appendChild(s);
  }

  /* ── Toast ──────────────────────────────────────────── */

  function toast(title, body, kind) {
    let c = document.getElementById("ve-toasts");
    if (!c) {
      c = document.createElement("div");
      c.id = "ve-toasts";
      document.body.appendChild(c);
    }
    const colour = { success: "#3b82f6", error: "#3b82f6", info: "#3b82f6", warning: "#fbbf24" }[kind] || "#3b82f6";
    const el = document.createElement("div");
    el.style.cssText = `background:#0d0d12;border:1px solid ${colour};border-left:4px solid ${colour};border-radius:14px;padding:14px 18px;color:#f1f1f1;font-size:13px;line-height:1.45;box-shadow:0 8px 32px rgba(59,130,246,.25);animation:veSlideIn .3s ease;opacity:1;transition:opacity .35s`;
    el.innerHTML = `<div style="font-weight:800;color:${colour};margin-bottom:3px">${esc(title)}</div><div style="color:#9ca3af">${esc(body)}</div>`;
    c.appendChild(el);
    setTimeout(() => { el.style.opacity = "0"; setTimeout(() => el.remove(), 350); }, 6000);
  }

  function ping() {
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.connect(g); g.connect(ctx.destination);
      o.frequency.setValueAtTime(880, ctx.currentTime);
      o.frequency.exponentialRampToValueAtTime(1320, ctx.currentTime + 0.08);
      g.gain.setValueAtTime(0.12, ctx.currentTime);
      g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.25);
      o.start(); o.stop(ctx.currentTime + 0.25);
    } catch (_) {}
  }

  function browserNotify(title, body) {
    if ("Notification" in window && Notification.permission === "granted")
      new Notification(title, { body, tag: "ve-admin-" + Date.now(), icon: "/favicon.png" });
  }

  /* ── Force React app to refetch data ────────────────── */

  let _qc = null;

  /**
   * Walk the React fiber tree to find the TanStack QueryClient and call
   * invalidateQueries() on it. Mirrors the dashboard-realtime approach so
   * the orders / payments list actually refreshes without a manual reload.
   */
  function findQueryClient() {
    if (_qc) return _qc;

    const roots = [document.body, document.querySelector("main"), document.querySelector("#root"), document.querySelector("#app")];
    for (const r of roots) {
      if (!r) continue;
      for (const k of Object.keys(r)) {
        if (k.startsWith("__reactFiber$") || k.startsWith("__reactContainer$")) {
          const q = walkFiber(r[k]);
          if (q) { _qc = q; return q; }
        }
      }
    }
    return null;
  }

  function walkFiber(node) {
    if (!node) return null;
    const seen = new Set();
    const q = [node];
    while (q.length && seen.size < 1500) {
      const n = q.shift();
      if (!n || seen.has(n)) continue;
      seen.add(n);
      let s = n.memoizedState;
      while (s) {
        const mc = s.memoizedState;
        if (mc && typeof mc === "object" && typeof mc.invalidateQueries === "function" && typeof mc.getQueryCache === "function") return mc;
        if (mc?.queryClient?.invalidateQueries) return mc.queryClient;
        s = s.next;
      }
      if (n.child)   q.push(n.child);
      if (n.sibling) q.push(n.sibling);
    }
    return null;
  }

  function invalidateQueries() {
    // 1. Tell the TanStack QueryClient to refetch everything.
    try {
      const qc = findQueryClient();
      if (qc) qc.invalidateQueries();
    } catch (_) {}

    // 2. BroadcastChannel (cross-tab + same-tab).
    try {
      const bc = new BroadcastChannel("ve-admin-refresh");
      bc.postMessage({ ts: Date.now() });
      bc.close();
    } catch (_) {}

    // 3. Storage event trick — picked up by React Query's window listeners.
    try {
      localStorage.setItem("ve-admin-ping", String(Date.now()));
      setTimeout(() => localStorage.removeItem("ve-admin-ping"), 100);
    } catch (_) {}

    // 4. Custom + storage events for any listeners that prefer those.
    window.dispatchEvent(new Event("ve-realtime-update"));
    window.dispatchEvent(new StorageEvent("storage", { key: "ve-admin-ping" }));
  }

  /* ── Live badge in header ───────────────────────────── */

  /* ── Connection state tracker ──────────────────────── */
  let _connState = "loading"; // loading | connected | degraded | disconnected
  const _connLabel = { loading: "CONNECTING", connected: "LIVE", degraded: "DEGRADED", disconnected: "OFFLINE" };
  const _connColor = { loading: "#fbbf24", connected: "#00ff88", degraded: "#fbbf24", disconnected: "#ef4444" };

  function setConnectionState(state) {
    _connState = state;
    const badge = document.getElementById("ve-live");
    if (!badge) return;
    const dot  = badge.querySelector("span:first-child");
    const text = badge.childNodes[badge.childNodes.length - 1];
    const color = _connColor[state];
    badge.style.color = color;
    badge.style.borderColor = color.replace("#", "rgba(").replace(/([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/, (_, r, g, b) => `${parseInt(r,16)},${parseInt(g,16)},${parseInt(b,16)},.3)`);
    badge.style.background  = color.replace("#", "rgba(").replace(/([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/, (_, r, g, b) => `${parseInt(r,16)},${parseInt(g,16)},${parseInt(b,16)},.06)`);
    if (dot) { dot.style.background = color; dot.style.animation = state === "connected" ? "vePulse 2s infinite" : "none"; }
    if (text) text.textContent = " " + _connLabel[state];
  }

  function addLiveBadge() {
    const header = document.querySelector("header");
    if (!header) return;
    const badge = document.createElement("span");
    badge.id = "ve-live";
    badge.style.cssText = "display:inline-flex;align-items:center;gap:5px;font-size:10px;font-weight:800;color:#fbbf24;padding:5px 10px;border-radius:20px;border:1px solid rgba(251,191,36,.3);background:rgba(251,191,36,.06);letter-spacing:.5px;transition:all .3s ease";
    badge.innerHTML = '<span style="width:7px;height:7px;border-radius:50%;background:#fbbf24"></span> CONNECTING';
    header.querySelector("div")?.appendChild(badge);
  }

  /* ── "Packages" shortcut in the admin header ───────── */
  function addPackagesLink() {
    const header = document.querySelector("header");
    if (!header || document.getElementById("ve-pkg-link")) return;
    const link = document.createElement("a");
    link.id = "ve-pkg-link";
    link.href = "/admin/packages";
    link.textContent = "📦 Packages";
    link.style.cssText = "margin-left:auto;margin-right:12px;font-size:11px;font-weight:900;letter-spacing:.5px;color:#fbbf24;text-transform:uppercase;text-decoration:none;padding:6px 12px;border-radius:20px;border:1px solid rgba(251,191,36,.3);background:rgba(251,191,36,.06)";
    // Insert AFTER the live badge so layout stays: logo | LIVE | Packages
    const live = document.getElementById("ve-live");
    const container = header.querySelector("div");
    if (live && live.parentElement === container) {
      container.insertBefore(link, live.nextSibling);
      link.addEventListener("mouseenter", () => link.style.background = "rgba(251,191,36,.15)");
      link.addEventListener("mouseleave", () => link.style.background = "rgba(251,191,36,.06)");
    } else {
      container.appendChild(link);
    }
  }

  /* ── Counter badge for pending items ────────────────── */

  let pendingCount = 0;
  function updateCounter() {
    let counter = document.getElementById("ve-pending-count");
    if (!counter) {
      counter = document.createElement("span");
      counter.id = "ve-pending-count";
      counter.style.cssText = "display:none;position:absolute;top:-4px;right:-4px;min-width:18px;height:18px;border-radius:9px;background:#ff4444;color:#fff;font-size:10px;font-weight:800;text-align:center;line-height:18px;padding:0 4px";
      const live = document.getElementById("ve-live");
      if (live) {
        live.style.position = "relative";
        live.appendChild(counter);
      }
    }
    if (pendingCount > 0) {
      counter.style.display = "grid";
      counter.textContent = pendingCount > 99 ? "99+" : pendingCount;
    } else {
      counter.style.display = "none";
    }
  }

  /* ── Main ───────────────────────────────────────────── */

  async function init() {
    injectStyles();
    // Load the Supabase UMD client — try local first, then CDN fallbacks
    const cdnUrls = [
      "/assets/supabase.min.js",
      "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js",
      "https://unpkg.com/@supabase/supabase-js@2/dist/umd/supabase.min.js"
    ];
    let loaded = false;
    for (const url of cdnUrls) {
      try { await loadScript(url); loaded = true; break; } catch (_) { /* try next */ }
    }
    if (!loaded || !window.supabase) {
      console.error("[VirtualHub] ❌ Could not load Supabase client — realtime disabled");
      return;
    }

    const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

    if ("Notification" in window && Notification.permission === "default")
      Notification.requestPermission();

    addLiveBadge();
    addPackagesLink();
    console.log("%c[VirtualHub] ⚡ Admin real-time sync active", "color:#00ff88;font-weight:bold");

    // Wait a tick for React to mount, then wire up QueryClient invalidation.
    setTimeout(() => {
      if (findQueryClient()) {
        console.log("%c[VirtualHub] ✅ TanStack QueryClient wired — orders list will live-refresh", "color:#00ff88;font-weight:bold");
      } else {
        // Retry every 2s for up to 10s — React may mount after first paint.
        let tries = 0;
        const retry = setInterval(() => {
          tries++;
          if (findQueryClient() || tries > 5) clearInterval(retry);
        }, 2000);
      }
    }, 1000);    /* ── Subscription status logging ─────────────────── */
    const TOTAL_CHANNELS = 6; // payments, orders, profiles, gold, efootball, spin
    let _subOk = 0, _subFail = 0;
    function logSubStatus(channel, status) {
      if (status === 'SUBSCRIBED') {
        _subOk++;
        console.log(`%c[VirtualHub] ✅ ${channel} subscribed (${_subOk}/${_subOk+_subFail})`, 'color:#00ff88;font-weight:bold');
        // All channels connected → green LIVE
        if (_subOk >= TOTAL_CHANNELS) setConnectionState('connected');
        // Some connected, some failed → yellow DEGRADED
        else if (_subOk > 0 && _subFail > 0) setConnectionState('degraded');
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        _subFail++;
        console.warn(`%c[VirtualHub] ⚠️ ${channel} ${status} — will retry via polling`, 'color:#fbbf24;font-weight:bold');
        if (_subFail >= TOTAL_CHANNELS) setConnectionState('disconnected');
        else if (_subOk > 0) setConnectionState('degraded');
      } else if (status === 'CLOSED' || status === 'CHANNEL_CLOSED') {
        _subFail++;
        setConnectionState('disconnected');
      }
    }

    // After 5s, if no subscriptions have confirmed, show degraded
    setTimeout(() => {
      if (_connState === 'loading') setConnectionState(_subOk > 0 ? 'connected' : 'degraded');
    }, 5000);

    /* ── Fallback heartbeat: force-invalidate every 15s ─ */
    setInterval(() => { invalidateQueries(); }, 15000);

    /* ── New payment proofs (registrations) ────────────── */

    sb.channel("admin-payments")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "payments" }, (p) => {
        const r = p.new;
        // Show FULL sender details in the toast so the admin has everything
        // to make a decision without opening a separate page.
        const sender = r.sender_name ? `${r.sender_name} (${r.sender_number || 'no number'})` : 'sender unknown';
        const txn    = r.txn_id ? ` · TXN ${r.txn_id}` : '';
        toast(
          `📩 New Payment Proof · ${r.email}`,
          `${r.method} · ${r.currency} ${r.amount} · ${sender}${txn}`,
          "info"
        );
        pendingCount++; updateCounter();
        ping();
        browserNotify(
          "New Payment Proof",
          `${r.email} · ${r.method} · ${r.currency} ${r.amount} · ${sender}`
        );
        invalidateQueries();
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "payments" }, (p) => {
        const r = p.new;
        toast("✅ Payment Reviewed", `${r.email} — ${r.status}`, r.status === "approved" ? "success" : "warning");
        pendingCount = Math.max(0, pendingCount - 1); updateCounter();
        ping(); invalidateQueries();
      })
      .subscribe((status) => logSubStatus('admin-payments', status));

    /* ── New diamond / gold orders ─────────────────────── */
    sb.channel("admin-orders")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "orders" }, (p) => {
        const r = p.new;
        // Detect gold packages (the JS labels them "X Gold")
        const isGold = (r.package_name || '').toLowerCase().includes('gold');
        const icon   = isGold ? '🪙' : '💎';
        const kind   = isGold ? 'Gold' : 'Diamond';
        const sender = r.sender_name ? `${r.sender_name} (${r.sender_number || 'no number'})` : 'sender unknown';
        const txn    = r.txn_id ? ` · TXN ${r.txn_id}` : '';
        toast(
          `${icon} New ${kind} Order · ${r.email}`,
          `${r.package_name} · ${r.diamonds} ${isGold ? 'coins' : 'diamonds'} · ${r.currency} ${r.amount} · ${sender}${txn}`,
          "info"
        );
        pendingCount++; updateCounter();
        ping();
        browserNotify(
          `New ${kind} Order`,
          `${r.email} · ${r.diamonds} ${isGold ? 'coins' : 'diamonds'} · ${r.currency} ${r.amount}`
        );
        invalidateQueries();
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "orders" }, (p) => {
        const r = p.new;
        toast("💎 Order Reviewed", `${r.email} — ${r.diamonds} — ${r.status}`, r.status === "approved" ? "success" : "warning");
        pendingCount = Math.max(0, pendingCount - 1); updateCounter();
        ping(); invalidateQueries();
      })
      .subscribe((status) => logSubStatus('admin-orders', status));

    /* ── New member registrations ──────────────────────── */
    sb.channel("admin-profiles")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "profiles" }, (p) => {
        const r = p.new;
        toast("👤 New Member", `${r.email || r.full_name || 'Unknown'} — ${r.status}`, "success");
        pendingCount++; updateCounter();
        ping(); browserNotify("New Member", `${r.email || r.full_name}`);
        invalidateQueries();
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "profiles" }, (p) => {
        const n = p.new, o = p.old;
        if (n.status !== o.status)
          toast("👤 Status Changed", `${n.email || n.full_name}: ${o.status} → ${n.status}`, "info");
        if (n.diamonds !== o.diamonds)
          toast("💎 Diamonds Updated", `${n.email}: ${o.diamonds} → ${n.diamonds}`, "info");
        if (n.gold !== o.gold)
          toast("🪙 Gold Updated", `${n.email}: ${o.gold} → ${n.gold}`, "info");
        ping(); invalidateQueries();
      })
      .subscribe((status) => logSubStatus('admin-profiles', status));

    /* ── Gold transactions ─────────────────────────────── */
    sb.channel("admin-gold")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "gold_transactions" }, (p) => {
        const r = p.new;
        toast("🪙 Gold Transaction", `${r.kind}: ${r.amount} gold — ${r.reason}`, "info");
        ping(); invalidateQueries();
      })
      .subscribe((status) => logSubStatus('admin-gold', status));

    /* ── Booking code requests ─────────────────────────── */
    sb.channel("admin-efootball")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "booking_code_requests" }, (p) => {
        const r = p.new;
        toast("⚽ New Booking Code Request", `User requested an eFootball booking code`, "info");
        pendingCount++; updateCounter();
        ping(); invalidateQueries();
      })
      .subscribe((status) => logSubStatus('admin-efootball', status));

    /* ── Spin signals ──────────────────────────────────── */
    sb.channel("admin-spin")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "spin_signals" }, (p) => {
        const r = p.new;
        toast("🎰 New Spin Signal", `Direction: ${r.direction} — Confidence: ${r.confidence}%`, "info");
        ping(); invalidateQueries();
      })
      .subscribe((status) => logSubStatus('admin-spin', status));
  }

  /* ── Boot ───────────────────────────────────────────── */
  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else
    init();
})();
