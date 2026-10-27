#!/usr/bin/env node
// Runs a Sora-format module in Node the way Shirox's JavaScriptCore bridge runs it
// (Shirox/Services/JSEngine.swift, ModuleJSRunner.swift, JSEngine+Streams.swift), or the way
// Sora runs it (--env sora), so a failure can be pinned on the site or on the host app.
//
// Shirox differences this models (all verified against the Shirox source):
//   fetch(url, options)   -> response object (Sora: resolves to the body STRING, 2nd arg = headers)
//   res.text()/res.json() -> plain values     (Sora: Promises)
//   fetchv2 network error -> REJECTS          (Sora: resolves { error })
//   fetchv2 5th arg       -> "extra"/impersonate (Sora: redirect flag); object bodies -> "[object Object]"
//   headers with any non-string value are dropped wholesale (Swift `as? [String: String]`)
//   setTimeout/setInterval exist; adult-host blocklist rejects requests
//   asyncJS/streamAsyncJS ignored: every hook gets the URL/keyword, never page HTML
//   stream parsing: per-stream `subtitle(s)` ignored, `subtitles` array ignored, only top-level
//   `subtitle`/`subtitles` STRING + `allSubtitles` [{url,title}]; streams ["Title","url",...]
//   pairs read as URLs; a top-level JSON array is a parse error
//
// Usage:
//   node shirox-harness.js <module.js> --all "<keyword>" [--env shirox|sora] [--pick N] [--ep N] [--json]
//   node shirox-harness.js <module.js> <hook> '<json arg>' [--env sora]

const fs = require("fs");
const vm = require("vm");
const path = require("path");
const http = require("http");
const https = require("https");
const zlib = require("zlib");

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf(n); return i === -1 ? d : args[i + 1]; };
const ENV = flag("--env", "shirox");
const JSON_OUT = args.includes("--json");

const SHIROX_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const SORA_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
const SAFARI_IOS_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const CHROME_WIN_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";
const FIREFOX_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0";

const logs = [];
const hosts = new Map();
const flags = new Set();      // engine-relevant events worth reporting

