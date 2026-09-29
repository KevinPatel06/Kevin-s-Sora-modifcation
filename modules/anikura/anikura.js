// ==========================================
// ⚙️ SORA MODULE — ANIKURA
// ==========================================
// anikura.club is a Next.js App Router site with its own internal anime ids
// (One Piece is 1642 there, not AniList's 21 — the two must never be confused).
// Its record carries ani_id and mal_id, but the playback endpoint is keyed by
// the internal id, so everything hangs off that.
//
//   1. Search    GET /search?q=<text>
//                -> <a class="poster-link" href="/anime/<id>/<slug>"> with the
//                   title in the img alt and the poster behind
//                   /api/media/image?u=<url-encoded original>
//   2. Entry     GET /anime/<id>/<slug>
//                -> description in <meta name="description">, and the episode
//                   list rendered as "Episode N"
//   3. Streams   GET /api/watch/streams?id=<id>&ep=<n>&lang=<sub|dub>
//                   header x-anikura-player: 1
//                -> {streams:[{id,label,language,kind,url}], audioRelease, language}
//
// Note on /browse: it takes a ?q= parameter that the server ignores — every
// query, including a nonsense one, returns the same 47-record default payload.
// Only /search?q= actually searches. Verified by counter-example rather than
// assumed.
//
// The site has accounts and a membership (/api/auth/me, /api/membership/me),
// and the player code handles a 401 with a "trial" flag. Measured, though:
// /api/watch/streams answers 200 with real streams and no credentials at all.
// If that ever changes, the module returns "none" rather than a broken link.
//
// Stream urls come both absolute (anikura-stream-edge.anikura.workers.dev) and
// site-relative (/api/stream/proxy?url=…); the relative ones are prefixed.
//
// Subtitles: each stream carries its own `tracks` [{label, language, url,
// format}], site-relative and timed to that server's encode, so they go on the
// stream as `subtitle` rather than in a shared top-level list. Sora's subtitle
// loader sends no Referer, and www.anikura.club 403s a request without a
// browser User-Agent; the edge worker serves the same signed path with no
// headers at all, so tracks are resolved against it. "srt" tracks come back
// from the proxy already converted to WEBVTT.
//
// Fork note: upstream's Supabase usage tracker (searches, opened entries,
// played episodes and stream urls POSTed to the author's database) is removed;
// the module talks to anikura hosts only.

const AK_BASE = "https://www.anikura.club";

const AK_EDGE = "https://anikura-stream-edge.anikura.workers.dev";

const AK_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const AK_LANGS = ["sub", "dub"];

// ==========================================
// 🌐 NETWORK
// ==========================================

async function soraFetch(url, options = { headers: {}, method: 'GET', body: null }) {
    // The host expects every request to carry a User-Agent; fill one in when
    // the caller did not set one.
    const headers = options.headers || {};
    if (!headers["User-Agent"]) headers["User-Agent"] = AK_UA;
    try {
        if (typeof fetchv2 !== 'undefined') {
            return await fetchv2(url, headers, options.method ?? 'GET', options.body ?? null);
        } else {
            return await fetch(url, { ...options, headers: headers });
        }
    } catch (e) {
        try { return await fetch(url, { ...options, headers: headers }); } catch (error) { return null; }
    }
}

async function readBody(response) {
    if (!response) return "";
    if (typeof response.text === 'function') return await response.text();
    if (typeof response.data === 'string') return response.data;
    return "";
}

async function akGet(path) {
    const headers = {
        "User-Agent": AK_UA,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Referer": `${AK_BASE}/`
    };
    return await readBody(await soraFetch(`${AK_BASE}${path}`, { method: 'GET', headers: headers }));
}

async function akGetJson(path) {
    const headers = {
        "User-Agent": AK_UA,
        "Accept": "application/json",
        "Referer": `${AK_BASE}/`,
        // The player identifies itself with this header; without it the route
        // is less predictable.
        "x-anikura-player": "1"
    };
    const body = await readBody(await soraFetch(`${AK_BASE}${path}`, { method: 'GET', headers: headers }));
    if (!body) return null;
    try { return JSON.parse(body); } catch (e) { return null; }
}

