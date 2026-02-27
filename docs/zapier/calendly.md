## Calendly → Intake Guardian

Trigger:
- App: Calendly
- Event: Invitee Created

Action:
- Webhooks by Zapier (POST)

Body:
{
  "source": "calendly",
  "type": "booking",
  "lead": {
    "fullName": "{{invitee_name}}",
    "email": "{{invitee_email}}",
    "event": "{{event_type_name}}",
    "time": "{{event_start_time}}"
  }
}
