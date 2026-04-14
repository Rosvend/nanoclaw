#!/bin/bash
# bw-login.sh — Opaque credential-filling wrapper for Bitwarden Agent-Access
#
# Fetches credentials from Bitwarden vault via encrypted tunnel and fills
# browser login forms using agent-browser. Credentials NEVER appear in stdout.
#
# Usage:
#   /opt/bw-login.sh --domain github.com --user-ref @e1 --pass-ref @e2 --submit-ref @e3 [--save-state auth.json]
#   /opt/bw-login.sh --id 12345-abcde --user-ref @e1 --pass-ref @e2 --submit-ref @e3
#   /opt/bw-login.sh --test --domain duolingo.com   # diagnostic: fill dummy form, verify values match
#
# Lookup priority: --domain (by URI), --id (by vault item ID). At least one required.
#
# Requires:
#   - AAC_PAIRING_TOKEN environment variable (set by host for main group only)
#   - /opt/bw-aac binary (Bitwarden agent-access CLI)
#   - agent-browser running with a page already open

set -euo pipefail

# --- Argument parsing ---
DOMAIN=""
ITEM_ID=""
USER_REF=""
PASS_REF=""
SUBMIT_REF=""
SAVE_STATE=""
TEST_MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="$2";     shift 2 ;;
    --id)         ITEM_ID="$2";    shift 2 ;;
    --user-ref)   USER_REF="$2";   shift 2 ;;
    --pass-ref)   PASS_REF="$2";   shift 2 ;;
    --submit-ref) SUBMIT_REF="$2"; shift 2 ;;
    --save-state) SAVE_STATE="$2"; shift 2 ;;
    --test)       TEST_MODE="1";   shift ;;
    *) echo '{"success": false, "error": "Unknown argument: '"$1"'"}'; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$DOMAIN" && -z "$ITEM_ID" ]]; then
  echo '{"success": false, "error": "Required: --domain or --id (to look up credentials in Bitwarden)"}'
  exit 1
fi

if [[ -z "$TEST_MODE" && ( -z "$USER_REF" || -z "$PASS_REF" || -z "$SUBMIT_REF" ) ]]; then
  echo '{"success": false, "error": "Required: --user-ref, --pass-ref, --submit-ref (or use --test for diagnostics)"}'
  exit 1
fi

if [[ -z "${AAC_PAIRING_TOKEN:-}" ]]; then
  echo '{"success": false, "error": "AAC_PAIRING_TOKEN not set — Bitwarden access not available"}'
  exit 1
fi

if [[ ! -x /opt/bw-aac ]]; then
  echo '{"success": false, "error": "aac binary not found at /opt/bw-aac"}'
  exit 1
fi

# --- Fetch credentials via encrypted tunnel ---
AAC_STDERR=$(mktemp)

if [[ -n "$DOMAIN" ]]; then
  # Try the domain as-is first, then with/without www. prefix (aac does exact hostname matching)
  DOMAINS_TO_TRY=("$DOMAIN")
  if [[ "$DOMAIN" == www.* ]]; then
    DOMAINS_TO_TRY+=("${DOMAIN#www.}")       # strip www.
  else
    DOMAINS_TO_TRY+=("www.$DOMAIN")           # add www.
  fi

  CRED_JSON=""
  for TRY_DOMAIN in "${DOMAINS_TO_TRY[@]}"; do
    CRED_JSON=$(/opt/bw-aac connect --token "$AAC_PAIRING_TOKEN" --domain "$TRY_DOMAIN" --output json 2>"$AAC_STDERR") && break
    CRED_JSON=""
  done

  if [[ -z "$CRED_JSON" ]]; then
    AAC_ERR=$(cat "$AAC_STDERR" | tr '\n' ' ' | sed 's/"/\\"/g')
    rm -f "$AAC_STDERR"
    echo '{"success": false, "error": "Bitwarden lookup failed for domain '"$DOMAIN"' (also tried www variant): '"$AAC_ERR"'"}'
    exit 1
  fi