function decodeEntities(text) {
    if (!text) return "";
    return String(text)
        .replace(/&#x27;|&#039;|&#39;|&rsquo;/g, "'")
        .replace(/&quot;|&#34;/g, '"')
        .replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ')
        .replace(/&#(\d+);/g, (m, code) => String.fromCharCode(parseInt(code, 10)))
        .replace(/\s+/g, ' ')
        .trim();
}

// Posters are served through a resizing proxy that carries the original url in
// its `u` parameter; hand the original to Sora so it caches a stable address.
function unwrapPoster(src) {
    if (!src) return "";
    const match = src.match(/\/api\/media\/image\?u=([^"&]+)/);
    if (match) {
        try { return decodeURIComponent(match[1]); } catch (e) { /* keep the proxy */ }
    }
    if (src.charAt(0) === '/') return `${AK_BASE}${src}`;
    return src;
}

// Pick the English track when there is one, else the first; Sora takes one
// subtitle per stream.
function pickSubtitle(tracks) {
    if (!Array.isArray(tracks) || tracks.length === 0) return "";
    const withUrl = tracks.filter(t => t && t.url);
    if (withUrl.length === 0) return "";
    const english = withUrl.find(t => t.language === "en" || /^english/i.test(t.label || ""));
    const url = (english || withUrl[0]).url;
    if (url.charAt(0) === '/') return `${AK_EDGE}${url}`;
    return url;
}

// ==========================================
// 🔍 SEARCH
// ==========================================

async function searchResults(keyword) {
    console.log(`[Search] 🔍 Anikura — searching for "${keyword}"`);
    try {
        const html = await akGet(`/search?q=${encodeURIComponent(keyword)}`);

        const results = [];
        const seen = new Set();

        // Every result is one <a class="poster-link …> block.
        const blocks = String(html).split(/<a class="poster-link/).slice(1);
        for (const block of blocks) {
            const chunk = block.slice(0, 2000);

            const hrefMatch = chunk.match(/href="(\/anime\/(\d+)\/[^"]+)"/);
            if (!hrefMatch) continue;
            const path = hrefMatch[1];
            const id = hrefMatch[2];
            if (seen.has(id)) continue;
            seen.add(id);

            const altMatch = chunk.match(/alt="([^"]*)"/);
            const title = altMatch ? decodeEntities(altMatch[1]) : `Anikura ${id}`;

            const srcMatch = chunk.match(/\bsrc="([^"]*)"/);
            const image = unwrapPoster(srcMatch ? srcMatch[1] : "");

            results.push({ title: title, image: image, href: `anikura://${path}` });
        }

        console.log(`[Search] ✅ ${results.length} result(s)`);
        return JSON.stringify(results);
    } catch (error) {
        console.log(`[Search] 🚨 ${error}`);
        return JSON.stringify([]);
    }
}

// ==========================================
// 📖 DETAILS
// ==========================================

// href is `anikura:///anime/<id>/<slug>`; the play href is
// `anikura-play://<id>/<episode>`.
function parseHref(url) {
    const rest = url.replace('anikura://', '');
    const match = rest.match(/\/anime\/(\d+)\/(.*)$/);
    if (match) return { id: match[1], path: rest };
    return { id: rest.split('/')[0], path: rest };
}

async function extractDetails(url) {
    const ref = parseHref(url);
    console.log(`[Details] 📖 Anikura — ${ref.path}`);

    try {
        const html = await akGet(ref.path);

        const descMatch = html.match(/<meta[^>]+name="description"[^>]+content="([^"]*)"/)
            || html.match(/<meta[^>]+property="og:description"[^>]+content="([^"]*)"/);
        const description = descMatch ? decodeEntities(descMatch[1]) : "";

        const aliasParts = [];
        // The entry line reads "Studio: X" and "Source: Y", each value wrapped
        // in its own span.
        const studio = html.match(/Studio:<!-- -->\s*<span[^>]*>([^<]+)</);
        if (studio) aliasParts.push(`Studio: ${decodeEntities(studio[1])}`);
        const source = html.match(/Source:<!-- -->\s*<span[^>]*>([^<]+)</);
        if (source) aliasParts.push(`Source: ${decodeEntities(source[1])}`);

        let airdate = "";
        const year = html.match(/"year":(\d{4})/);
        if (year) airdate = year[1];
        const status = html.match(/"status":"([^"]{3,30})"/);
        if (status) airdate = airdate ? `${airdate} · ${status[1]}` : status[1];

        return JSON.stringify([{
            description: description || "No synopsis available.",
            aliases: aliasParts.join(' | '),
            airdate: airdate
        }]);
    } catch (error) {
        console.log(`[Details] 🚨 ${error}`);
        return JSON.stringify([{ description: 'Loading error.', aliases: '', airdate: '' }]);
    }
}

// ==========================================
// 📂 EPISODES
// ==========================================

async function extractEpisodes(url) {
    const ref = parseHref(url);
    console.log(`[Episodes] 📂 Anikura — entry ${ref.id}`);

    try {
        const html = await akGet(ref.path);

        // The entry page renders every episode as the literal text
        // "Episode <n>". Collect the distinct numbers rather than trusting a
        // single advertised count, which is absent on ongoing shows.
        const numbers = new Set();
        const re = /Episode (\d{1,4})\b/g;
        let m;
        while ((m = re.exec(html)) !== null) {
            const n = parseInt(m[1], 10);
            if (n > 0) numbers.add(n);
        }

        // Fall back on the declared count when the list did not render.
        if (numbers.size === 0) {
            const declared = html.match(/"episodes":"?(\d{1,4})"?/);
            const total = declared ? parseInt(declared[1], 10) : 0;
            for (let n = 1; n <= total; n++) numbers.add(n);
        }
        if (numbers.size === 0) numbers.add(1);

        const episodes = Array.from(numbers).sort((a, b) => a - b).map(n => ({
            href: `anikura-play://${ref.id}/${n}`,
            number: n,
            season: 1,
            title: `Episode ${n}`
        }));

        console.log(`[Episodes] ✅ ${episodes.length} episode(s)`);
        return JSON.stringify(episodes);
    } catch (error) {
        console.log(`[Episodes] 🚨 ${error}`);
        return JSON.stringify([]);
    }
}

// ==========================================
// 🎬 PLAYBACK
// ==========================================

async function extractStreamUrl(url) {
    const parts = url.replace('anikura-play://', '').split('/');
    const id = parts[0];
    const epNumber = parts.length > 1 ? parts[1] : '1';

    console.log(`[Player] 🎬 Anikura — entry ${id}, episode ${epNumber}`);

    const streams = [];

    try {
        for (const lang of AK_LANGS) {
            const data = await akGetJson(`/api/watch/streams?id=${encodeURIComponent(id)}&ep=${encodeURIComponent(epNumber)}&lang=${lang}`);

            if (!data) {
                console.log(`[Player] ⚠️ No JSON returned for ${lang}.`);
                continue;
            }

            // The player treats 401 as "unauthorized / trial"; the endpoint has
            // answered anonymously so far, but say so plainly if that changes.
            if (data.unauthorized === true) {
                console.log(`[Player] 🔒 Anikura requires an account for ${lang}.`);
                continue;
            }

            const list = Array.isArray(data.streams) ? data.streams : [];
            if (list.length === 0) {
                console.log(`[Player] ⚠️ No stream for this episode (${lang}).`);
                continue;
            }

            for (const stream of list) {
                let streamUrl = stream.url || "";
                if (!streamUrl) continue;
                // Some entries are site-relative (/api/stream/proxy?url=…).
                if (streamUrl.charAt(0) === '/') streamUrl = `${AK_BASE}${streamUrl}`;
                if (streams.some(s => s.streamUrl === streamUrl)) continue;

                const label = stream.label || stream.id || `Anikura ${lang}`;
                const subtitle = pickSubtitle(stream.tracks);
                const entry = {
                    title: `Anikura ${label}`,
                    streamUrl: streamUrl,
                    headers: { "Referer": `${AK_BASE}/`, "User-Agent": AK_UA }
                };
                if (subtitle) entry.subtitle = subtitle;
                streams.push(entry);
                console.log(`   -> ${label} (${stream.kind || 'hls'})${subtitle ? ' + subtitle' : ''}`);
            }
        }

        console.log(`-----------------------------------------------------`);
        console.log(`[Player] 📊 Summary: ${streams.length} link(s).`);


        if (streams.length === 0) return JSON.stringify({ type: "none" });

        // No top-level `subtitles`: a non-empty one would open a shared picker
        // and override each stream's own track.
        return JSON.stringify({
            type: "servers",
            streams: streams
        });
    } catch (error) {
        console.log(`[Player] 🚨 ${error}`);
        return JSON.stringify({ type: "none" });
    }
}
