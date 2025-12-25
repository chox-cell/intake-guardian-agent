import fs from "fs";
import path from "path";

import dotenv from "dotenv";
dotenv.config({ path: path.resolve(process.cwd(), ".env.local") });
dotenv.config({ path: path.resolve(process.cwd(), ".env") });

import express from "express";
import pino from "pino";

import { makeRoutes } from "./api/routes.js";
import { makeAdapterRoutes } from "./api/adapters.js";
import { makeOutboundRoutes } from "./api/outbound.js";
import { makeUiRoutes } from "./api/ui.js";
import { ShareStore } from "./share/store.js";
import { captureRawBody } from "./api/raw-body.js";
import { FileStore } from "./store/file.js";
import { ResendMailer } from "./lib/resend.js";
import { TenantsStore } from "./tenants/store.js";

const log = pino({ level: process.env.LOG_LEVEL || "info" });

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);
const WA_VERIFY_TOKEN = process.env.WA_VERIFY_TOKEN || "";
const RESEND_API_KEY = process.env.RESEND_API_KEY || "";
const RESEND_FROM = process.env.RESEND_FROM || "";
const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL || "http://127.0.0.1:7090";
const RESEND_DRY_RUN = process.env.RESEND_DRY_RUN === "1";

fs.mkdirSync(DATA_DIR, { recursive: true });
const store = new FileStore(path.resolve(DATA_DIR));

const shares = new ShareStore();
const mailer = (RESEND_API_KEY && RESEND_FROM)
  ? new ResendMailer({ apiKey: RESEND_API_KEY, from: RESEND_FROM, publicBaseUrl: PUBLIC_BASE_URL, dryRun: RESEND_DRY_RUN })
  : undefined;
const tenants = new TenantsStore({ dataDir: DATA_DIR });


async function main() {
  await store.init();

  const app = express();
  app.use(express.json({ limit: "512kb", verify: captureRawBody as any }));
  app.use(express.urlencoded({ extended: true, limit: "512kb", verify: captureRawBody as any }));

  app.use("/api", makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS }));

  
  app.use(
    "/api/adapters",
    makeAdapterRoutes({ store,
      tenants,
      shares,
      presetId: PRESET_ID,
      dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS,
      waVerifyToken: WA_VERIFY_TOKEN || undefined,
      mailer,
      publicBaseUrl: PUBLIC_BASE_URL
     })
  );




  // Simple HTML UI (MVP)
  app.use("/ui", makeUiRoutes({ store, tenants, shares }));
  // V3 sales pack routes
  app.use("/api", makeOutboundRoutes({ store, tenants }));

  app.listen(PORT, () => {
    log.info(
      {
        PORT,
        DATA_DIR,
        PRESET_ID,
        DEDUPE_WINDOW_SECONDS,
        TENANT_KEYS_CONFIGURED: Boolean((process.env.TENANT_KEYS_JSON || "").trim()) || tenants.list().length > 0,
        SLACK_CONFIGURED: Boolean((process.env.SLACK_WEBHOOK_URL || "").trim()),
        ADMIN_KEY_CONFIGURED: Boolean((process.env.ADMIN_KEY || "").trim()),
        SMTP_CONFIGURED: Boolean((process.env.SMTP_HOST || "").trim())
      },
      "Intake-Guardian Agent running (FileStore)"
    );
  });
}

main().catch((err) => {
  log.error({ err }, "fatal");
  process.exit(1);
});
