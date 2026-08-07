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
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

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

AGENT_NAME="${AGENT_NAME:-}"                       # compatibility alias for TASK_AGENT_NAME
TASK_AGENT_NAME="${TASK_AGENT_NAME:-${AGENT_NAME:-$FINOPS_AGENT_NAME}}"
SUB_ID_WAS_SET="${SUB_ID+x}"
MODEL_TIER="${MODEL_TIER:-ReasoningHeavy}"         # canonical default for task-specific tiers
ALERT_EMAIL="${ALERT_EMAIL:-}"                    # optional; unset keeps results in the task run only
GITHUB_REPO="${GITHUB_REPO:-}"                    # optional owner/repo for change correlation
MI_OBJECT_ID="${MI_OBJECT_ID:-}"                 # agent MI objectId; set to auto-grant Cost Management Reader
TASK_RENDERER="$SCRIPT_DIR/scheduled-tasks/render_tasks.py"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. Preflight -----------------------------------------------------------
say "Preflight"
command -v az     >/dev/null 2>&1 || die "az (Azure CLI) not found."
command -v curl   >/dev/null 2>&1 || die "curl not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."
command -v mktemp >/dev/null 2>&1 || die "mktemp not found."
az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' first."
[ -f "$FINOPS_AGENT_MANIFEST" ] || die "Agent manifest not found: $FINOPS_AGENT_MANIFEST"
[ -f "$TASK_RENDERER" ] || die "Scheduled-task renderer not found: $TASK_RENDERER"
python3 "$TASK_RENDERER" check || \
  die "Scheduled-task references drifted from the canonical manifest/prompts."
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
export AGENT_RESOURCE_ID TASK_AGENT_NAME MODEL_TIER ALERT_EMAIL GITHUB_REPO

if [ -z "$GITHUB_REPO" ]; then
  warn "GITHUB_REPO not set — scheduled anomaly detection will skip GitHub correlation."
fi
if [ -z "$ALERT_EMAIL" ]; then
  warn "ALERT_EMAIL not set — scheduled findings will remain in task results and no email will be sent."
fi

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "$TEMP_ROOT" 2>/dev/null && pwd -P)" || \
  die "Temporary directory is unavailable: ${TMPDIR:-/tmp}"
case "$TEMP_ROOT" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) TEMP_ROOT="$(cd /tmp && pwd -P)";;
esac
INSTALL_WORK_DIR="$(mktemp -d "$TEMP_ROOT/finops-install.XXXXXXXX")" || \
  die "Could not create secure installer work directory."
chmod 700 "$INSTALL_WORK_DIR" || die "Could not secure installer work directory."
trap 'rm -rf -- "$INSTALL_WORK_DIR"' EXIT

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
  local out
  out="$(curl "${args[@]}" "$ENDPOINT$path")" || return
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
mk_body="$INSTALL_WORK_DIR/marketplace.json"
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
if api POST /api/v2/plugins/marketplaces "$mk_body"; then
  resp="$RESP_BODY"
else
  rm -f -- "$mk_body"
  die "Marketplace register request failed before receiving an HTTP response."
fi
rm -f -- "$mk_body"
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
    "finops-report-renderer",
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
    ok "All ten FinOps skills ready"
    break
  fi
  printf '  … skills not ready (%d/60)\n' "$i"
  sleep 2
  [ "$i" -eq 60 ] && die "Timed out waiting for all ten FinOps skills."
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

agent_body="$INSTALL_WORK_DIR/agent.json"
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
    "finops-report-renderer",
}
configured_skills = properties.get("allowedSkills")
if not isinstance(configured_skills, list) or not required_skills <= set(configured_skills):
    raise SystemExit(
        "Managed-scope safety error: properties.allowedSkills must include all "
        "ten FinOps skills."
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
  200) printf '%s' "$RESP_BODY" > "$INSTALL_WORK_DIR/scheduled-tasks-before.json";;
  *) die "Could not list scheduled tasks (HTTP $HTTP_CODE): $RESP_BODY";;
esac

python3 "$TASK_RENDERER" install-plan \
  --existing "$INSTALL_WORK_DIR/scheduled-tasks-before.json" \
  --output-dir "$INSTALL_WORK_DIR" || \
  die "Could not build the scheduled-task install plan."

while IFS=$'\x1f' read -r retired_id retired_name; do
  [ -n "$retired_id" ] || continue
  say "Retiring merged scheduled task '$retired_name'"
  api DELETE "/api/v1/scheduledtasks/${retired_id}"
  case "$HTTP_CODE" in
    200|204) ok "Retired duplicate scheduled task: $retired_name";;
    *) die "Retired task delete failed (HTTP $HTTP_CODE): $RESP_BODY";;
  esac
done < "$INSTALL_WORK_DIR/retired-plan.tsv"

