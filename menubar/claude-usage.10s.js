#!/usr/bin/env node
// <xbar.title>Claude Usage</xbar.title>
// <xbar.desc>Reads Claude usage limits from the desktop app's local cache.</xbar.desc>
// <xbar.author>claude-usage</xbar.author>

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HISTORY_PATH = join(
  homedir(),
  "Library/Application Support/Claude/plan-usage-history.json"
);

// The Claude app writes this file every 5 minutes; the 10s interval in the
// filename lets us pick up a new write without much delay.
const STALE_MS = 15 * 60 * 1000;

const LIMITS = [
  { key: "fh", label: "5-Hour Session", windowMs: 5 * 60 * 60 * 1000 },
  { key: "sd", label: "Weekly (7 days)", windowMs: 7 * 24 * 60 * 60 * 1000 },
];

const colorFor = (pct) => (pct >= 80 ? "#ff3b30" : pct >= 50 ? "#ff9f0a" : "#30d158");

const line = (text, params) => (params ? `${text} | ${params}` : text);

function formatDuration(ms) {
  if (ms <= 0) return "soon";
  const totalMin = Math.round(ms / 60000);
  const days = Math.floor(totalMin / 1440);
  const hours = Math.floor((totalMin % 1440) / 60);
  const mins = totalMin % 60;
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${mins}m`;
  return `${mins}m`;
}

// Returns the index of the first sample where the current non-zero
// "streak" (walking backward from fromIndex) began.
function streakStartIndex(samples, fromIndex, key) {
  let i = fromIndex;
  while (i > 0 && samples[i - 1].u[key] !== 0) i--;
  return i;
}

// Given a sample at fromIndex whose value is zero, returns the index where
// that same zero "plateau" began, walking backward. If the user didn't
// open Claude for hours, this plateau can be dozens of samples of flat zero.
function zeroPlateauStartIndex(samples, fromIndex, key) {
  let i = fromIndex;
  while (i > 0 && samples[i - 1].u[key] === 0) i--;
  return i;
}

// Start of the current window. A zero plateau only counts as a "real
// reset" if the value that immediately follows it is genuinely lower than
// the value before the plateau (a real reset climbs back up slowly from
// zero). If a momentary zero is followed by a jump straight back to the
// previous level, that's a one-off reporting glitch from the Claude app —
// otherwise a fake zero like this could make the estimate think the window
// started much earlier than it actually did, throwing the reset time off
// by hours. Once a real reset is found, the window starts not at that
// moment but at the user's first actual use afterward (so, e.g., if Claude
// wasn't used overnight, the estimate is still correct despite the long gap).
function estimateReset(samples, key, windowMs, now) {
  if (samples.at(-1).u[key] === 0) return null;

  let i = samples.length - 1;
  while (true) {
    const streakStart = streakStartIndex(samples, i, key);
    if (streakStart === 0) { i = 0; break; }

    const plateauStart = zeroPlateauStartIndex(samples, streakStart - 1, key);
    const valueBeforeZero = plateauStart > 0 ? samples[plateauStart - 1].u[key] : Infinity;
    const valueAfterZero = samples[streakStart].u[key];

    if (valueAfterZero < valueBeforeZero) {
      i = streakStart; // found a real reset
      break;
    }
    if (plateauStart === 0) { i = 0; break; }
    i = plateauStart - 1; // fake zero plateau - merge with the previous streak and look further back
  }

  const windowStart = samples[i].t;
  const resetAt = windowStart + windowMs;
  return resetAt > now ? resetAt : null;
}

function usageMenu(now) {
  const { samples = [] } = JSON.parse(readFileSync(HISTORY_PATH, "utf8"));
  if (samples.length === 0) throw new Error("No records found");

  const last = samples.at(-1);
  const age = now - last.t;
  const stale = age > STALE_MS;
  const headline = last.u[LIMITS[0].key];

  const out = [
    line(`%${headline}`, `sfimage=bolt.fill color=${stale ? "gray" : colorFor(headline)}`),
    "---",
    "Claude Usage Limits",
    "---",
  ];

  for (const { key, label, windowMs } of LIMITS) {
    const pct = last.u[key];
    const resetAt = estimateReset(samples, key, windowMs, now);
    const reset =
      pct === 0
        ? "no usage yet"
        : resetAt
          ? formatDuration(resetAt - now)
          : "unknown";

    out.push(line(`${label}: %${pct}`, `color=${colorFor(pct)}`));
    out.push(line(`   Resets (estimated): ${reset}`, "size=12 color=gray"));
  }

  const clock = new Date(last.t).toLocaleTimeString("en-US", {
    hour: "2-digit",
    minute: "2-digit",
  });
  out.push("---");
  out.push(line(`Data: ${clock} (${formatDuration(age)} ago)`, "size=11 color=gray"));
  if (stale) {
    out.push(
      line("⚠️ Data is stale — Claude may not be running", "size=11 color=#ff9f0a")
    );
  }

  return out;
}

function errorMenu(err) {
  return [
    line("N/A", "sfimage=cloud.slash color=gray"),
    "---",
    "Couldn't read Claude usage data",
    line(`Error: ${err.message}`, "size=11 color=gray"),
    line(
      "The Claude desktop app must be installed and opened at least once",
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
  line("Open Claude", "bash='/usr/bin/open' param1='-a' param2='Claude' terminal=false")
);

console.log(menu.join("\n"));
