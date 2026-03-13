import { test } from "node:test";
import assert from "node:assert";
import { ticketsToCsv } from "./ticket-store";

test("ticketsToCsv standard escaping", () => {
  const rows = [
    {
      id: "t_1",
      status: "open",
      source: "web",
      type: "lead",
      title: "Normal Title",
      createdAtUtc: "2025-01-01T00:00:00Z",
      evidenceHash: "abcdef",
    },
    {
      id: "t_2",
      status: "pending",
      source: "api,1", // contains comma
      type: "lead",
      title: "Title with \"quotes\"", // contains quotes
      createdAtUtc: "2025-01-02T00:00:00Z",
      evidenceHash: "123456",
    },
  ];

  const csv = ticketsToCsv(rows);
  const lines = csv.trim().split("\n");

  assert.strictEqual(lines.length, 3);
  assert.strictEqual(lines[0], "id,status,source,type,title,createdAtUtc,evidenceHash");
  assert.strictEqual(lines[1], "t_1,open,web,lead,Normal Title,2025-01-01T00:00:00Z,abcdef");
  assert.strictEqual(lines[2], "t_2,pending,\"api,1\",lead,\"Title with \"\"quotes\"\"\",2025-01-02T00:00:00Z,123456");
});

test("ticketsToCsv formula injection prevention", () => {
  const rows = [
    {
      id: "=1+1",
      status: "+open",
      source: "-web",
      type: "@lead",
      title: "=CMD|' /C calc'!A0",
      createdAtUtc: "2025-01-01T00:00:00Z",
      evidenceHash: "abcdef",
    },
  ];

  const csv = ticketsToCsv(rows);
  const lines = csv.trim().split("\n");

  assert.strictEqual(lines.length, 2);
  assert.strictEqual(lines[0], "id,status,source,type,title,createdAtUtc,evidenceHash");
  assert.strictEqual(lines[1], "'=1+1,'+open,'-web,'@lead,'=CMD|' /C calc'!A0,2025-01-01T00:00:00Z,abcdef");
});
