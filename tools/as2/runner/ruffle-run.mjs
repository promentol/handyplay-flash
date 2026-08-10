// Run a SWF in ruffle's prebuilt wasm under headless Chromium, then hand
// back what it traced and what it drew.
//
//   node ruffle-run.mjs <file.swf> <out.png> <out.txt> [ms] [renderer]
//
// The wait is WALL CLOCK — ruffle web has no "tick N frames" API — so
// tests meant for comparison should settle on their first frame and stay
// still. `ms` is how long to let it run before the screenshot.
import { readFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import { createRequire } from "node:module";
// NODE_PATH does not apply to ESM imports; `require` still honours it,
// and puppeteer-core is installed globally in the image.
const puppeteer = createRequire(import.meta.url)("puppeteer-core");

const [swfPath, pngPath, txtPath, msArg, rendererArg] = process.argv.slice(2);
const ms = Number(msArg ?? 600);
// WEBGPU, not webgl. Ruffle's WebGL backend implements only Normal, Add
// and Subtract and falls back to Normal for every other blend mode
// (render/webgl/src/lib.rs:776, "TODO: Unsupported blend mode"), so a
// comparison run on it silently agrees about nothing. The wgpu path is
// also what produced the PNGs in ruffle's own corpus.
const renderer = rendererArg ?? "webgpu";

const swf = readFileSync(resolve(swfPath));

const browser = await puppeteer.launch({
    executablePath: process.env.CHROMIUM ?? "/usr/bin/chromium",
    headless: true,
    args: [
        "--no-sandbox",
        "--disable-dev-shm-usage",
        // Software GL: there is no GPU in here, and SwiftShader is what
        // makes WebGL2 available at all.
        "--enable-unsafe-swiftshader",
        "--enable-unsafe-webgpu",
        "--enable-features=Vulkan",
        "--use-gl=angle",
        "--use-angle=swiftshader",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
    ],
});

try {
    const page = await browser.newPage();
    // Ruffle also logs traces through `tracing` to the console; keeping
    // both channels means a version that drops one is still observable.
    // WHERE THE TRACES COME FROM. `traceObserver` is what ruffle's own
    // selfhosted tests use, but it never fires here, and `trace()` also
    // goes through `tracing` to the console from web/src/log_adapter.rs.
    // That channel works, so it is the one we read: the console text is
    // tracing-wasm's format string with its %c styles appended, and the
    // message sits between the last %c and the first style argument.
    const consoleTraces = [];
    page.on("console", (m) => {
        const t = m.text();
        if (process.env.RUFFLE_CONSOLE) console.error("  console[" + m.type() + "] " + t);
        const at = t.indexOf("log_adapter.rs:");
        if (at < 0) return;
        const body = t.slice(t.indexOf("%c", at) + 2).replace(/^ /, "");
        const style = body.lastIndexOf(" color: whitesmoke;");
        consoleTraces.push(style >= 0 ? body.slice(0, style) : body);
    });
    page.on("pageerror", (e) => console.error("  pageerror " + e.message));
    // Serve the bundle and the movie from one origin so the wasm loads.
    await page.setRequestInterception(true);
    page.on("request", (req) => {
        const url = new URL(req.url());
        if (process.env.RUFFLE_TRACE_REQ) console.error("  req " + url.pathname);
        if (url.pathname === "/") {
            req.respond({
                contentType: "text/html",
                // Cross-origin isolation: ruffle picks a wasm build with
                // threads when it can, and that one needs SharedArrayBuffer.
                headers: {
                    "Cross-Origin-Opener-Policy": "same-origin",
                    "Cross-Origin-Embedder-Policy": "require-corp",
                },
                body: "<!doctype html><html><body></body></html>",
            });
        } else if (url.pathname === "/movie.swf") {
            req.respond({ contentType: "application/x-shockwave-flash", body: swf });
        } else {
            // The bundle asks for its wasm and its lazy chunks relative to
            // the PAGE, not to ruffle.js, so anything whose basename is in
            // the bundle directory is served from there.
            const name = url.pathname.split("/").pop();
            try {
                const body = readFileSync("/opt/ruffle/" + name);
                const type = name.endsWith(".js") ? "text/javascript"
                    : name.endsWith(".wasm") ? "application/wasm"
                    : name.endsWith(".map") ? "application/json"
                    : "application/octet-stream";
                req.respond({
                    contentType: type,
                    headers: {
                        "Cross-Origin-Opener-Policy": "same-origin",
                        "Cross-Origin-Embedder-Policy": "require-corp",
                        "Cross-Origin-Resource-Policy": "same-origin",
                    },
                    body,
                });
            } catch {
                req.respond({ status: 404, body: "no" });
            }
        }
    });
    await page.goto("http://ruffle.local/", { waitUntil: "domcontentloaded" });

    const size = await page.evaluate(async ({ renderer }) => {
        const mod = await import("/ruffle/ruffle.js");
        window.__traces = [];
        window.__diag = [];
        const ruffle = window.RufflePlayer.newest();
        const player = ruffle.createPlayer();
        player.style.width = "100%";
        player.style.height = "100%";
        document.body.style.margin = "0";
        document.body.appendChild(player);
        // On the INNER player, which is where ruffle's own selfhosted
        // tests attach it (web/packages/selfhosted/test/utils.ts:105).
        const inner = player.ruffle();
        inner.traceObserver = (m) => window.__traces.push(m);
        await inner.load({
            url: "/movie.swf",
            autoplay: "on",
            unmuteOverlay: "hidden",
            preferredRenderer: renderer,
            contextMenu: "off",
            splashScreen: false,
            forceScale: true,
            scale: "exactFit",
            allowScriptAccess: true,
            logLevel: "info",
        });
        // Ruffle loads PAUSED — its own selfhosted harness calls resume()
        // after attaching the observer, and without this the movie never
        // runs a frame and traces nothing.
        try { inner.resume(); } catch (e) { /* already playing */ }
        if (window.__diag) window.__diag.push("inner=" + typeof inner + " obs=" + typeof inner.traceObserver + " keys=" + Object.getOwnPropertyNames(Object.getPrototypeOf(inner)).slice(0, 12).join(","));

        // The movie's own stage size decides the canvas we screenshot.
        const meta = await new Promise((ok) => {
            const done = () => ok(player.metadata ?? null);
            if (player.metadata) return done();
            player.addEventListener("loadedmetadata", done, { once: true });
            setTimeout(done, 4000);
        });
        return meta ? { width: meta.width, height: meta.height } : null;
    }, { renderer });

    if (size) {
        await page.setViewport({ width: Math.ceil(size.width), height: Math.ceil(size.height) });
        await page.evaluate(({ w, h }) => {
            const p = document.querySelector("ruffle-player") ?? document.body.firstElementChild;
            p.style.width = w + "px";
            p.style.height = h + "px";
        }, { w: size.width, h: size.height });
    }

    await new Promise((r) => setTimeout(r, ms));

    if (process.env.RUFFLE_DIAG) {
        console.error(await page.evaluate(() => (window.__diag || []).join("\n")));
    }
    const observed = await page.evaluate(() => window.__traces);
    const lines = observed.length ? observed : consoleTraces;
    writeFileSync(txtPath, lines.length ? lines.join("\n") + "\n" : "");

    const el = await page.$("ruffle-player");
    const shot = await (el ?? page).screenshot({ type: "png", omitBackground: false });
    writeFileSync(pngPath, shot);
    console.error(`ruffle: ${basename(swfPath)} -> ${pngPath} (${size ? size.width + "x" + size.height : "?"}), ${lines.length} trace lines`);
} finally {
    await browser.close();
}
