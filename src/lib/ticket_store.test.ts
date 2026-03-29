import { test } from "node:test";
import assert from "node:assert";
import { ticketsToCsv, Ticket } from "./ticket_store";

test("ticketsToCsv escapes formula characters", () => {
  const rows: Ticket[] = [
    {
      id: "=1+1",
      subject: "+open",
      sender: "-web",
      status: "open",
      priority: "high",
      due: "@type",
      createdAt: "2023-01-01T00:00:00Z",
      updatedAt: "2023-01-01T00:00:00Z",
      tenantId: "tenant1",
    },
    {
      id: "normal",
      subject: "=SUM(A1:A2)",
      sender: "web",
      status: "open",
      priority: "low",
      due: "2023-01-01",
      createdAt: "2023-01-01T00:00:00Z",
      updatedAt: "2023-01-01T00:00:00Z",
      tenantId: "tenant1",
    }
  ];

  const csv = ticketsToCsv(rows);
  const lines = csv.trim().split("\n");

  assert.strictEqual(lines.length, 3);

  // Header
  assert.strictEqual(lines[0], "id,subject,sender,status,priority,due,createdAt,updatedAt");

  // First row (starts with formula chars)
  assert.strictEqual(lines[1], "'=1+1,'+open,'-web,open,high,'@type,2023-01-01T00:00:00Z,2023-01-01T00:00:00Z");

  // Second row (subject starts with =)
  assert.strictEqual(lines[2], "normal,'=SUM(A1:A2),web,open,low,2023-01-01,2023-01-01T00:00:00Z,2023-01-01T00:00:00Z");
});
