import { fetchUsage } from "./claudeApi.js";

try {
  const data = await fetchUsage();
  console.log(JSON.stringify(data, null, 2));
} catch (err) {
  console.error("Hata:", err.message);
  process.exit(1);
}