// Shirox's bundled adult-host list (HostBlocklist.swift): a host or any parent with >= 2 labels.
const BLOCKLIST = (() => {
    const p = flag("--blocklist", path.join(__dirname, "../../Shirox/Shirox/Resources/adult_hosts.txt"));
    try {
        return new Set(fs.readFileSync(p, "utf8").split("\n").map(l => l.replace(/#.*/, "").trim().split(/\s+/).pop())
            .filter(h => h && h.includes(".")).map(h => h.toLowerCase()));
    } catch (e) { return new Set(); }
})();
function blocked(host) {
    const labels = host.toLowerCase().split(".");
    for (let i = 0; i <= labels.length - 2; i++) if (BLOCKLIST.has(labels.slice(i).join("."))) return true;
    return false;
}

// Minimal cookie jar: URLSession stores and replays cookies by default in both apps.
const jar = new Map();
function storeCookies(u, setCookie) {
    if (!setCookie) return;
    const list = Array.isArray(setCookie) ? setCookie : [setCookie];
    const m = jar.get(u.host) || new Map();
    for (const c of list) { const kv = c.split(";")[0]; const i = kv.indexOf("="); if (i > 0) m.set(kv.slice(0, i).trim(), kv.slice(i + 1)); }
    jar.set(u.host, m);
}
function cookieHeader(u) { const m = jar.get(u.host); return m && m.size ? [...m].map(([k, v]) => k + "=" + v).join("; ") : null; }

function rawRequest(url, headers, method, body, redirect = true, hops = 0) {
    return new Promise((resolve, reject) => {
        const u = new URL(url);
        hosts.set(u.host, (hosts.get(u.host) || 0) + 1);
        const lib = u.protocol === "http:" ? http : https;
        const h = Object.assign({ "Accept": "*/*", "Accept-Encoding": "gzip, deflate, br" }, headers || {});
        const ck = cookieHeader(u);
        if (ck && !Object.keys(h).some(k => k.toLowerCase() === "cookie")) h["Cookie"] = ck;
        if (body != null) h["Content-Length"] = Buffer.byteLength(body);
        const req = lib.request(u, { method, headers: h, timeout: 30000 }, (res) => {
            storeCookies(u, res.headers["set-cookie"]);
            const loc = res.headers.location;
            if (redirect !== false && loc && res.statusCode >= 300 && res.statusCode < 400 && hops < 10) {
                res.resume();
                const keep = res.statusCode === 307 || res.statusCode === 308;
                return resolve(rawRequest(new URL(loc, u).toString(), headers, keep ? method : "GET", keep ? body : null, redirect, hops + 1));
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
        req.on("timeout", () => req.destroy(new Error("The request timed out.")));
        req.on("error", reject);
        if (body != null) req.write(body);
        req.end();
    });
}

// Swift: Data(base64Encoded:) is strict (no whitespace, padding required), then UTF-8 or "".
function strictAtob(s, failValue) {
    s = String(s);
    if (s.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(s)) { flags.add("atob: non-strict base64 input (Swift returns " + JSON.stringify(failValue) + ")"); return failValue; }
    const buf = Buffer.from(s, "base64");
    const txt = buf.toString("utf8");
    if (Buffer.from(txt, "utf8").equals(buf)) return txt;
    flags.add("atob: decoded bytes not UTF-8 (Swift returns " + JSON.stringify(failValue) + ")");
    return failValue;
}

function profileHeaders(target) {
    if (target === "chrome") return { "User-Agent": CHROME_WIN_UA, "sec-ch-ua": '"Chromium";v="128", "Not;A=Brand";v="24", "Google Chrome";v="128"', "sec-ch-ua-mobile": "?0", "sec-ch-ua-platform": '"Windows"', "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", "Accept-Language": "en-US,en;q=0.9", "Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-User": "?1", "Sec-Fetch-Dest": "document", "Upgrade-Insecure-Requests": "1" };
    if (target === "firefox") return { "User-Agent": FIREFOX_UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Accept-Language": "en-US,en;q=0.5", "Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "none", "Sec-Fetch-User": "?1", "Upgrade-Insecure-Requests": "1" };
    return { "User-Agent": SAFARI_IOS_UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Accept-Language": "en-US,en;q=0.9", "Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document", "Upgrade-Insecure-Requests": "1" };
}

// ---- Shirox context -------------------------------------------------------------------------

function shiroxContext() {
    const sb = {};
    sb.console = {
        log: (m) => logs.push(String(m)), debug: (m) => logs.push(String(m)),
        error: (m) => logs.push("ERROR " + String(m)), warn: (m) => logs.push("WARN " + String(m)),
    };
    sb.btoa = (s) => Buffer.from(String(s), "utf8").toString("base64");
    sb.atob = (s) => strictAtob(s, "");
    sb._0xB4F2 = () => "shirox-cranci-10";
    sb.setTimeout = (fn, ms) => setTimeout(() => { try { fn(); } catch (e) { logs.push("timer error " + e); } }, ms || 0);
    sb.clearTimeout = clearTimeout; sb.setInterval = setInterval; sb.clearInterval = clearInterval;
    sb.networkFetch = sb.networkFetchSimple = () => { flags.add("uses networkFetch (WKWebView) - not emulated"); return Promise.reject("networkFetch not emulated"); };

    // JSEngine.setupFetchV2 native half.
    sb.fetchv2Native = (urlString, headersVal, methodVal, bodyVal, extraVal, resolve, reject) => {
        let url;
        try { url = new URL(urlString); } catch (e) { return reject("Invalid URL: " + urlString); }
        if (blocked(url.host)) { flags.add("BLOCKED by Shirox adult-host list: " + url.host); return reject("Blocked host: " + url.host); }
        const method = methodVal == null ? "GET" : String(methodVal);
        const body = bodyVal == null ? null : String(bodyVal);  // JSValue.toString(): objects -> "[object Object]"
        if (bodyVal != null && typeof bodyVal === "object") flags.add("fetchv2 body is an object: Shirox sends \"[object Object]\" (Sora JSON-encodes it)");
        let jsHeaders = {};
        if (headersVal != null && typeof headersVal === "object") {
            const entries = Object.entries(headersVal);
            if (entries.every(([, v]) => typeof v === "string")) jsHeaders = Object.assign({}, headersVal);
            else flags.add("headers had a non-string value: Shirox drops ALL headers for that request");
        }
        let imp = null, webview = false;
        const pick = (v) => { const s = String(v).toLowerCase(); if (s === "webview") webview = true; else imp = ["safari", "chrome", "firefox"].includes(s) ? s : "auto"; };
        if (extraVal != null) {
            if (typeof extraVal === "boolean") { if (extraVal) imp = "auto"; }
            else if (typeof extraVal === "string") pick(extraVal);
            else if (typeof extraVal === "object") {
                if (extraVal.impersonate === true) imp = "auto"; else if (typeof extraVal.impersonate === "string") pick(extraVal.impersonate);
                if (String(extraVal.engine || "").toLowerCase() === "webview") webview = true;
            }
        }
        if (!imp && !webview && jsHeaders.impersonate) { pick(jsHeaders.impersonate); delete jsHeaders.impersonate; }
        if (webview) flags.add("fetchv2 engine=webview - emulated as plain request");
        let h = { "User-Agent": SHIROX_UA };
        if (imp) h = Object.assign(h, profileHeaders(imp));
        // URLRequest.setValue is case-insensitive: a module's "user-agent" replaces ours.
        for (const [k, v] of Object.entries(jsHeaders)) { for (const e of Object.keys(h)) if (e.toLowerCase() === k.toLowerCase()) delete h[e]; h[k] = v; }
        rawRequest(url.toString(), h, method, body).then(r => {
            const text = r.body.toString("utf8");
            const hd = {}; for (const [k, v] of Object.entries(r.headers)) hd[k] = Array.isArray(v) ? v.join(", ") : String(v);
            resolve(sb.__shiroxMakeResponse(r.status, http.STATUS_CODES[r.status] || "", r.url, hd, text, null));
        }, e => reject(e.message || String(e)));
    };
    vm.createContext(sb);
    vm.runInContext(`
        function fetchv2(url, headers, method, body, extra) {
            var h = headers || {}; var m = method || 'GET'; var b = body || null; var opt = extra || null;
            if (typeof headers === 'boolean' || typeof headers === 'string') { opt = { impersonate: headers }; h = {}; }
            else if (typeof headers === 'object' && headers !== null && (headers.method || headers.headers || headers.body || headers.impersonate !== undefined || headers.engine !== undefined)) {
                h = headers.headers || {}; m = headers.method || (typeof method === 'string' ? method : 'GET');
                b = headers.body || (typeof body === 'string' ? body : null); opt = headers;
            } else if (typeof extra === 'boolean') { opt = { impersonate: extra }; }
            else if (typeof method === 'boolean') { opt = { impersonate: method }; m = 'GET'; }
            else if (typeof body === 'boolean') { opt = { impersonate: body }; b = null; }
            return new Promise(function(resolve, reject) { fetchv2Native(url, h, m, b, opt || {}, resolve, reject); });
        }
        (function(global) {
            var shiroxFetchV2 = global.fetchv2;
            function shiroxSoraFetch(url, options) {
                var headers = {}, method = 'GET', body = null, extra = null;
                if (options && typeof options === 'object') { headers = options.headers || {}; method = options.method || 'GET'; body = options.body || null; extra = options; }
                return shiroxFetchV2(url, headers, method, body, extra);
            }
            global.soraFetch = shiroxSoraFetch;
            global.fetch = function(url, options) { return shiroxSoraFetch(url, options); };
        })(this);
        if (typeof sendLog === 'undefined') { function sendLog(msg) { console.log('[Module] ' + msg); } }
        function getElementsByTag(html, tag) { var regex = new RegExp('<' + tag + '[^>]*>([\\\\s\\\\S]*?)</' + tag + '>', 'gi'); var matches = []; var match; while ((match = regex.exec(html)) !== null) matches.push(match[0]); return matches; }
        function getAttribute(element, attr) { var regex = new RegExp(attr + '=["\\'](.*?)["\\']'); var match = element.match(regex); return match ? match[1] : ''; }
        function getInnerText(element) { return element.replace(/<[^>]*>/g, '').trim(); }
        function stripHtml(html) { return html.replace(/<[^>]*>/g, ''); }
        var __shiroxMakeResponse = function (status, statusText, url, headers, body, raw) {
            var response = { status: status, ok: status >= 200 && status < 300, url: url, headers: headers,
                text: function () { return body; },
                json: function () { try { return JSON.parse(body); } catch (e) { console.log('[fetchv2] json(): ' + e); return undefined; } } };
            if (statusText != null) response.statusText = statusText;
            return response;
        };
    `, sb);
    return sb;
}

// ---- Sora context (JavaScriptCore+Extensions.swift) -----------------------------------------

function soraContext() {
    const sb = {
        console: { log: (m) => logs.push(String(m)), error: (m) => logs.push("ERROR " + String(m)) },
        log: (m) => logs.push("JavaScript log: " + String(m)),
        btoa: (s) => Buffer.from(String(s), "utf8").toString("base64"),
        atob: (s) => strictAtob(s, null),
        _0xB4F2: () => "sora-cranci-xx1",
        networkFetch: () => { flags.add("uses networkFetch (WKWebView) - not emulated"); return Promise.reject("networkFetch not emulated"); },
        fetchv2: async (url, headers = {}, method = "GET", body = null, redirect = true) => {
            const payload = method === "GET" || body == null ? null : (typeof body === "object" ? JSON.stringify(body) : String(body));
            const h = Object.assign({ "User-Agent": SORA_UA }, headers && typeof headers === "object" ? headers : {});
            try {
                const r = await rawRequest(url, h, method, payload, redirect);
                const text = r.body.toString("utf8");
                return { status: r.status, headers: r.headers, _data: text, text: () => Promise.resolve(text), json: () => { try { return Promise.resolve(JSON.parse(text)); } catch (e) { return Promise.reject("JSON parse error: " + e.message); } } };
            } catch (e) { return { error: String(e && e.message || e) }; }
        },
        fetch: async (url, headers = {}) => (await rawRequest(url, Object.assign({ "User-Agent": SORA_UA }, headers || {}), "GET")).body.toString("utf8"),
    };
    vm.createContext(sb);
    return sb;
}

function load(file) {
    const ctx = ENV === "sora" ? soraContext() : shiroxContext();
    try { vm.runInContext(fs.readFileSync(file, "utf8"), ctx, { filename: file }); }
    catch (e) { throw new Error("script load error: " + e.message); }
    return ctx;
}

// JSValue.toString() of whatever the promise resolved with.
async function call(ctx, hook, arg) {
    if (typeof ctx[hook] !== "function") throw new Error(`JS function ${hook} not found`);
    let out = ctx[hook](arg);
    if (out && typeof out.then === "function") {
        out = await Promise.race([out, new Promise((_, rej) => setTimeout(() => rej(new Error(hook + " timed out (120s)")), 120000))]);
    }
    if (out === undefined || out === null) throw new Error(`${hook} returned ${out}`);
    return String(out);
}

// ---- What each app does with extractStreamUrl's string --------------------------------------

function validURL(s) { if (typeof s !== "string" || !s) return false; try { new URL(s); return true; } catch (e) { return false; } }
const isDict = (x) => x && typeof x === "object" && !Array.isArray(x);
const strHeaders = (x) => isDict(x) && Object.values(x).every(v => typeof v === "string") ? x : {};

function parseShirox(raw) {
    const t = raw.trim();
    if (validURL(t) && !t.startsWith("{")) return { sources: [{ title: "Play", url: t, headers: {} }], subs: [] };
    let obj; try { obj = JSON.parse(t); } catch (e) { return { error: "not JSON and not a URL" }; }
    if (!isDict(obj)) return { error: "top-level JSON " + (Array.isArray(obj) ? "array" : typeof obj) + " - Shirox only accepts an object" };
    const subs = [];
    const single = typeof obj.subtitle === "string" ? obj.subtitle : (typeof obj.subtitles === "string" ? obj.subtitles : null);
    if (Array.isArray(obj.allSubtitles) && obj.allSubtitles.every(isDict)) {
        for (const s of obj.allSubtitles) { const u = s.url || s.file || s.src; if (validURL(u)) subs.push({ title: s.title || s.label || s.lang || s.language || s.name || "Subtitle", url: u, headers: strHeaders(s.headers) }); }
    }
    // PlayerView.loadSubtitles: the default track is shown first; when its URL is also in
    // allSubtitles that entry (and its headers) is selected, otherwise `subtitleHeaders` go along.
    if (single) {
        const i = subs.findIndex(s => s.url === single);
        if (i >= 0) subs.unshift(subs.splice(i, 1)[0]);
        else subs.unshift({ title: "Subtitle (default)", url: single, headers: strHeaders(obj.subtitleHeaders) });
    }
    const sources = [];
    const s = obj.streams;
    if (Array.isArray(s) && s.length && s.every(isDict)) {
        for (const x of s) { const u = typeof x.streamUrl === "string" ? x.streamUrl : (typeof x.url === "string" ? x.url : null); if (validURL(u)) sources.push({ title: x.title || "Stream", url: u, headers: strHeaders(x.headers), droppedHeaders: isDict(x.headers) && !Object.values(x.headers).every(v => typeof v === "string"), ignoredSubs: x.subtitle || x.subtitles || null }); }
    } else if (Array.isArray(s) && s.every(x => typeof x === "string")) {
        s.forEach((u, i) => { if (validURL(u)) sources.push({ title: "Stream " + (i + 1), url: u, headers: {} }); else sources.push({ title: "Stream " + (i + 1), url: u, headers: {}, bogus: true }); });
    } else if (typeof obj.stream === "string" && validURL(obj.stream)) sources.push({ title: "Stream", url: obj.stream, headers: {} });
    else if (isDict(obj.stream) && validURL(obj.stream.url)) sources.push({ title: "Stream", url: obj.stream.url, headers: strHeaders(obj.stream.headers) });
    return { sources, subs, ignoredSubsArray: Array.isArray(obj.subtitles) ? obj.subtitles.length : 0 };
}

function parseSora(raw) {
    const t = raw.trim();
    let obj; try { obj = JSON.parse(t); } catch (e) { return { sources: [{ title: "Stream 1", url: t, headers: {} }], subs: [] }; }
    if (Array.isArray(obj)) return { sources: obj.map((u, i) => ({ title: "Stream " + (i + 1), url: u, headers: {} })), subs: [] };
    if (!isDict(obj)) return { sources: [{ title: "Stream 1", url: t, headers: {} }], subs: [] };
    const sources = [];
    const subsFrom = (v) => Array.isArray(v) ? v.filter(x => typeof x === "string") : (typeof v === "string" ? [v] : []);
    if (Array.isArray(obj.streams) && obj.streams.length && obj.streams.every(isDict)) {
        obj.streams.forEach((x, i) => sources.push({ title: x.title || "Server " + (i + 1), url: x.streamUrl || x.url, headers: x.headers || {}, subs: subsFrom(x.subtitle || x.subtitles) }));
    } else if (isDict(obj.stream)) sources.push({ title: "Stream 1", url: obj.stream.url || obj.stream.streamUrl, headers: obj.stream.headers || {}, subs: subsFrom(obj.stream.subtitle) });
    else if (Array.isArray(obj.streams)) {
        const a = obj.streams;
        for (let i = 0; i < a.length;) { if (i + 1 < a.length && !String(a[i]).toLowerCase().includes("http")) { sources.push({ title: a[i], url: a[i + 1], headers: {} }); i += 2; } else { sources.push({ title: "Server", url: a[i], headers: {} }); i++; } }
    } else if (typeof obj.stream === "string") sources.push({ title: "Stream 1", url: obj.stream, headers: {} });
    const top = subsFrom(obj.subtitles).map(u => ({ title: "Subtitle", url: u }));
    const per = sources.flatMap(s => (s.subs || []).map(u => ({ title: s.title + " sub", url: u })));
    return { sources, subs: top.length ? top : per };
}

// ---- Probes ---------------------------------------------------------------------------------

async function probeStream(src) {
    if (!validURL(src.url)) return "invalid url";
    try {
        const r = await rawRequest(src.url, Object.assign({ "User-Agent": SAFARI_IOS_UA, "Range": "bytes=0-4095" }, src.headers || {}), "GET", null);
        const head = r.body.slice(0, 4096).toString("utf8");
        const kind = head.includes("#EXTM3U") ? "m3u8" : /video|mpegurl|octet/.test(r.headers["content-type"] || "") ? (r.headers["content-type"] || "") : (head.trim().startsWith("<") ? "HTML page" : (r.headers["content-type"] || "?"));
        return `${r.status} ${kind}`;
    } catch (e) { return "error " + e.message; }
}
async function probeSub(sub) {
    try {
        const r = await rawRequest(sub.url, Object.assign({ "User-Agent": SAFARI_IOS_UA }, sub.headers || {}), "GET", null);
        const t = r.body.toString("utf8").trim();
        return `${r.status} ${t.includes("WEBVTT") ? "vtt" : t.includes("[Script Info]") ? "ass" : t.includes("-->") ? "srt" : "not subtitles"}`;
    } catch (e) { return "error " + e.message; }
}
const looksEnglish = (s) => /\b(en|eng|english)\b/i.test((s.title || "") + " " + s.url.replace(/[_./-]/g, " "));

// ---- Pipeline -------------------------------------------------------------------------------

async function runAll(file, keyword, pick, epIndex) {
    const R = { env: ENV, stage: "load" };
    // Shirox's JSEngine keeps one context per module; Sora re-evaluates per hook.
    const shared = load(file);
    const ctxFor = () => ENV === "sora" ? load(file) : shared;
    try {
        R.stage = "search";
        const sr = JSON.parse(await call(ctxFor(), "searchResults", keyword));
        if (!Array.isArray(sr)) throw new Error("searchResults is not an array");
        const kept = sr.filter(i => typeof i.title === "string" && typeof i.image === "string" && typeof i.href === "string");
        R.search = { raw: sr.length, kept: kept.length };
        if (sr.length && !kept.length) throw new Error("all results dropped (title/image/href must all be strings)");
        if (!kept.length) throw new Error("0 search results");
        const item = kept[Math.min(pick, kept.length - 1)];
        R.picked = item.title;

        R.stage = "details";
        try { const d = JSON.parse(await call(ctxFor(), "extractDetails", item.href)); R.details = Array.isArray(d) && d.length ? "ok" : "NOT a non-empty array"; }
        catch (e) { R.details = "failed: " + e.message; }

        R.stage = "episodes";
        const eps = JSON.parse(await call(ctxFor(), "extractEpisodes", item.href));
        if (!Array.isArray(eps)) throw new Error("extractEpisodes not an array");
        R.episodes = { count: eps.length, nonNumeric: eps.filter(e => typeof e.number !== "number").length, noHref: eps.filter(e => typeof e.href !== "string").length };
        const usable = eps.filter(e => typeof e.href === "string");
        if (!usable.length) throw new Error("0 usable episodes");
        const ep = usable[Math.min(epIndex, usable.length - 1)];

        R.stage = "stream";
        const raw = await call(ctxFor(), "extractStreamUrl", ep.href);
        R.rawStreamShape = raw.trim().slice(0, 1) === "{" ? Object.keys(JSON.parse(raw)).join(",") : raw.trim().slice(0, 60);
        if (args.includes("--raw")) R.raw = raw;
        const parsed = ENV === "sora" ? parseSora(raw) : parseShirox(raw);
        if (parsed.error) throw new Error("stream parse: " + parsed.error);
        R.sources = [];
        for (const s of parsed.sources.slice(0, 4)) R.sources.push({ title: s.title, probe: await probeStream(s), bogus: s.bogus || undefined, droppedHeaders: s.droppedHeaders || undefined, ignoredSubs: s.ignoredSubs ? (Array.isArray(s.ignoredSubs) ? s.ignoredSubs.length : 1) : undefined });
        R.subs = { count: parsed.subs.length, english: parsed.subs.filter(looksEnglish).length, ignoredSubsArray: parsed.ignoredSubsArray || undefined };
        // The track the player loads on its own: Shirox's default (first), Sora's first.
        if (parsed.subs[0]) { R.subs.default = parsed.subs[0].title + (looksEnglish(parsed.subs[0]) ? " [EN]" : ""); R.subs.probe = await probeSub(parsed.subs[0]); }
        if (!parsed.sources.length) throw new Error("0 playable sources after parsing");
        R.stage = "done";
    } catch (e) { R.error = e.message; }
    R.flags = [...flags];
    R.hosts = [...hosts.keys()];
    R.lastLogs = logs.slice(-6).map(l => l.slice(0, 200));
    return R;
}

(async () => {
    const [file, hook, arg] = args;
    if (!file || !hook) { console.log("usage: node shirox-harness.js <module.js> --all \"<keyword>\" [--env shirox|sora] [--pick N] [--ep N] [--json]"); process.exit(1); }
    if (hook === "--all") {
        const R = await runAll(file, arg, parseInt(flag("--pick", "0"), 10), parseInt(flag("--ep", "0"), 10));
        console.log(JSON_OUT ? JSON.stringify(R) : JSON.stringify(R, null, 2));
    } else {
        try { console.log(await call(load(file), hook, JSON.parse(arg))); } catch (e) { console.log("FAILED: " + e.message); }
        if (args.includes("--logs")) logs.forEach(l => console.log("  log: " + l));
        console.log("flags: " + [...flags].join(" | "));
    }
    process.exit(0);
})();
