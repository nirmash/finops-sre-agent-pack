# FinOps Plugin

FinOps skills for Azure SRE Agent, delivered entirely as **skills + agents + scheduled tasks** —
no changes to the SRE Agent product. Skills compose existing read-only Azure tools
(`RunAzCliReadCommands`, Resource Graph, Azure Monitor), the GitHub connector, and in-sandbox
Python (`ExecutePythonCode`).

## Skills

| Skill | What it does | Status |
|-------|--------------|--------|
| [`finops-cost-anomaly-detection`](skills/finops-cost-anomaly-detection/SKILL.md) | Detect cost spikes and correlate each to the deployment / change / PR that caused it | ✅ Wave 1 — validated live |
| [`finops-rightsizing-advisor`](skills/finops-rightsizing-advisor/SKILL.md) | Advisor cost recs + live utilization + inventory → ranked rightsizing / idle-cleanup recommendations (incl. idle Azure Container Apps environments, always-on apps, and warm session pools with no traffic, plus a cost-led sweep so no high-spend resource is missed), validated against real utilization and cost | ✅ Wave 1 — validated live |
| [`finops-cost-allocation`](skills/finops-cost-allocation/SKILL.md) | Join cost line items with tags → showback by team/env/service/costCenter/app/owner; explicit unallocated bucket + ranked untagged spend + tag-hygiene flags | ✅ Wave 2 — offline-tested |
| [`finops-budget-governance`](skills/finops-budget-governance/SKILL.md) | Read native Azure budgets (`GET Microsoft.Consumption/budgets`) → evaluate each against amount + its own notification thresholds; Azure `forecastSpend` when present, else a client-side run-rate month-end forecast; ranks over / forecast-over / at-risk budgets and flags process gates. Handles the no-budgets-defined case. | ✅ Wave 2 — offline-tested |
| [`finops-budget-editor`](skills/finops-budget-editor/SKILL.md) | **Advisory** budget right-sizing: read native budgets → recommend an amount (`max(current, forecast) × 1.15`, reusing the run-rate forecast) and render the exact `az rest --method put` command for a human to run. **Stays read-only** — it prints the write command but never executes it; applying it needs Cost Management Contributor. | ✅ Wave 2 — offline-tested |
| `cost-optimization-report` | Recurring cost report bundling anomalies, rightsizing, budget status, policy violations | 🔜 planned |
| `finops-for-ai` | Attribute AOAI/Cognitive Services spend per deployment/model from token metrics | 🔜 planned |
| `cost-vs-reliability` | Join spend with incident/alert history to weigh reliability spend vs risk | 🔜 planned |

## Roadmap & backlog

Planned **skills** are listed in the table above (🔜). Cross-cutting work items not represented as a
skill:

| Item | What | Status |
|------|------|--------|
| **Usage examples per skill** | For each shipped skill (`finops-cost-anomaly-detection`, `finops-rightsizing-advisor`, `finops-cost-allocation`, `finops-budget-governance`, `finops-budget-editor`): sample input data, an example invocation, and expected output/report — under each skill folder (an `examples/` dir or an Examples section in `SKILL.md`). Do after the implementation work is complete. | 🔜 planned |
| **Cost-pull recipe simplification** | Lead the anti-`413` recipe with `$top` + `--query` field projection (the levers that actually shrink the server response); demote date-windowing to a fallback. Live runs showed the `usageStart` slice filter isn't reliably applied, so it's belt-and-suspenders, not primary. | 🔜 planned |
| **Make repo public** | Flip the repo to public and drop the install PAT once the pack is ready to share. | 🔜 planned |

Engineering wave order: `cost-optimization-report` → `finops-for-ai` → `cost-vs-reliability`. (F4 `budget-governance` — read budgets/forecast — and F5 `budget-editor` — advisory right-sizing that prints the write command but stays read-only — are now built.)

## Prerequisites

These are **RBAC grants on the customer's subscription**, not product changes. Grant them to the
SRE Agent's managed identity.

| Grant | Needed for | Command |
|-------|-----------|---------|
| **Cost Management Reader** | All cost skills (`costInUSD` is null without it) | `az role assignment create --assignee <AGENT_MI_OBJECT_ID> --role "Cost Management Reader" --scope /subscriptions/<SUB_ID>` |
| **Cost Management Contributor** *(write)* | **Not used by the pack.** `finops-budget-editor` is advisory — it prints an `az rest --method put` command but never runs it. A person needs this role only to **apply** that command themselves. No skill in the pack calls a write API. | `az role assignment create --assignee <YOUR_PRINCIPAL> --role "Cost Management Contributor" --scope /subscriptions/<SUB_ID>` |
| **Log Analytics Reader** + `api.loganalytics.io` scope | Pod/namespace-level AKS rightsizing (Container Insights KQL) | Grant the role on the workspace and allowlist the scope for the MI |

