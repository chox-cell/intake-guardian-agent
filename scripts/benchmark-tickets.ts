
import { upsertTicket, listTickets } from "../src/lib/ticket-store";
import fs from "fs";
import path from "path";

const TENANT_ID = "benchmark_tenant";
const DATA_DIR = process.env.DATA_DIR || "./data";
const TICKETS_FILE = path.join(DATA_DIR, "tenants", TENANT_ID, "tickets.json");

// Ensure clean state
if (fs.existsSync(TICKETS_FILE)) {
  fs.rmSync(TICKETS_FILE);
}

const TICKET_COUNT = 5000;
console.log(`Generating ${TICKET_COUNT} tickets...`);

const startGen = performance.now();
// Need to await upsertTicket now
await (async () => {
    for (let i = 0; i < TICKET_COUNT; i++) {
        await upsertTicket(TENANT_ID, {
            source: "benchmark",
            type: "lead",
            title: `Benchmark Ticket ${i}`,
            payload: { i, random: Math.random() },
            missingFields: [],
            flags: [],
        });
    }
})();

const endGen = performance.now();
console.log(`Generation took ${(endGen - startGen).toFixed(2)}ms`);

// Benchmark Read
const ITERATIONS = 100;
console.log(`Running ${ITERATIONS} read iterations...`);

const startRead = performance.now();
await (async () => {
    for (let i = 0; i < ITERATIONS; i++) {
        // Need to await listTickets now
        const tickets = await listTickets(TENANT_ID);
        if (tickets.length !== TICKET_COUNT) {
            throw new Error(`Expected ${TICKET_COUNT} tickets, got ${tickets.length}`);
        }
    }
})();

const endRead = performance.now();
const totalTime = endRead - startRead;
const avgTime = totalTime / ITERATIONS;

console.log(`Total read time: ${totalTime.toFixed(2)}ms`);
console.log(`Average read time per iteration: ${avgTime.toFixed(2)}ms`);
