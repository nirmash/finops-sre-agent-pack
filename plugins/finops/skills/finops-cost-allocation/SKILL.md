---
name: finops-cost-allocation
description: Showback / cost allocation for Azure, read-only. Joins per-resource monthly cost (modern Consumption UsageDetails) with resource tags (Resource Graph) to attribute spend to an owner dimension (team / env / service / costCenter / app / owner), then surfaces the spend that has no owner — an explicit unallocated bucket, a ranked untagged-resource list, and tag-hygiene flags — using the bundled allocate.py (run in-sandbox via ExecutePythonCode). Use for "who owns this bill", showback/chargeback prep, and finding untagged spend.
---

## When to use this skill

Use it when the user wants to **attribute Azure spend to an owner** (team, environment, service,
cost center, app, or owner) — a showback breakdown, chargeback preparation, or a hunt for **untagged
spend that has no owner**. It answers "who/what is this bill for?" and "how much spend is
unattributable?" It is read-only and recommends tagging actions only; it never changes tags.

For cost *spikes* and their cause use `finops-cost-anomaly-detection`; for rightsizing / idle waste
use `finops-rightsizing-advisor`.

## Required access

- **Cost Management Reader** on the subscription (`costInUSD` is null without it) and **Reader** for
  Resource Graph tags.
- Read-only `az` (`RunAzCliReadCommands`) and `ExecutePythonCode` (in-sandbox allocation). No
  POST/write APIs are used.

## Scope

Attributes any resource that lands a cost line item in Consumption UsageDetails — the allocation is
**service-agnostic** (it works off cost + tags, not a hard-coded resource list). Shared or untaggable
cost (session pools, networking, shared clusters) is **never force-allocated**: cost with no value for
the requested dimension is kept in an explicit **unallocated** bucket, and resources missing a value
for **every** ownership key are listed as **untagged** for follow-up. Cross-charging exports and
management-group rollups are out of scope here until needed.

## Procedure

### Step 1 — Pull per-resource monthly cost

Use the **same hardened Consumption UsageDetails pull as `finops-cost-anomaly-detection` Step 1**
(modern GET, `&$top=100`, retry smaller on a `413 Request Too Large`, paginate `nextLink`; if
pagination cannot complete, keep partial rows but label totals "partial — cost pull truncated"). Over
the trailing ~30 days, aggregate `costInUSD` by resource id into `{resourceId: monthly_usd}`. In modern
billing the full ARM resource id is in `properties.instanceName` (`properties.resourceId` is null) —
key on `instanceName`, fall back to `resourceId`. Ids are matched case-insensitively.

### Step 2 — Pull resource tags (Resource Graph)

```bash
az graph query -q "Resources | project id, tags" --first 1000 -o json
```

Paginate with `--skip-token` until empty (Resource Graph caps at 1000 rows/page). Flatten to
`{resourceId: {tagKey: tagVal}}`. Keep the raw tag values as-is — the ranker normalizes case and
flags variant spellings itself.

### Step 3 — Allocate (bundled allocate.py, in-sandbox)

Read the module and run it — do **not** re-implement the logic in the prompt:

```
read_skill_file(skill_name="finops-cost-allocation", file_path="allocate.py")
```

```python
from allocate import allocate_costs
result = allocate_costs(
    costs=costs,               # from Step 1  {resourceId: monthly_usd}
    tags=tags,                 # from Step 2  {resourceId: {tagKey: tagVal}}
    dimension="team",          # or env / service / costCenter / app / owner
)
```

`allocate_costs` handles all grouping and governance:

- **groups**: spend per owner value for the requested `dimension`, ranked by dollars, with `pct` of
  total and `resource_count`. Values are grouped case-insensitively; the most costly raw spelling is
  shown.
- **unallocated**: cost of resources with **no value for the requested dimension** — kept as its own
  bucket (never spread onto tagged owners) with `monthly_usd`, `pct`, and the top resources.
- **untagged_resources** / **untagged_usd**: resources missing a value for **all** ownership keys
  (`{team, env, service, costCenter, app, owner}` by default) — the tagging backlog, ranked by cost.
- **tag_hygiene**: owner values that collapse to the same group under normalization (e.g. `Prod` vs
  `production`) with the cost each variant carries — these otherwise split one owner's spend.

Run it once per dimension the user cares about (e.g. `team` and `env`).

### Step 4 — Report

Produce, for the chosen dimension: a **showback table** (owner, monthly $, % of total, resource
count) with the **total** and the **unallocated** row called out explicitly; an **untagged-spend**
section (total $ + top resources to tag); and **tag-hygiene** warnings. Recommend tagging actions
only — never modify tags. If cost was partial (Step 1 truncation), say so at the top. If everything is
allocated and there is no untagged spend, say so in one line.
