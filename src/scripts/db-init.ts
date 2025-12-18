async function main() {
  console.log("db-init: no-op (FileStore).");
}
main().catch((e: unknown) => {
  console.error("db-init failed:", e);
  process.exit(1);
});
