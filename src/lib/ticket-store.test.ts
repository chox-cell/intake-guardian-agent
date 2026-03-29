import { test } from "node:test";
import assert from "node:assert";
import { ticketsToCsv } from "./ticket-store";

test("ticketsToCsv escapes formula characters", () => {
  const rows = [
    {
      id: "=1+1",
      status: "+open",
      source: "-web",
      type: "@type",
      title: "Normal Title",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash"
    },
    {
      id: "normal",
      status: "open",
      source: "web",
      type: "type",
      title: "=SUM(A1:A2)",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash"
    }
  ];

  const csv = ticketsToCsv(rows);
  const lines = csv.trim().split("\n");

  assert.strictEqual(lines.length, 3);

  // Header
  assert.strictEqual(lines[0], "id,status,source,type,title,createdAtUtc,evidenceHash");

  // First row (starts with formula chars)
  assert.strictEqual(lines[1], "'=1+1,'+open,'-web,'@type,Normal Title,2023-01-01T00:00:00Z,hash");

  // Second row (title starts with =)
  assert.strictEqual(lines[2], "normal,open,web,type,'=SUM(A1:A2),2023-01-01T00:00:00Z,hash");
});
