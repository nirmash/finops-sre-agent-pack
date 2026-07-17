#!/usr/bin/env bash
#
# install-api.sh — client-side installer for the FinOps cost-anomaly package.
#
# Installs EVERYTHING via the SRE Agent's own management API — no srectl, no .NET,
# no private NuGet feed. It does exactly what srectl does under the hood:
#   * gets an AAD token for the SRE Agent first-party scope (https://azuresre.dev/.default)
#   * calls the agent's data-plane endpoint (RBAC-guarded by AuthorizeArmOperation)
#
# It performs three control-plane operations:
#   1. Register this repo as a plugin marketplace         POST /api/v2/plugins/marketplaces
#   2. Install the `finops` plugin (server clones + copies POST .../plugins/finops/install
#      the whole skill dir: SKILL.md + detect.py)
#   3. Upsert the daily "Cost Anomaly Detection" task     POST/PUT /api/v1/scheduledtasks
#
# Caller identity (az login) must hold the agent's ARM write actions
# (AgentExtendedAgentWrite, AgentScheduledTaskWrite) — the resource owner does.
#
# Requires: az (logged in), curl, python3.
#
# Usage:
#   AGENT_RESOURCE_ID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/agents/<name> \
#     ./install-api.sh
#   # or pass the endpoint directly:
#   ENDPOINT=https://<agent>.azuresre.ai ./install-api.sh
#   # private repo clone (until the repo is public) needs a GitHub PAT:
#   GITHUB_PAT=<pat> AGENT_RESOURCE_ID=<id> ./install-api.sh
#
set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
AGENT_RESOURCE_ID="${AGENT_RESOURCE_ID:-}"       # ARM id; endpoint is derived from it
ENDPOINT="${ENDPOINT:-}"                          # or pass the data-plane URL directly
TOKEN_RESOURCE="${TOKEN_RESOURCE:-https://azuresre.dev}"

MARKETPLACE_NAME="${MARKETPLACE_NAME:-finops-pack}"
PLUGIN_NAME="${PLUGIN_NAME:-finops}"
SKILL_NAME="${SKILL_NAME:-finops-cost-anomaly-detection}"
REPO_SLUG="${REPO_SLUG:-nirmash/finops-sre-agent-pack}"   # owner/repo (marketplace sourceUrl)
SOURCE_FORMAT="${SOURCE_FORMAT:-copilot}"
GITHUB_PAT="${GITHUB_PAT:-}"                      # set for a private repo; else host-default identity

TASK_NAME="${TASK_NAME:-FinOps: Cost Anomaly Detection (Daily)}"
RIGHTSIZE_TASK_NAME="${RIGHTSIZE_TASK_NAME:-FinOps: Rightsizing Review (Weekly)}"
REPORT_TASK_NAME="${REPORT_TASK_NAME:-FinOps: Cost Overview (Live Report, Daily)}"
RIGHTSIZE_REPORT_TASK_NAME="${RIGHTSIZE_REPORT_TASK_NAME:-FinOps: Rightsizing Savings (Live Report, Weekly)}"
AGENT_NAME="${AGENT_NAME:-Nir Mashkowski}"
SUB_ID="${SUB_ID:-93cba93f-571e-44e9-ac0a-a2987b58848c}"
CRON="${CRON:-0 14 * * *}"                         # daily anomaly scan (14:00 UTC)
RIGHTSIZE_CRON="${RIGHTSIZE_CRON:-0 15 * * 1}"     # weekly rightsizing review (Mon 15:00 UTC)
REPORT_CRON="${REPORT_CRON:-0 14 * * *}"           # daily live-report refresh (14:00 UTC)
REPORT_NAME="${REPORT_NAME:-FinOps: Cost Overview}" # the Live Report's display name (kept stable so daily runs version the same report)
RIGHTSIZE_REPORT_CRON="${RIGHTSIZE_REPORT_CRON:-0 15 * * 1}"  # weekly rightsizing live-report refresh (Mon 15:00 UTC)
RIGHTSIZE_REPORT_NAME="${RIGHTSIZE_REPORT_NAME:-FinOps: Rightsizing Savings}" # display name; kept stable so weekly runs version the same report
ALERT_EMAIL="${ALERT_EMAIL:-nimashkowski@microsoft.com}"
GITHUB_REPO="${GITHUB_REPO:-nirmash/azure-sre-agent-sandbox}"   # repo searched for change correlation
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

