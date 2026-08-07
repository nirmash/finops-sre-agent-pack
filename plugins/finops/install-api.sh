#!/usr/bin/env bash
#
# install-api.sh — client-side installer for the FinOps package.
#
# Installs EVERYTHING via the SRE Agent's own management API — no srectl, no .NET,
# no private NuGet feed. It does exactly what srectl does under the hood:
#   * gets an AAD token for the SRE Agent first-party scope (https://azuresre.dev/.default)
#   * calls the agent's data-plane endpoint (RBAC-guarded by AuthorizeArmOperation)
#
# It performs four control-plane operations:
#   1. Register this repo as a plugin marketplace         POST /api/v2/plugins/marketplaces
#   2. Install the `finops` plugin (server clones + copies POST .../plugins/finops/install
#      the whole skill dir: SKILL.md + detect.py)
#   3. Upsert the read-only FinOps investigator agent    PUT /api/v2/extendedAgent/agents/...
#   4. Upsert the proactive FinOps scheduled tasks       POST/PUT /api/v1/scheduledtasks
#
# Caller identity (az login) must hold the agent's ARM write actions
# (AgentExtendedAgentWrite, AgentScheduledTaskWrite, and AgentScheduledTaskDelete for the one-time
# task retarget migration) — the resource owner does.
#
# Requires: az (logged in), curl, python3.
#
# Usage:
#   AGENT_RESOURCE_ID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/agents/<name> \
#     ./install-api.sh
#   # private repo clone (until the repo is public) needs a GitHub PAT:
#   GITHUB_PAT=<pat> AGENT_RESOURCE_ID=<id> ./install-api.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Configuration (override via environment) -------------------------------
AGENT_RESOURCE_ID="${AGENT_RESOURCE_ID:-}"       # required ARM id; endpoint and managed scopes are read from it
ENDPOINT="${ENDPOINT:-}"                          # optional consistency check; ARM endpoint remains authoritative
TOKEN_RESOURCE="${TOKEN_RESOURCE:-https://azuresre.dev}"

MARKETPLACE_NAME="${MARKETPLACE_NAME:-finops-pack}"
PLUGIN_NAME="${PLUGIN_NAME:-finops}"
SKILL_NAME="${SKILL_NAME:-finops-cost-anomaly-detection}"
REPO_SLUG="${REPO_SLUG:-nirmash/finops-sre-agent-pack}"   # owner/repo (marketplace sourceUrl)
SOURCE_FORMAT="${SOURCE_FORMAT:-copilot}"
GITHUB_PAT="${GITHUB_PAT:-}"                      # set for a private repo; else host-default identity
FINOPS_AGENT_NAME="${FINOPS_AGENT_NAME:-finops-investigator}"
FINOPS_AGENT_MANIFEST="${FINOPS_AGENT_MANIFEST:-$SCRIPT_DIR/agents/finops-investigator.json}"
FINOPS_MCP_TOOLS="${FINOPS_MCP_TOOLS:-}"           # comma-separated connector/tool identifiers
FINOPS_CONNECTORS="${FINOPS_CONNECTORS:-}"         # comma-separated connector names

TASK_NAME="${TASK_NAME:-FinOps: Cost Anomaly Detection (Daily)}"
RIGHTSIZE_TASK_NAME="${RIGHTSIZE_TASK_NAME:-FinOps: Rightsizing Review (Weekly)}"
REPORT_TASK_NAME="${REPORT_TASK_NAME:-FinOps: Cost Overview (Live Report, Daily)}"
RIGHTSIZE_REPORT_TASK_NAME="${RIGHTSIZE_REPORT_TASK_NAME:-FinOps: Rightsizing Savings (Live Report, Weekly)}"
AGENT_NAME="${AGENT_NAME:-}"                       # compatibility alias for TASK_AGENT_NAME
TASK_AGENT_NAME="${TASK_AGENT_NAME:-${AGENT_NAME:-$FINOPS_AGENT_NAME}}"
SUB_ID_WAS_SET="${SUB_ID+x}"
CRON="${CRON:-0 14 * * *}"                         # daily anomaly scan (14:00 UTC)
RIGHTSIZE_CRON="${RIGHTSIZE_CRON:-0 15 * * 1}"     # weekly rightsizing review (Mon 15:00 UTC)
REPORT_CRON="${REPORT_CRON:-0 14 * * *}"           # daily live-report refresh (14:00 UTC)
REPORT_NAME="${REPORT_NAME:-FinOps: Cost Overview}" # the Live Report's display name (kept stable so daily runs version the same report)
RIGHTSIZE_REPORT_CRON="${RIGHTSIZE_REPORT_CRON:-0 15 * * 1}"  # weekly rightsizing live-report refresh (Mon 15:00 UTC)
RIGHTSIZE_REPORT_NAME="${RIGHTSIZE_REPORT_NAME:-FinOps: Rightsizing Savings}" # display name; kept stable so weekly runs version the same report
BUDGET_REPORT_TASK_NAME="${BUDGET_REPORT_TASK_NAME:-FinOps: Budget Status (Live Report, Daily)}"
BUDGET_REPORT_CRON="${BUDGET_REPORT_CRON:-0 16 * * *}"       # daily budget live-report refresh (16:00 UTC)
BUDGET_REPORT_NAME="${BUDGET_REPORT_NAME:-FinOps: Budget Status}" # display name; kept stable so daily runs version the same report
COST_OPT_TASK_NAME="${COST_OPT_TASK_NAME:-FinOps: Cost Optimization (Live Report, Weekly)}"
COST_OPT_CRON="${COST_OPT_CRON:-0 17 * * 1}"                 # weekly executive rollup live-report refresh (Mon 17:00 UTC)
COST_OPT_NAME="${COST_OPT_NAME:-FinOps: Cost Optimization}"  # display name; kept stable so weekly runs version the same report
AI_REPORT_TASK_NAME="${AI_REPORT_TASK_NAME:-FinOps: AI Spend (Live Report, Weekly)}"
AI_REPORT_CRON="${AI_REPORT_CRON:-0 18 * * 1}"               # weekly AI-spend live-report refresh (Mon 18:00 UTC)
AI_REPORT_NAME="${AI_REPORT_NAME:-FinOps: AI Spend}"         # display name; kept stable so weekly runs version the same report
RELIABILITY_REPORT_TASK_NAME="${RELIABILITY_REPORT_TASK_NAME:-FinOps: Cost vs Reliability (Live Report, Weekly)}"
RELIABILITY_REPORT_CRON="${RELIABILITY_REPORT_CRON:-0 19 * * 1}" # weekly cost-vs-reliability live-report refresh (Mon 19:00 UTC)
RELIABILITY_REPORT_NAME="${RELIABILITY_REPORT_NAME:-FinOps: Cost vs Reliability}" # display name; kept stable so weekly runs version the same report
MODEL_TIER="${MODEL_TIER:-ReasoningHeavy}"        # default for all scheduled tasks
ANOMALY_MODEL_TIER="${ANOMALY_MODEL_TIER:-$MODEL_TIER}"
RIGHTSIZE_MODEL_TIER="${RIGHTSIZE_MODEL_TIER:-$MODEL_TIER}"
REPORT_MODEL_TIER="${REPORT_MODEL_TIER:-$MODEL_TIER}"
RIGHTSIZE_REPORT_MODEL_TIER="${RIGHTSIZE_REPORT_MODEL_TIER:-$MODEL_TIER}"
BUDGET_REPORT_MODEL_TIER="${BUDGET_REPORT_MODEL_TIER:-$MODEL_TIER}"
COST_OPT_MODEL_TIER="${COST_OPT_MODEL_TIER:-$MODEL_TIER}"
AI_REPORT_MODEL_TIER="${AI_REPORT_MODEL_TIER:-$MODEL_TIER}"
RELIABILITY_REPORT_MODEL_TIER="${RELIABILITY_REPORT_MODEL_TIER:-$MODEL_TIER}"
ALERT_EMAIL="${ALERT_EMAIL:-}"                    # optional; unset keeps results in the task run only
GITHUB_REPO="${GITHUB_REPO:-}"                    # optional owner/repo for change correlation
MI_OBJECT_ID="${MI_OBJECT_ID:-}"                 # agent MI objectId; set to auto-grant Cost Management Reader

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. Preflight -----------------------------------------------------------
say "Preflight"
command -v az     >/dev/null 2>&1 || die "az (Azure CLI) not found."
command -v curl   >/dev/null 2>&1 || die "curl not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."
az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' first."
[ -f "$FINOPS_AGENT_MANIFEST" ] || die "Agent manifest not found: $FINOPS_AGENT_MANIFEST"
case "$FINOPS_AGENT_NAME" in
  *[!A-Za-z0-9._-]*|'') die "FINOPS_AGENT_NAME must contain only letters, numbers, dot, underscore, or hyphen.";;