# upsert_task BODY NAME AGENT CRON ID CURRENT_AGENT STATUS
TASK_SUMMARY=()
upsert_task() {
  local body="$1" name="$2" payload_agent="$3" cron="$4"
  local task_id="$5" current_agent="$6" current_status="$7"
  [ "$payload_agent" = "$TASK_AGENT_NAME" ] || \
    die "Rendered task '$name' targets unexpected agent '$payload_agent'."

  # The v1 scheduled-task PUT contract cannot change Agent. Replace once when the
  # target differs; later installer runs return to ordinary in-place updates.
  if [ -n "$task_id" ] && [ "$current_agent" != "$TASK_AGENT_NAME" ]; then
    warn "Replacing scheduled task '$name' to change agent '$current_agent' -> '$TASK_AGENT_NAME'"
    api DELETE "/api/v1/scheduledtasks/${task_id}"
    case "$HTTP_CODE" in
      200|204) task_id="";;
      *) die "Task replacement delete failed (HTTP $HTTP_CODE): $RESP_BODY";;
    esac
  fi

  if [ -n "$task_id" ]; then
    api PUT "/api/v1/scheduledtasks/${task_id}" "$body"
    case "$HTTP_CODE" in
      200|201|204) ok "Scheduled task updated: $name ($task_id)";;
      *) die "Task update failed (HTTP $HTTP_CODE): $RESP_BODY";;
    esac
  else
    api POST /api/v1/scheduledtasks "$body"
    case "$HTTP_CODE" in
      200|201)
        local created_id
        created_id="$(printf '%s' "$RESP_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("taskId",""))' 2>/dev/null || true)"
        case "$current_status" in
          paused|Paused|PAUSED)
            if [ -n "$created_id" ]; then
              api POST "/api/v1/scheduledtasks/${created_id}/pause"
              case "$HTTP_CODE" in
                200|204) ok "Scheduled task recreated and paused: $name";;
                *) die "Task recreated but pause restore failed (HTTP $HTTP_CODE): $RESP_BODY";;
              esac
            else
              ok "Scheduled task created: $name"
            fi
            ;;
          *) ok "Scheduled task created: $name";;
        esac
        ;;
      *) die "Task create failed (HTTP $HTTP_CODE): $RESP_BODY";;
    esac
  fi
  TASK_SUMMARY+=("$name"$'\t'"$cron")
}

task_index=0
while IFS=$'\x1f' read -r body_name name payload_agent cron task_id current_agent current_status; do
  [ -n "$body_name" ] || continue
  task_index=$((task_index + 1))
  task_body="$INSTALL_WORK_DIR/$body_name"
  say "Upserting scheduled task '$name'"
  upsert_task "$task_body" "$name" "$payload_agent" "$cron" \
    "$task_id" "$current_agent" "$current_status"
done < "$INSTALL_WORK_DIR/task-plan.tsv"
[ "$task_index" -eq 7 ] || die "Canonical task renderer produced $task_index tasks; expected 7."

LIVE_REPORT_NAMES=()
while IFS= read -r report_name; do
  [ -n "$report_name" ] && LIVE_REPORT_NAMES+=("$report_name")
done < "$INSTALL_WORK_DIR/reports.txt"

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
api GET /api/v1/scheduledtasks
case "$HTTP_CODE" in
  200) printf '%s' "$RESP_BODY" > "$INSTALL_WORK_DIR/scheduled-tasks-after.json";;
  *) die "Could not verify scheduled tasks (HTTP $HTTP_CODE): $RESP_BODY";;
esac
python3 "$TASK_RENDERER" verify-install \
  --existing "$INSTALL_WORK_DIR/scheduled-tasks-after.json" \
  --expected "$INSTALL_WORK_DIR/expected-tasks.json" || \
  die "Scheduled-task verification failed."
ok "all 7 scheduled tasks verified on $TASK_AGENT_NAME; retired duplicate absent"

say "Done — FinOps pack installed via the agent API."
printf '  • Package: 10 skills, 1 agent, 7 tasks, 6 Live Reports\n'
printf '  • Skills : finops-cost-anomaly-detection, finops-rightsizing-advisor, finops-cost-allocation, finops-budget-governance, finops-budget-editor, finops-cost-optimization-report, finops-for-ai, finops-cost-vs-reliability, finops-managed-scope, finops-report-renderer (from marketplace %s -> %s)\n' "$MARKETPLACE_NAME" "$REPO_SLUG"
printf '  • Agent  : "%s" (standalone, autonomous, read-only; task target: "%s")\n' "$FINOPS_AGENT_NAME" "$TASK_AGENT_NAME"
printf '  • Budget planning: advisory proposals may include a human-run script; the agent and installer execute no budget writes and add no budget-write RBAC\n'
printf '  • Tasks  :\n'
for task_entry in "${TASK_SUMMARY[@]}"; do
  IFS=$'\t' read -r task_name task_cron <<< "$task_entry"
  printf '      - "%s" (%s)\n' "$task_name" "$task_cron"
done
printf '  • Live Reports:\n'
for report_name in "${LIVE_REPORT_NAMES[@]}"; do
  printf '      - "%s"\n' "$report_name"
done
printf '    (appear in Operations Hub > Live Reports when enabled on the agent)\n'
