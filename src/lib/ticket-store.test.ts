import { test } from "node:test";
import assert from "node:assert";
import { ticketsToCsv } from "./ticket-store";

test("ticketsToCsv escapes fields starting with =, +, -, @ to prevent formula injection", () => {
  const rows = [
    {
      id: "1",
      status: "open",
      source: "web",
      type: "bug",
      title: "=CMD|' /C calc'!A0",
      createdAtUtc: "2023-01-01",
      evidenceHash: "hash1"
    },
    {
      id: "2",
      status: "closed",
      source: "+1+1",
      type: "-1-1",
      title: "@SUM(1+1)",
      createdAtUtc: "2023-01-02",
      evidenceHash: "hash2"
    }
  ];

  const csv = ticketsToCsv(rows);
  const lines = csv.trim().split("\n");

  // Header
  assert.strictEqual(lines[0], "id,status,source,type,title,createdAtUtc,evidenceHash");

  // Row 1
  const row1 = lines[1].split(",");
  assert.strictEqual(row1[4], "'=CMD|' /C calc'!A0", "Should escape =");

  // Row 2
  const row2 = lines[2].split(",");
  assert.strictEqual(row2[2], "'+1+1", "Should escape +");
  assert.strictEqual(row2[3], "'-1-1", "Should escape -");
  assert.strictEqual(row2[4], "'@SUM(1+1)", "Should escape @");
});