esac
[ -z "${FINOPS_EXTRA_TOOLS:-}" ] || \
  die "FINOPS_EXTRA_TOOLS is no longer supported: the FinOps agent core tool set is fixed and read-only."

[ -n "$AGENT_RESOURCE_ID" ] || \
  die "AGENT_RESOURCE_ID is required. ENDPOINT-only installation cannot enforce dynamic managed scope."
if [ -n "$SUB_ID_WAS_SET" ]; then
  warn "SUB_ID is deprecated and ignored; managed scopes come only from AGENT_RESOURCE_ID."
fi
if [ -n "$ALERT_EMAIL" ] && [[ ! "$ALERT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$ ]]; then
  die "ALERT_EMAIL must be a single email address, or unset it to disable email delivery."
fi
if [ -n "$GITHUB_REPO" ] && [[ ! "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "GITHUB_REPO must use owner/repo format, or unset it to disable GitHub correlation."
fi
for model_tier in \
  "$ANOMALY_MODEL_TIER" "$RIGHTSIZE_MODEL_TIER" "$REPORT_MODEL_TIER" \
  "$RIGHTSIZE_REPORT_MODEL_TIER" "$BUDGET_REPORT_MODEL_TIER" \
  "$COST_OPT_MODEL_TIER" "$AI_REPORT_MODEL_TIER" "$RELIABILITY_REPORT_MODEL_TIER"; do
  case "$model_tier" in
    *[!A-Za-z0-9._-]*|'') die "Scheduled-task model tiers must contain only letters, numbers, dot, underscore, or hyphen.";;
  esac
done

if [ -n "$GITHUB_REPO" ]; then
  ANOMALY_CORRELATION_STEP="for EACH anomaly, search only its effective managed scope's subscription/resource-group deployments, activity-log write ops, and GitHub commits + merged PRs (repo ${GITHUB_REPO}) within +/-1 day of the spike date, and attach the most likely cause."
else
  warn "GITHUB_REPO not set — scheduled anomaly detection will skip GitHub correlation."
  ANOMALY_CORRELATION_STEP="for EACH anomaly, search only its effective managed scope's subscription/resource-group deployments and activity-log write ops within +/-1 day of the spike date, and attach the most likely cause. GitHub correlation is disabled because GITHUB_REPO was not set at installation time."
fi
if [ -n "$ALERT_EMAIL" ]; then
  ANOMALY_DELIVERY_STEP="email the report to ${ALERT_EMAIL} with subject \"Cost anomaly detected — <date>\" and High importance."
  RIGHTSIZE_DELIVERY_STEP="email the report to ${ALERT_EMAIL} with subject \"Weekly rightsizing review — <date>\" and Normal importance."
else
  warn "ALERT_EMAIL not set — scheduled findings will remain in task results and no email will be sent."
  ANOMALY_DELIVERY_STEP="do not send email; ALERT_EMAIL was not set at installation time, so return the report only in the scheduled-task result."
  RIGHTSIZE_DELIVERY_STEP="do not send email; ALERT_EMAIL was not set at installation time, so return the report only in the scheduled-task result."
fi

say "Discovering agent endpoint, managed scopes, and identity"
ARM_AGENT_JSON="$(az resource show --ids "$AGENT_RESOURCE_ID" -o json)" \
  || die "Could not read the agent ARM resource: $AGENT_RESOURCE_ID"
DISCOVERY_JSON="$(printf '%s' "$ARM_AGENT_JSON" | python3 -c '
import json
import re
import sys

doc = json.load(sys.stdin)
properties = doc.get("properties")
if not isinstance(properties, dict):
    raise SystemExit("Agent resource is missing properties.")

endpoint = properties.get("agentEndpoint")
if not isinstance(endpoint, str) or not endpoint.strip():
    raise SystemExit("Agent resource properties.agentEndpoint is empty.")

managed = (properties.get("knowledgeGraphConfiguration") or {}).get("managedResources")
if not isinstance(managed, list) or not managed:
    raise SystemExit(
        "Agent resource properties.knowledgeGraphConfiguration.managedResources "
        "must be a nonempty list."
    )

subscription_pattern = re.compile(r"/subscriptions/([^/]+)", re.IGNORECASE)
resource_group_pattern = re.compile(
    r"/subscriptions/([^/]+)/resourceGroups/([^/]+)", re.IGNORECASE
)
management_group_pattern = re.compile(
    r"/providers/Microsoft\.Management/managementGroups/([^/]+)",
    re.IGNORECASE,
)
invalid_path_chars = frozenset("\\?#")


def segment(value, field):
    if not value or value != value.strip():
        raise SystemExit(f"{field} must be nonempty and have no surrounding whitespace.")
    if any(ord(char) < 32 for char in value) or any(
        char in invalid_path_chars for char in value
    ):
        raise SystemExit(f"{field} contains unsafe path characters.")
    return value


def canonicalize_scope(value):
    if any(ord(char) < 32 for char in value) or "\\" in value:
        raise SystemExit("Managed scope contains unsafe path characters.")
    raw = value.strip()
    if raw != "/":
        raw = raw.rstrip("/")

    match = subscription_pattern.fullmatch(raw)
    if match:
        subscription_id = segment(match.group(1), "subscriptionId")
        return f"/subscriptions/{subscription_id}"

    match = resource_group_pattern.fullmatch(raw)
    if match:
        subscription_id = segment(match.group(1), "subscriptionId")
        resource_group = segment(match.group(2), "resourceGroupName")
        return f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"

    match = management_group_pattern.fullmatch(raw)
    if match:
        management_group = segment(match.group(1), "managementGroupId")
        return (
            "/providers/Microsoft.Management/managementGroups/"
            f"{management_group}"
        )

    raise SystemExit(f"Unsupported managedResources scope ID: {raw}")


scopes = []
seen = set()
for item in managed:
    if isinstance(item, dict):
        lowered = {str(key).casefold(): value for key, value in item.items()}
        item = next(
            (lowered[key] for key in ("id", "resourceid", "scope") if lowered.get(key)),
            None,
        )
    if not isinstance(item, str) or not item.strip():
        raise SystemExit("Every managedResources entry must be a nonempty ARM scope ID string.")
    scope = canonicalize_scope(item)
    key = scope.casefold()
    if key not in seen:
        seen.add(key)
        scopes.append(scope)
if not scopes:
    raise SystemExit("No supported managedResources scopes remain after normalization.")

identity = doc.get("identity")
if not isinstance(identity, dict):
    raise SystemExit("Agent resource is missing its user-assigned identity.")
uamis = identity.get("userAssignedIdentities")
if not isinstance(uamis, dict) or len(uamis) != 1:
    raise SystemExit("Agent resource must have exactly one user-assigned identity.")
uami_resource_id, uami_details = next(iter(uamis.items()))
if not isinstance(uami_resource_id, str) or not uami_resource_id.strip():
    raise SystemExit("Agent user-assigned identity resource ID is empty.")
inline_principal_id = ""
if isinstance(uami_details, dict):
    value = uami_details.get("principalId")
    if isinstance(value, str):
        inline_principal_id = value.strip()

json.dump(
    {
        "endpoint": endpoint.strip().rstrip("/"),
        "managedScopes": scopes,
        "uamiResourceId": uami_resource_id.strip(),
        "inlinePrincipalId": inline_principal_id,
    },
    sys.stdout,
)
')" || die "Agent endpoint/managed-scope/identity discovery failed."

ARM_ENDPOINT="$(printf '%s' "$DISCOVERY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')"
if [ -n "$ENDPOINT" ] && [ "${ENDPOINT%/}" != "$ARM_ENDPOINT" ]; then
  die "ENDPOINT does not match properties.agentEndpoint on $AGENT_RESOURCE_ID."
fi
ENDPOINT="$ARM_ENDPOINT"
FINOPS_MANAGED_SCOPES_JSON="$(printf '%s' "$DISCOVERY_JSON" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["managedScopes"], separators=(",",":")))')"
MANAGED_SCOPES=()
while IFS= read -r scope; do
  [ -n "$scope" ] && MANAGED_SCOPES+=("$scope")
done < <(printf '%s' "$FINOPS_MANAGED_SCOPES_JSON" | python3 -c 'import json,sys; print(*json.load(sys.stdin), sep="\n")')
[ "${#MANAGED_SCOPES[@]}" -gt 0 ] || die "No normalized managed scopes were discovered."

COST_READER_SCOPES=()
while IFS= read -r scope; do
  [ -n "$scope" ] && COST_READER_SCOPES+=("$scope")
done < <(printf '%s' "$FINOPS_MANAGED_SCOPES_JSON" | python3 -c '
import json
import re
import sys

subscription_scope = re.compile(
    r"^/subscriptions/([^/]+)(?:/resourceGroups/[^/]+)?$",
    re.IGNORECASE,
)
result = []
seen = set()
for scope in json.load(sys.stdin):
    match = subscription_scope.fullmatch(scope)
    transport_scope = f"/subscriptions/{match.group(1)}" if match else scope
    key = transport_scope.casefold()
    if key not in seen:
        seen.add(key)
        result.append(transport_scope)
print(*result, sep="\n")
')
[ "${#COST_READER_SCOPES[@]}" -gt 0 ] || die "No Cost Management transport scopes were derived."

UAMI_RESOURCE_ID="$(printf '%s' "$DISCOVERY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["uamiResourceId"])')"
UAMI_PRINCIPAL_ID="$(printf '%s' "$DISCOVERY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["inlinePrincipalId"])')"
if [ -z "$UAMI_PRINCIPAL_ID" ]; then
  UAMI_PRINCIPAL_ID="$(az identity show --ids "$UAMI_RESOURCE_ID" --query principalId -o tsv)" \
    || die "Could not resolve principalId for agent UAMI: $UAMI_RESOURCE_ID"
fi
[ -n "$UAMI_PRINCIPAL_ID" ] || die "Agent UAMI principalId is empty: $UAMI_RESOURCE_ID"

read -r -d '' FINOPS_SCOPE_PREAMBLE <<EOF || true
STRICT MANAGED-SCOPE PREAMBLE — complete this before any Azure analysis query,
email, ListReports/GetReport call, or SaveReport call:
0. Load finops-managed-scope and follow its scope.py procedure using agent resource
   ID ${AGENT_RESOURCE_ID}. Dynamically GET the agent's current managedResources;
   do not use a cached list. Validate and normalize every scope, expand only to
   Azure descendants, and use that effective scope set as the sole analysis boundary.
   - If discovery fails, is malformed, or returns an empty list, FAIL CLOSED:
     stop without querying analysis data, sending email, or creating/updating/
     saving a report. State the scope error only.
   - This scheduled task accepts NO override or broader user/requested scope.
     Broad RBAC/visibility must never expand the boundary.
   - Query every effective scope produced by scope.py independently where the API
     supports scoped retrieval; paginate each independently, de-duplicate overlaps, filter all
     results against the boundary, and disclose included, excluded, unattributed,
     unsupported, and partial/failed scope coverage.
   - Consumption UsageDetails is subscription-scoped transport. For RG-only scopes,
     query each containing subscription endpoint once, paginate it completely, then
     use scope.py to keep only rows inside the exact managed RGs. Never construct a
     /resourceGroups/.../providers/Microsoft.Consumption/usageDetails URL, and never
     treat the transport subscription as an expanded analysis boundary.
   - Never infer, add, or substitute a subscription or parent scope.
   - Installer-time normalized scope snapshot (diagnostic only; rediscover at run time):
     ${FINOPS_MANAGED_SCOPES_JSON}
EOF
export AGENT_RESOURCE_ID FINOPS_MANAGED_SCOPES_JSON FINOPS_SCOPE_PREAMBLE

ok "Endpoint: $ENDPOINT"
ok "Managed scopes: ${#MANAGED_SCOPES[@]}"
ok "Cost Management transport scopes: ${#COST_READER_SCOPES[@]}"
ok "Agent UAMI principal: $UAMI_PRINCIPAL_ID"

TOKEN="$(az account get-access-token --resource "$TOKEN_RESOURCE" --query accessToken -o tsv)" \
  || die "Failed to mint token for $TOKEN_RESOURCE"
[ -n "$TOKEN" ] || die "Empty access token."
ok "Access token acquired for $TOKEN_RESOURCE"

# api METHOD PATH [json-body-file]  -> sets HTTP_CODE and RESP_BODY
HTTP_CODE=""
RESP_BODY=""
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN")
  if [ -n "$body" ]; then args+=(-H "Content-Type: application/json" --data-binary @"$body"); fi
  local out; out="$(curl "${args[@]}" "$ENDPOINT$path")"
  HTTP_CODE="${out##*$'\n'}"
  RESP_BODY="${out%$'\n'*}"
}

# ---- 1. RBAC ---------------------------------------------------------------
has_exact_role_assignment() {
  local principal_id="$1" role_name="$2" scope_id="$3" assignments
  assignments="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --role "$role_name" \
    --scope "$scope_id" \
    -o json 2>/dev/null)" || return 2
  printf '%s' "$assignments" | ROLE_NAME="$role_name" SCOPE_ID="$scope_id" python3 -c '
import json
import os
import sys

role = os.environ["ROLE_NAME"].casefold()
scope = os.environ["SCOPE_ID"].casefold()
items = json.load(sys.stdin)
raise SystemExit(0 if any(
    isinstance(item, dict)
    and str(item.get("roleDefinitionName", "")).casefold() == role
    and str(item.get("scope", "")).casefold() == scope
    for item in items
) else 1)
'
}

ensure_exact_role_assignment() {
  local principal_id="$1" role_name="$2" scope_id="$3"
  local check_status create_status=0
  if has_exact_role_assignment "$principal_id" "$role_name" "$scope_id"; then
    ok "$role_name already assigned at exactly $scope_id"
    return
  else
    check_status=$?
    [ "$check_status" -ne 2 ] || die "Failed to inspect $role_name assignment at $scope_id."
  fi

  az role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "$role_name" \
    --scope "$scope_id" >/dev/null 2>&1 || create_status=$?

  for i in $(seq 1 10); do
    if has_exact_role_assignment "$principal_id" "$role_name" "$scope_id"; then
      ok "Verified $role_name at exactly $scope_id"
      return
    else
      check_status=$?
      [ "$check_status" -ne 2 ] || die "Failed to verify $role_name assignment at $scope_id."
    fi
    [ "$i" -eq 10 ] || sleep 2
  done
  die "Failed to create/verify $role_name at exactly $scope_id (az exit $create_status)."
}

say "Agent resource Reader RBAC"
ensure_exact_role_assignment "$UAMI_PRINCIPAL_ID" "Reader" "$AGENT_RESOURCE_ID"

say "Cost Management transport Reader RBAC"
if [ -n "$MI_OBJECT_ID" ]; then
  for scope in "${COST_READER_SCOPES[@]}"; do
    ensure_exact_role_assignment "$MI_OBJECT_ID" "Cost Management Reader" "$scope"
  done
else
  warn "MI_OBJECT_ID not set — skipping Cost Management Reader grants on transport scopes."
  warn "The required Reader grant on the agent resource was still enforced."
fi

# ---- 2. Register the marketplace -------------------------------------------
say "Registering marketplace '$MARKETPLACE_NAME' -> $REPO_SLUG"
mk_body="$(mktemp)"; trap 'rm -f "$mk_body" "${task_body:-}" "${agent_body:-}"' EXIT
MARKETPLACE_NAME="$MARKETPLACE_NAME" REPO_SLUG="$REPO_SLUG" SOURCE_FORMAT="$SOURCE_FORMAT" \
GITHUB_PAT="$GITHUB_PAT" python3 - "$mk_body" <<'PY'
import json, os, sys
owner = os.environ["REPO_SLUG"].split("/", 1)[0]
spec = {
    "sourceType": "github",
    "sourceUrl": os.environ["REPO_SLUG"],
    "owner": {"name": owner},
    "description": "FinOps cost-anomaly pack",
    "sourceFormat": os.environ["SOURCE_FORMAT"],
}
pat = os.environ.get("GITHUB_PAT") or ""
if pat:
    spec["credentials"] = {"authMethod": "pat", "pat": pat}
doc = {"metadata": {"name": os.environ["MARKETPLACE_NAME"]}, "spec": spec}
open(sys.argv[1], "w").write(json.dumps(doc))
PY
api POST /api/v2/plugins/marketplaces "$mk_body"; resp="$RESP_BODY"
case "$HTTP_CODE" in
  200|201|202) ok "Marketplace upserted (HTTP $HTTP_CODE)";;
  *) die "Marketplace register failed (HTTP $HTTP_CODE): $resp";;
