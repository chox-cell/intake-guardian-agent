import { describe, it } from "node:test";
import assert from "node:assert";
import { listTickets, upsertTicket, setTicketStatus } from "./ticket-store";

describe("ticket-store", () => {
  describe("path traversal prevention", () => {
    it("should prevent directory traversal in listTickets", () => {
      assert.throws(
        () => listTickets("../../../etc/passwd"),
        /Invalid tenantId/
      );
    });

    it("should prevent directory traversal in upsertTicket", () => {
      assert.throws(
        () => upsertTicket("../../../etc/passwd", { title: "Test" }),
        /Invalid tenantId/
      );
    });

    it("should prevent directory traversal in setTicketStatus", () => {
      assert.throws(
        () => setTicketStatus("../../../etc/passwd", "t_123", "closed"),
        /Invalid tenantId/
      );
    });

    it("should allow valid tenantIds", () => {
      // Just check it doesn't throw the specific "Invalid tenantId" error
      // It might throw something else if the directory isn't set up or try to read an empty array
      try {
        listTickets("tenant_valid-123_abc");
      } catch (err: any) {
        assert.doesNotMatch(err.message, /Invalid tenantId/);
      }
    });
  });
});
