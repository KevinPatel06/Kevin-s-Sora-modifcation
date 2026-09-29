---
name: module-builder
description: Exhaustive cheat sheet for Sora manifest creation, exact JSON return schemas, and CLI sandbox testing.
---

## 1. Required Manifest (`module.json`)
Every module requires a manifest JSON file. Base your configuration on this template:

```json
{
    "sourceName": "YourSourceName",
    "iconUrl": "https://your-source.com/icon.png",
    "author": {
        "name": "AuthorName",
        "icon": "https://your-source.com/author-icon.png",
        "url": "https://your-source.com/author-profile" // Optional: URL to the author's profile
    },
    "version": "1.0.0",
    "language": "English (DUB)",
    "streamType": "HLS",
    "quality": "720p",
    "baseUrl": "https://api.your-source.com/",
    "searchBaseUrl": "https://your-source.com/search=%s",
    "scriptUrl": "https://your-source.com/script.js",
    "type": "anime",
    "downloadSupport": false, // Required for the module library
    "asyncJS": true,
    "streamAsyncJS": false,
    "softsub": true
}

```

## 2. Exact Output Schemas

Your JavaScript functions must return `JSON.stringify(data)` matching these exact structures:

* **`searchResults(keyword)`**:


```json
[
    {
        "title": "Example Title",
        "image": "https://your-source.com/image.jpg",
        "href": "https://your-source.com/title/123/"
    }
]

```


* **`extractDetails(url)`**:


```json
{
    "description": "Show description.",
    "aliases": "Alternate Name", // Genres if no alternate title
    "airdate": "2022"
}

```


* **`extractEpisodes(url)`**:


```json
[
    {
        "href": "https://your-source.com/episode/123",
        "number": 1
    }
]

```


(Note: `number` MUST be an integer)


* **`extractStreamUrl(url)` (Multi-Server Selector Recommended)**:


```json
{
  "streams": [
    {
      "title": "Server 1",
      "streamUrl": "https://your-source.com/stream1.m3u8",
      "headers": {"Referer": "..."}
    }
  ],
  "subtitle": "https://your-source.com/subtitles.vtt" 
}
```

VERY IMPORTANT: Avoid Node functions (or stuff that is not part of the plain JS language), no DOM parser - use regex instead.


### Module JS Template

```js

/** Sora Module Template
 * This template is designed to help you create a module for Sora.
 * It includes functions for searching, extracting details, episodes, and stream URLs.
 * You can modify these functions to suit your needs.
 * 
 * For more information, visit the Sora documentation at https://sora.jm26.net/docs
 */


/** searchResults
 * Searches for anime/shows/movies based on a keyword.
 * @param {string} keyword - The search keyword.
 * @returns {Promise<string>} - A JSON string of search results.
 */
async function searchResults(keyword) {
    try {
        const encodedKeyword = encodeURIComponent(keyword);
        const responseText = await soraFetch(`https://api.animemundo.net/api/v2/hianime/search?q=${encodedKeyword}&language=dub`);
        const data = JSON.parse(responseText);

        const filteredAnimes = data.data.animes.filter(anime => anime.episodes.dub !== null); 
        
        const transformedResults = data.data.animes.map(anime => ({
            title: anime.name,
            image: anime.poster,
            href: `https://hianime.to/watch/${anime.id}`
        }));
        
        return JSON.stringify(transformedResults);
        
    } catch (error) {
        console.log('Fetch error:', error);
        return JSON.stringify([{ title: 'Error', image: '', href: '' }]);
    }
}

/** extractDetails
 * Extracts details of an anime from its page URL.
 * @param {string} url - The URL of the anime page.
 * @returns {Promise<string>} - A JSON string of the anime details.
 */
