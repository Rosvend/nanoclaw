---
name: bitwarden-login
description: Log into websites using Bitwarden vault credentials without exposing passwords. Use when the user asks to log into a website, authenticate on a page, or when browser automation needs login credentials.
allowed-tools: Bash(/opt/bw-login.sh:*)
---

# Bitwarden Login

Log into websites securely using credentials from the user's Bitwarden vault. Credentials are fetched through an encrypted tunnel and filled directly into browser forms — you never see, handle, or output any passwords.

## Workflow

1. **Navigate to the login page** and snapshot to identify form fields:

```bash
agent-browser open https://example.com/login
agent-browser snapshot -i
```

2. **Identify the field refs** from the snapshot output (username/email field, password field, submit button).

3. **Call the login wrapper** with the domain and refs:

```bash
/opt/bw-login.sh --domain example.com --user-ref @e1 --pass-ref @e2 --submit-ref @e3
```

4. **Check the result** — the script outputs JSON:
   - `{"success": true}` — login succeeded
   - `{"success": true, "savedState": "auth.json"}` — login succeeded and state saved
   - `{"success": false, "error": "..."}` — login failed with reason

### Save login state for reuse

Add `--save-state <filename>` to persist the browser session:

```bash
/opt/bw-login.sh --domain github.com --user-ref @e1 --pass-ref @e2 --submit-ref @e3 --save-state github-auth.json
```

On subsequent runs, load the saved state instead of re-authenticating:

```bash
agent-browser state load github-auth.json
agent-browser open https://github.com/dashboard
```

## Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--domain` | One of `--domain` or `--id` | Domain to look up by URI in Bitwarden (e.g., "github.com") |
| `--id` | One of `--domain` or `--id` | Vault item ID to look up directly (use when domain lookup fails) |
| `--user-ref` | Yes | agent-browser ref for username/email field |
| `--pass-ref` | Yes | agent-browser ref for password field |
| `--submit-ref` | Yes | agent-browser ref for submit/login button |
| `--save-state` | No | Filename to save browser auth state after login |

## Lookup behavior

- `--domain` matches against the **URI hostname** of vault items, not the item name
- The domain must match the hostname in the vault item's URI (e.g., if the URI is `https://registro.mundogaturro.com`, use `--domain registro.mundogaturro.com`, not `mundogaturro.com`)
- If `--domain` fails with "no credential found", ask the user what domain their Bitwarden entry uses, or ask for the vault item ID to use `--id` instead
- The user can find item IDs with `bw list items --search <name>` on their host machine

## Important rules

- **Never ask the user for passwords** — the wrapper fetches them from Bitwarden
- **Never try to read credentials yourself** — do not call `aac`, read env vars, or inspect the wrapper script output for credential values
- **Always snapshot first** to get accurate field refs before calling the wrapper
- **Use saved state** when available to avoid repeated logins
- If login fails, suggest the user check their Bitwarden vault entry for the domain
- TOTP/2FA is handled automatically if the Bitwarden entry includes a TOTP seed

## Availability

This tool is only available to the **main group**. Non-main groups will receive an error if they attempt to use it.

## Troubleshooting

If a login attempt fails with "wrong password" but the user insists the password is correct, run the diagnostic test first:

```bash
/opt/bw-login.sh --test --domain example.com
```

This fills a local dummy form (no real site) and verifies the credentials arrive intact. The output tells you:
- **PASS** — credentials are fine, the target site is likely detecting browser automation (bot protection)
- **FAIL** — something is corrupting the credentials in the pipeline

If the test passes but login still fails, the site has anti-bot measures. Suggest the user log in manually once, save the browser state with `agent-browser state save`, and use that for future sessions.

## Host setup (required)

The user must run `aac listen --reusable-psk` on the host with their Bitwarden vault unlocked. The reusable PSK token must be set as `AAC_PAIRING_TOKEN` in NanoClaw's environment. Without this, credential lookups will fail with connection errors.
