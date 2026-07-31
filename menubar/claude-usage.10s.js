#!/usr/local/bin/node
// <xbar.title>Claude Kullanım</xbar.title>
// <xbar.desc>Claude kullanım limitlerini masaüstü uygulamasının yerel önbelleğinden okur.</xbar.desc>
// <xbar.author>claude-usage</xbar.author>

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HISTORY_PATH = join(
  homedir(),
  "Library/Application Support/Claude/plan-usage-history.json"
);

// Claude uygulamasi bu dosyayi 5 dakikada bir yazar; dosya adindaki 10sn'lik
// aralik, yeni yazimi gecikmeden yakalamamizi saglar.
const STALE_MS = 15 * 60 * 1000;

const LIMITS = [
  { key: "fh", label: "5 Saatlik Oturum", windowMs: 5 * 60 * 60 * 1000 },
  { key: "sd", label: "Haftalık (7 gün)", windowMs: 7 * 24 * 60 * 60 * 1000 },
];

const colorFor = (pct) => (pct >= 80 ? "#ff3b30" : pct >= 50 ? "#ff9f0a" : "#30d158");

const line = (text, params) => (params ? `${text} | ${params}` : text);

function formatDuration(ms) {
  if (ms <= 0) return "birazdan";
  const totalMin = Math.round(ms / 60000);
  const days = Math.floor(totalMin / 1440);
  const hours = Math.floor((totalMin % 1440) / 60);
  const mins = totalMin % 60;
  if (days > 0) return `${days}g ${hours}s`;
  if (hours > 0) return `${hours}s ${mins}dk`;
  return `${mins}dk`;
}

// Mevcut pencerenin baslangici: son ornekten geriye dogru, degerin 0 olmadigi
// ardisik serinin basi. Pencere deger zaten 0'ken sifirlanabildigi icin
// (0 -> 0 gecisi gorunmez) "dususu ara" yaklasimindan daha guvenilir.
function estimateReset(samples, key, windowMs, now) {
  if (samples.at(-1).u[key] === 0) return null;

  let i = samples.length - 1;
  while (i > 0 && samples[i - 1].u[key] !== 0) i--;
  const windowStart = i > 0 ? (samples[i - 1].t + samples[i].t) / 2 : samples[i].t;

  const resetAt = windowStart + windowMs;
  return resetAt > now ? resetAt : null;
}

function usageMenu(now) {
  const { samples = [] } = JSON.parse(readFileSync(HISTORY_PATH, "utf8"));
  if (samples.length === 0) throw new Error("Kayıt bulunamadı");

  const last = samples.at(-1);
  const age = now - last.t;
  const stale = age > STALE_MS;
  const headline = last.u[LIMITS[0].key];

  const out = [
    line(`%${headline}`, `sfimage=bolt.fill color=${stale ? "gray" : colorFor(headline)}`),
    "---",
    "Claude Kullanım Limitleri",
    "---",
  ];

  for (const { key, label, windowMs } of LIMITS) {
    const pct = last.u[key];
    const resetAt = estimateReset(samples, key, windowMs, now);
    const reset =
      pct === 0
        ? "henüz kullanım yok"
        : resetAt
          ? formatDuration(resetAt - now)
          : "bilinmiyor";

    out.push(line(`${label}: %${pct}`, `color=${colorFor(pct)}`));
    out.push(line(`   Sıfırlanma (tahmini): ${reset}`, "size=12 color=gray"));
  }

  const clock = new Date(last.t).toLocaleTimeString("tr-TR", {
    hour: "2-digit",
    minute: "2-digit",
  });
  out.push("---");
  out.push(line(`Veri: ${clock} (${formatDuration(age)} önce)`, "size=11 color=gray"));
  if (stale) {
    out.push(
      line("⚠️ Veri bayat — Claude uygulaması kapalı olabilir", "size=11 color=#ff9f0a")
    );
  }

  return out;
}

function errorMenu(err) {
  return [
    line("N/A", "sfimage=cloud.slash color=gray"),
    "---",
    "Claude kullanım verisi okunamadı",
    line(`Hata: ${err.message}`, "size=11 color=gray"),
    line(
      "Claude masaüstü uygulamasının kurulu ve en az bir kez açılmış olması gerekir",
      "size=11 color=gray"
    ),
  ];
}

let menu;
try {
  menu = usageMenu(Date.now());
} catch (err) {
  menu = errorMenu(err);
}

menu.push("---");
menu.push(
  line("Claude'u Aç", "bash='/usr/bin/open' param1='-a' param2='Claude' terminal=false")
);

console.log(menu.join("\n"));
