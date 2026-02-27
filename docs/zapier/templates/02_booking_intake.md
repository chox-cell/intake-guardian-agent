POST http://BASE_URL/api/webhook/intake?tenantId=TENANT_ID&k=TENANT_KEY
Headers: Content-Type: application/json
Body:
{
  "source":"zapier",
  "type":"booking",
  "booking":{"fullName":"John Smith","email":"john@example.com"}
}
