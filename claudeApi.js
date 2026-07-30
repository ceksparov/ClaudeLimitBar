import "dotenv/config";

const BASE_URL = "https://claude.ai";

// Genel, hesaba ozel olmayan sabit degerler
const STATIC_HEADERS = {
  accept: "*/*",
  "accept-language": "en-US,en;q=0.9",
  "content-type": "application/json",
  "anthropic-client-platform": "web_claude_ai",
  "anthropic-client-version": "1.0.0",
  referer: "https://claude.ai/new",
  "sec-fetch-dest": "empty",
  "sec-fetch-mode": "cors",
  "sec-fetch-site": "same-origin",
  "user-agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
};

function buildCookie() {
  const parts = [`sessionKey=${process.env.SESSION_KEY}`];
  if (process.env.CF_CLEARANCE) parts.push(`cf_clearance=${process.env.CF_CLEARANCE}`);
  if (process.env.CF_BM) parts.push(`__cf_bm=${process.env.CF_BM}`);
  return parts.join("; ");
}

export async function fetchUsage() {
  const { ORG_ID, SESSION_KEY } = process.env;
  if (!ORG_ID || !SESSION_KEY) {
    throw new Error("ORG_ID ve SESSION_KEY .env dosyasinda tanimli olmali");
  }

  const res = await fetch(`${BASE_URL}/api/organizations/${ORG_ID}/usage`, {
    headers: { ...STATIC_HEADERS, cookie: buildCookie() },
  });

  const text = await res.text();
  if (!res.ok) {
    throw new Error(
      `API ${res.status} dondurdu. ${
        res.status === 403
          ? "Cloudflare engellemis olabilir - tarayicidan cf_clearance ve __cf_bm cookie'lerini .env'e ekle."
          : res.status === 401
            ? "sessionKey suresi dolmus olabilir - tarayicidan yeni sessionKey al."
            : text.slice(0, 300)
      }`
    );
  }
  return JSON.parse(text);
}