if [ -z "$ENDPOINT" ]; then
  [ -n "$AGENT_RESOURCE_ID" ] || die "Set ENDPOINT or AGENT_RESOURCE_ID."
  say "Resolving agent endpoint from resource id"
  ENDPOINT="$(az resource show --ids "$AGENT_RESOURCE_ID" --query properties.agentEndpoint -o tsv)"
  [ -n "$ENDPOINT" ] || die "Could not read properties.agentEndpoint from $AGENT_RESOURCE_ID"
fi
ENDPOINT="${ENDPOINT%/}"
ok "Endpoint: $ENDPOINT"

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

# ---- 1. RBAC (optional) -----------------------------------------------------
say "Cost Management Reader RBAC"
if [ -n "$MI_OBJECT_ID" ]; then
  if az role assignment create --assignee-object-id "$MI_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "Cost Management Reader" --scope "/subscriptions/${SUB_ID}" >/dev/null 2>&1; then
    ok "Granted Cost Management Reader to $MI_OBJECT_ID"
  else
    warn "Grant not applied (already assigned, or you can't assign roles here)."
  fi
else
  warn "MI_OBJECT_ID not set — skipping grant. The skill needs Cost Management Reader on the"
  warn "agent MI or costInUSD is null. Grant it once with:"
  printf '      az role assignment create --assignee <AGENT_MI_OBJECT_ID> \\\n'
  printf '        --role "Cost Management Reader" --scope /subscriptions/%s\n' "$SUB_ID"
fi

# ---- 2. Register the marketplace -------------------------------------------
say "Registering marketplace '$MARKETPLACE_NAME' -> $REPO_SLUG"
mk_body="$(mktemp)"; trap 'rm -f "$mk_body" "${task_body:-}"' EXIT
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

# ---- 4. Upsert the scheduled tasks -----------------------------------------
# upsert_task NAME DESCRIPTION CRON PROMPT — POST new / PUT existing by name.
upsert_task() {
  local name="$1" description="$2" cron="$3" prompt="$4"

  api GET /api/v1/scheduledtasks; local existing="$RESP_BODY"
  local task_id
  task_id="$(printf '%s' "$existing" | TASK_NAME="$name" python3 -c '
import json,os,sys
name=os.environ["TASK_NAME"]
try: data=json.load(sys.stdin)
except Exception: data=[]
tasks=data if isinstance(data,list) else data.get("value",[])
print(next((t.get("id","") for t in tasks if t.get("name")==name), ""))' 2>/dev/null || true)"

  local body; body="$(mktemp)"
  TASK_NAME="$name" TASK_DESC="$description" CRON="$cron" AGENT_NAME="$AGENT_NAME" PROMPT="$prompt" \
    python3 - "$body" <<'PY'
import json, os, sys
doc = {
    "name": os.environ["TASK_NAME"],
    "description": os.environ["TASK_DESC"],
    "cronExpression": os.environ["CRON"],
    "agentPrompt": os.environ["PROMPT"],
    "agent": os.environ["AGENT_NAME"],
    "agentMode": "autonomous",
}
open(sys.argv[1], "w").write(json.dumps(doc))
PY

  if [ -n "$task_id" ]; then
    api PUT "/api/v1/scheduledtasks/${task_id}" "$body"
    case "$HTTP_CODE" in 200|201|204) ok "Scheduled task updated: $name ($task_id)";; *) rm -f "$body"; die "Task update failed (HTTP $HTTP_CODE): $RESP_BODY";; esac
  else
    api POST /api/v1/scheduledtasks "$body"
    case "$HTTP_CODE" in 200|201) ok "Scheduled task created: $name";; *) rm -f "$body"; die "Task create failed (HTTP $HTTP_CODE): $RESP_BODY";; esac
  fi
  rm -f "$body"
}

