import fs from "fs";
import path from "path";

import dotenv from "dotenv";
dotenv.config({ path: path.resolve(process.cwd(), ".env.local") });
dotenv.config({ path: path.resolve(process.cwd(), ".env") });

import express from "express";
import pino from "pino";

import { FileStore } from "./store/file.js";
import { TenantsStore } from "./tenants/store.js";

import { makeRoutes } from "./api/routes.js";
import { makeAdapterRoutes } from "./api/adapters.js";
import { makeOutboundRoutes } from "./api/outbound.js";
import { makeUiRoutes } from "./api/ui.js";

const log = pino({ level: process.env.LOG_LEVEL || "info" });

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);
const WA_VERIFY_TOKEN = (process.env.WA_VERIFY_TOKEN || "").trim() || undefined;

fs.mkdirSync(DATA_DIR, { recursive: true });

const store = new FileStore(path.resolve(DATA_DIR));
const tenants = new TenantsStore(path.resolve(DATA_DIR, "tenants.json"));

async function main() {
  await store.init();
  const tenantsAny: any = tenants as any;
  if (typeof tenantsAny.init === "function") await tenantsAny.init();
const app = express();
  app.use(express.json({ limit: "512kb" }));
  app.use(express.urlencoded({ extended: true, limit: "512kb" }));

  // Core API
  app.use("/api", makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS }));

  // Inbound adapters (Email/WhatsApp/Webhook)
  app.use(
    "/api/adapters",
    makeAdapterRoutes({
      store,
      tenants,
      presetId: PRESET_ID,
      dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS,
      waVerifyToken: WA_VERIFY_TOKEN
    })
  );

  // Outbound/Admin routes (already in repo)
  app.use("/api", makeOutboundRoutes({ store, tenants }));

  // UI routes
  app.use("/", makeUiRoutes({ store, tenants }));

  app.listen(PORT, () => {
    log.info(
      {
        PORT,
        DATA_DIR,
        PRESET_ID,
        DEDUPE_WINDOW_SECONDS,
        TENANT_KEYS_CONFIGURED: Boolean((process.env.TENANT_KEYS_JSON || "").trim()),
        ADMIN_KEY_CONFIGURED: Boolean((process.env.ADMIN_KEY || "").trim())
      },
      "Intake-Guardian Agent running"
    );
  });
}

main().catch((err) => {
  log.error({ err }, "fatal");
  process.exit(1);
});
