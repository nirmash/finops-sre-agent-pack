# FinOps Plugin

FinOps skills for Azure SRE Agent, delivered entirely as **skills + agents + scheduled tasks** —
no changes to the SRE Agent product. Skills compose existing read-only Azure tools
(`RunAzCliReadCommands`, Resource Graph, Azure Monitor), the GitHub connector, and in-sandbox
Python (`ExecutePythonCode`).

## Skills

| Skill | What it does | Status |
|-------|--------------|--------|
| [`cost-anomaly-detection`](skills/cost-anomaly-detection/SKILL.md) | Detect cost spikes and correlate each to the deployment / change / PR that caused it | ✅ Wave 1 — validated live |
| `rightsizing-advisor` | Advisor + live utilization + AKS node pools → rightsizing recommendations | 🔜 planned |
| `cost-optimization-report` | Recurring cost report bundling anomalies, rightsizing, budget status, policy violations | 🔜 planned |
| `cost-allocation` (showback) | Join cost line items with tags → spend by service/team/env; flag untagged spend | 🔜 planned |
| `budget-governance` | Burn-rate vs thresholds, client-side month-end forecast, process gates | 🔜 planned |
| `finops-for-ai` | Attribute AOAI/Cognitive Services spend per deployment/model from token metrics | 🔜 planned |
| `cost-vs-reliability` | Join spend with incident/alert history to weigh reliability spend vs risk | 🔜 planned |

## Prerequisites

These are **RBAC grants on the customer's subscription**, not product changes. Grant them to the
SRE Agent's managed identity.

| Grant | Needed for | Command |
|-------|-----------|---------|
| **Cost Management Reader** | All cost skills (`costInUSD` is null without it) | `az role assignment create --assignee <AGENT_MI_OBJECT_ID> --role "Cost Management Reader" --scope /subscriptions/<SUB_ID>` |
| **Log Analytics Reader** + `api.loganalytics.io` scope | Pod/namespace-level AKS rightsizing (Container Insights KQL) | Grant the role on the workspace and allowlist the scope for the MI |

## Why read-only `az` is sufficient for cost

Actual cost comes from the **modern Consumption UsageDetails REST GET**
(`Microsoft.Consumption/usageDetails?api-version=2023-05-01&metric=ActualCost`), which passes the
read-only tool gate. The Cost Management **Query API is POST-based and stays blocked, but is not
required** — line items are aggregated / detected client-side in the sandbox. (Legacy
`az consumption usage list` returns null under MCA modern billing and is not used.)

## Install

You have two ways to register the skill onto an agent. No product build or redeploy is required.

### Option 1 — MCP `sre-agent-skills` tool (validated path)

This is what was used to install and validate `cost-anomaly-detection` on a live agent. It uploads a
single self-contained skill blob (the detector is embedded inline in the skill body and written to
`detect.py` in the sandbox at runtime), so no separate reference-file upload is needed.

1. Point the `sre-agent` MCP server at your deployed agent (already authenticated via `az login`).
2. Call the `sre-agent-skills` tool with `action: create`, passing:
   - `name`: `cost-anomaly-detection`
   - `description`: short summary
   - `content`: the SKILL.md body **with the contents of `detect.py` embedded inline** as a Python
     block the agent writes to `detect.py` before running it.
3. Verify with `sre-agent-skills` `action: list` — the skill should appear in the registry.

### Option 2 — `srectl` (directory-based, requires building Agent.Cli)

`srectl skill apply --name cost-anomaly-detection` installs directly from this plugin's
`skills/<name>/` directory (carrying `SKILL.md` **and** the bundled `detect.py` reference file, so no
inlining is needed). This is the cleaner long-term path.

> **Note:** `srectl` must be built from `Agent.Cli` in the `sreagent-runtime` repo, which requires the
> private Antares Azure DevOps NuGet feed and .NET SDK `10.0.301`. If you don't have feed access, use
> Option 1.

### RBAC prerequisite

Before either install works end-to-end, grant **Cost Management Reader** to the agent's managed
identity (see Prerequisites above) — otherwise `costInUSD` is null and no cost data flows.

## Validation status

`cost-anomaly-detection` was validated **end-to-end on a live subscription** (`93cba93f…`):

- Pulled 3,217 real Consumption UsageDetails line items (4 pages paginated, 13 days).
- Detector imported and ran clean on real data (0 anomalies — stable sub, expected).
- Backtest: injected a 5× synthetic spike on the top meter (Azure Container Apps) → flagged as
  `spike`, ranked #1 by impact (`current $227.11` / `baseline $17.71` / `Δ +$209.40`, +1182%).
- Correlation join queried deployments + activity log + GitHub PRs/commits for the spike window.

All 5 validation parts passed.

## Test

The detection logic is pure Python and offline-testable:

```bash
pip install -r requirements-dev.txt
pytest tests/
```