## Why read-only `az` is sufficient for cost

Actual cost comes from the **modern Consumption UsageDetails REST GET**
(`Microsoft.Consumption/usageDetails?api-version=2023-05-01&metric=ActualCost`), which passes the
read-only tool gate. The Cost Management **Query API is POST-based and stays blocked, but is not
required** — line items are aggregated / detected client-side in the sandbox. (Legacy
`az consumption usage list` returns null under MCA modern billing and is not used.)

## Install everything (recommended)

This plugin ships as a **package**: one command installs the skills, the five proactive scheduled
tasks (two email reviews + three Live Reports), and (optionally) the RBAC grant. The tasks are all
prefixed **`FinOps:`** so it's clear in the agent's Scheduled Tasks list that they belong to the
FinOps pack and were installed alongside the skills.

### Option A — API installer (no srectl, recommended)

[`install-api.sh`](install-api.sh) installs everything by calling the agent's own management API
directly (the same control-plane `srectl` uses) — so it needs only `az` (logged in), `curl`, and
`python3`. No .NET build, no private NuGet feed. It (1) registers this repo as a plugin marketplace,
(2) installs the `finops` plugin (the server clones the repo and copies **both** skill dirs —
`SKILL.md` + `detect.py`/`rightsize.py`), and (3) upserts the daily and weekly scheduled tasks.
Re-running is safe.

```bash
# Your az-login identity must own ARM write on the agent (the resource owner does).
AGENT_RESOURCE_ID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/agents/<agent> \
  ./install-api.sh

# While this repo is private, pass a GitHub PAT so the server can clone it:
GITHUB_PAT=$(gh auth token) AGENT_RESOURCE_ID=<id> ./install-api.sh

# Also grant Cost Management Reader to the agent MI automatically:
MI_OBJECT_ID=<agent-mi-object-id> AGENT_RESOURCE_ID=<id> ./install-api.sh
```

Configuration (all optional, shown with defaults): `AGENT_RESOURCE_ID`/`ENDPOINT`,
`MARKETPLACE_NAME=finops-pack`, `PLUGIN_NAME=finops`, `REPO_SLUG=nirmash/finops-sre-agent-pack`,
`GITHUB_PAT`, `TASK_NAME`, `CRON="0 14 * * *"` (daily 14:00 UTC), `RIGHTSIZE_TASK_NAME`,
`RIGHTSIZE_CRON="0 15 * * 1"` (Mon 15:00 UTC), `REPORT_TASK_NAME`, `REPORT_CRON="0 14 * * *"`
(daily Cost Overview Live Report), `RIGHTSIZE_REPORT_TASK_NAME`, `RIGHTSIZE_REPORT_CRON="0 15 * * 1"`
(weekly Rightsizing Savings Live Report), `BUDGET_REPORT_TASK_NAME`, `BUDGET_REPORT_CRON="0 16 * * *"`
(daily Budget Status Live Report), `AGENT_NAME`, `SUB_ID`, `ALERT_EMAIL`, `GITHUB_REPO`,
`MI_OBJECT_ID`.

> Once this repo is public, drop `GITHUB_PAT` — the server clones it with the host's default GitHub
> identity.

### Option B — srectl installer

[`install.sh`](install.sh) does the same thing via `srectl` (skill apply + scheduledtask apply for
both skills and both tasks, upsert by name). Point srectl at your agent first
(`srectl init --resource-url <endpoint>`).

```bash
AGENT_NAME="My Agent" SUB_ID=<subscription-id> ./install.sh

# Also perform the Cost Management Reader grant automatically:
MI_OBJECT_ID=<agent-mi-object-id> AGENT_NAME="My Agent" SUB_ID=<sub> ./install.sh
```

What both installers set up:

| Component | What / where |
|-----------|--------------|
| **Skill** `finops-cost-anomaly-detection` | the whole skill dir `skills/finops-cost-anomaly-detection/` (SKILL.md + `detect.py`) |
| **Skill** `finops-rightsizing-advisor` | the whole skill dir `skills/finops-rightsizing-advisor/` (SKILL.md + `rightsize.py`) |
| **Scheduled task** `FinOps: Cost Anomaly Detection (Daily)` | daily scan from [`scheduled-tasks/cost-anomaly-daily.yaml`](scheduled-tasks/cost-anomaly-daily.yaml) — alerts only on a spike |
| **Scheduled task** `FinOps: Rightsizing Review (Weekly)` | weekly review from [`scheduled-tasks/rightsizing-weekly.yaml`](scheduled-tasks/rightsizing-weekly.yaml) — ranked savings opportunities |
| **Live Report** `FinOps: Cost Overview` (daily) | driven by [`scheduled-tasks/cost-overview-report-daily.yaml`](scheduled-tasks/cost-overview-report-daily.yaml) — a snapshot cost dashboard (total, daily trend, top services, top resource groups) in Operations Hub, re-versioned daily |
| **Live Report** `FinOps: Rightsizing Savings` (weekly) | driven by [`scheduled-tasks/rightsizing-savings-report-weekly.yaml`](scheduled-tasks/rightsizing-savings-report-weekly.yaml) — a snapshot savings dashboard (total potential savings, top-opportunities chart, ranked table) in Operations Hub, re-versioned weekly |
| **Live Report** `FinOps: Budget Status` (daily) | driven by [`scheduled-tasks/budget-status-report-daily.yaml`](scheduled-tasks/budget-status-report-daily.yaml) — a snapshot budget-governance dashboard (spend vs amount, forecast, status, and gated budgets from `finops-budget-governance`) in Operations Hub, re-versioned daily |
| **RBAC** (optional) | Cost Management Reader on the agent MI when `MI_OBJECT_ID` is set |

> `install.sh` uses `srectl`, which must be built from `Agent.Cli` in the `sreagent-runtime` repo
> (requires the private Antares Azure DevOps NuGet feed and .NET SDK `10.0.301`). If you can't build
> it, use Option A (`install-api.sh`) or the manual MCP path below.

## Proactive monitoring

The bundled scheduled task runs the skill on a daily cron and **reports only when a spike is
detected** (otherwise it emits a single "no anomalies" line and stays quiet). On a detection it
correlates the spike to deployments / activity-log writes / GitHub merges and emails a ranked report
to `ALERT_EMAIL` with High importance. Edit the cron/agent/email in
[`scheduled-tasks/cost-anomaly-daily.yaml`](scheduled-tasks/cost-anomaly-daily.yaml) or override via
the installer's environment variables. Manage it with `srectl scheduledtask list|pause|resume|get`.

## Live Reports (Operations Hub)

The pack also installs three **Live Reports** — self-contained HTML dashboards that appear in
**Operations Hub → Live Reports**:

- **`FinOps: Cost Overview`** (daily) — total spend, daily-spend trend, top services, and top
  resource groups.
- **`FinOps: Rightsizing Savings`** (weekly) — total potential monthly savings, a top-opportunities
  chart, and a ranked recommendations table from the `finops-rightsizing-advisor` analysis.
- **`FinOps: Budget Status`** (daily) — each budget's spend vs amount, forecast (Azure's or a
  run-rate estimate), status, breached thresholds, and any gated budgets, from the
  `finops-budget-governance` evaluation (budgets `GET` only — no cost pull).

These are **snapshot** reports: there is no external REST API to upload a report, so the pack ships
a scheduled task that drives the built-in `live_report_authoring` skill to author + `SaveReport` the
dashboard with the data **baked in** (`allowedTools=[]`, so it saves with no connector-approval
prompt). Each run finds the report by name and saves a **new version**, so the dashboard refreshes on
the task's cron (daily / weekly) rather than on every view. Azure cost data (`UsageDetails`) only
settles roughly daily, so daily/weekly refresh matches the data's freshness.

> **Requires Live Reports enabled on the agent** (first-party + Operations Hub; feature flag
> `EnableLiveReports`). Where it isn't enabled the three report tasks install but no-op at run time; the
> two email tasks and both skills are unaffected.

## Install the skill only (manual)

If you only want the skill (no scheduled task), use one of these instead of `install.sh`.

### Option 1 — MCP `sre-agent-skills` tool (validated path)

This is what was used to install and validate `finops-cost-anomaly-detection` on a live agent. It uploads a
single self-contained skill blob (the detector is embedded inline in the skill body and written to
`detect.py` in the sandbox at runtime), so no separate reference-file upload is needed.

