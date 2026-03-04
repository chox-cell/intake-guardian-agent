import { test } from "node:test";
import assert from "node:assert";
import { ticketsToCsv } from "./ticket-store";

test("ticketsToCsv escapes CSV Formula Injection characters", () => {
  const mockRows = [
    {
      id: "t_123",
      status: "open",
      source: "webhook",
      type: "lead",
      title: "=cmd|' /C calc'!A0",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "abc",
    },
    {
      id: "t_124",
      status: "open",
      source: "webhook",
      type: "lead",
      title: "+1+1",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "def",
    },
    {
      id: "t_125",
      status: "open",
      source: "webhook",
      type: "lead",
      title: "-1-1",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "ghi",
    },
    {
      id: "t_126",
      status: "open",
      source: "webhook",
      type: "lead",
      title: "@SUM(1,1)",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "jkl",
    },
    {
      id: "t_127",
      status: "open",
      source: "webhook",
      type: "lead",
      title: "Normal Title",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "mno",
    },
    {
      id: "t_128",
      status: "open",
      source: "webhook",
      type: "lead",
      title: "Title with, comma",
      createdAtUtc: "2023-01-01T00:00:00Z",
      evidenceHash: "pqr",
    }
  ];

  const csv = ticketsToCsv(mockRows);
  const lines = csv.split("\n");

  assert.match(lines[1], /'=cmd\|' \/C calc'!A0/, "Should escape =");
  assert.match(lines[2], /'\+1\+1/, "Should escape +");
  assert.match(lines[3], /'-1-1/, "Should escape -");
  assert.match(lines[4], /'@SUM\(1,1\)/, "Should escape @");
  assert.match(lines[5], /Normal Title/, "Should not escape normal strings");
  assert.match(lines[6], /"Title with, comma"/, "Should handle commas");
});
