#!/usr/bin/env node
// Runs a Sora module in Node with the globals the app's JavaScriptCore context
// actually provides (JavaScriptCore+Extensions.swift), and none it doesn't:
//
//   fetchv2(url, headers, method, body, redirect, encoding)
//       -> { status, headers, text(), json() }; network errors RESOLVE { error }
//   fetch(url, headers)             legacy: resolves to the body string
//   console.log / console.error / log   single string argument
//   btoa / atob
//   no setTimeout, setInterval, DOM, require, or Node's fetch
//
// Usage:
//   node sora-harness.js <module.js> <hook> '<json arg>'      one hook
//   node sora-harness.js <module.js> --all "<keyword>" [--pick N] [--ep N]
//       search -> details -> episodes -> stream, then checks each subtitle URL
//       loads the way the app's subtitle loader fetches it (browser UA, no
//       other headers).
//
// Passing here is a first check, not proof: verify on device in Settings -> Logger.

const fs = require("fs");
const vm = require("vm");

const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
const hosts = new Map();
const logs = [];

function note(url) {
    try { const h = new URL(url).host; hosts.set(h, (hosts.get(h) || 0) + 1); } catch (e) { /* ignore */ }
}

// Usage trackers seen in community modules. Requests to them are counted in the
// host list but never sent.
const BLOCKED = [/\.supabase\.co$/i];

// Plain http(s) requests rather than Node's fetch: undici adds sec-fetch-* and
// accept-language headers that iOS URLSession never sends, and some hosts
// (VidRift's embed check) answer those with a 403 the app would not get.
const http = require("http");
const https = require("https");
const zlib = require("zlib");

function rawRequest(url, headers, method, body, redirect, hops = 0) {
    return new Promise((resolve, reject) => {
        const u = new URL(url);
        const lib = u.protocol === "http:" ? http : https;
        const h = Object.assign({ "User-Agent": UA, "Accept": "*/*", "Accept-Encoding": "gzip, deflate, br" }, headers || {});
        if (body != null) h["Content-Length"] = Buffer.byteLength(body);
        const req = lib.request(u, { method, headers: h, timeout: 30000 }, (res) => {
            const loc = res.headers.location;
            if (redirect !== false && loc && res.statusCode >= 300 && res.statusCode < 400 && hops < 10) {
                res.resume();
                const next = new URL(loc, u).toString();
                const keep = res.statusCode === 307 || res.statusCode === 308;
                return resolve(rawRequest(next, headers, keep ? method : "GET", keep ? body : null, redirect, hops + 1));
            }
            let stream = res;
            const enc = res.headers["content-encoding"];
            if (enc === "gzip") stream = res.pipe(zlib.createGunzip());
            else if (enc === "deflate") stream = res.pipe(zlib.createInflate());
            else if (enc === "br") stream = res.pipe(zlib.createBrotliDecompress());
            const chunks = [];
            stream.on("data", c => chunks.push(c));
            stream.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks), url: u.toString() }));
            stream.on("error", reject);
        });
        req.on("timeout", () => req.destroy(new Error("timed out")));
        req.on("error", reject);
        if (body != null) req.write(body);
        req.end();
    });
}

async function nodeFetch(url, headers, method, body, redirect) {
    note(url);
    if (BLOCKED.some(re => re.test(new URL(url).host))) return { status: 204, headers: {}, body: Buffer.alloc(0), url };
    return rawRequest(url, headers, method || "GET", body == null ? null : body, redirect);
}

function makeContext() {
    const sandbox = {
        console: {
            log: (m) => logs.push(String(m)),
            error: (m) => logs.push("ERROR " + String(m))
        },
        log: (m) => logs.push("JavaScript log: " + String(m)),
        btoa: (s) => { try { return Buffer.from(String(s), "utf8").toString("base64"); } catch (e) { return null; } },
        atob: (s) => { try { return Buffer.from(String(s), "base64").toString("utf8"); } catch (e) { return null; } },
        fetchv2: async (url, headers = {}, method = "GET", body = null, redirect = true) => {
            if (method === "GET" && body) return "GET request must not have a body";
            const payload = body == null ? undefined : (typeof body === "string" ? body : JSON.stringify(body));
            try {
                const r = await nodeFetch(url, headers, method, payload, redirect);
                if (r.body.length > 10 * 1024 * 1024) return { error: "Response exceeds 10MB" };
                const text = r.body.toString("utf8");
                return { status: r.status, headers: r.headers, text: async () => text, json: async () => JSON.parse(text) };
            } catch (e) {
                return { error: String(e && e.message || e) };
            }
        },
        fetch: async (url, headers = {}) => {
            const r = await nodeFetch(url, headers, "GET");
            return r.body.toString("utf8");
        }
    };
    vm.createContext(sandbox);
    return sandbox;
}

function load(path) {
    const ctx = makeContext();
    vm.runInContext(fs.readFileSync(path, "utf8"), ctx, { filename: path });
    return ctx;
}

async function call(ctx, hook, arg) {
    if (typeof ctx[hook] !== "function") throw new Error(`No JavaScript function ${hook} found`);
    const out = await ctx[hook](arg);
    if (typeof out !== "string") throw new Error(`${hook} returned ${typeof out}, not a JSON string`);
    return out;
}

