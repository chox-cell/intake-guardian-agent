import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
const ROOT = process.cwd();
const OUT = path.join(ROOT, "governance", "manifest.json");
// Adjust what you consider "code state"
const INCLUDE_DIRS = ["src", "scripts", "governance"];
const EXCLUDE_PATTERNS = [
    /^data\//,
    /^node_modules\//,
    /^\.git\//,
    /^dist\//,
    /^build\//,
    /^\.bak\//,
    /^governance\/manifest\.json$/,
];
function shouldExclude(rel) {
    return EXCLUDE_PATTERNS.some((re) => re.test(rel.replace(/\\/g, "/")));
}
function walk(dirAbs) {
    const out = [];
    for (const name of fs.readdirSync(dirAbs)) {
        const abs = path.join(dirAbs, name);
        const st = fs.statSync(abs);
        const rel = path.relative(ROOT, abs).replace(/\\/g, "/");
        if (shouldExclude(rel))
            continue;
        if (st.isDirectory())
            out.push(...walk(abs));
        else if (st.isFile())
            out.push(abs);
    }
    return out;
}
function sha256File(abs) {
    const buf = fs.readFileSync(abs);
    return crypto.createHash("sha256").update(buf).digest("hex");
}
function sha256Text(s) {
    return crypto.createHash("sha256").update(s, "utf8").digest("hex");
}
const filesAbs = INCLUDE_DIRS
    .map((d) => path.join(ROOT, d))
    .filter((p) => fs.existsSync(p))
    .flatMap((p) => walk(p));
const entries = filesAbs
    .map((abs) => {
    const rel = path.relative(ROOT, abs).replace(/\\/g, "/");
    const buf = fs.readFileSync(abs);
    return { file: rel, sha256: crypto.createHash("sha256").update(buf).digest("hex"), bytes: buf.length };
})
    .sort((a, b) => a.file.localeCompare(b.file));
const manifest = {
    version: 1,
    generatedAtUtc: new Date().toISOString(),
    entryCount: entries.length,
    entries,
};
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(manifest, null, 2), "utf8");
// Compute MASTER candidate = sha256(manifest.json)
const masterCandidate = sha256Text(fs.readFileSync(OUT, "utf8"));
console.log("OK: wrote governance/manifest.json");
console.log("MASTER_CANDIDATE_SHA256:", masterCandidate);
