/* ============================================================================
 * VirtualHub — Cache clearer (v9)
 *
 * Forces every browser visiting the site to drop the previously-cached bundles
 * (CSS, JS, HTML) and re-fetch fresh copies from the server. Fixes the
 * "after renaming the site / site looks broken" symptom caused by browsers
 * hydrating with stale JS/CSS that still reference the old name.
 *
 * Runs on every page load. Safe for repeat visits: the work is a no-op when
 * the cache is already clean.
 * ============================================================================ */
(function () {
  "use strict";

  // Skip entirely on localhost — the local server already sends no-store
  // cache headers, so there is nothing to bust and the forced-reload
  // redirect just causes an annoying flash.
  try {
    var hn = location.hostname;
    if (hn === "localhost" || hn === "127.0.0.1" || hn === "0.0.0.0") return;
  } catch (_) { /* continue */ }

  var VERSION = "v9"; // keep in sync with the ?v=N query strings in HTML

  function log(kind, msg) {
    var prefix = "%c[VirtualHub cache " + kind + "]";
    var style =
      kind === "cleared"
        ? "color:#22c55e;font-weight:bold"
        : kind === "ok"
        ? "color:#3b82f6;font-weight:bold"
        : "color:#9ca3af;font-weight:bold";
    // eslint-disable-next-line no-console
    console.log(prefix + " " + msg, style);
  }

  function reloadOnce() {
    // Use a session flag so we only force-reload once per session, otherwise
    // navigation between pages would loop forever.
    try {
      if (sessionStorage.getItem("__vhub_reload") === VERSION) return false;
      sessionStorage.setItem("__vhub_reload", VERSION);
      return true;
    } catch (e) {
      return true;
    }
  }

  function clearCaches() {
    // Cache Storage API (service-worker style caches, if any)
    if (typeof caches !== "undefined" && caches.keys) {
      caches.keys().then(function (keys) {
        keys.forEach(function (k) {
          caches.delete(k).then(function () {
            log("cleared", "Cache Storage entry dropped: " + k);
          });
        });
      });
    }

    // HTTP cache: we can't truly wipe it from JS, but we CAN force the page
    // to refetch by appending a one-shot query string. The server already
    // returns Cache-Control: no-store, so the reload itself picks up fresh
    // assets naturally.
  }

  try {
    log("ok", "active " + VERSION + " — forcing fresh fetch on first visit");
    clearCaches();

    // Only force-reload if the page was loaded WITHOUT our version param.
    // i.e. the user landed on a stale URL that hasn't been bumped yet.
    var url = new URL(window.location.href);
    if (!url.searchParams.has("v")) {
      if (reloadOnce()) {
        url.searchParams.set("v", VERSION);
        log("cleared", "forcing reload with ?v=" + VERSION);
        window.location.replace(url.toString());
        return;
      }
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn("[VirtualHub cache] non-fatal error:", err);
  }
})();