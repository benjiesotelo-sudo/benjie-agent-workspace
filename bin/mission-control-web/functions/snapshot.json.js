// snapshot.json.js - the Cloudflare Pages Function behind the public page's /snapshot.json.
// bin/fm-mission-control-web.sh deploys it with the page when public_page.host is
// "cloudflare" and writes each changed snapshot to the Workers KV namespace bound
// here as SNAPSHOT, so the page's code is redeployed only when it changes. It only
// reads that one key; bin/fm_mission_control_web.py owns what the snapshot may contain.
const KEY = "snapshot.json";
const CACHE_SECONDS = 60;

export async function onRequestGet({ env }) {
  const body = env.SNAPSHOT ? await env.SNAPSHOT.get(KEY, { cacheTtl: CACHE_SECONDS }) : null;
  if (body === null) {
    return new Response('{"error":"no snapshot yet"}\n', {
      status: 503,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
    });
  }
  return new Response(body, {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=" + CACHE_SECONDS,
      "x-content-type-options": "nosniff",
    },
  });
}