esac

# Wait for the background clone to reach Ready
say "Waiting for repo clone"
for i in $(seq 1 30); do
  api GET "/api/v2/plugins/marketplaces/${MARKETPLACE_NAME}"; resp="$RESP_BODY"
  status="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("cloneStatus",""))' 2>/dev/null || true)"
  case "$status" in
    Ready)  ok "Clone Ready"; break;;
    Failed) err="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("spec",{}).get("cloneError",""))' 2>/dev/null)"; die "Clone Failed: $err";;
    *)      printf '  … cloneStatus=%s (%d/30)\n' "${status:-?}" "$i"; sleep 4;;
  esac
  [ "$i" -eq 30 ] && die "Timed out waiting for clone (last status: ${status:-?})"
done

# ---- 3. Install the plugin --------------------------------------------------
say "Installing plugin '$PLUGIN_NAME'"
api POST "/api/v2/plugins/marketplaces/${MARKETPLACE_NAME}/plugins/${PLUGIN_NAME}/install"; resp="$RESP_BODY"
case "$HTTP_CODE" in
  200|201|202) ok "Plugin install requested (HTTP $HTTP_CODE)";;
  *) die "Plugin install failed (HTTP $HTTP_CODE): $resp";;
esac

say "Waiting for all FinOps skills"
for i in $(seq 1 60); do
  api GET /api/v2/plugins/installations
  if printf '%s' "$RESP_BODY" | MARKETPLACE_NAME="$MARKETPLACE_NAME" PLUGIN_NAME="$PLUGIN_NAME" python3 -c '
