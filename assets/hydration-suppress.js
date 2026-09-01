/* ============================================================================
 * VirtualHub — Hydration watchdog (v2)
 *
 * Earlier versions silently swallowed React error #418 (hydration mismatch)
 * so the red console noise went away. That masked the real bug instead of
 * fixing it, and #418 only fires when the SSR HTML and the client bundle
 * disagree about what the page should look like.
 *
 * This version is a NO-OP. The SSR HTML has been rebuilt to match what the
 * JS bundle actually renders, so hydration should now succeed cleanly.
 * If a #418 ever appears again, it will surface in the console where it
 * belongs — fix the SSR/bundle drift, don't silence the warning.
 * ============================================================================ */
(function () {
  "use strict";
  // Intentionally empty. Hydration is now safe; no swallower needed.
})();