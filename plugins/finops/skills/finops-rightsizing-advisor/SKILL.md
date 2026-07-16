---
name: finops-rightsizing-advisor
description: Recommend rightsizing and idle-resource cleanup for Azure, read-only. Combines Azure Advisor cost recommendations with live utilization from Azure Monitor and inventory state from Resource Graph, validates each candidate against real CPU utilization and real cost before surfacing it, then ranks recommendations by estimated monthly savings using the bundled rightsize.py (run in-sandbox via ExecutePythonCode). Use for "what can we downsize or turn off", periodic savings reviews, and adding a cost-efficiency lens to capacity questions.
---

## When to use this skill

Use it when the user wants to **find underutilized or idle Azure resources and get concrete
resize / deallocate / delete recommendations** — an on-demand "what can we rightsize or shut down?",
a weekly savings review, or a cost-efficiency pass during a capacity discussion. This skill
**validates Advisor's suggestions against real utilization and real cost** before surfacing them and
ranks by dollar savings. It recommends only; it never changes anything (all steps are read-only, and
a human approves any action).

For cost *spikes* and their root cause, use `finops-cost-anomaly-detection` instead.

## Required access

- **Reader** on the subscription/resource groups for Advisor, Resource Graph, and Azure Monitor
  metrics. **Cost Management Reader** to attach per-resource monthly cost (without it, savings are
  still estimated from Advisor where available but resources with no Advisor number show unknown cost).
- Read-only `az` (`RunAzCliReadCommands`) and `ExecutePythonCode` (in-sandbox ranking). No POST/write
  APIs are used.

## Scope

VM / disk / storage-tier / App Service plan / node-level rightsizing works today. **Pod- and
namespace-level AKS rightsizing needs a Log Analytics Reader grant + `api.loganalytics.io` scope on
the agent identity** (Container Insights KQL is otherwise blocked) — out of scope here until that
grant lands.

## Procedure

### Step 1 — Pull Azure Advisor cost recommendations

```bash
az advisor recommendation list --category Cost -o json
```

Flatten each recommendation to the shape `rightsize.py` expects:
`{resourceId, problem, recommendation, targetSku, savingsUsd}` — `resourceId` from
`resourceMetadata.resourceId` (or the `impactedValue`), `problem`/`recommendation` from
`shortDescription`, and `savingsUsd` from `extendedProperties.savingsAmount`/`annualSavingsAmount`
(convert an annual figure to monthly by dividing by 12) when present.

### Step 2 — Pull inventory (Resource Graph) for idle patterns Advisor misses

```bash
az graph query -q "Resources | where type in~ ('microsoft.compute/virtualmachines','microsoft.compute/disks','microsoft.web/serverfarms') | project id, type, sku=tostring(sku.name), properties, tags" --first 1000 -o json
```

On large subscriptions Resource Graph caps at 1000 rows per page — **paginate with `--skip-token`**
(from the response) until it's empty so you don't miss resources.

Flatten each row to `{resourceId, type, sku, powerState, diskState, numberOfSites, tags}`:

- **VM** `powerState` from `properties.extended.instanceView.powerState.code` (e.g.
  `PowerState/stopped` vs `PowerState/deallocated`). A **Stopped (not Deallocated)** VM still bills
  for compute.
- **Disk** `diskState` from `properties.diskState` (`Unattached` disks are pure waste).
- **App Service plan** `numberOfSites` from `properties.numberOfSites` (0 = empty plan).

### Step 3 — Pull utilization (Azure Monitor) for VM candidates

For each VM candidate (from Advisor or inventory), pull trailing CPU so the recommendation can be
**validated against reality**:

```bash
az monitor metrics list --resource <vm-resource-id> --metric "Percentage CPU" --interval PT1H --start-time <UTC-14d> --aggregation Average Maximum -o json
```

Reduce each series to `{cpu_p95, cpu_avg, mem_p95, sample_days}` (percent, 0–100). `cpu_p95` is the
95th percentile of the hourly Average series; `sample_days` is the number of distinct days covered.
Skip resources with fewer than `min_sample_days` (default 7) of data — the skill treats them as
unvalidated rather than guessing.

### Step 4 — Pull per-resource monthly cost (optional but recommended)

Reuse the `finops-cost-anomaly-detection` cost pull (modern Consumption UsageDetails GET, paginated) over
the trailing ~30 days and aggregate `costInUSD` by resource id into `{resourceId: monthly_usd}`.
In **modern billing the full ARM resource id is in `properties.instanceName`** (the `resourceId`
field is null) — key on `instanceName` and fall back to `resourceId`. Ids are matched
case-insensitively. This is what lets the skill **rank by dollars** and size idle waste. The Cost
Management Query/POST API is not needed.

### Step 5 — Rank (bundled rightsize.py, in-sandbox)

Read the module and run it — do **not** re-implement the logic in the prompt:

```
read_skill_file(skill_name="finops-rightsizing-advisor", file_path="rightsize.py")
```

```python
from rightsize import recommend_rightsizing
recs = recommend_rightsizing(
    resources=resources,       # from Step 2
    utilization=utilization,   # from Step 3  {resourceId: {...}}
    costs=costs,               # from Step 4  {resourceId: monthly_usd}
    advisor=advisor,           # from Step 1
)   # returns findings ranked by estMonthlySavingsUsd desc
```

`recommend_rightsizing` handles all classification and validation:

- **kind** is `idle` (unattached disk, stopped-not-deallocated VM, empty plan, or p95 CPU below
  `cpu_idle_pct`=5%), `oversized` (p95 CPU below `cpu_underutil_pct`=20%), or `advisor` (an Advisor
  rec with no independent signal).
- **validated** is `True` when utilization/inventory backs the call, `False` when utilization
  **contradicts** an Advisor rec (high CPU — flagged "verify before acting"), and `None`/unvalidated
  when no metrics were available.
- **estMonthlySavingsUsd**: full monthly cost for idle resources; Advisor's own number when present;
  otherwise a conservative 50% estimate for a one-tier downsize. Findings below
  `min_monthly_savings_usd` (default $5) are dropped; findings with unknown cost are kept and sort last.
- Signals for the same `resourceId` (Advisor + inventory + utilization) merge into one finding, joined
  case-insensitively.

### Step 6 — Report

Produce a ranked table: resource (id + type), kind, current SKU, recommended action, current monthly
$, estimated monthly savings $, validated, and the evidence/sources. Call out the **total estimated
monthly savings** at the top. Clearly mark `validated=False` and unvalidated rows as "verify first".
Recommend only — do not perform any resize/deallocate/delete. If nothing clears the threshold, say so
in one line.

Read-only only. Do not use any write/POST Azure operations.

## Notes

- Storage hot→cold tiering and reservation/savings-plan suggestions come through Advisor (Step 1) and
  flow through as `advisor` findings; utilization validation applies only to VM CPU today.
- The 50% one-tier savings estimate and the CPU thresholds are tunable via `recommend_rightsizing`
  keyword args if a subscription needs a different risk posture.