import json, os, sys
expected = {
    "finops-cost-anomaly-detection",
    "finops-rightsizing-advisor",
    "finops-cost-allocation",
    "finops-budget-governance",
    "finops-budget-editor",
    "finops-cost-optimization-report",
    "finops-for-ai",
    "finops-cost-vs-reliability",
    "finops-managed-scope",
}
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
installations = data if isinstance(data, list) else data.get("value", [])
for item in installations:
    spec = item.get("spec", {})
    if (
        spec.get("marketplaceName") == os.environ["MARKETPLACE_NAME"]
        and spec.get("pluginName") == os.environ["PLUGIN_NAME"]
    ):
        imported = {skill.get("skillName") for skill in spec.get("importedSkills", [])}
        raise SystemExit(0 if expected <= imported else 1)
raise SystemExit(1)
'; then
    ok "All nine FinOps skills ready"
    break
  fi
  printf '  … skills not ready (%d/60)\n' "$i"
  sleep 2
  [ "$i" -eq 60 ] && die "Timed out waiting for all nine FinOps skills."
done

# ---- 4. Upsert the FinOps investigator agent -------------------------------
say "Validating agent '$FINOPS_AGENT_NAME'"
api GET "/api/v1/extendedAgent/systemtools?stableOnly=false"
case "$HTTP_CODE" in
  200) ;;
  *) die "Could not list runtime system tools (HTTP $HTTP_CODE): $RESP_BODY";;
esac
FINOPS_PYTHON_TOOL="$(printf '%s' "$RESP_BODY" | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
items = doc if isinstance(doc, list) else doc.get("data", doc.get("value", []))
names = {
    item.get("name")
    for item in items
    if isinstance(item, dict) and isinstance(item.get("name"), str)
}
required = {"RunAzCliReadCommands", "ListReports", "GetReport", "SaveReport"}
missing = sorted(required - names)
if missing:
    raise SystemExit("Missing required FinOps system tools: " + ", ".join(missing))
if "ExecutePythonCode" in names:
    print("ExecutePythonCode")
elif "RunInTerminal" in names:
    print("RunInTerminal")
else:
    raise SystemExit(
        "Missing sandbox execution tool: expected ExecutePythonCode or RunInTerminal"
    )
')" || die "Runtime tool compatibility check failed."
ok "Sandbox execution tool: $FINOPS_PYTHON_TOOL"

agent_body="$(mktemp)"
FINOPS_AGENT_NAME="$FINOPS_AGENT_NAME" \
FINOPS_AGENT_MANIFEST="$FINOPS_AGENT_MANIFEST" \
FINOPS_MCP_TOOLS="$FINOPS_MCP_TOOLS" \
FINOPS_CONNECTORS="$FINOPS_CONNECTORS" \
FINOPS_PYTHON_TOOL="$FINOPS_PYTHON_TOOL" \
AGENT_RESOURCE_ID="$AGENT_RESOURCE_ID" \
python3 - "$agent_body" <<'PY'
import json
import os
import sys


def csv_values(name):
    return [value.strip() for value in os.environ.get(name, "").split(",") if value.strip()]


def append_unique(existing, additions):
    result = list(existing or [])
    for value in additions:
        if value not in result:
            result.append(value)
    return result


with open(os.environ["FINOPS_AGENT_MANIFEST"]) as handle:
    doc = json.load(handle)

doc["name"] = os.environ["FINOPS_AGENT_NAME"]
properties = doc.setdefault("properties", {})
manifest_tools = [
    "RunAzCliReadCommands",
    "ExecutePythonCode",
    "ListReports",
    "GetReport",
    "SaveReport",
]
configured_tools = properties.get("tools")
if (
    not isinstance(configured_tools, list)
    or len(configured_tools) != len(manifest_tools)
    or set(configured_tools) != set(manifest_tools)
):
    raise SystemExit(
        "Read-only Azure safety error: properties.tools must contain exactly "
        + ", ".join(manifest_tools)
    )
python_tool = os.environ["FINOPS_PYTHON_TOOL"]
if python_tool not in {"ExecutePythonCode", "RunInTerminal"}:
    raise SystemExit("Unsupported sandbox execution tool: " + python_tool)
properties["tools"] = [
    "RunAzCliReadCommands",
    python_tool,
    "ListReports",
    "GetReport",
    "SaveReport",
]
properties["mcpTools"] = append_unique(properties.get("mcpTools"), csv_values("FINOPS_MCP_TOOLS"))
properties["connectors"] = append_unique(properties.get("connectors"), csv_values("FINOPS_CONNECTORS"))
instructions = properties.get("instructions")
if not isinstance(instructions, str) or not instructions.strip():
    raise SystemExit("Agent manifest properties.instructions must be a nonempty string.")
