#!/usr/bin/env bash
#
# install.sh — one-shot installer for the FinOps pack.
#
# Installs EVERYTHING the pack needs onto an SRE Agent:
#   1. (optional) the Cost Management Reader RBAC grant on the agent's managed identity
#   2. the skills: `finops-cost-anomaly-detection`, `finops-rightsizing-advisor`
#   3. the proactive scheduled tasks:
#        - "FinOps: Cost Anomaly Detection (Daily)"
#        - "FinOps: Rightsizing Review (Weekly)"
#
# Requires `srectl` (pointed at your agent) and `az` (logged in). Re-running is safe:
# skill apply and scheduledtask apply both upsert by name.
#
# Usage:
#   ./install.sh                        # uses the defaults below
#   AGENT_NAME="My Agent" SUB_ID=<sub> DAILY_CRON="0 14 * * *" ./install.sh
#   MI_OBJECT_ID=<mi-object-id> ./install.sh   # also performs the RBAC grant
#
set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
AGENT_NAME="${AGENT_NAME:-Nir Mashkowski}"
SUB_ID="${SUB_ID:-93cba93f-571e-44e9-ac0a-a2987b58848c}"
DAILY_CRON="${DAILY_CRON:-${CRON:-0 14 * * *}}"  # daily 14:00 UTC (CRON kept for back-compat)
WEEKLY_CRON="${WEEKLY_CRON:-0 15 * * 1}"         # Mondays 15:00 UTC
REPORT_CRON="${REPORT_CRON:-0 14 * * *}"         # daily live-report refresh 14:00 UTC
RIGHTSIZE_REPORT_CRON="${RIGHTSIZE_REPORT_CRON:-0 15 * * 1}"  # weekly rightsizing live-report refresh Mon 15:00 UTC
ALERT_EMAIL="${ALERT_EMAIL:-nimashkowski@microsoft.com}"
GITHUB_REPO="${GITHUB_REPO:-nirmash/azure-sre-agent-sandbox}"
MI_OBJECT_ID="${MI_OBJECT_ID:-}"                 # agent managed identity objectId; set to auto-grant RBAC
RESOURCE_URL="${RESOURCE_URL:-}"                 # if set, runs `srectl init` against this endpoint first

SKILL_NAMES=("finops-cost-anomaly-detection" "finops-rightsizing-advisor")
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAILY_TEMPLATE="${PLUGIN_DIR}/scheduled-tasks/cost-anomaly-daily.yaml"
WEEKLY_TEMPLATE="${PLUGIN_DIR}/scheduled-tasks/rightsizing-weekly.yaml"
REPORT_TEMPLATE="${PLUGIN_DIR}/scheduled-tasks/cost-overview-report-daily.yaml"
RIGHTSIZE_REPORT_TEMPLATE="${PLUGIN_DIR}/scheduled-tasks/rightsizing-savings-report-weekly.yaml"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. Preflight -----------------------------------------------------------
say "Preflight checks"
command -v srectl >/dev/null 2>&1 || die "srectl not found. Build it from Agent.Cli (see plugin README) or install the CLI."
command -v az     >/dev/null 2>&1 || die "az (Azure CLI) not found."
az account show >/dev/null 2>&1   || die "Not logged in to Azure. Run 'az login' first."
[ -f "$DAILY_TEMPLATE" ]          || die "Task template not found: $DAILY_TEMPLATE"
[ -f "$WEEKLY_TEMPLATE" ]         || die "Task template not found: $WEEKLY_TEMPLATE"
ok "srectl and az present; Azure session active"

if [ -n "$RESOURCE_URL" ]; then
  say "Pointing srectl at $RESOURCE_URL"
  srectl init --resource-url "$RESOURCE_URL" || warn "srectl init returned non-zero (already initialized?)"
fi

# ---- 1. RBAC (Cost Management Reader) --------------------------------------
say "Cost Management Reader RBAC"
if [ -n "$MI_OBJECT_ID" ]; then
  if az role assignment create \
        --assignee-object-id "$MI_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "Cost Management Reader" \
        --scope "/subscriptions/${SUB_ID}" >/dev/null 2>&1; then
    ok "Granted Cost Management Reader to $MI_OBJECT_ID on subscription $SUB_ID"
  else
    warn "Grant not applied (likely already assigned, or you lack permission to assign roles)."
  fi
