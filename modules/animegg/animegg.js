async function searchResults(keyword) {
    const regex = /<a href="([^"]*)" class="mse">[\s\S]*?<img src="([^"]*)" class="media-object">[\s\S]*?<h2>([^<]*?)<\/h2>/g;
    const results = [];
    try {
        const response = await fetchv2("https://www.animegg.org/search/?q=" + encodeURIComponent(keyword));
        const html = await response.text();

        let match;
        while ((match = regex.exec(html)) !== null) {
            results.push({
                title: match[3].trim(),
                image: match[2].trim(),
                href: "https://www.animegg.org" + match[1].trim()
            });
        }

        return JSON.stringify(results);
    } catch (err) {
        return JSON.stringify([{
            title: "Error",
            image: "Error",
            href: "Error"
        }]);
    }
}

async function extractDetails(url) {
    try {
        const response = await fetchv2(url);
        const html = await response.text();

        const descMatch = html.match(/<p class="ptext">(.*?)<\/p>/s);
        const description = descMatch ? descMatch[1].trim() : "N/A";

        return JSON.stringify([{
            description: description,
            aliases: "N/A",
            airdate: "N/A"
        }]);
    } catch (err) {
        return JSON.stringify([{
            description: "Error",
            aliases: "Error",
            airdate: "Error"
        }]);
    }
}

async function extractEpisodes(url) {
    const results = [];
    try {
        const response = await fetchv2(url);
        const html = await response.text();

        const regex = /<a[^>]+href="([^"#]+)"[^>]*>\s*<strong>[^<]*?\s+(\d+)<\/strong>/gi;
        let match;
        const seen = new Set();
        while ((match = regex.exec(html)) !== null) {
            const href = match[1].startsWith('http') ? match[1].trim() : "https://www.animegg.org" + match[1].trim();
            const epNum = parseInt(match[2], 10);
            if (!seen.has(href)) {
                seen.add(href);
                results.push({ href: href, number: epNum });
            }
        }

        if (results.length === 0) {
            const fallbackRegex = /<a[^>]+href="([^"#]+-episode-(\d+))"/gi;
            while ((match = fallbackRegex.exec(html)) !== null) {
                const href = match[1].startsWith('http') ? match[1].trim() : "https://www.animegg.org" + match[1].trim();
                const epNum = parseInt(match[2], 10);
                if (!seen.has(href)) {
                    seen.add(href);
                    results.push({ href: href, number: epNum });
                }
            }
        }

        return JSON.stringify(results.reverse());
    } catch (err) {
        return JSON.stringify([{
            href: "Error",
            number: "Error"
        }]);
    }
}

async function extractStreamUrl(url) {
    try {
        const response = await fetchv2(url);
        const html = await response.text();
        const ulMatch = html.match(/<ul id="videos"[^>]*>(.*?)<\/ul>/s);
        // Fork: no `subtitle: "none"`. Sora ignores a top-level `subtitle`, but
        // Shirox reads it as the default track's URL and tries to load "none".
        // Subtitles here are burned into the video.
        if (!ulMatch) return JSON.stringify({streams: []});
        const ulHtml = ulMatch[1];
        const liRegex = /<li><a[^>]*data-id='(\d+)'[^>]*data-version="(subbed|dubbed)"[^>]*>/g;
        const versions = [];
        let liMatch;
        while ((liMatch = liRegex.exec(ulHtml)) !== null) {
            versions.push({id: liMatch[1], type: liMatch[2]});
        }
        // Fork: one embed failing no longer throws away the other version's
        // streams (Shirox's fetchv2 rejects on a network error).
        const embedPromises = versions.map(async (ver) => { try {
            const embedUrl = `https://www.animegg.org/embed/${ver.id}`;
            const embedResponse = await fetchv2(embedUrl);
            const embedHtml = await embedResponse.text();
            const vsMatch = embedHtml.match(/(?:var|const|let) videoSources = (\[[\s\S]*?\]);/);
            if (!vsMatch) return [];
            const jsonString = vsMatch[1].replace(/([{,]\s*)([a-zA-Z_][a-zA-Z0-9_]*)\s*:/g, '$1"$2":');
            const vsJson = JSON.parse(jsonString);
            return vsJson.map(src => {
                const quality = src.label;
                const fileUrl = "https://www.animegg.org" + src.file;
                const title = (ver.type === 'subbed' ? 'Sub' : 'Dub') + ' • ' + quality;
                return {
                    title: title,
                    streamUrl: fileUrl,
                    headers: { "Referer": "https://www.animegg.org/" }
                };
            });
        } catch (e) { console.log('[animegg] embed ' + ver.id + ' failed: ' + e); return []; } });
        const streamArrays = await Promise.all(embedPromises);
        // Fork: best quality first within Sub, then Dub, so the default pick is
        // 1080p subbed rather than 360p.
        const rank = (t) => (t.indexOf('Sub') === 0 ? 0 : 10000) - (parseInt((t.match(/(\d{3,4})p/) || [0, 0])[1], 10) || 0);
        const streams = streamArrays.flat().sort((a, b) => rank(a.title) - rank(b.title));
        return JSON.stringify({streams: streams});
    } catch (err) {
        return JSON.stringify({streams: []});
    }
}
