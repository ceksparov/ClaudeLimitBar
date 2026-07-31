#!/usr/local/bin/node
// <xbar.title>Claude Kullanım</xbar.title>
// <xbar.desc>Claude.ai plan kullanım yüzdesini masaüstü uygulamasının yerel önbelleğinden okur.</xbar.desc>
// <xbar.author>claude-usage</xbar.author>

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HISTORY_PATH = join(
  homedir(),
  "Library/Application Support/Claude/plan-usage-history.json"
);
const FIVE_HOURS_MS = 5 * 60 * 60 * 1000;
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const STALE_MS = 15 * 60 * 1000;

function colorFor(pct) {
  if (pct >= 80) return "#ff3b30";
  if (pct >= 50) return "#ff9f0a";
  return "#30d158";
}

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

// Mevcut pencerenin ne zaman basladigini bulmak icin, en son ornekten
// geriye dogru "hala 0 olmayan" ardisik serinin basina kadar gidiyoruz.
// Deger zaten 0'ken sessizce sifirlanan pencereler icin (0 -> 0 gecisi
// tespit edilemez) bu, eski "sadece dususu ara" mantigindan daha guvenilir.
function estimateReset(samples, key, windowMs, now) {
  const n = samples.length;
  const current = samples[n - 1].u[key];
  if (current === 0) return null; // pencere henuz baslamadi

  let i = n - 1;
  while (i > 0 && samples[i - 1].u[key] !== 0) i--;
  const windowStart = i > 0 ? (samples[i - 1].t + samples[i].t) / 2 : samples[i].t;

  const resetAt = windowStart + windowMs;
  return resetAt > now ? resetAt : null;
}

function line(text, params) {
  return params ? `${text} | ${params}` : text;
}

function resetLabel(pct, resetAt, now) {
  if (pct === 0) return "henüz kullanım yok";
  if (resetAt) return formatDuration(resetAt - now);
  return "bilinmiyor";
}

const out = [];

try {
  const data = JSON.parse(readFileSync(HISTORY_PATH, "utf8"));
  const samples = data.samples ?? [];
  if (samples.length === 0) throw new Error("Kayıt bulunamadı");

  const last = samples[samples.length - 1];
  const { fh, sd } = last.u;
  const now = Date.now();
  const age = now - last.t;
  const stale = age > STALE_MS;

  out.push(line(`%${fh}`, `sfimage=bolt.fill color=${stale ? "gray" : colorFor(fh)}`));
  out.push("---");
  out.push("Claude Kullanım Limitleri");
  out.push("---");

  out.push(line(`5 Saatlik Oturum: %${fh}`, `color=${colorFor(fh)}`));
  const resetFh = estimateReset(samples, "fh", FIVE_HOURS_MS, now);
  out.push(
    line(`   Sıfırlanma (tahmini): ${resetLabel(fh, resetFh, now)}`, "size=12 color=gray")
  );

  out.push(line(`Haftalık (7 gün): %${sd}`, `color=${colorFor(sd)}`));
  const resetSd = estimateReset(samples, "sd", SEVEN_DAYS_MS, now);
  out.push(
    line(`   Sıfırlanma (tahmini): ${resetLabel(sd, resetSd, now)}`, "size=12 color=gray")
  );

  out.push("---");
  const updatedAt = new Date(last.t).toLocaleTimeString("tr-TR", {
    hour: "2-digit",
    minute: "2-digit",
  });
  out.push(
    line(`Son güncelleme: ${updatedAt} (${formatDuration(age)} önce)`, "size=11 color=gray")
  );
  if (stale) {
    out.push(
      line(
        "⚠️ Veri bayat — Claude uygulaması kapalı olabilir",
        "size=11 color=#ff9f0a"
      )
    );
  }
} catch (err) {
  out.push(line("N/A", "sfimage=cloud.slash color=gray"));
  out.push("---");
  out.push("Claude kullanım verisi okunamadı");
  out.push(line(`Hata: ${err.message}`, "size=11 color=gray"));
  out.push(
    line(
      "Claude masaüstü uygulamasının kurulu olduğundan ve en az bir kez açıldığından emin olun",
      "size=11 color=gray"
    )
  );
}

out.push("---");
out.push(line("Claude'u Aç", "bash='/usr/bin/open' param1='-a' param2='Claude' terminal=false"));
out.push(line("Yenile", "refresh=true"));

console.log(out.join("\n"));