say "Upserting scheduled task '$TASK_NAME'"
read -r -d '' ANOMALY_PROMPT <<EOF || true
Run the \`finops-cost-anomaly-detection\` skill for subscription ${SUB_ID}. Read-only. Follow the skill's procedure exactly:

1. Load the skill — read its SKILL.md so you use the bundled detector and steps.
2. Step 1 (pull): GET Consumption UsageDetails (ActualCost) for the last 35 days via \`az rest --method get\`, paginate nextLink, and flatten each row to {date, cost, meterCategory, resourceGroup, resourceId, tags} (resourceId from properties.instanceName, falling back to properties.resourceId — resourceId is null in modern billing).
3. Step 2 (detect): write the skill's embedded detect.py to the sandbox and run detect_anomalies(line_items) with defaults (baseline_days=28, k=3.0, min_delta_usd=5.0, wow_ratio=1.5). Keep assume_last_partial=True so the partial newest billing day is excluded.
4. Step 3 (correlate): for EACH anomaly, search az subscription/resource-group deployments, activity-log write ops, and GitHub commits + merged PRs (repo ${GITHUB_REPO}) within +/-1 day of the spike date, and attach the most likely cause.
5. Step 4 (report):
   - If NO anomalies are detected, reply with a single line "No cost anomalies detected for <date>." and stop. Do not email.
   - If one or more anomalies ARE detected, produce a ranked table (dimension, value, kind, current_usd, baseline_mean_usd, dod_delta_usd, %change, candidate cause) and email the report to ${ALERT_EMAIL} with subject "Cost anomaly detected — <date>" and High importance.

Read-only only. Do not use any write/POST Azure operations.
EOF
upsert_task "$TASK_NAME" \
  "Part of the FinOps pack — installed with the finops-cost-anomaly-detection skill. Proactive daily cost-anomaly scan; reports only when a spike is detected." \
  "$CRON" "$ANOMALY_PROMPT"

say "Upserting scheduled task '$RIGHTSIZE_TASK_NAME'"
read -r -d '' RIGHTSIZE_PROMPT <<EOF || true
Run the \`finops-rightsizing-advisor\` skill for subscription ${SUB_ID}. Read-only. Follow the skill's procedure exactly:

1. Load the skill — read its SKILL.md so you use the bundled rightsize.py and steps.
2. Step 1 (Advisor): \`az advisor recommendation list --category Cost\` and flatten to {resourceId, problem, recommendation, targetSku, savingsUsd}.
3. Step 2 (inventory): \`az graph query\` for VMs, disks, App Service plans, Azure Container Apps (managedenvironments + containerapps), and dynamic session pools (microsoft.app/sessionpools); flatten to {resourceId, type, sku, powerState, diskState, numberOfSites, environmentId, minReplicas, readySessionInstances, tags}. Note session pools do NOT appear in \`az resource list\` — only \`az graph query\` returns them, and they are often the largest line items.
4. Step 3 (utilization): for each VM candidate, \`az monitor metrics list\` "Percentage CPU" over 14 days; reduce to {cpu_p95, cpu_avg, mem_p95, sample_days}.
5. Step 3b (activity): for each Container App, \`az monitor metrics list\` "Requests" (Total, P1D) over 14 days; for each session pool, "SessionApiRequestCount" (Total, P1D) over 14 days (retry once or twice — the sessionPools metric namespace is flaky). Reduce to {resourceId: {requests_total, sample_days}} — this flags unused ACA environments, always-on apps with no traffic, and warm session pools with no sessions.
6. Step 4 (cost): GET Consumption UsageDetails (ActualCost) for ~30 days via \`az rest --method get\`, paginate nextLink, aggregate costInUSD by resourceId into {resourceId: monthly_usd}.
7. Step 5 (rank): write the skill's rightsize.py to the sandbox and run recommend_rightsizing(resources=..., utilization=..., activity=..., costs=..., advisor=...).
8. Step 6 (report):
   - If NOTHING clears the savings threshold, reply with a single line "No rightsizing opportunities above threshold this week." and stop. Do not email.
   - Otherwise produce a ranked table (resource, type, kind, current SKU, recommended action, current monthly \$, est monthly savings \$, validated, evidence) with the TOTAL estimated monthly savings at the top, mark validated=false / unvalidated rows as "verify first", and email the report to ${ALERT_EMAIL} with subject "Weekly rightsizing review — <date>" and Normal importance.

Recommend only. Read-only. Do not use any write/POST Azure operations.
EOF
upsert_task "$RIGHTSIZE_TASK_NAME" \
  "Part of the FinOps pack — installed with the finops-rightsizing-advisor skill. Weekly read-only rightsizing / idle-resource review; reports ranked savings opportunities." \
  "$RIGHTSIZE_CRON" "$RIGHTSIZE_PROMPT"

say "Upserting scheduled task '$REPORT_TASK_NAME'"
read -r -d '' REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps cost overview snapshot for Azure subscription ${SUB_ID}.

Idempotent daily refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW, at authoring time, using read-only Azure cost commands. Use \`az rest --method get\` against Consumption UsageDetails (ActualCost) for the last 30 days and paginate nextLink. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Read costInUSD; take the resource id from properties.instanceName, falling back to properties.resourceId (resourceId is null in modern billing).
3. Aggregate with in-sandbox Python into: (a) total spend for the window and a daily total time-series, (b) top 8 services by cost (meterCategory), (c) top 8 resource groups by cost.
4. BAKE the numbers directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${REPORT_NAME}"
   - description: one sentence noting it is a daily-refreshed snapshot of Azure cost, part of the FinOps pack, as of today's date.
5. Author a single self-contained HTML file. Follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files (use Chart.js for the daily line chart). Light mode. Wrap every render block defensively with a small empty-state.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$REPORT_TASK_NAME" \
  "Part of the FinOps pack — a daily-refreshed Live Report (Operations Hub) snapshot of Azure cost: total, daily trend, top services, and top resource groups." \
  "$REPORT_CRON" "$REPORT_PROMPT"

say "Upserting scheduled task '$RIGHTSIZE_REPORT_TASK_NAME'"
read -r -d '' RIGHTSIZE_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps rightsizing / savings snapshot for Azure subscription ${SUB_ID}.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${RIGHTSIZE_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

Gather the data NOW by running the \`finops-rightsizing-advisor\` skill's analysis (read-only):
2. Load finops-rightsizing-advisor (read its SKILL.md) and follow its steps to produce ranked recommendations: Azure Advisor cost recs (\`az advisor recommendation list --category Cost\`); Resource Graph inventory of VMs/disks/App Service plans/Azure Container Apps (managedenvironments + containerapps; project environmentId + minReplicas) and dynamic session pools (microsoft.app/sessionpools; project readySessionInstances — these do not show in \`az resource list\` and often top the bill); per-VM "Percentage CPU" over 14 days; per-Container-App "Requests" and per-session-pool "SessionApiRequestCount" (Total, P1D) over 14 days into activity={resourceId:{requests_total,sample_days}} (flags unused ACA environments, always-on apps with no traffic, and warm session pools with no sessions); ~30 days of Consumption UsageDetails (ActualCost) via \`az rest --method get\` (paginate nextLink; costInUSD; resource id from properties.instanceName falling back to properties.resourceId). Then write the skill's rightsize.py to the sandbox and run recommend_rightsizing(resources=..., utilization=..., activity=..., costs=..., advisor=...) to get the ranked list with estimated monthly savings (including any kind="review" high-spend items with no idle rule yet).
3. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write.

This is a SNAPSHOT report, not a connector-backed live report:
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${RIGHTSIZE_REPORT_NAME}"
   - description: one sentence noting it is a weekly-refreshed rightsizing / idle-resource savings snapshot, part of the FinOps pack, as of today's date.
5. Content: a headline TOTAL estimated monthly savings; a Chart.js bar chart of the top savings opportunities; and a ranked table (resource, type, kind [idle/oversized/advisor], current SKU, recommended action, current monthly \$, est monthly savings \$, validated). Mark validated=false / unvalidated rows as "verify first". Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state.

Recommend only. Read-only Azure. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$RIGHTSIZE_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) of rightsizing / idle-resource savings: total potential savings, a top-opportunities chart, and a ranked recommendations table." \
  "$RIGHTSIZE_REPORT_CRON" "$RIGHTSIZE_REPORT_PROMPT"

# ---- 5. Verify --------------------------------------------------------------
say "Verifying"
api GET /api/v2/plugins/installations; resp="$RESP_BODY"
printf '%s' "$resp" | grep -qi "$PLUGIN_NAME" && ok "plugin installation present" || warn "plugin not visible yet (install may still be finishing)"
api GET /api/v1/scheduledtasks; resp="$RESP_BODY"
printf '%s' "$resp" | grep -qi "Cost Anomaly Detection" && ok "daily anomaly task present"   || warn "anomaly task not visible"
printf '%s' "$resp" | grep -qi "Rightsizing Review"     && ok "weekly rightsizing task present" || warn "rightsizing task not visible"
printf '%s' "$resp" | grep -qi "Cost Overview"          && ok "daily live-report task present"  || warn "live-report task not visible"
printf '%s' "$resp" | grep -qi "Rightsizing Savings"    && ok "weekly rightsizing live-report task present" || warn "rightsizing live-report task not visible"

say "Done — FinOps pack installed via the agent API."
printf '  • Skills : finops-cost-anomaly-detection, finops-rightsizing-advisor (from marketplace %s -> %s)\n' "$MARKETPLACE_NAME" "$REPO_SLUG"
printf '  • Tasks  : "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s)\n' \
  "$TASK_NAME" "$CRON" "$RIGHTSIZE_TASK_NAME" "$RIGHTSIZE_CRON" \
  "$REPORT_TASK_NAME" "$REPORT_CRON" "$RIGHTSIZE_REPORT_TASK_NAME" "$RIGHTSIZE_REPORT_CRON"
printf '  • Live Reports "%s" and "%s" appear in Operations Hub > Live Reports (requires Live Reports enabled on the agent).\n' "$REPORT_NAME" "$RIGHTSIZE_REPORT_NAME"
