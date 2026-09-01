/* ============================================================================
 * VirtualHub — local static server  (no dependencies, no downloads)
 * Serves the built site exactly like Vercel:
 *   - serves real files (dashboard/index.html, gold/index.html, assets/...)
 *   - falls back to the root index.html (SPA routing) for unknown paths
 *   - auto-opens the browser
 *
 * Run it via run-local.bat  (or:  node local-server.js)
 * ========================================================================== */
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = __dirname;
const HOST = process.env.HOST || "127.0.0.1";
// Port from --port <n> CLI arg, else PORT env, else default 5173
const argIndex = process.argv.indexOf("--port");
let PORT = Number(
  (argIndex !== -1 && process.argv[argIndex + 1]) ||
  process.env.PORT ||
  5173
);

/* ── Try the requested port, then fall back to the next free one ── */
function tryListen(srv, host, port, attempts) {
  return new Promise((resolve, reject) => {
    const onError = (err) => {
      srv.off("listening", onListening);
      if (err && err.code === "EADDRINUSE" && attempts > 0) {
        console.log(`[VirtualHub] Port ${port} is in use, trying ${port + 1}…`);
        tryListen(srv, host, port + 1, attempts - 1).then(resolve, reject);
      } else {
        reject(err);
      }
    };
    const onListening = () => {
      srv.off("error", onError);
      resolve(srv.address().port);
    };
    srv.once("error", onError);
    srv.once("listening", onListening);
    srv.listen(port, host);
  });
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
  ".txt": "text/plain; charset=utf-8",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
};

function typeFor(filePath) {
  return MIME[path.extname(filePath).toLowerCase()] || "application/octet-stream";
}

function safeResolve(urlPath) {
  let clean = urlPath.split("?")[0].split("#")[0];
  try {
    clean = decodeURIComponent(clean);
  } catch (_) { /* keep raw on bad encoding */ }
  // Normalize and strip any traversal outside root
  const rel = path.normalize("/" + clean).replace(/^(\.\.[\/\\])+/, "");
  return path.join(ROOT, rel);
}

function sendFile(res, filePath) {
  fs.readFile(filePath, (err, data) => {
    if (err) { send404(res); return; }
    res.writeHead(200, {
      "Content-Type": typeFor(filePath),
      // Strong no-cache: browsers must revalidate with the server before using
      // a cached copy. Combined with the no-store pragma, this prevents the
      // "VirtualHub → prediit" regression where stale bundles hydrate the DOM.
      "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
      "Pragma": "no-cache",
      "Expires": "0",
    });
    res.end(data);
  });
}

function send404(res) {
  fs.readFile(path.join(ROOT, "404.html"), (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("404 Not Found");
      return;
    }
    res.writeHead(404, { "Content-Type": "text/html; charset=utf-8" });
    res.end(data);
  });
}

function sendIndex(res) {
  fs.readFile(path.join(ROOT, "index.html"), (err, data) => {
    if (err) { send404(res); return; }
    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
      "Pragma": "no-cache",
      "Expires": "0",
    });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  const urlPath = req.url || "/";

  // Health check
  if (urlPath === "/--ping" ) {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("pong");
    return;
  }

  let filePath = safeResolve(urlPath);

  // Serve the exact file if it exists
  if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
    sendFile(res, filePath);
    return;
  }

  // Serve directory index (e.g. /dashboard -> dashboard/index.html)
  if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
    const idx = path.join(filePath, "index.html");
    if (fs.existsSync(idx)) { sendFile(res, idx); return; }
  }

  // If it looks like a real asset that's missing, 404 (don't hijack with the SPA)
  if (/\.(js|css|png|jpe?g|svg|ico|woff2?|json|gif|webp|map)$/i.test(urlPath)) {
    send404(res);
    return;
  }

  // SPA fallback -> root index.html (mirrors vercel.json catch-all)
  sendIndex(res);
});

// Try the requested port, then up to 10 subsequent ports if it's taken.
tryListen(server, HOST, PORT, 10).then((boundPort) => {
  PORT = boundPort;
  const url = `http://${HOST}:${PORT}`;
  console.log("===============================================");
  console.log("  VirtualHub local server running");
  console.log("  Open:  " + url);
  console.log("  (Close this window to stop the server)");
  console.log("===============================================");

  // Auto-open the default browser (Windows)
  if (process.platform === "win32") {
    try { require("child_process").exec(`start "" "${url}"`); } catch (_) {}
  }
}).catch((err) => {
  console.error("[VirtualHub] Could not bind any port:", err.message);
  console.error("[VirtualHub] Another VirtualHub / node process may still be running.");
  console.error("[VirtualHub] Close it (Task Manager → node.exe) and re-run this script.");
  process.exit(1);
});