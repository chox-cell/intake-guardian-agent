# EASY MODE — Decision Cover™ (Local)

## 1) Start server (with ADMIN_KEY)
Run:
  ADMIN_KEY="dev_admin_key_123" bash scripts/dev_7090.sh

## 2) Founder creates a workspace (1 click)
Open:
  http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123

Fill:
- workspace name
- agency email
Click: Create Workspace

## 3) Client experience (1 link only)
Send ONLY the "Pilot" link from the generated kit.
Client opens it and can navigate:
- Tickets
- Decisions
- Export CSV
- Evidence ZIP

## Notes
- Client auth uses the link token k (query param) or x-tenant-key header.
- Unauthorized pages never show dev code.