placeholders = ("__AGENT_RESOURCE_ID__", "{{AGENT_RESOURCE_ID}}", "${AGENT_RESOURCE_ID}")
if not any(placeholder in instructions for placeholder in placeholders):
    raise SystemExit(
        "Managed-scope safety error: properties.instructions must contain an "
        "AGENT_RESOURCE_ID placeholder."
    )
required_skills = {
    "finops-managed-scope",
    "finops-cost-anomaly-detection",
    "finops-rightsizing-advisor",
    "finops-cost-allocation",
    "finops-budget-governance",
    "finops-budget-editor",
    "finops-cost-optimization-report",
    "finops-for-ai",
    "finops-cost-vs-reliability",
}
configured_skills = properties.get("allowedSkills")
if not isinstance(configured_skills, list) or not required_skills <= set(configured_skills):
    raise SystemExit(
        "Managed-scope safety error: properties.allowedSkills must include all "
        "nine FinOps skills."
    )
for placeholder in placeholders:
    instructions = instructions.replace(placeholder, os.environ["AGENT_RESOURCE_ID"])
if python_tool == "RunInTerminal":
    instructions = instructions.replace(
        "use RunAzCliReadCommands and sandbox Python for analysis",
        "use RunAzCliReadCommands and RunInTerminal for sandbox Python analysis",
    )
properties["instructions"] = instructions

with open(sys.argv[1], "w") as handle:
    json.dump(doc, handle)
PY

api PUT "/api/v2/extendedAgent/agents/${FINOPS_AGENT_NAME}?dryRun=true" "$agent_body"
case "$HTTP_CODE" in
  200|201|202|204) ok "Agent definition validated";;
  *) die "Agent validation failed (HTTP $HTTP_CODE): $RESP_BODY";;
esac

say "Upserting agent '$FINOPS_AGENT_NAME'"
api PUT "/api/v2/extendedAgent/agents/${FINOPS_AGENT_NAME}" "$agent_body"
case "$HTTP_CODE" in
  200|201|202|204) ok "Agent upserted";;
  *) die "Agent upsert failed (HTTP $HTTP_CODE): $RESP_BODY";;
esac
rm -f "$agent_body"

say "Waiting for agent registration"
for i in $(seq 1 30); do
  api GET "/api/v2/extendedAgent/agents/${FINOPS_AGENT_NAME}"
  case "$HTTP_CODE" in
    200) ok "Agent ready"; break;;
    202|404) printf '  … agent not ready (%d/30)\n' "$i"; sleep 2;;
    *) die "Agent readiness check failed (HTTP $HTTP_CODE): $RESP_BODY";;
  esac
  [ "$i" -eq 30 ] && die "Timed out waiting for agent '$FINOPS_AGENT_NAME' to become ready."
done

# ---- 5. Upsert the scheduled tasks -----------------------------------------
# Load once for all upserts. A fresh list is fetched again during final verification.
say "Loading existing scheduled tasks"
api GET /api/v1/scheduledtasks
case "$HTTP_CODE" in
  200) SCHEDULED_TASKS_JSON="$RESP_BODY";;
  *) die "Could not list scheduled tasks (HTTP $HTTP_CODE): $RESP_BODY";;
esac

# upsert_task NAME DESCRIPTION CRON PROMPT MODEL_TIER — POST new / PUT existing by name.
upsert_task() {
  local name="$1" description="$2" cron="$3" prompt="$4" model_tier="$5"
  prompt="${FINOPS_SCOPE_PREAMBLE}"$'\n\n'"${prompt}"

  local task_info task_id current_agent current_status
  task_info="$(printf '%s' "$SCHEDULED_TASKS_JSON" | TASK_NAME="$name" python3 -c '
import json,os,sys
name=os.environ["TASK_NAME"]
try: data=json.load(sys.stdin)
except Exception: data=[]
tasks=data if isinstance(data,list) else data.get("value",[])
task=next((t for t in tasks if t.get("name")==name), {})
print("\t".join((str(task.get("id","")), str(task.get("agent","")), str(task.get("status","")))))' 2>/dev/null || true)"
  IFS=$'\t' read -r task_id current_agent current_status <<< "$task_info"

  # The v1 scheduled-task PUT contract cannot change Agent. Replace a task once when its
  # target differs, then subsequent installer runs return to ordinary in-place updates.
  if [ -n "$task_id" ] && [ "$current_agent" != "$TASK_AGENT_NAME" ]; then
    warn "Replacing scheduled task '$name' to change agent '$current_agent' -> '$TASK_AGENT_NAME'"
    api DELETE "/api/v1/scheduledtasks/${task_id}"
    case "$HTTP_CODE" in
      200|204) task_id="";;
      *) die "Task replacement delete failed (HTTP $HTTP_CODE): $RESP_BODY";;
    esac
  fi

  local body; body="$(mktemp)"
  TASK_NAME="$name" TASK_DESC="$description" CRON="$cron" TASK_AGENT_NAME="$TASK_AGENT_NAME" \
  MODEL_TIER="$model_tier" PROMPT="$prompt" \
    python3 - "$body" <<'PY'
import json, os, sys
doc = {
    "name": os.environ["TASK_NAME"],
    "description": os.environ["TASK_DESC"],
    "cronExpression": os.environ["CRON"],
    "agentPrompt": os.environ["PROMPT"],
    "agent": os.environ["TASK_AGENT_NAME"],
    "agentMode": "autonomous",
    "modelTier": os.environ["MODEL_TIER"],
}
open(sys.argv[1], "w").write(json.dumps(doc))
PY

  if [ -n "$task_id" ]; then
    api PUT "/api/v1/scheduledtasks/${task_id}" "$body"
    case "$HTTP_CODE" in 200|201|204) ok "Scheduled task updated: $name ($task_id)";; *) rm -f "$body"; die "Task update failed (HTTP $HTTP_CODE): $RESP_BODY";; esac
  else
    api POST /api/v1/scheduledtasks "$body"
    case "$HTTP_CODE" in
      200|201)
        local created_id
        created_id="$(printf '%s' "$RESP_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("taskId",""))' 2>/dev/null || true)"
        if [ "${current_status,,}" = "paused" ] && [ -n "$created_id" ]; then
          api POST "/api/v1/scheduledtasks/${created_id}/pause"
          case "$HTTP_CODE" in
            200|204) ok "Scheduled task recreated and paused: $name";;
            *) rm -f "$body"; die "Task recreated but pause restore failed (HTTP $HTTP_CODE): $RESP_BODY";;
          esac
        else
          ok "Scheduled task created: $name"
        fi
        ;;
      *) rm -f "$body"; die "Task create failed (HTTP $HTTP_CODE): $RESP_BODY";;
    esac
  fi
  rm -f "$body"
}

