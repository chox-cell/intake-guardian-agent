import { SqliteStore } from "../store/sqlite.js";

const DB_PATH = process.env.DB_PATH || "./data/guardian.sqlite";
const store = new SqliteStore(DB_PATH);

store.init().then(() => {
  console.log("ok: db initialized", DB_PATH);
}).catch((e) => {
  console.error("db init failed", e);
  process.exit(1);
});
