import { test } from "node:test";
import assert from "node:assert";
import { ticketsToCsv as ticketsToCsv1 } from "./ticket-store";
import { ticketsToCsv as ticketsToCsv2, Ticket } from "./ticket_store";

test("ticket-store: ticketsToCsv prevents formula injection", () => {
  const rows = [
    {
      id: "t_1",
      status: "open",
      source: "web",
      type: "lead",
      title: "=cmd|' /C calc'!A0",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash1"
    },
    {
      id: "t_2",
      status: "open",
      source: "web",
      type: "lead",
      title: "+1+1",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash2"
    },
    {
      id: "t_3",
      status: "open",
      source: "web",
      type: "lead",
      title: "-1+1",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash3"
    },
    {
      id: "t_4",
      status: "open",
      source: "web",
      type: "lead",
      title: "@SUM(1+1)",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash4"
    },
    {
      id: "t_5",
      status: "open",
      source: "web",
      type: "lead",
      title: "Normal title",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "hash5"
    }
  ];

  const csv = ticketsToCsv1(rows);
  const lines = csv.split("\n");

  // Header is line 0
  assert.ok(lines[1].includes("'=cmd|' /C calc'!A0"), "Should escape '='");
  assert.ok(lines[2].includes("'+1+1"), "Should escape '+'");
  assert.ok(lines[3].includes("'-1+1"), "Should escape '-'");
  assert.ok(lines[4].includes("'@SUM(1+1)"), "Should escape '@'");
  assert.ok(lines[5].includes("Normal title"), "Should not escape normal strings");
  assert.ok(!lines[5].includes("'Normal title"), "Should not escape normal strings");
});

test("ticket_store: ticketsToCsv prevents formula injection", () => {
  const rows: Ticket[] = [
    {
      id: "t_1",
      tenantId: "tenant_1",
      subject: "=cmd|' /C calc'!A0",
      sender: "+123456789",
      body: "body",
      status: "open",
      priority: "medium",
      due: "-1",
      createdAt: "2023-01-01T00:00:00Z",
      updatedAt: "2023-01-01T00:00:00Z"
    },
    {
      id: "t_2",
      tenantId: "tenant_1",
      subject: "Normal subject",
      sender: "sender@example.com",
      body: "body",
      status: "open",
      priority: "medium",
      due: null,
      createdAt: "2023-01-01T00:00:00Z",
      updatedAt: "2023-01-01T00:00:00Z"
    }
  ];

  const csv = ticketsToCsv2(rows);
  const lines = csv.split("\n");

  // Header is line 0
  // t_1: id,subject,sender,status,priority,due,createdAt,updatedAt
  const t1Fields = lines[1].split(",");
  assert.strictEqual(t1Fields[1], "'=cmd|' /C calc'!A0", "Should escape '=' in subject");
  assert.strictEqual(t1Fields[2], "'+123456789", "Should escape '+' in sender");
  assert.strictEqual(t1Fields[5], "'-1", "Should escape '-' in due");

  const t2Fields = lines[2].split(",");
  assert.strictEqual(t2Fields[1], "Normal subject", "Should not escape normal subject");
  assert.strictEqual(t2Fields[2], "sender@example.com", "Should not escape normal sender");
});