else
  # Lookup by vault item ID
  CRED_JSON=$(/opt/bw-aac connect --token "$AAC_PAIRING_TOKEN" --id "$ITEM_ID" --output json 2>"$AAC_STDERR") || {
    AAC_ERR=$(cat "$AAC_STDERR" | tr '\n' ' ' | sed 's/"/\\"/g')
    rm -f "$AAC_STDERR"
    echo '{"success": false, "error": "Bitwarden lookup failed for id '"$ITEM_ID"': '"$AAC_ERR"'"}'
    exit 1
  }
fi
rm -f "$AAC_STDERR"

# --- Diagnostic test mode ---
if [[ -n "$TEST_MODE" ]]; then
  DIAG_RESULT=$(node -e '
const { execFileSync } = require("child_process");
const json = process.argv[1];

let r;
try { r = JSON.parse(json); } catch(e) {
  process.stdout.write(JSON.stringify({success:false, error:"Failed to parse aac JSON: " + e.message, rawLength: json.length}));
  process.exit(0);
}
const c = r.credential || r;
const username = c.username || "";
const password = c.password || "";

if (!username || !password) {
  process.stdout.write(JSON.stringify({success:false, error:"No username or password in response", keys: Object.keys(c)}));
  process.exit(0);
}

// Open a dummy HTML form (local, no network)
const html = "<html><body><form>" +
  "<input id=\"u\" type=\"text\" />" +
  "<input id=\"p\" type=\"text\" />" +
  "<button id=\"s\">Go</button>" +
  "</form></body></html>";
const dataUrl = "data:text/html," + encodeURIComponent(html);

try {
  execFileSync("agent-browser", ["open", dataUrl], {stdio:"ignore", timeout:10000});
  execFileSync("agent-browser", ["wait", "1000"], {stdio:"ignore", timeout:5000});

  // Get snapshot to find refs — snapshot format is [ref=e1], commands use @e1
  const snapshot = execFileSync("agent-browser", ["snapshot", "-i"], {encoding:"utf8", timeout:10000});
  const lines = snapshot.split("\n");
  const inputRefs = lines.filter(l => /ref=e\d+/.test(l) && /textbox|input/i.test(l));

  if (inputRefs.length < 2) {
    process.stdout.write(JSON.stringify({success:false, error:"Could not find 2 input fields in test form", snapshot: snapshot.substring(0, 500)}));
    process.exit(0);
  }

  const uRef = "@" + inputRefs[0].match(/ref=(e\d+)/)[1];
  const pRef = "@" + inputRefs[1].match(/ref=(e\d+)/)[1];

  // Fill using the same code path as real login
  execFileSync("agent-browser", ["fill", uRef, username], {stdio:"ignore"});
  execFileSync("agent-browser", ["fill", pRef, password], {stdio:"ignore"});

  // Read values back
  const filledUser = execFileSync("agent-browser", ["get", "value", uRef], {encoding:"utf8", timeout:5000}).trim();
  const filledPass = execFileSync("agent-browser", ["get", "value", pRef], {encoding:"utf8", timeout:5000}).trim();

  // Compare (mask actual values for security)
  const mask = (s) => s.length <= 2 ? "*".repeat(s.length) : s[0] + "*".repeat(s.length - 2) + s[s.length - 1];

  const result = {
    success: true,
    diagnostic: true,
    username: {
      expected_length: username.length,
      filled_length: filledUser.length,
      match: username === filledUser,
      expected_masked: mask(username),
      filled_masked: mask(filledUser),
    },
    password: {
      expected_length: password.length,
      filled_length: filledPass.length,
      match: password === filledPass,
      expected_masked: mask(password),
      filled_masked: mask(filledPass),
    },
    verdict: (username === filledUser && password === filledPass)
      ? "PASS — credentials arrive intact. If login still fails, the target site is likely detecting browser automation."
      : "FAIL — credentials are being corrupted in the fill pipeline."
  };

  execFileSync("agent-browser", ["close"], {stdio:"ignore"});
  process.stdout.write(JSON.stringify(result, null, 2));
} catch(e) {
  process.stdout.write(JSON.stringify({success:false, error:"Diagnostic test failed: " + e.message}));
}
' "$CRED_JSON" 2>/dev/null) || {
    echo '{"success": false, "error": "Diagnostic script crashed"}'
    exit 1
  }
  echo "$DIAG_RESULT"
  exit 0
