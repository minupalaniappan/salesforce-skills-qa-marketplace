#!/usr/bin/env bash
# Seed a disposable Salesforce org with the eval fixture. Re-runnable.
#
# usage: seed/seed-org.sh <org-alias> [--no-address-settings] [--dry-run]
#
# Runs the load order in seed/GUIDELINES.md (S0-S4c, M1-M3) with the sf CLI against an
# already-authenticated alias. A complete fixture is detected and only the current-week
# finalizer (S4c) re-runs; a partial fixture stops the script so it can be reset first.
# --dry-run prints the commands and assumes an empty org.
set -euo pipefail

alias=""; address=1; dry=0
for arg in "$@"; do
  case "$arg" in
    --no-address-settings) address=0 ;;
    --dry-run) dry=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) alias="$arg" ;;
  esac
done
[ -n "$alias" ] || { echo "usage: seed/seed-org.sh <org-alias> [--no-address-settings] [--dry-run]" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)

run() { if [ "$dry" -eq 1 ]; then echo "+ $*"; else "$@"; fi; }
count() {
  if [ "$dry" -eq 1 ]; then echo 0; return; fi
  sf data query -o "$alias" --json -q "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["totalSize"])'
}

[ "$dry" -eq 1 ] || sf org display -o "$alias" >/dev/null

if [ "$address" -eq 1 ]; then
  echo "--> S0 address picklist values"
  run sf project deploy start --metadata-dir "$here/address-settings" -o "$alias" --wait 20
fi

cd "$here/core"
echo "--> S1 schema"
run sf project deploy start --source-dir force-app/main/default/objects \
  --source-dir force-app/main/default/permissionsets -o "$alias" --wait 20
echo "--> S2 permission set"
run sf org assign permset --name H360_Test_Data -o "$alias" || echo "  (already assigned)"

n=$(count "SELECT Id FROM Opportunity WHERE Name LIKE 'Joja Corporation - %' OR Name LIKE 'Pierre%s General Store - Initial Rollout'")
if [ "$n" -eq 6 ]; then
  echo "  Sales fixture present; skipping S3, S4a, S4b"
elif [ "$n" -ne 0 ]; then
  echo "✗ partial Sales fixture ($n of 6 opportunities): reset it before reseeding" >&2
  exit 1
else
  echo "--> S3 Sales rows"; run sf data import tree --plan data/plan.json -o "$alias"
  echo "--> S4a products and pricebook"; run sf apex run --file scripts/seed-products-pricebook.apex -o "$alias"
  echo "--> S4b communications"; run sf apex run --file scripts/seed-communications.apex -o "$alias"
fi
echo "--> S4c history and current-week events"
run sf apex run --file scripts/trigger-opp-history.apex -o "$alias"

echo "--> M1 Marketing User permission"
if [ "$dry" -eq 1 ]; then
  echo "+ sf data update record -s User -i <running user Id> -v UserPermissionsMarketingUser=true -o $alias"
else
  user=$(sf org display -o "$alias" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["username"])')
  uid=$(sf data query -o "$alias" --json -q "SELECT Id FROM User WHERE Username = '$user'" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]["records"]; assert len(r) == 1; print(r[0]["Id"])')
  sf data update record -o "$alias" -s User -i "$uid" -v "UserPermissionsMarketingUser=true" >/dev/null
fi

m=$(count "SELECT Id FROM Campaign WHERE Name LIKE 'H360 Eval %'")
if [ "$m" -eq 5 ]; then echo "  Marketing fixture present"
elif [ "$m" -ne 0 ]; then echo "✗ partial Marketing fixture ($m of 5 campaigns): reset it before reseeding" >&2; exit 1
else echo "--> M2 Marketing campaigns"; run sf data import tree --plan data/marketing-plan.json -o "$alias"
fi

if [ -d "$here/supplemental-marketing" ]; then
  s=$(count "SELECT Id FROM Campaign WHERE Name IN ('Summer Adventure', 'Summer Adventure Re-engagement', 'Velocity Road 2 Launch', 'Spring Launch', 'Holiday Campaign 2026', 'Black Friday Launch')")
  if [ "$s" -eq 6 ]; then echo "  supplemental campaigns present"
  elif [ "$s" -ne 0 ]; then echo "✗ partial supplemental fixture ($s of 6 campaigns): reset it before reseeding" >&2; exit 1
  else echo "--> M3 supplemental campaigns"; (cd "$here/supplemental-marketing" && run sf data import tree --plan plan.json -o "$alias")
  fi
fi
echo "✓ seeded $alias. Run the checks in seed/GUIDELINES.md, section 4."
