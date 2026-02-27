import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import PDFDocument from "pdfkit";
const ROOT = process.cwd();
const SSOT = path.join(ROOT, "governance", "ssot.md");
const MANIFEST = path.join(ROOT, "governance", "manifest.json");
function sha256Text(s) {
    return crypto.createHash("sha256").update(s, "utf8").digest("hex");
}
function parseMaster(md) {
    const m = md.match(/MASTER_HASH:\s*([a-f0-9]{64}|__TBD__)/i);
    return m ? m[1] : "UNKNOWN";
}
const moduleName = process.argv[2] || "MODULE";
const outDir = path.join(ROOT, "governance", "reports");
fs.mkdirSync(outDir, { recursive: true });
const ssot = fs.readFileSync(SSOT, "utf8");
const master = parseMaster(ssot);
const manifestText = fs.readFileSync(MANIFEST, "utf8");
const manifestHash = sha256Text(manifestText);
const out = path.join(outDir, `COMPLETION_REPORT__${moduleName}.pdf`);
const doc = new PDFDocument({ size: "A4", margin: 48 });
doc.pipe(fs.createWriteStream(out));
doc.fontSize(20).text("Completion Report", { underline: true });
doc.moveDown();
doc.fontSize(14).text(`Module: ${moduleName}`);
doc.text(`Generated: ${new Date().toISOString()}`);
doc.moveDown();
doc.fontSize(12).text("Integrity Proof", { underline: true });
doc.moveDown(0.5);
doc.font("Courier").fontSize(10);
doc.text(`MASTER_HASH (ssot.md): ${master}`);
doc.text(`MANIFEST_HASH (manifest.json sha256): ${manifestHash}`);
doc.moveDown();
doc.font("Helvetica").fontSize(12).text("Summary", { underline: true });
doc.moveDown(0.5);
doc.fontSize(10).text("- This PDF is a tamper-evident proof of the repository state at completion time.\n" +
    "- For true PKI signing, integrate node-signpdf (optional).");
doc.end();
console.log("OK: wrote", out);
