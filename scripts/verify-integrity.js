import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
const ROOT = process.cwd();
const SSOT = path.join(ROOT, "governance", "ssot.md");
const MANIFEST = path.join(ROOT, "governance", "manifest.json");
function sha256Text(s) {
    return crypto.createHash("sha256").update(s, "utf8").digest("hex");
}
function readMasterHashFromSsot(md) {
    const m = md.match(/MASTER_HASH:\s*([a-f0-9]{64}|__TBD__)/i);
    if (!m)
        return null;
    if (m[1] === "__TBD__")
        return "__TBD__";
    return m[1].toLowerCase();
}
if (!fs.existsSync(SSOT)) {
    console.error("FAIL: missing governance/ssot.md");
    process.exit(2);
}
if (!fs.existsSync(MANIFEST)) {
    console.error("FAIL: missing governance/manifest.json. Run: pnpm integrity:generate");
    process.exit(2);
}
const ssot = fs.readFileSync(SSOT, "utf8");
const master = readMasterHashFromSsot(ssot);
if (!master) {
    console.error("FAIL: could not parse MASTER_HASH from ssot.md");
    process.exit(2);
}
const manifestText = fs.readFileSync(MANIFEST, "utf8");
const current = sha256Text(manifestText);
if (master === "__TBD__") {
    console.log("WARN: MASTER_HASH is __TBD__. Current candidate:", current);
    console.log("Action: owner must set MASTER_HASH in governance/ssot.md");
    process.exit(0);
}
if (current !== master) {
    console.error("FAIL: integrity mismatch");
    console.error("MASTER:", master);
    console.error("CURRENT:", current);
    console.error("Hint: Someone changed code state without updating SSOT approval.");
    process.exit(1);
}
console.log("OK: integrity verified");