async function extractDetails(url) {
    try {
        const match = url.match(/https:\/\/hianime\.to\/watch\/(.+)$/);
        const encodedID = match[1];
        const response = await soraFetch(`https://api.animemundo.net/api/v2/hianime/anime/${encodedID}`);
        const data = JSON.parse(response);
        
        const animeInfo = data.data.anime.info;
        const moreInfo = data.data.anime.moreInfo;

        const transformedResults = [{
            description: animeInfo.description || 'No description available',
            aliases: `Duration: ${animeInfo.stats?.duration || 'Unknown'}`,
            airdate: `Aired: ${moreInfo?.aired || 'Unknown'}`
        }];
        
        return JSON.stringify(transformedResults);
    } catch (error) {
        console.log('Details error:', error);
        return JSON.stringify([{
        description: 'Error loading description',
        aliases: 'Duration: Unknown',
        airdate: 'Aired: Unknown'
        }]);
  }
}

/** extractEpisodes
 * Extracts episodes of an anime from its page URL.
 * @param {string} url - The URL of the anime page.
 * @returns {Promise<string>} - A JSON string of the anime episodes.
 */
async function extractEpisodes(url) {
    try {
        const match = url.match(/https:\/\/hianime\.to\/watch\/(.+)$/);
        const encodedID = match[1];
        const response = await soraFetch(`https://api.animemundo.net/api/v2/hianime/anime/${encodedID}/episodes`);
        const data = JSON.parse(response);

        const transformedResults = data.data.episodes.map(episode => ({
            href: `https://hianime.to/watch/${encodedID}?ep=${episode.episodeId.split('?ep=')[1]}`,
            number: episode.number
        }));
        
        return JSON.stringify(transformedResults);
        
    } catch (error) {
        console.log('Fetch error:', error);
    }    
}

/** extractStreamUrl
 * Extracts the stream URL of an anime episode from its page URL.
 * @param {string} url - The URL of the anime episode page.
 * @returns {Promise<string|null>} - The stream URL or null if not found.
 */
async function extractStreamUrl(url) {
    try {
       const match = url.match(/https:\/\/hianime\.to\/watch\/(.+)$/);
       const encodedID = match[1];
       const response = await soraFetch(`https://api.animemundo.net/api/v2/hianime/episode/sources?animeEpisodeId=${encodedID}&category=dub`);
       const data = JSON.parse(response);
       
       const hlsSource = data.data.sources.find(source => source.type === 'hls');
       
       return hlsSource ? hlsSource.url : null;
    } catch (error) {
       console.log('Fetch error:', error);
       return null;
    }
}


/** Fetch function that tries to use a custom fetch implementation first,
 * and falls back to the native fetch if it fails.
 * @param {string} url - The URL to fetch.
 * @param {Object} options - The options for the fetch request.
 * @returns {Promise<Response|null>} - The response object or null if an error occurs.
 * @note This function is designed to provide Node.js compatibility
 */
async function soraFetch(url, options = { headers: {}, method: 'GET', body: null }) {
    try {
        return await fetchv2(url, options.headers ?? {}, options.method ?? 'GET', options.body ?? null);
    } catch(e) {
        try {
            return await fetch(url, options);
        } catch(error) {
            await console.log('soraFetch error: ' + error.message);
            return null;
        }
    }
}

```


More examples at https://library.cufiy.net/api/modules.min.json

## 3. CLI Validation Sandbox (`run_module.js`)

Use these exact commands to verify the module works in the Node VM:

* **Test Search:** `node run_module.js --path 'module.js' --function searchResults --param '"naruto"'`

* **Test Details:** `node run_module.js --path 'module.js' --function extractDetails --param '"https://target-url.com/show"'`

* **Test Episodes:** `node run_module.js --path 'module.js' --function extractEpisodes --param '"https://target-url.com/show"'`

* **Test Streams (with debug):** `node run_module.js --path 'module.js' --function extractStreamUrl --param '"https://target-url.com/episode/1"' --debug`

You can fetch this script from here: https://files.catbox.moe/xs54tu.js