1. Point the `sre-agent` MCP server at your deployed agent (already authenticated via `az login`).
2. Call the `sre-agent-skills` tool with `action: create`, passing:
   - `name`: `finops-cost-anomaly-detection`
   - `description`: short summary
   - `content`: the SKILL.md body **with the contents of `detect.py` embedded inline** as a Python
     block the agent writes to `detect.py` before running it.
3. Verify with `sre-agent-skills` `action: list` — the skill should appear in the registry.

### Option 2 — `srectl` (directory-based, requires building Agent.Cli)

`srectl skill apply --name finops-cost-anomaly-detection` installs directly from this plugin's
`skills/<name>/` directory (carrying `SKILL.md` **and** the bundled `detect.py` reference file, so no
inlining is needed). This is the cleaner long-term path.

> **Note:** `srectl` must be built from `Agent.Cli` in the `sreagent-runtime` repo, which requires the
> private Antares Azure DevOps NuGet feed and .NET SDK `10.0.301`. If you don't have feed access, use
> Option 1.

### RBAC prerequisite

Before either install works end-to-end, grant **Cost Management Reader** to the agent's managed
identity (see Prerequisites above) — otherwise `costInUSD` is null and no cost data flows.

## Validation status

`finops-cost-anomaly-detection` was validated **end-to-end on a live subscription** (`93cba93f…`):

- Pulled 3,217 real Consumption UsageDetails line items (4 pages paginated, 13 days).
- Detector imported and ran clean on real data (0 anomalies — stable sub, expected).
- Backtest: injected a 5× synthetic spike on the top meter (Azure Container Apps) → flagged as
  `spike`, ranked #1 by impact (`current $227.11` / `baseline $17.71` / `Δ +$209.40`, +1182%).
- Correlation join queried deployments + activity log + GitHub PRs/commits for the spike window.

All 5 validation parts passed. The **daily proactive scheduled task** is also registered and Active
on the live agent (`FinOps: Cost Anomaly Detection (Daily)`, cron `0 14 * * *`), and the whole pack
has been installed end-to-end via [`install-api.sh`](install-api.sh) against a live agent.

`finops-rightsizing-advisor` was validated to the **same level** — 30 offline unit tests plus a live
end-to-end run on the same subscription (`93cba93f…`):

- Pulled **8 real Azure Advisor cost recs** (unattached disk, 3 empty App Service plans, 4 AKS).
- Pulled **live Resource Graph inventory** and **30 days of Consumption cost** (4 pages), aggregating
  spend by resource id — surfacing the `instanceName`/`resourceId` modern-billing detail below.
- Ran `recommend_rightsizing` on the real data: Advisor + inventory findings merged and ranked by
  estimated monthly savings, quantified rows first and unknown-savings rows last.
- Backtest: injected a synthetic idle VM (p95 CPU 1.5%) and an oversized VM (p95 CPU 11%) → classified
  `idle` (full-cost savings) and `oversized` (50% one-tier estimate), ranked idle first.
- **Azure Container Apps idle detection**: flags unused ACA environments (empty, or every app had
  zero `Requests` traffic over the window), always-on container apps (`minReplicas>=1`) with no
  hits, and **warm dynamic session pools** (`readySessionInstances>=1`) with zero `SessionApiRequestCount`
  — a class invisible to `az resource list` that was the subscription's #1/#2 spend ($331/mo each),
  validated live against real metrics.
- **Cost-led coverage sweep**: any resource costing ≥ $20/mo whose type has no idle rule (and that no
  other signal flagged) is surfaced as a `review` finding, so no expensive line item is ever silently
  dropped just because a heuristic doesn't exist for its type yet.

All 6 validation parts passed. The **weekly proactive scheduled task**
(`FinOps: Rightsizing Review (Weekly)`, cron `0 15 * * 1`) is part of the same package install.

> Modern-billing note found during validation: in Consumption UsageDetails the full ARM resource id
> is in `properties.instanceName` (the `resourceId` field is null), so cost is aggregated by
> `instanceName` (case-insensitive), falling back to `resourceId`.

## Test

Both skills' logic is pure Python and offline-testable (`detect.py`, `rightsize.py`, `allocate.py`,
`budget.py`):

```bash
pip install -r requirements-dev.txt
pytest tests/          # 76 tests: 8 anomaly, 30 rightsizing, 9 cost-allocation, 14 budget-governance, 15 budget-editor
```
