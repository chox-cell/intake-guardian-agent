import { ticketsToCsv } from "./src/lib/ticket-store";
const cases = [
    {
        name: "Formula Injection",
        input: {
            id: "1",
            status: "open",
            source: "web",
            type: "bug",
            title: "=cmd|' /C calc'!A0",
            createdAtUtc: "2023-01-01",
            evidenceHash: "123"
        },
        expectedTitle: "'=cmd|' /C calc'!A0"
    },
    {
        name: "Normal Text",
        input: {
            id: "2",
            status: "open",
            source: "web",
            type: "bug",
            title: "Just a title",
            createdAtUtc: "2023-01-01",
            evidenceHash: "123"
        },
        expectedTitle: "Just a title"
    },
    {
        name: "Text with comma",
        input: {
            id: "3",
            status: "open",
            source: "web",
            type: "bug",
            title: "Title, with comma",
            createdAtUtc: "2023-01-01",
            evidenceHash: "123"
        },
        expectedTitle: "\"Title, with comma\""
    },
    {
        name: "Text with quote",
        input: {
            id: "4",
            status: "open",
            source: "web",
            type: "bug",
            title: "Title \"with quote\"",
            createdAtUtc: "2023-01-01",
            evidenceHash: "123"
        },
        expectedTitle: "\"Title \"\"with quote\"\"\""
    },
    {
        name: "Formula with comma",
        input: {
            id: "5",
            status: "open",
            source: "web",
            type: "bug",
            title: "=1+1,2",
            createdAtUtc: "2023-01-01",
            evidenceHash: "123"
        },
        expectedTitle: "\"'=1+1,2\""
    }
];
let failed = false;
cases.forEach(c => {
    const csv = ticketsToCsv([c.input]);
    const lines = csv.trim().split("\n");
    const dataLine = lines[1];
    const columns = dataLine.split(","); // Simplified CSV parsing for this test, might break on commas inside quotes if not careful, but okay for checking specific fields if we control the input
    // Better verification: check if the expected title substring exists in the line
    if (!csv.includes(c.expectedTitle)) {
        console.error(`[FAIL] ${c.name}: Expected to find '${c.expectedTitle}' in output.`);
        console.log(`Output: ${csv}`);
        failed = true;
    }
    else {
        console.log(`[PASS] ${c.name}`);
    }
});
if (failed)
    process.exit(1);
