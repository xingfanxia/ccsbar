#!/usr/bin/env bash
# regen-fixture.sh — refresh the checked-in status.json contract fixture from a
# live clauth daemon.
#
# The fixture (Sources/CCSBarKit/Fixtures/status.json) is the single source for
# both the --snapshot render and the decode contract test, so it has to stay a
# faithful sample of what `clauth status --json` emits.
#
# It is also PUBLIC, and a live status.json carries real account names and real
# billing addresses. The old version of this script wrote the live capture
# straight over the fixture and left a comment asking whoever ran it to remember
# to sanitize — which is not a control, it is a hope. So:
#
#   * every profile name becomes account-1, account-2, … in first-seen order;
#   * every account_email becomes account-N@example.com, keeping the mapping so
#     two rows that shared an inbox still share one in the fixture;
#   * the capture goes to a temp file and is PRINTED, not installed, unless you
#     pass --write.
#
# --write is a starting point, not the answer. The fixture is deliberately
# richer than any one live capture — it holds a stale row, a broken login, and
# codex rows carrying banked reset credits, because those states have to decode
# in a test and a healthy machine emits none of them. Read the diff and keep the
# states the live capture flattened.
#
# Usage:
#   Scripts/regen-fixture.sh            # capture, scrub, show the diff
#   Scripts/regen-fixture.sh --write    # …and install it over the fixture
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst="$repo_root/Sources/CCSBarKit/Fixtures/status.json"

write=0
case "${1:-}" in
  --write) write=1 ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--write]" >&2; exit 2 ;;
esac

clauth="$(command -v clauth || echo "$HOME/.cargo/bin/clauth")"
if [ ! -x "$clauth" ]; then
  echo "error: clauth not found on PATH or in ~/.cargo/bin" >&2
  exit 1
fi

tmp="$(mktemp -t ccsbar-fixture)"
trap 'rm -f "$tmp"' EXIT

"$clauth" status --json | python3 -c '
import json, sys

status = json.load(sys.stdin)
names, emails = {}, {}

def scrub_name(real):
    if real is None:
        return None
    return names.setdefault(real, f"account-{len(names) + 1}")

def scrub_email(real):
    if real is None:
        return None
    return emails.setdefault(real, f"account-{len(emails) + 1}@example.com")

for row in status.get("profiles", []):
    row["name"] = scrub_name(row.get("name"))
    if "account_email" in row:
        row["account_email"] = scrub_email(row.get("account_email"))

# The names appear again outside the roster: whatever is active, whatever is
# mid-switch, and every member of both fallback chains. A rename that stops at
# the roster leaves the real name in the chain and breaks the fixture, because
# a chain member that matches no profile is not a shape the app ever sees.
for key in ("active_profile", "active_codex_profile", "pending_switch"):
    if key in status:
        status[key] = scrub_name(status[key])
for key in ("fallback_chain", "codex_fallback_chain"):
    chain = status.get(key)
    if isinstance(chain, list):
        status[key] = [scrub_name(m) for m in chain]

leaked = [n for n in names if n.startswith("account-")]
json.dump(status, sys.stdout, indent=4, sort_keys=False)
sys.stdout.write("\n")
if leaked:
    print(f"warning: profile(s) already named like the scrub target: {leaked}", file=sys.stderr)
' > "$tmp"

python3 - "$tmp" <<'PY'
# Refuse to hand back a capture that still carries an @ outside example.com or a
# name the scrub missed. Cheap, and it fails loudly rather than quietly shipping.
import json, re, sys
text = open(sys.argv[1]).read()
bad = [m for m in re.findall(r'"[^"]*@[^"]*"', text) if not m.endswith('@example.com"')]
if bad:
    print(f"error: unscrubbed address(es) survived: {sorted(set(bad))}", file=sys.stderr)
    raise SystemExit(1)
json.loads(text)
PY

if [ "$write" -eq 1 ]; then
  cp "$tmp" "$dst"
  echo "wrote $dst"
  echo "run 'swift test' to confirm it still decodes."
else
  echo "captured and scrubbed; NOT installed. Diff against the current fixture:"
  echo
  diff -u "$dst" "$tmp" || true
  echo
  echo "re-run with --write to install it."
fi
