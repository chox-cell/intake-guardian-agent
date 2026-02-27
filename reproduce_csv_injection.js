import { ticketsToCsv } from "./src/lib/ticket-store";
const maliciousTicket = {
    id: "1",
    status: "open",
    source: "web",
    type: "bug",
    title: "=cmd|' /C calc'!A0",
    createdAtUtc: "2023-01-01",
    evidenceHash: "123"
};
const csv = ticketsToCsv([maliciousTicket]);
console.log(csv);
if (csv.includes(`"=cmd|' /C calc'!A0"`)) {
    console.log("Vulnerability confirmed: Formula not escaped properly.");
}
else if (csv.includes(`"'=cmd|' /C calc'!A0"`)) {
    console.log("Fix verified: Formula escaped.");
}
else {
    console.log("Output needs manual inspection.");
}
