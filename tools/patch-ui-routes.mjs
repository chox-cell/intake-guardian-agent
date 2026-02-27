import fs from "node:fs";
import path from "node:path";

function fail(msg) {
  console.error("FAIL:", msg);
  process.exit(1);
}

const candidates = ["src/ui/routes.ts", "src/ui/routes.js"];
const file = candidates.find((p) => fs.existsSync(p));
if (!file) fail("cannot find src/ui/routes.ts|js");

let s = fs.readFileSync(file, "utf8");

// 1) ensure imports (TS) or requires (JS)
const isTS = file.endsWith(".ts");

if (isTS) {
  if (!s.includes("mountAdminProvisionUI")) {
    // keep ASCII only
    s = s.replace(
      /(^import[^\n]*\n)/m,
      `$1import { mountAdminProvisionUI } from "./admin_provision_route.js";\n`
    );
  }
  if (!s.includes("mountPilotSalesPack")) {
    s = s.replace(
      /(^import[^\n]*\n)/m,
      `$1import { mountPilotSalesPack } from "./pilot_sales_pack_route.js";\n`
    );
  }
} else {
  if (!s.includes("admin_provision_route")) {
    s = s.replace(
      /(^const[^\n]*\n)/m,
      `$1const { mountAdminProvisionUI } = require("./admin_provision_route");\n`
    );
  }
  if (!s.includes("pilot_sales_pack_route")) {
    s = s.replace(
      /(^const[^\n]*\n)/m,
      `$1const { mountPilotSalesPack } = require("./pilot_sales_pack_route");\n`
    );
  }
}

// 2) ensure calls inside mountUi(app)
const m = s.match(/function\s+mountUi\s*\(\s*app[^\)]*\)\s*\{([\s\S]*?)\n\}/m);
if (!m) fail("cannot locate function mountUi(app) { ... } in " + file);

if (!s.includes("mountAdminProvisionUI(")) {
  s = s.replace(
    /function\s+mountUi\s*\(\s*app[^\)]*\)\s*\{([\s\S]*?)\n\}/m,
    (all, body) =>
      all.replace(
        body,
        `${body}\n\n  // Admin (Founder) - Provision workspace + invite link\n  mountAdminProvisionUI(app as any);\n`
      )
  );
}

if (!s.includes("mountPilotSalesPack(")) {
  s = s.replace(
    /function\s+mountUi\s*\(\s*app[^\)]*\)\s*\{([\s\S]*?)\n\}/m,
    (all, body) =>
      all.replace(
        body,
        `${body}\n\n  // Pilot Sales Pack - 60s demo page\n  mountPilotSalesPack(app as any);\n`
      )
  );
}

fs.writeFileSync(file, s, "utf8");
console.log("OK: patched", file);