function parse(hook, out) {
    try { return JSON.parse(out); } catch (e) { return out; }
}

// Mirrors JSController-Streams.swift + MediaInfoView subtitle resolution.
function summarizeStreams(res) {
    if (typeof res === "string") return { sources: [{ title: "Stream 1", url: res }], topSubs: [] };
    const sources = [];
    if (Array.isArray(res.streams) && res.streams.length && typeof res.streams[0] === "object") {
        res.streams.forEach((s, i) => sources.push({ title: s.title || `Stream ${i + 1}`, url: s.streamUrl || s.url, subtitle: s.subtitle, headers: s.headers }));
    } else if (res.stream && typeof res.stream === "object") {
        sources.push({ title: "Stream 1", url: res.stream.url || res.stream.streamUrl, subtitle: res.stream.subtitle, headers: res.stream.headers });
    } else if (Array.isArray(res.streams)) {
        res.streams.forEach((s, i) => sources.push({ title: `Stream ${i + 1}`, url: s }));
    } else if (typeof res.stream === "string") {
        sources.push({ title: "Stream 1", url: res.stream });
    }
    let top = [];
    if (Array.isArray(res.subtitles)) top = res.subtitles;
    else if (typeof res.subtitles === "string") top = [res.subtitles];
    const topUrls = top.filter(s => /^https?:\/\//i.test(s));
    return { sources, topSubs: topUrls, ignoredTopLevelSubtitle: res.subtitle !== undefined };
}

async function subtitleLoads(url) {
    try {
        const r = await rawRequest(url, {}, "GET", null, true);
        const t = r.body.toString("utf8").trim();
        const fmt = t.includes("WEBVTT") ? "vtt" : (t.includes("-->") ? "srt" : "not subtitles");
        return `${r.status} ${fmt}`;
    } catch (e) {
        return `error ${e.message}`;
    }
}

async function runAll(path, keyword, pick, epIndex) {
    const ctx = load(path);
    const search = parse("searchResults", await call(ctx, "searchResults", keyword));
    console.log(`searchResults: ${Array.isArray(search) ? search.length : "?"} result(s)`);
    if (!Array.isArray(search) || !search.length) return;
    const item = search[Math.min(pick, search.length - 1)];
    console.log(`  picked: ${item.title} -> ${item.href}`);

    const details = parse("extractDetails", await call(load(path), "extractDetails", item.href));
    console.log(`extractDetails: ${Array.isArray(details) ? "array" : "NOT AN ARRAY (app shows nothing)"}; airdate=${JSON.stringify((details[0] || details).airdate)}; ${String((details[0] || details).description || "").slice(0, 60)}`);

    const t0 = Date.now();
    const eps = parse("extractEpisodes", await call(load(path), "extractEpisodes", item.href));
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    const badNums = Array.isArray(eps) ? eps.filter(e => typeof e.number !== "number").length : 0;
    console.log(`extractEpisodes: ${eps.length} episode(s) in ${secs}s${secs > 15 ? " (OVER the app's 15s timeout)" : ""}; non-integer numbers: ${badNums}`);
    if (!eps.length) return;
    const ep = eps[Math.min(epIndex, eps.length - 1)];
    console.log(`  playing: #${ep.number} -> ${ep.href}`);

    const raw = await call(load(path), "extractStreamUrl", ep.href);
    const s = summarizeStreams(parse("extractStreamUrl", raw));
    console.log(`extractStreamUrl: ${s.sources.length} source(s)`);
    for (const src of s.sources) {
        const sub = src.subtitle ? ` | subtitle: ${await subtitleLoads(src.subtitle)}` : "";
        console.log(`  - ${src.title}${sub}`);
    }
    if (s.topSubs.length) {
        console.log(`  top-level subtitles (override per-source): ${s.topSubs.length}`);
        for (const u of s.topSubs.slice(0, 3)) console.log(`    ${await subtitleLoads(u)}  ${u.slice(0, 90)}`);
    } else {
        console.log(`  top-level subtitles: none`);
    }
    if (s.ignoredTopLevelSubtitle) console.log(`  WARNING: top-level "subtitle" key is ignored by the app`);
}

(async () => {
    const [path, hook, arg, ...rest] = process.argv.slice(2);
    if (!path || !hook) {
        console.log("usage: node sora-harness.js <module.js> <hook> '<json arg>' | --all \"<keyword>\" [--pick N] [--ep N]");
        process.exit(1);
    }
    try {
        if (hook === "--all") {
            const opt = (name) => { const i = rest.indexOf(name); return i === -1 ? 0 : parseInt(rest[i + 1], 10) || 0; };
            await runAll(path, arg, opt("--pick"), opt("--ep"));
        } else {
            console.log(await call(load(path), hook, JSON.parse(arg)));
        }
    } catch (e) {
        console.log("FAILED: " + e.message);
    }
    if (process.argv.includes("--logs")) logs.forEach(l => console.log("  log: " + l));
    console.log("hosts contacted: " + [...hosts.entries()].map(([h, n]) => `${h} (${n})`).join(", "));
})();
