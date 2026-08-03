#!/usr/bin/env bash
#
# install-api.sh — client-side installer for the FinOps package.
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
#   3. Upsert the proactive FinOps scheduled tasks       POST/PUT /api/v1/scheduledtasks
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
2. Step 1 (pull): GET Consumption UsageDetails (ActualCost) for the last 35 days via \`az rest --method get\` with \`&\$top=1000\`. Project to just the needed fields with \`--query "{value: value[].{date: properties.date, cost: properties.costInUSD, meterCategory: properties.meterCategory, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"\` and paginate every nextLink. If a request 413s, lower \$top (1000→100→20). Only if bounded pages still fail, use short usageStart date slices as a fallback; verify returned dates because the filter is not reliably applied, then de-duplicate combined rows. --query is client-side and keeps retained JSON small but does not itself prevent a server 413. nextLink in the body is HTML-escaped (&amp;) — decode before following. resourceId comes from properties.instanceName, falling back to properties.resourceId (resourceId is null in modern billing). If the pull cannot complete, keep partial rows but label downstream totals "partial — cost pull truncated".
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
6. Step 4 (cost): GET Consumption UsageDetails (ActualCost) for ~30 days via \`az rest --method get\` with \`&\$top=1000\`, projecting to just the needed fields with \`--query "{value: value[].{date: properties.date, cost: properties.costInUSD, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"\`, and paginate every nextLink. If a request 413s, lower \$top (1000→100→20). Only if bounded pages still fail, use short usageStart date slices as a fallback; verify returned dates because the filter is not reliably applied, then de-duplicate combined rows. --query is client-side and keeps retained JSON small but does not itself prevent a server 413. Aggregate costInUSD by resourceId into {resourceId: monthly_usd}. If the pull cannot complete, keep partial rows but label savings totals "partial — cost pull truncated".
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
2. Pull the data NOW, at authoring time, using read-only Azure cost commands. Use \`az rest --method get\` against Consumption UsageDetails (ActualCost) for the last 30 days with \`&\$top=1000\`, projecting to just the needed fields with \`--query "{value: value[].{date: properties.date, cost: properties.costInUSD, meterCategory: properties.meterCategory, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"\`, and paginate every nextLink. On 413 lower \$top (1000→100→20). Only if bounded pages still fail, use short usageStart date slices as a fallback; verify returned dates and de-duplicate combined rows because the filter is not reliably applied. --query is client-side and keeps retained JSON small but does not itself prevent a server 413. If the pull cannot complete, keep partial rows but label the report totals "partial — cost pull truncated". Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Read costInUSD; take the resource id from properties.instanceName, falling back to properties.resourceId (resourceId is null in modern billing).
3. Aggregate with in-sandbox Python into: (a) total spend for the window and a daily total time-series, (b) top 8 services by cost (meterCategory), (c) top 8 resource groups by cost.
4. BAKE the numbers directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${REPORT_NAME}"
   - description: one sentence noting it is a daily-refreshed snapshot of Azure cost, part of the FinOps pack, as of today's date.
5. Author a single self-contained HTML file. Follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files (use Chart.js for the daily line chart). Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is. Note near it that Azure cost data settles ~daily.

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
2. Load finops-rightsizing-advisor (read its SKILL.md) and follow its steps to produce ranked recommendations: Azure Advisor cost recs (\`az advisor recommendation list --category Cost\`); Resource Graph inventory of VMs/disks/App Service plans/Azure Container Apps (managedenvironments + containerapps; project environmentId + minReplicas) and dynamic session pools (microsoft.app/sessionpools; project readySessionInstances — these do not show in \`az resource list\` and often top the bill); per-VM "Percentage CPU" over 14 days; per-Container-App "Requests" and per-session-pool "SessionApiRequestCount" (Total, P1D) over 14 days into activity={resourceId:{requests_total,sample_days}} (flags unused ACA environments, always-on apps with no traffic, and warm session pools with no sessions); ~30 days of Consumption UsageDetails (ActualCost) via \`az rest --method get\` with \`&\$top=1000\`, minimal field projection, and complete nextLink pagination; on 413 lower \$top (1000→100→20), then use short usageStart date slices only as a fallback, verifying returned dates and de-duplicating combined rows because the filter is not reliable; if the pull cannot complete, keep partial rows but label totals "partial — cost pull truncated". Then write the skill's rightsize.py to the sandbox and run recommend_rightsizing(resources=..., utilization=..., activity=..., costs=..., advisor=...) to get the ranked list with estimated monthly savings (including any kind="review" high-spend items with no idle rule yet).
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
  "$RIGHTSIZE_REPORT_CRON" "$RIGHTSIZE_REPORT_PROMPT"

say "Upserting scheduled task '$BUDGET_REPORT_TASK_NAME'"
read -r -d '' BUDGET_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps budget-governance snapshot for Azure subscription ${SUB_ID}.

Idempotent daily refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${BUDGET_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW using the read-only \`finops-budget-governance\` skill. Read its SKILL.md and follow it: GET the native Azure budgets with \`az rest --method get --url "https://management.azure.com/subscriptions/${SUB_ID}/providers/Microsoft.Consumption/budgets?api-version=2023-05-01"\`. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Do NOT do a UsageDetails cost pull — budget status comes from the budgets GET only. If the budgets list is empty, author the report stating clearly that no budgets are defined and recommend creating one.
3. Read the skill's budget.py into the sandbox and run evaluate_budgets(budgets) to get per-budget status, forecast (Azure's forecastSpend when present, else a run-rate estimate), breached notification thresholds, portfolio summary, and the gated budgets.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${BUDGET_REPORT_NAME}"
   - description: one sentence noting it is a daily-refreshed snapshot of Azure budget status, part of the FinOps pack, as of today's date.
5. Content: the gated budgets (over / forecast-to-exceed) called out at the top as action items with their reason; a Chart.js bar chart of % used and % forecast per budget against the 100% line; and a ranked table (budget, scope, amount, spent + % used, forecast + source, status, breached thresholds). Where a forecast is run-rate (not Azure's), label it an estimate. Where a budget's current spend is 0 on a newly created budget, note it may be an unsynced value (Azure computes currentSpend asynchronously) rather than real zero spend. If no budgets are defined, show a clear empty-state recommending one be created. Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure computes budget currentSpend asynchronously so the underlying spend can lag that time.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$BUDGET_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a daily-refreshed Live Report (Operations Hub) snapshot of Azure budget governance: each budget's spend vs amount, forecast, status, and any budgets that need a decision." \
  "$BUDGET_REPORT_CRON" "$BUDGET_REPORT_PROMPT"

say "Upserting scheduled task '$COST_OPT_TASK_NAME'"
read -r -d '' COST_OPT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps executive cost-optimization rollup for Azure subscription ${SUB_ID}.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${COST_OPT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW by running the pack's four read-only analyses via the \`finops-cost-optimization-report\` skill. Read its SKILL.md and follow it — run each underlying skill and keep its structured output: (a) finops-cost-anomaly-detection -> detect_anomalies(line_items); (b) finops-rightsizing-advisor -> recommend_rightsizing(...); (c) finops-cost-allocation -> allocate_costs(costs, tags, dimension=...); (d) finops-budget-governance -> evaluate_budgets(budgets). Pull the shared cost line items ONCE and feed both anomaly detection and cost allocation. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. If any one analysis cannot run or returns nothing, keep going: the rollup treats a missing input as an empty section.
3. Read the skill's summarize.py into the sandbox and run summarize_optimization(anomalies=..., rightsizing=..., allocation=..., budgets=...) to get the executive headline, the single dollar-ranked priorities list (each item labelled with an impact_type), and per-section detail.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${COST_OPT_NAME}"
   - description: one sentence noting it is a weekly-refreshed executive cost-optimization rollup, part of the FinOps pack, as of today's date.
5. Content: an executive HEADLINE row (total monthly spend, total potential monthly savings, anomaly count, budgets over/forecast-over/at-risk, untagged spend); the TOP PRIORITIES table next (rank, category, impact + impact_type, action) as the "where to act first" list; then a section per analysis — rightsizing savings (Chart.js bar chart of top opportunities + table), anomalies (ranked table), budget status (over / forecast-over / at-risk), and governance/policy findings (untagged spend, tag hygiene, budget gates). NEVER sum savings, overruns, spikes, and governance exposure into one number — they are different kinds of dollars; label each priority by its impact_type. Mark run-rate budget forecasts and unvalidated rightsizing rows as estimates / "verify first". Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure cost data settles ~daily.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$COST_OPT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) executive rollup for Azure: potential savings, cost anomalies, budget status, and governance (policy) findings, with one prioritized action list." \
  "$COST_OPT_CRON" "$COST_OPT_PROMPT"

say "Upserting scheduled task '$AI_REPORT_TASK_NAME'"
read -r -d '' AI_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps Azure AI spend breakdown for subscription ${SUB_ID}.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${AI_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW using the read-only \`finops-for-ai\` skill. Read its SKILL.md and follow it: pull the modern Consumption UsageDetails line items with bounded \$top, minimal field projection, and complete nextLink pagination; lower \$top on 413 and use verified date slices only as a final fallback. PROJECT the extra fields consumedService + meterSubCategory + meterName (needed to classify AI spend and parse the model), then KEEP ONLY rows whose consumedService is Microsoft.CognitiveServices or Microsoft.MachineLearningServices (case-insensitive). Do NOT filter on kind or on a meter category — that would drop Foundry AIServices accounts. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write. Optionally pull each resource's kind via a Resource Graph GET to label OpenAI vs AIServices vs the ML kind.
3. Read the skill's attribute.py into the sandbox and run attribute_ai_costs(line_items=..., resource_kinds=...) to get total AI spend, the service-family split, the token-vs-compute meter split, per-resource and per-model breakdowns, top drivers, and the read-only hints.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${AI_REPORT_NAME}"
   - description: one sentence noting it is a weekly-refreshed snapshot of Azure AI spend (OpenAI + Foundry + ML), part of the FinOps pack, as of today's date.
5. Content: a HEADLINE row (total AI spend, resource count, model count, and the model-token vs compute dollar split); a Chart.js bar chart of the top models by spend; a by-model table (model, monthly \$, % of model spend, # resources); a by-resource table (resource, kind, service family, top model, monthly \$); the top cost drivers; and the hints as a "where to look first" list. NEVER sum model-token and compute dollars into a single number — they are different cost drivers. Mark PTU/commitment and compute-with-no-tokens hints as estimates / "verify first" (true idle detection needs utilization metrics). Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state (a subscription may have no AI spend — say so clearly). Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure cost data settles ~daily.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$AI_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) of Azure AI spend: total AI cost, per-model and per-resource breakdowns, a token-vs-compute split, top cost drivers, and read-only optimization hints. Covers Azure OpenAI + AI Foundry + ML." \
  "$AI_REPORT_CRON" "$AI_REPORT_PROMPT"

say "Upserting scheduled task '$RELIABILITY_REPORT_TASK_NAME'"
read -r -d '' RELIABILITY_REPORT_PROMPT <<EOF || true
Create or update a Live Report now using the \`live_report_authoring\` skill. This is an explicit request to author and SAVE a Live Report — proceed without asking any questions and do not defer it to chat.

Report: a FinOps cost-vs-reliability snapshot for Azure subscription ${SUB_ID}.

Idempotent weekly refresh — keep ONE report and version it:
1. Call ListReports. If a report named exactly "${RELIABILITY_REPORT_NAME}" already exists, call GetReport to check it out and reuse its reportId; you will pass that reportId to SaveReport (saving a new VERSION). If it does not exist, omit reportId (create it).

This is a SNAPSHOT report, not a connector-backed live report:
2. Pull the data NOW using the read-only \`finops-cost-vs-reliability\` skill. Read its SKILL.md and follow it: pull Consumption UsageDetails (ActualCost) with GET only; pull Azure Monitor alerts via GET from Microsoft.AlertsManagement/alerts; pull Resource Health availabilityStatuses via GET and keep Unavailable/Degraded; pull Advisor HighAvailability recommendations; optionally include Activity Log ResourceHealth events. Do NOT use \`az rest --method post\` or the Cost Management Query API — POST is blocked as a write.
3. Read the skill's reliability.py into the sandbox and run analyze_cost_vs_reliability(line_items=..., alerts=..., health_events=..., advisor_recommendations=...) to get totals, coverage, per-resource rankings, per-service rollups, top drivers, hints, unmatched reliability, and data quality.
4. BAKE the results directly into the HTML as static data (a JS constant / static DOM). Do NOT use window.sreagent.callTool anywhere — the report must render fully with no view-time tool calls. Call SaveReport with allowedTools set to an EMPTY list (so it saves with no connector-approval prompt).
   - name: "${RELIABILITY_REPORT_NAME}"
   - description: one sentence noting it is a weekly-refreshed snapshot comparing Azure spend and reliability pain from alerts, Resource Health, and Advisor, part of the FinOps pack, as of today's date.
5. Content: a HEADLINE row (total monthly spend, resource count, reliability signal count, joined/unmatched coverage, and partial-cost warning if applicable); a Chart.js bar chart of the top resources by reliability score with monthly cost in the tooltip; a "Spend + pain" table (resource, service, monthly \$, alert/severity counts, health events, Advisor HA count, reliability score, pain per \$1K, risk band, primary signal); a service rollup; a "High pain / low spend" investment-candidates section; a "High spend / no pain — verify before cutting" section; and a data-quality section for unmatched or subscription-level signals and disclosed limitations. Single self-contained HTML file; follow the skill's CSP/nonce rules and copy the exact SRI library tags from the reference files. Light mode. Wrap every render block defensively with a small empty-state. Render a visible "Last refreshed: <UTC date-time> UTC" line in the report header — compute the current UTC timestamp in the sandbox at author time (e.g. Python datetime.now(timezone.utc)) and BAKE it in as static text so a viewer can always see how fresh the data is; note near it that Azure cost data settles ~daily and alerts are weighted counts, not a complete incident system.

Read-only Azure only. Do not use any write/POST Azure operations. When done, confirm the saved report id and version number.
EOF
upsert_task "$RELIABILITY_REPORT_TASK_NAME" \
  "Part of the FinOps pack — a weekly-refreshed Live Report (Operations Hub) comparing Azure spend with reliability pain from alerts, Resource Health, and Advisor HighAvailability; ranks resources/services, investment candidates, and verify-before-cutting candidates." \
  "$RELIABILITY_REPORT_CRON" "$RELIABILITY_REPORT_PROMPT"

# ---- 5. Verify --------------------------------------------------------------
say "Verifying"
api GET /api/v2/plugins/installations; resp="$RESP_BODY"
printf '%s' "$resp" | grep -qi "$PLUGIN_NAME" && ok "plugin installation present" || warn "plugin not visible yet (install may still be finishing)"
api GET /api/v1/scheduledtasks; resp="$RESP_BODY"
printf '%s' "$resp" | grep -qi "Cost Anomaly Detection" && ok "daily anomaly task present"   || warn "anomaly task not visible"
printf '%s' "$resp" | grep -qi "Rightsizing Review"     && ok "weekly rightsizing task present" || warn "rightsizing task not visible"
printf '%s' "$resp" | grep -qi "Cost Overview"          && ok "daily live-report task present"  || warn "live-report task not visible"
printf '%s' "$resp" | grep -qi "Rightsizing Savings"    && ok "weekly rightsizing live-report task present" || warn "rightsizing live-report task not visible"
printf '%s' "$resp" | grep -qi "Budget Status"          && ok "daily budget live-report task present" || warn "budget live-report task not visible"
printf '%s' "$resp" | grep -qi "Cost Optimization"      && ok "weekly cost-optimization live-report task present" || warn "cost-optimization live-report task not visible"
printf '%s' "$resp" | grep -qi "AI Spend"               && ok "weekly AI-spend live-report task present" || warn "AI-spend live-report task not visible"
printf '%s' "$resp" | grep -qi "Cost vs Reliability"    && ok "weekly cost-vs-reliability live-report task present" || warn "cost-vs-reliability live-report task not visible"

say "Done — FinOps pack installed via the agent API."
printf '  • Package: 8 skills, 8 tasks, 6 Live Reports\n'
printf '  • Skills : finops-cost-anomaly-detection, finops-rightsizing-advisor, finops-cost-allocation, finops-budget-governance, finops-budget-editor, finops-cost-optimization-report, finops-for-ai, finops-cost-vs-reliability (from marketplace %s -> %s)\n' "$MARKETPLACE_NAME" "$REPO_SLUG"
printf '  • Tasks  : "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s); "%s" (%s)\n' \
  "$TASK_NAME" "$CRON" "$RIGHTSIZE_TASK_NAME" "$RIGHTSIZE_CRON" \
  "$REPORT_TASK_NAME" "$REPORT_CRON" "$RIGHTSIZE_REPORT_TASK_NAME" "$RIGHTSIZE_REPORT_CRON" \
  "$BUDGET_REPORT_TASK_NAME" "$BUDGET_REPORT_CRON" "$COST_OPT_TASK_NAME" "$COST_OPT_CRON" \
  "$AI_REPORT_TASK_NAME" "$AI_REPORT_CRON" "$RELIABILITY_REPORT_TASK_NAME" "$RELIABILITY_REPORT_CRON"
printf '  • Live Reports "%s", "%s", "%s", "%s", "%s", and "%s" appear in Operations Hub > Live Reports (requires Live Reports enabled on the agent).\n' "$REPORT_NAME" "$RIGHTSIZE_REPORT_NAME" "$BUDGET_REPORT_NAME" "$COST_OPT_NAME" "$AI_REPORT_NAME" "$RELIABILITY_REPORT_NAME"
