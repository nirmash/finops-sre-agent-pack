#!/usr/bin/env bash
#
# install.sh — one-shot installer for the FinOps cost-anomaly package.
#
# Installs EVERYTHING the cost-anomaly capability needs onto an SRE Agent:
#   1. (optional) the Cost Management Reader RBAC grant on the agent's managed identity
#   2. the `cost-anomaly-detection` skill
#   3. the "Cost Anomaly Detection (Daily)" proactive scheduled task
#
# Requires `srectl` (pointed at your agent) and `az` (logged in). Re-running is safe:
# skill apply and scheduledtask apply both upsert by name.
#
# Usage:
#   ./install.sh                        # uses the defaults below
#   AGENT_NAME="My Agent" SUB_ID=<sub> CRON="0 14 * * *" ./install.sh
#   MI_OBJECT_ID=<mi-object-id> ./install.sh   # also performs the RBAC grant
#
set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
AGENT_NAME="${AGENT_NAME:-Nir Mashkowski}"
SUB_ID="${SUB_ID:-93cba93f-571e-44e9-ac0a-a2987b58848c}"
CRON="${CRON:-0 14 * * *}"                       # daily 14:00 UTC (host tz)
ALERT_EMAIL="${ALERT_EMAIL:-nimashkowski@microsoft.com}"
GITHUB_REPO="${GITHUB_REPO:-nirmash/azure-sre-agent-sandbox}"
MI_OBJECT_ID="${MI_OBJECT_ID:-}"                 # agent managed identity objectId; set to auto-grant RBAC
RESOURCE_URL="${RESOURCE_URL:-}"                 # if set, runs `srectl init` against this endpoint first

SKILL_NAME="cost-anomaly-detection"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_TEMPLATE="${PLUGIN_DIR}/scheduled-tasks/cost-anomaly-daily.yaml"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. Preflight -----------------------------------------------------------
say "Preflight checks"
command -v srectl >/dev/null 2>&1 || die "srectl not found. Build it from Agent.Cli (see plugin README) or install the CLI."
command -v az     >/dev/null 2>&1 || die "az (Azure CLI) not found."
az account show >/dev/null 2>&1   || die "Not logged in to Azure. Run 'az login' first."
[ -f "$TASK_TEMPLATE" ]           || die "Task template not found: $TASK_TEMPLATE"
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
  warn "The skill needs Cost Management Reader on the agent's managed identity, or costInUSD is null:"
  printf '      az role assignment create --assignee <AGENT_MI_OBJECT_ID> \\\n'
  printf '        --role "Cost Management Reader" --scope /subscriptions/%s\n' "$SUB_ID"
fi

# ---- 2. Install the skill ---------------------------------------------------
say "Installing skill '$SKILL_NAME'"
# `srectl skill apply --name` discovers ./skills/<name> recursively from the CWD,
# so run from the plugin dir where skills/cost-anomaly-detection/ lives.
( cd "$PLUGIN_DIR" && srectl skill apply --name "$SKILL_NAME" ) || die "Skill apply failed."
ok "Skill '$SKILL_NAME' applied"

# ---- 3. Apply the proactive scheduled task ---------------------------------
say "Applying scheduled task 'Cost Anomaly Detection (Daily)'"
rendered="$(mktemp -t cost-anomaly-daily.XXXXXX.yaml)"
trap 'rm -f "$rendered"' EXIT
sed -e "s|__AGENT_NAME__|${AGENT_NAME}|g" \
    -e "s|__SUB_ID__|${SUB_ID}|g" \
    -e "s|__CRON__|${CRON}|g" \
    -e "s|__ALERT_EMAIL__|${ALERT_EMAIL}|g" \
    -e "s|__GITHUB_REPO__|${GITHUB_REPO}|g" \
    "$TASK_TEMPLATE" > "$rendered"
srectl scheduledtask apply --file "$rendered" || die "Scheduled task apply failed."
ok "Scheduled task applied (cron '$CRON', agent '$AGENT_NAME')"

# ---- 4. Verify --------------------------------------------------------------
say "Verifying"
srectl skill list         | grep -i "$SKILL_NAME"            && ok "skill registered"          || warn "skill not visible in list"
srectl scheduledtask list | grep -i "Cost Anomaly Detection" && ok "scheduled task registered" || warn "task not visible in list"

say "Done — cost-anomaly package installed."
printf '  • On-demand:  ask the agent \"run the %s skill for subscription %s\"\n' "$SKILL_NAME" "$SUB_ID"
printf '  • Proactive:  runs daily on cron \"%s\"; alerts %s only when a spike is found\n' "$CRON" "$ALERT_EMAIL"
