# FinOps Plugin

FinOps skills for Azure SRE Agent, delivered entirely as **skills + agents + scheduled tasks** —
no changes to the SRE Agent product. Skills compose existing read-only Azure tools
(`RunAzCliReadCommands`, Resource Graph, Azure Monitor), the GitHub connector, and in-sandbox
Python (`ExecutePythonCode`).

## Skills

| Skill | What it does | Status |
|-------|--------------|--------|
| [`cost-anomaly-detection`](skills/cost-anomaly-detection/SKILL.md) | Detect cost spikes and correlate each to the deployment / change / PR that caused it | ✅ Wave 1 |
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

Register this plugin's skill directory onto your agent as an extended skill (via the ExtendedAgents
API / dynamic skill registration). No product build or redeploy is required.

## Test

The detection logic is pure Python and offline-testable:

```bash
pip install -r requirements-dev.txt
pytest tests/
```