else
  warn "MI_OBJECT_ID not set — skipping automatic grant."
  warn "The skills need Cost Management Reader on the agent's managed identity, or costInUSD is null:"
  printf '      az role assignment create --assignee <AGENT_MI_OBJECT_ID> \\\n'
  printf '        --role "Cost Management Reader" --scope /subscriptions/%s\n' "$SUB_ID"
fi

# ---- 2. Install the skills --------------------------------------------------
# `srectl skill apply --name` discovers ./skills/<name> recursively from the CWD,
# so run from the plugin dir where skills/<name>/ lives.
for skill in "${SKILL_NAMES[@]}"; do
  say "Installing skill '$skill'"
  ( cd "$PLUGIN_DIR" && srectl skill apply --name "$skill" ) || die "Skill apply failed: $skill"
  ok "Skill '$skill' applied"
done

# ---- 3. Apply the proactive scheduled tasks --------------------------------
apply_task() {
  local template="$1" cron="$2" label="$3"
  say "Applying scheduled task '$label'"
  local rendered; rendered="$(mktemp -t finops-task.XXXXXX.yaml)"
  sed -e "s|__AGENT_NAME__|${AGENT_NAME}|g" \
      -e "s|__SUB_ID__|${SUB_ID}|g" \
      -e "s|__CRON__|${cron}|g" \
      -e "s|__ALERT_EMAIL__|${ALERT_EMAIL}|g" \
      -e "s|__GITHUB_REPO__|${GITHUB_REPO}|g" \
      "$template" > "$rendered"
  srectl scheduledtask apply --file "$rendered" || { rm -f "$rendered"; die "Scheduled task apply failed: $label"; }
  rm -f "$rendered"
  ok "Scheduled task applied: $label (cron '$cron', agent '$AGENT_NAME')"
}
apply_task "$DAILY_TEMPLATE"  "$DAILY_CRON"  "FinOps: Cost Anomaly Detection (Daily)"
apply_task "$WEEKLY_TEMPLATE" "$WEEKLY_CRON" "FinOps: Rightsizing Review (Weekly)"
apply_task "$REPORT_TEMPLATE" "$REPORT_CRON" "FinOps: Cost Overview (Live Report, Daily)"
apply_task "$RIGHTSIZE_REPORT_TEMPLATE" "$RIGHTSIZE_REPORT_CRON" "FinOps: Rightsizing Savings (Live Report, Weekly)"

# ---- 4. Verify --------------------------------------------------------------
say "Verifying"
for skill in "${SKILL_NAMES[@]}"; do
  srectl skill list | grep -i "$skill" >/dev/null && ok "skill registered: $skill" || warn "skill not visible: $skill"
done
srectl scheduledtask list | grep -i "Cost Anomaly Detection" >/dev/null && ok "daily anomaly task registered"   || warn "daily task not visible"
srectl scheduledtask list | grep -i "Rightsizing Review"     >/dev/null && ok "weekly rightsizing task registered" || warn "weekly task not visible"
srectl scheduledtask list | grep -i "Cost Overview"          >/dev/null && ok "daily live-report task registered"  || warn "live-report task not visible"
srectl scheduledtask list | grep -i "Rightsizing Savings"    >/dev/null && ok "weekly rightsizing live-report task registered" || warn "rightsizing live-report task not visible"

say "Done — FinOps pack installed."
printf '  • On-demand:  ask the agent \"run the finops-cost-anomaly-detection skill for subscription %s\"\n' "$SUB_ID"
printf '                or \"run the finops-rightsizing-advisor skill for subscription %s\"\n' "$SUB_ID"
printf '  • Proactive:  anomaly scan daily on \"%s\"; rightsizing review weekly on \"%s\" -> %s\n' "$DAILY_CRON" "$WEEKLY_CRON" "$ALERT_EMAIL"
printf '  • Live Reports: \"FinOps: Cost Overview\" daily on \"%s\"; \"FinOps: Rightsizing Savings\" weekly on \"%s\" (Operations Hub > Live Reports; requires Live Reports enabled).\n' "$REPORT_CRON" "$RIGHTSIZE_REPORT_CRON"
printf '  • Live Report: \"FinOps: Cost Overview\" refreshed daily on \"%s\" (Operations Hub > Live Reports; requires Live Reports enabled).\n' "$REPORT_CRON"
