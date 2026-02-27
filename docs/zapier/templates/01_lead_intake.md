POST http://BASE_URL/api/webhook/intake?tenantId=TENANT_ID&k=TENANT_KEY
Headers: Content-Type: application/json
Body:
{
  "source":"zapier",
  "type":"lead",
  "lead":{"fullName":"Jane Doe","email":"jane@example.com"}
}