say "Upserting scheduled task '$TASK_NAME'"
read -r -d '' ANOMALY_PROMPT <<EOF || true
Run the \`finops-cost-anomaly-detection\` skill for every dynamically discovered managed scope. Read-only. Follow the skill's procedure exactly:

1. Load the skill — read its SKILL.md so you use the bundled detector and steps.
2. Step 1 (pull): independently GET Consumption UsageDetails (ActualCost) for every effective scope for the last 35 days via \`az rest --method get\` with \`&\$top=1000\`. Project to just the needed fields with \`--query "{value: value[].{date: properties.date, cost: properties.costInUSD, meterCategory: properties.meterCategory, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"\` and paginate every nextLink. If a request 413s, lower \$top (1000→100→20). Only if bounded pages still fail, use short usageStart date slices as a fallback; verify returned dates because the filter is not reliably applied, then de-duplicate combined rows. --query is client-side and keeps retained JSON small but does not itself prevent a server 413. nextLink in the body is HTML-escaped (&amp;) — decode before following. resourceId comes from properties.instanceName, falling back to properties.resourceId (resourceId is null in modern billing). If the pull cannot complete, keep partial rows but label downstream totals "partial — cost pull truncated".
3. Step 2 (detect): write the skill's embedded detect.py to the sandbox and run detect_anomalies(line_items) with defaults (baseline_days=28, k=3.0, min_delta_usd=5.0, wow_ratio=1.5). Keep assume_last_partial=True so the partial newest billing day is excluded.
4. Step 3 (correlate only its effective managed scope): ${ANOMALY_CORRELATION_STEP}
5. Step 4 (report):
   - If NO anomalies are detected, reply with a single line "No cost anomalies detected for <date>." and stop. Do not email.
   - If one or more anomalies ARE detected, produce a ranked table (dimension, value, kind, current_usd, baseline_mean_usd, dod_delta_usd, %change, candidate cause) and ${ANOMALY_DELIVERY_STEP}

Read-only only. Do not use any write/POST Azure operations.
EOF
upsert_task "$TASK_NAME" \
  "Part of the FinOps pack — installed with the finops-cost-anomaly-detection skill. Proactive daily cost-anomaly scan; reports only when a spike is detected." \
  "$CRON" "$ANOMALY_PROMPT" "$ANOMALY_MODEL_TIER"

say "Upserting scheduled task '$RIGHTSIZE_TASK_NAME'"
read -r -d '' RIGHTSIZE_PROMPT <<EOF || true
Run the \`finops-rightsizing-advisor\` skill for every dynamically discovered managed scope. Read-only. Follow the skill's procedure exactly:

1. Load the skill — read its SKILL.md so you use the bundled rightsize.py and steps.
2. Step 1 (Advisor): scope every command explicitly. For an effective subscription run \`az advisor recommendation list --category Cost --subscription <subscription-id>\`; for an effective resource group run \`az advisor recommendation list --category Cost --subscription <subscription-id> --resource-group <resource-group-name>\`. Never run Advisor without the managed subscription/RG arguments. Flatten to {resourceId, problem, recommendation, targetSku, savingsUsd}.
3. Step 2 (inventory): scope every Resource Graph command explicitly. For an effective subscription run \`az graph query --subscriptions <subscription-id> -q "<inventory-query>"\`; for an effective resource group use the same \`--subscriptions <subscription-id>\` and add an exact case-insensitive \`resourceGroup =~ '<resource-group-name>'\` predicate to the KQL before the inventory projection. Never run \`az graph query\` without \`--subscriptions\`, and never query the rest of a subscription for an RG-only effective scope. Inventory VMs, disks, App Service plans, Azure Container Apps (managedenvironments + containerapps), and dynamic session pools (microsoft.app/sessionpools); flatten to {resourceId, type, sku, powerState, diskState, numberOfSites, environmentId, minReplicas, readySessionInstances, tags}. Note session pools do NOT appear in \`az resource list\` — only scoped \`az graph query\` returns them, and they are often the largest line items.
4. Step 3 (utilization): for each VM candidate, \`az monitor metrics list\` "Percentage CPU" over 14 days; reduce to {cpu_p95, cpu_avg, mem_p95, sample_days}.
5. Step 3b (activity): for each Container App, \`az monitor metrics list\` "Requests" (Total, P1D) over 14 days; for each session pool, "SessionApiRequestCount" (Total, P1D) over 14 days (retry once or twice — the sessionPools metric namespace is flaky). Reduce to {resourceId: {requests_total, sample_days}} — this flags unused ACA environments, always-on apps with no traffic, and warm session pools with no sessions.
6. Step 4 (cost): GET Consumption UsageDetails (ActualCost) for ~30 days via \`az rest --method get\` with \`&\$top=1000\`, projecting to just the needed fields with \`--query "{value: value[].{date: properties.date, cost: properties.costInUSD, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"\`, and paginate every nextLink. If a request 413s, lower \$top (1000→100→20). Only if bounded pages still fail, use short usageStart date slices as a fallback; verify returned dates because the filter is not reliably applied, then de-duplicate combined rows. --query is client-side and keeps retained JSON small but does not itself prevent a server 413. Aggregate costInUSD by resourceId into {resourceId: monthly_usd}. If the pull cannot complete, keep partial rows but label savings totals "partial — cost pull truncated".
7. Step 5 (rank): write the skill's rightsize.py to the sandbox and run recommend_rightsizing(resources=..., utilization=..., activity=..., costs=..., advisor=...).
8. Step 6 (report):
   - If NOTHING clears the savings threshold, reply with a single line "No rightsizing opportunities above threshold this week." and stop. Do not email.
   - Otherwise produce a ranked table (resource, type, kind, current SKU, recommended action, current monthly \$, est monthly savings \$, validated, evidence) with the TOTAL estimated monthly savings at the top, mark validated=false / unvalidated rows as "verify first", and ${RIGHTSIZE_DELIVERY_STEP}

Recommend only. Read-only. Do not use any write/POST Azure operations.
EOF
upsert_task "$RIGHTSIZE_TASK_NAME" \
  "Part of the FinOps pack — installed with the finops-rightsizing-advisor skill. Weekly read-only rightsizing / idle-resource review; reports ranked savings opportunities." \
  "$RIGHTSIZE_CRON" "$RIGHTSIZE_PROMPT" "$RIGHTSIZE_MODEL_TIER"

say "Upserting scheduled task '$REPORT_TASK_NAME'"
read -r -d '' REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps cost overview snapshot for every dynamically discovered managed scope.

Idempotent daily refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW, at authoring time, per effective managed scope using read-only Azure cost commands. Use \`az rest --method get\` against Consumption UsageDetails (ActualCost) for the last 30 days with \`&\$top=1000\`, projecting to just the needed fields with \`--query "{value: value[].{date: properties.date, cost: properties.costInUSD, meterCategory: properties.meterCategory, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"\`, and paginate every nextLink. On 413 lower \$top (1000→100→20). Only if bounded pages still fail, use short usageStart date slices as a fallback; verify returned dates and de-duplicate combined rows because the filter is not reliably applied. --query is client-side and keeps retained JSON small but does not itself prevent a server 413. If the pull cannot complete, keep partial rows but label the report totals "partial — cost pull truncated". Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Read costInUSD; take the resource id from properties.instanceName, falling back to properties.resourceId (resourceId is null in modern billing).
3. Aggregate with in-sandbox Python into: (a) total spend for the window and a daily total time-series, (b) top 8 services by cost (meterCategory), (c) top 8 resource groups by cost.
4. BAKE the numbers directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${REPORT_NAME}"
   - description: one sentence noting it is a daily-refreshed snapshot of Azure cost, part of the FinOps pack, as of today's date.
5. Author a single self-contained HTML file. Follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files (use Chart.js for the daily line chart). Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is. Note near it that Azure cost data settles ~daily.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$REPORT_TASK_NAME" \
  "Part of the FinOps pack — a daily-refreshed Live Report (Operations Hub) snapshot of Azure cost: total, daily trend, top services, and top resource groups." \
  "$REPORT_CRON" "$REPORT_PROMPT" "$REPORT_MODEL_TIER"

say "Upserting scheduled task '$RIGHTSIZE_REPORT_TASK_NAME'"
read -r -d '' RIGHTSIZE_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps rightsizing / savings snapshot for every dynamically discovered managed scope.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${RIGHTSIZE_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

Gather the data NOW by running the \`finops-rightsizing-advisor\` skill's analysis (read-only):
2. Load finops-rightsizing-advisor (read its SKILL.md) and follow its steps for every effective managed scope/expanded descendant to produce ranked recommendations. Scope Azure Advisor explicitly: for an effective subscription use \`az advisor recommendation list --category Cost --subscription <subscription-id>\`; for an effective resource group add \`--resource-group <resource-group-name>\`. Scope Resource Graph explicitly: always use \`az graph query --subscriptions <subscription-id>\`, and for an RG-only effective scope add an exact case-insensitive \`resourceGroup =~ '<resource-group-name>'\` KQL predicate. Never run either command without the managed subscription/RG restriction. Inventory VMs/disks/App Service plans/Azure Container Apps (managedenvironments + containerapps; project environmentId + minReplicas) and dynamic session pools (microsoft.app/sessionpools; project readySessionInstances — these do not show in \`az resource list\` and often top the bill); collect per-VM "Percentage CPU" over 14 days; per-Container-App "Requests" and per-session-pool "SessionApiRequestCount" (Total, P1D) over 14 days into activity={resourceId:{requests_total,sample_days}} (flags unused ACA environments, always-on apps with no traffic, and warm session pools with no sessions); and ~30 days of Consumption UsageDetails (ActualCost) via \`az rest --method get\` with \`&\$top=1000\`, minimal field projection, and complete nextLink pagination. On 413 lower \$top (1000→100→20), then use short usageStart date slices only as a fallback, verifying returned dates and de-duplicating combined rows because the filter is not reliable; if the pull cannot complete, keep partial rows but label totals "partial — cost pull truncated". Then write the skill's rightsize.py to the sandbox and run recommend_rightsizing(resources=..., utilization=..., activity=..., costs=..., advisor=...) to get the ranked list with estimated monthly savings (including any kind="review" high-spend items with no idle rule yet).
3. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write.

This is a SNAPSHOT report, not a connector-backed live report:
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${RIGHTSIZE_REPORT_NAME}"
   - description: one sentence noting it is a weekly-refreshed rightsizing / idle-resource savings snapshot, part of the FinOps pack, as of today's date.
5. Content: a headline TOTAL estimated monthly savings; a Chart.js bar chart of the top savings opportunities; and a ranked table (resource, type, kind [idle/oversized/advisor], current SKU, recommended action, current monthly \$, est monthly savings \$, validated). Mark validated=false / unvalidated rows as "verify first". Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is.

Recommend only. Read-only Azure. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$RIGHTSIZE_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) of rightsizing / idle-resource savings: total potential savings, a top-opportunities chart, and a ranked recommendations table." \
  "$RIGHTSIZE_REPORT_CRON" "$RIGHTSIZE_REPORT_PROMPT" "$RIGHTSIZE_REPORT_MODEL_TIER"

say "Upserting scheduled task '$BUDGET_REPORT_TASK_NAME'"
read -r -d '' BUDGET_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps budget-governance snapshot for every dynamically discovered managed scope.

Idempotent daily refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${BUDGET_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW using the read-only \`finops-budget-governance\` skill. Read its SKILL.md and follow it. Build the budget query-scope list as the case-insensitive de-duplicated union of (a) every configured \`management_group_scopes\` entry returned by scope.py and (b) every descendant/effective subscription or resource-group scope. Directly GET the native budget collection for every configured management-group scope with \`https://management.azure.com/providers/Microsoft.Management/managementGroups/{management-group-id}/providers/Microsoft.Consumption/budgets?api-version=2023-05-01\`, in addition to GETting budgets once for every unique de-duplicated expanded descendant effective scope. Preserve source scope on every budget and never substitute descendant subscription budgets for management-group-level budgets. De-duplicate returned budgets across overlapping query scopes before evaluation. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Do NOT do a UsageDetails cost pull — budget status comes from the budgets GET only. If the budgets list is empty, author the report stating clearly that no budgets are defined and recommend creating one.
3. Read the skill's budget.py into the sandbox and run evaluate_budgets(budgets) to get per-budget status, forecast (Azure's forecastSpend when present, else a run-rate estimate), breached notification thresholds, portfolio summary, and the gated budgets.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${BUDGET_REPORT_NAME}"
   - description: one sentence noting it is a daily-refreshed snapshot of Azure budget status, part of the FinOps pack, as of today's date.
5. Content: the gated budgets (over / forecast-to-exceed) called out at the top as action items with their reason; a Chart.js bar chart of % used and % forecast per budget against the 100% line; and a ranked table (budget, scope, amount, spent + % used, forecast + source, status, breached thresholds). Where a forecast is run-rate (not Azure's), label it an estimate. Where a budget's current spend is 0 on a newly created budget, note it may be an unsynced value (Azure computes currentSpend asynchronously) rather than real zero spend. If no budgets are defined, show a clear empty-state recommending one be created. Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure computes budget currentSpend asynchronously so the underlying spend can lag that time.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$BUDGET_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a daily-refreshed Live Report (Operations Hub) snapshot of Azure budget governance: each budget's spend vs amount, forecast, status, and any budgets that need a decision." \
  "$BUDGET_REPORT_CRON" "$BUDGET_REPORT_PROMPT" "$BUDGET_REPORT_MODEL_TIER"

say "Upserting scheduled task '$COST_OPT_TASK_NAME'"
read -r -d '' COST_OPT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps executive cost-optimization rollup for every dynamically discovered managed scope.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${COST_OPT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW per effective managed scope/expanded descendant by running the pack's four read-only analyses via the \`finops-cost-optimization-report\` skill. Read its SKILL.md and follow it — run each underlying skill and keep its structured output: (a) finops-cost-anomaly-detection -> detect_anomalies(line_items); (b) finops-rightsizing-advisor -> recommend_rightsizing(...); (c) finops-cost-allocation -> allocate_costs(costs, tags, dimension=...); (d) finops-budget-governance -> evaluate_budgets(budgets). Pull shared cost line items independently per effective scope, with independent pagination, then de-duplicate and boundary-filter them before feeding both anomaly detection and cost allocation. For budget retrieval, build a case-insensitive de-duplicated query-scope union containing every configured \`management_group_scopes\` entry plus every descendant/effective subscription or resource-group scope; directly GET budgets once at each unique scope, retain management-group-level budgets, and de-duplicate overlapping results before evaluate_budgets. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. If any one analysis cannot run or returns nothing, keep going: the rollup treats a missing input as an empty section.
3. Read the skill's summarize.py into the sandbox and run summarize_optimization(anomalies=..., rightsizing=..., allocation=..., budgets=...) to get the executive headline, the single dollar-ranked priorities list (each item labelled with an impact_type), and per-section detail.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${COST_OPT_NAME}"
   - description: one sentence noting it is a weekly-refreshed executive cost-optimization rollup, part of the FinOps pack, as of today's date.
5. Content: an executive HEADLINE row (total monthly spend, total potential monthly savings, anomaly count, budgets over/forecast-over/at-risk, untagged spend); the TOP PRIORITIES table next (rank, category, impact + impact_type, action) as the "where to act first" list; then a section per analysis — rightsizing savings (Chart.js bar chart of top opportunities + table), anomalies (ranked table), budget status (over / forecast-over / at-risk), and governance/policy findings (untagged spend, tag hygiene, budget gates). NEVER sum savings, overruns, spikes, and governance exposure into one number — they are different kinds of dollars; label each priority by its impact_type. Mark run-rate budget forecasts and unvalidated rightsizing rows as estimates / "verify first". Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure cost data settles ~daily.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$COST_OPT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) executive rollup for Azure: potential savings, cost anomalies, budget status, and governance (policy) findings, with one prioritized action list." \
  "$COST_OPT_CRON" "$COST_OPT_PROMPT" "$COST_OPT_MODEL_TIER"

say "Upserting scheduled task '$AI_REPORT_TASK_NAME'"
read -r -d '' AI_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps Azure AI spend breakdown for every dynamically discovered managed scope.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${AI_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW per effective managed scope using the read-only \`finops-for-ai\` skill. Read its SKILL.md and follow it: pull the modern Consumption UsageDetails line items with bounded \$top, minimal field projection, and complete nextLink pagination; lower \$top on 413 and use verified date slices only as a final fallback. PROJECT the extra fields consumedService + meterSubCategory + meterName (needed to classify AI spend and parse the model), then KEEP ONLY rows whose consumedService is Microsoft.CognitiveServices or Microsoft.MachineLearningServices (case-insensitive). Do NOT filter on kind or on a meter category — that would drop Foundry AIServices accounts. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Optionally pull each resource's kind via a Resource Graph GET to label OpenAI vs AIServices vs the ML kind.
3. Read the skill's attribute.py into the sandbox and run attribute_ai_costs(line_items=..., resource_kinds=...) to get total AI spend, the service-family split, the token-vs-compute meter split, per-resource and per-model breakdowns, top drivers, and the read-only hints.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${AI_REPORT_NAME}"
   - description: one sentence noting it is a weekly-refreshed snapshot of Azure AI spend (OpenAI + Foundry + ML), part of the FinOps pack, as of today's date.
5. Content: a HEADLINE row (total AI spend, resource count, model count, and the model-token vs compute dollar split); a Chart.js bar chart of the top models by spend; a by-model table (model, monthly \$, % of model spend, # resources); a by-resource table (resource, kind, service family, top model, monthly \$); the top cost drivers; and the hints as a "where to look first" list. NEVER sum model-token and compute dollars into a single number — they are different cost drivers. Mark PTU/commitment and compute-with-no-tokens hints as estimates / "verify first" (true idle detection needs utilization metrics). Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state (a subscription may have no AI spend — say so clearly). Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure cost data settles ~daily.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$AI_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) of Azure AI spend: total AI cost, per-model and per-resource breakdowns, a token-vs-compute split, top cost drivers, and read-only optimization hints. Covers Azure OpenAI + AI Foundry + ML." \
  "$AI_REPORT_CRON" "$AI_REPORT_PROMPT" "$AI_REPORT_MODEL_TIER"

say "Upserting scheduled task '$RELIABILITY_REPORT_TASK_NAME'"
read -r -d '' RELIABILITY_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps cost-vs-reliability snapshot for every dynamically discovered managed scope.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${RELIABILITY_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW per effective managed scope/expanded descendant using the read-only \`finops-cost-vs-reliability\` skill. Read its SKILL.md and follow it: pull Consumption UsageDetails (ActualCost) with GET only; pull Azure Monitor alerts via GET from Microsoft.AlertsManagement/alerts; pull Resource Health availabilityStatuses via GET and keep Unavailable/Degraded; pull Advisor HighAvailability recommendations; optionally include Activity Log ResourceHealth events. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write.
3. Read the skill's reliability.py into the sandbox and run analyze_cost_vs_reliability(line_items=..., alerts=..., health_events=..., advisor_recommendations=...) to get totals, coverage, per-resource rankings, per-service rollups, top drivers, hints, unmatched reliability, and data quality.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${RELIABILITY_REPORT_NAME}"
   - description: one sentence noting it is a weekly-refreshed snapshot comparing Azure spend and reliability pain from alerts, Resource Health, and Advisor, part of the FinOps pack, as of today's date.
5. Content: a HEADLINE row (total monthly spend, resource count, reliability signal count, joined/unmatched coverage, and partial-cost warning if applicable); a Chart.js bar chart of the top resources by reliability score with monthly cost in the tooltip; a "Spend + pain" table (resource, service, monthly \$, alert/severity counts, health events, Advisor HA count, reliability score, pain per \$1K, risk band, primary signal); a service rollup; a "High pain / low spend" investment-candidates section; a "High spend / no pain — verify before cutting" section; and a data-quality section for unmatched or subscription-level signals and disclosed limitations. Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure cost data settles ~daily and alerts are weighted counts, not a complete incident system.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$RELIABILITY_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) comparing Azure spend with reliability pain from alerts, Resource Health, and Advisor HighAvailability; ranks resources/services, investment candidates, and verify-before-cutting candidates." \
  "$RELIABILITY_REPORT_CRON" "$RELIABILITY_REPORT_PROMPT" "$RELIABILITY_REPORT_MODEL_TIER"

# ---- 6. Verify --------------------------------------------------------------
say "Verifying"
api GET /api/v2/plugins/installations; resp="$RESP_BODY"
printf '%s' "$resp" | grep -qi "$PLUGIN_NAME" && ok "plugin installation present" || warn "plugin not visible yet (install may still be finishing)"
api GET "/api/v2/extendedAgent/agents/${FINOPS_AGENT_NAME}"; resp="$RESP_BODY"
case "$HTTP_CODE" in
  200) printf '%s' "$resp" | grep -qi "\"name\"[[:space:]]*:[[:space:]]*\"${FINOPS_AGENT_NAME}\"" \
         && ok "agent present: $FINOPS_AGENT_NAME" || warn "agent response did not contain expected name";;
  *) warn "agent not visible (HTTP $HTTP_CODE)";;
esac
api GET /api/v1/scheduledtasks; resp="$RESP_BODY"
verify_task_agent() {
  local name="$1"
  if printf '%s' "$resp" | TASK_NAME="$name" TASK_AGENT_NAME="$TASK_AGENT_NAME" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
tasks = data if isinstance(data, list) else data.get("value", [])
raise SystemExit(0 if any(
    task.get("name") == os.environ["TASK_NAME"]
    and task.get("agent") == os.environ["TASK_AGENT_NAME"]
    for task in tasks
) else 1)
'; then
    ok "task present on $TASK_AGENT_NAME: $name"
  else
    warn "task missing or targets another agent: $name"
  fi
}
verify_task_agent "$TASK_NAME"
verify_task_agent "$RIGHTSIZE_TASK_NAME"
verify_task_agent "$REPORT_TASK_NAME"
verify_task_agent "$RIGHTSIZE_REPORT_TASK_NAME"
verify_task_agent "$BUDGET_REPORT_TASK_NAME"
verify_task_agent "$COST_OPT_TASK_NAME"
verify_task_agent "$AI_REPORT_TASK_NAME"
verify_task_agent "$RELIABILITY_REPORT_TASK_NAME"

say "Done — FinOps pack installed via the agent API."
printf '  • Package: 9 skills, 1 agent, 8 tasks, 6 Live Reports\n'
printf '  • Skills : finops-cost-anomaly-detection, finops-rightsizing-advisor, finops-cost-allocation, finops-budget-governance, finops-budget-editor, finops-cost-optimization-report, finops-for-ai, finops-cost-vs-reliability, finops-managed-scope (from marketplace %s -> %s)\n' "$MARKETPLACE_NAME" "$REPO_SLUG"
printf '  • Agent  : "%s" (standalone, autonomous, read-only; task target: "%s")\n' "$FINOPS_AGENT_NAME" "$TASK_AGENT_NAME"
printf '  • Budget planning: advisory proposals may include a human-run script; the agent and installer execute no budget writes and add no budget-write RBAC\n'
printf '  • Tasks  : "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s)\n' \
  "$TASK_NAME" "$CRON" "$RIGHTSIZE_TASK_NAME" "$RIGHTSIZE_CRON" \
  "$REPORT_TASK_NAME" "$REPORT_CRON" "$RIGHTSIZE_REPORT_TASK_NAME" "$RIGHTSIZE_REPORT_CRON" \
  "$BUDGET_REPORT_TASK_NAME" "$BUDGET_REPORT_CRON" "$COST_OPT_TASK_NAME" "$COST_OPT_CRON" \
  "$AI_REPORT_TASK_NAME" "$AI_REPORT_CRON" "$RELIABILITY_REPORT_TASK_NAME" "$RELIABILITY_REPORT_CRON"
printf '  • Live Reports "%s", "%s", "%s", "%s", "%s", and "%s" appear in Operations Hub > Live Reports (requires Live Reports enabled on the agent).\n' "$REPORT_NAME" "$RIGHTSIZE_REPORT_NAME" "$BUDGET_REPORT_NAME" "$COST_OPT_NAME" "$AI_REPORT_NAME" "$RELIABILITY_REPORT_NAME"
