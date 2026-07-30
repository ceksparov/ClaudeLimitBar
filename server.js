import express from "express";
import { fetchUsage } from "./claudeApi.js";

const app = express();
const PORT = process.env.PORT || 3456;

app.use(express.static("public"));

app.get("/api/usage", async (_req, res) => {
  try {
    res.json(await fetchUsage());
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Claude Usage Dashboard: http://localhost:${PORT}`);
});
