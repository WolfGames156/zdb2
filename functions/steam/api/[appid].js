/**
 * Cloudflare Pages Function
 * Repo'daki yol: functions/steam/api/[appid].js
 *
 * GET https://zdb2.pages.dev/steam/api/{appid}
 *   → https://api.steamcmd.net/v1/info/{appid} proxy'si
 *
 * Cache stratejisi (stale-while-revalidate):
 *   - 5 gun boyunca "fresh" olarak serve edilir
 *   - 5 gun sonrasi istek geldiginde: aninda eski cache doner (kullanici beklemez)
 *     + arka planda steamcmd.net'ten yeni veri cekilip cache guncellenir
 *   - steamcmd.net down olursa: 30 gune kadar eski cache kullanilir (hic silinmez)
 */

const CACHE_FRESH_SECONDS     = 5 * 24 * 3600; // 5 gun (432000s) - fresh serve
const CACHE_STALE_SECONDS     = 5 * 24 * 3600; // +5 gun (432000s) - stale-while-revalidate
const CACHE_STALE_IF_ERROR    = 30 * 24 * 3600; // 30 gun - steamcmd down olursa bile doner

export async function onRequestGet(context) {
  const { params, request } = context;
  const appid = params.appid;

  // AppID sadece rakam olmali
  if (!appid || !/^\d+$/.test(appid)) {
    return new Response(JSON.stringify({ error: "Invalid appid" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const targetUrl = `https://api.steamcmd.net/v1/info/${appid}`;
  const cache = caches.default;
  const cacheKey = new Request(targetUrl);

  // 1. Cache'e bak
  const cached = await cache.match(cacheKey);

  if (cached) {
    const age = parseInt(cached.headers.get("X-Cache-Age") || "0");
    const now = Math.floor(Date.now() / 1000);
    const storedAt = parseInt(cached.headers.get("X-Cached-At") || "0");
    const ageSeconds = now - storedAt;

    if (ageSeconds < CACHE_FRESH_SECONDS) {
      // Fresh cache - direkt don
      return buildResponse(cached, "HIT-FRESH");
    }

    // Stale cache: aninda eski veri don, arka planda guncelle
    context.waitUntil(refreshCache(targetUrl, cacheKey, cache));
    return buildResponse(cached, "HIT-STALE");
  }

  // 2. Cache yok - steamcmd.net'ten cek
  try {
    const data = await fetchFromSteamCmd(targetUrl);
    if (!data) {
      return new Response(JSON.stringify({ error: "Upstream unavailable" }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }

    const response = buildSteamResponse(data);
    context.waitUntil(cache.put(cacheKey, response.clone()));
    return buildResponse(response, "MISS");

  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Proxy error", message: err.message }),
      { status: 502, headers: { "Content-Type": "application/json" } }
    );
  }
}

// steamcmd.net'ten veri cek
async function fetchFromSteamCmd(url) {
  try {
    const res = await fetch(url, {
      headers: {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
      },
      cf: {
        cacheTtl: 0,          // Cloudflare'in kendi cache'ini bypass et, biz yonetiyoruz
        cacheEverything: false,
      },
    });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  }
}

// Yeni veri cekip cache'i guncelle (arka planda)
async function refreshCache(targetUrl, cacheKey, cache) {
  const data = await fetchFromSteamCmd(targetUrl);
  if (data) {
    const response = buildSteamResponse(data);
    await cache.put(cacheKey, response);
  }
  // data null ise (steamcmd down) - eski cache korunur, dokunulmaz
}

// Steam response objesi olustur (cache'e konulacak standart format)
function buildSteamResponse(body) {
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      // Tarayici/istemci icin: 5 gun fresh, +5 gun stale-while-revalidate, 30 gun stale-if-error
      "Cache-Control": `public, max-age=${CACHE_FRESH_SECONDS}, stale-while-revalidate=${CACHE_STALE_SECONDS}, stale-if-error=${CACHE_STALE_IF_ERROR}`,
      "Access-Control-Allow-Origin": "*",
      "X-Cached-At": String(Math.floor(Date.now() / 1000)), // Cache'e konulma zamani (unix)
    },
  });
}

// Response'u clone edip X-Cache header ekle
function buildResponse(response, cacheStatus) {
  const headers = new Headers(response.headers);
  headers.set("X-Cache", cacheStatus);
  return new Response(response.body, {
    status: response.status,
    headers,
  });
}