fi

# --- Parse credentials and fill form via node (bypasses shell to avoid mangling special chars) ---
# node uses execFileSync which passes values directly as argv — no shell interpretation.
FILL_RESULT=$(node -e '
const { execFileSync } = require("child_process");
const json = process.argv[1];
const userRef = process.argv[2];
const passRef = process.argv[3];
const submitRef = process.argv[4];

let r;
try { r = JSON.parse(json); } catch(e) {
  process.stdout.write(JSON.stringify({success:false, error:"Failed to parse aac JSON response"}));
  process.exit(0);
}
const c = r.credential || r;
const username = c.username || "";
const password = c.password || "";
const totp = c.totp || "";

if (!username || !password) {
  process.stdout.write(JSON.stringify({success:false, error:"No username or password in Bitwarden response"}));
  process.exit(0);
}

try {
  // Fill username — execFileSync bypasses shell, so special chars are safe
  execFileSync("agent-browser", ["fill", userRef, username], {stdio:"ignore"});
} catch(e) {
  process.stdout.write(JSON.stringify({success:false, error:"Failed to fill username field"}));
  process.exit(0);
}

try {
  // Fill password — passed directly as argv, never touches a shell
  execFileSync("agent-browser", ["fill", passRef, password], {stdio:"ignore"});
} catch(e) {
  process.stdout.write(JSON.stringify({success:false, error:"Failed to fill password field"}));
  process.exit(0);
}

try {
  execFileSync("agent-browser", ["click", submitRef], {stdio:"ignore"});
} catch(e) {
  process.stdout.write(JSON.stringify({success:false, error:"Failed to click submit button"}));
  process.exit(0);
}

try {
  execFileSync("agent-browser", ["wait", "--load", "networkidle"], {stdio:"ignore", timeout:15000});
} catch(e) { /* timeout ok */ }

// Handle TOTP if present
if (totp) {
  try {
    execFileSync("agent-browser", ["wait", "1000"], {stdio:"ignore", timeout:3000});
    const snapshot = execFileSync("agent-browser", ["snapshot", "-i"], {encoding:"utf8", timeout:10000});
    const lines = snapshot.split("\n");
    const match = lines.find(l => /textbox|input/i.test(l) && /code|otp|verif|2fa|token|digit/i.test(l));
    if (match) {
      const refMatch = match.match(/ref=(e\d+)/);
      if (refMatch) {
        execFileSync("agent-browser", ["fill", "@" + refMatch[1], totp], {stdio:"ignore"});
        execFileSync("agent-browser", ["press", "Enter"], {stdio:"ignore"});
        execFileSync("agent-browser", ["wait", "--load", "networkidle"], {stdio:"ignore", timeout:15000});
      }
    }
  } catch(e) { /* totp handling best-effort */ }
}

process.stdout.write(JSON.stringify({success:true, filled:true}));
' "$CRED_JSON" "$USER_REF" "$PASS_REF" "$SUBMIT_REF" 2>/dev/null) || {
  echo '{"success": false, "error": "Credential fill script failed"}'
  exit 1
}

# Check if fill succeeded
FILL_SUCCESS=$(node -e "process.stdout.write(String(JSON.parse(process.argv[1]).success))" "$FILL_RESULT" 2>/dev/null) || true
if [[ "$FILL_SUCCESS" != "true" ]]; then
  echo "$FILL_RESULT"
  exit 1
fi

# Zero credentials
CRED_JSON=""

# --- Optionally save browser state ---
RESULT_EXTRA=""
if [[ -n "$SAVE_STATE" ]]; then
  if agent-browser state save "$SAVE_STATE" >/dev/null 2>&1; then
    RESULT_EXTRA=', "savedState": "'"$SAVE_STATE"'"'
  fi
fi

echo '{"success": true'"$RESULT_EXTRA"'}'
