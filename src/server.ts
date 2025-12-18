import express from "express";
import pino from "pino";
import fs from "fs";
import path from "path";
import { SqliteStore } from "./store/sqlite.js";
import { makeRoutes } from "./api/routes.js";
import { makeAdapterRoutes } from "./api/adapters.js";

const log = pino({ level: process.env.LOG_LEVEL || "info" });

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const DB_PATH = process.env.DB_PATH || path.join(DATA_DIR, "guardian.sqlite");
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);

// WhatsApp Cloud verify token (needed for GET verification)
const WA_VERIFY_TOKEN = process.env.WA_VERIFY_TOKEN || "";

fs.mkdirSync(DATA_DIR, { recursive: true });

const store = new SqliteStore(DB_PATH);

async function main() {
  await store.init();

  const app = express();
  app.use(express.json({ limit: "512kb" }));

  // Core API
  app.use("/api", makeRoutes({
    store,
    presetId: PRESET_ID,
    dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS
  }));

  // Adapter API
  app.use("/api/adapters", makeAdapterRoutes({
    store,
    presetId: PRESET_ID,
    dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS,
    waVerifyToken: WA_VERIFY_TOKEN || undefined
  }));

  app.listen(PORT, () => {
    log.info({ PORT, DB_PATH, PRESET_ID, DEDUPE_WINDOW_SECONDS }, "Intake-Guardian Agent running");
  });
}

main().catch((err) => {
  log.error({ err }, "fatal");
  process.exit(1);
});
