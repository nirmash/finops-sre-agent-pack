---
name: finops-cost-anomaly-detection
description: Detect Azure cost spikes and explain why they happened. Pulls the daily cost time-series from Cost Management (Consumption UsageDetails), detects per-service/per-meter anomalies with the bundled detect.py (run in-sandbox via ExecutePythonCode), then correlates each spike to recent deployments, activity-log changes, and GitHub merges to surface a probable cause. Use for scheduled cost monitoring, "did anything spike this week and why", and adding a cost lens to incident investigations.
---

## When to use this skill

Use it when the user wants to **find cost spikes and understand their cause** — daily/weekly
automated cost monitoring, an on-demand "why did cost go up?" question, or a cost check during an
incident. This skill does **detection + root-cause correlation**, not just totals. For a plain
periodic cost summary, use `cost-optimization-report` instead.

## Required access

- **Cost Management Reader** on the subscription (or billing scope) for the agent's managed
  identity. Without it, `costInUSD` comes back null. This is a one-time RBAC grant (see the
  plugin README).
- Read-only `az` (`RunAzCliReadCommands`), the GitHub connector (for change correlation), and
  `ExecutePythonCode` (in-sandbox detection). No POST/write APIs are used.

## Procedure

### Step 1 — Pull the daily cost time-series

Use the **modern Consumption UsageDetails GET** (the Cost Management Query/POST aggregation API is
blocked by the read-only gate and is **not needed** — detection happens client-side). Request a
trailing window large enough for a baseline plus the current period (default: 35 days).

**Pull in short date-windowed slices with a bounded page size, and project to only the fields you
need with `--query`.** Two things matter here, and they solve two different problems:

1. **Avoiding the server `413 Request Too Large` — use short date slices + bounded `\$top`.** The 413
   is a **server-side response-size limit**: when the page the Consumption API would return is too
   large it refuses with 413. The levers that actually shrink what the *server* returns are (a) short
   date windows and (b) a bounded `\$top`. Walk the trailing window in **3-day slices** bounded by
   `usageStart`, with `\$top=1000`. Empirically 3-day slices come back around a few hundred KB while a
   5-day slice trips the 413. `--query` does **not** help here — `az rest` downloads the full response
   before applying `--query` client-side, so it cannot change the server's decision.
2. **Keeping the data you retain small — use `--query` field projection.** A full UsageDetails row is
   large (meter details, billing ids, additionalInfo, …). Project each row down to just the fields the
   detector needs so the JSON you save and hand to the sandbox stays small and concatenation is cheap.

```bash
# for each 3-day [SLICE_START, SLICE_END) slice across the window:
az rest --method get --url "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.Consumption/usageDetails?api-version=2023-05-01&metric=ActualCost&\$top=1000&\$filter=properties/usageStart ge '<SLICE_START>' and properties/usageStart lt '<SLICE_END>'" \
  --query "{value: value[].{date: properties.date, cost: properties.costInUSD, meterCategory: properties.meterCategory, resourceGroup: properties.resourceGroup, resourceId: properties.instanceName, tags: tags}, nextLink: nextLink}"
```

- **3-day slices + `\$top=1000` (primary anti-413):** short windows keep each page under the server
  size cap and keep pagination shallow so the skip-token offset never grows deep enough to 413 on a
  later `nextLink`.
- **Fallbacks if a slice still 413s:** halve the slice (to ~1 day) and/or drop `\$top` (1000 → 100 →
  20) for that slice only.
- **`--query` projection (retained-payload hygiene):** keeps only `{date, cost, meterCategory,
  resourceGroup, resourceId, tags}` plus `nextLink`, so the concatenated dataset stays small.
- **Paginate within each slice:** follow `nextLink` until absent; concatenate all rows across every
  slice. `nextLink` already carries the skip token — GET it as-is (don't re-add params). Note the
  `nextLink` in the raw body is HTML-escaped (`&amp;`) — decode `&amp;`→`&` before following it.
- **De-dup** by `(resourceId, date, meterId)` when concatenating slices (slice boundaries use a
  half-open `[ge, lt)` filter, so overlaps shouldn't occur, but de-dup defensively).
- **Never proceed on silently-partial cost.** If some slice cannot complete even after halving,
  keep the rows you have **but explicitly label every downstream total as "partial — cost pull
  truncated, spend understated"** so the numbers aren't trusted as complete.
- The projected rows already match the shape `detect.py` expects:
  `{date, cost, meterCategory, resourceGroup, resourceId, tags}` — `date` from
  `properties.date`, `cost` from `properties.costInUSD`. For `resourceId` use
  **`properties.instanceName`** (in modern billing the full ARM resource id lives there and
  `properties.resourceId` is null); fall back to `properties.resourceId` when `instanceName`
  is absent.

### Step 2 — Detect (bundled detect.py, in-sandbox)

Read the detector and run it with `ExecutePythonCode`:

```
read_skill_file(skill_name="finops-cost-anomaly-detection", file_path="detect.py")
```

```python
from detect import detect_anomalies
anomalies = detect_anomalies(line_items)   # returns list ranked by impact_usd desc
```

`detect_anomalies` handles all detection rules — do **not** re-implement them in the prompt:

- Per-dimension trailing baseline (`meterCategory`, `resourceGroup`, `resourceId`); a spike fires
  when today exceeds `mean + k*std` **or** is ≥ `wow_ratio`× the same day last week, and only when
  the absolute change clears `min_delta_usd` (defaults `k=3`, `wow_ratio=1.5`, `min_delta_usd=$5`).
- Dimensions with no prior history are labelled `new_spend`, not `spike`.
- Billing lag: pass `assume_last_partial=True` (default) so the partial newest day is excluded and
  the last **complete** day is analysed. Never flag the partial trailing day.
- Results are ranked by **absolute dollar impact**, not percentage.

Tune via keyword args (`baseline_days`, `k`, `min_delta_usd`, `wow_ratio`) — daily watchers use
tighter settings than weekly ones.

### Step 3 — Correlate each spike to a probable cause

For every returned anomaly, gather evidence in the same date window (spike day ± 1) scoped to the
spiking `value` (resource / RG / meter):

- **Deployments:** `az deployment group list -g <RG>` and `az deployment sub list` — match
  `properties.timestamp` near the spike.
- **Activity log:** `az monitor activity-log list --start-time <T-1d> --end-time <T+1d>` — write
  and action operations on the resource/RG (scale, SKU change, create).
- **GitHub changes:** via the connector, `List Commits` / `List Pull Requests` (merged) near the
  spike date for the connected repo(s).

Join on **resource/RG identity + timestamp proximity**. Present matches as **candidate causes with
evidence links** — correlation, not proof. If nothing correlates, say so ("no deployment/change
found near this spike") rather than inventing a cause.

### Step 4 — Report

Emit a ranked list; each row: `{value, current_usd, dod_delta_usd, dod_delta_pct, wow_delta_usd,
date, kind, candidate cause(s) with links}`, plus a one-line executive summary. In scheduled mode,
**report only when `detect_anomalies` returns a non-empty list**; otherwise emit a short "no
anomalies" line.

## Delivery modes

- **Scheduled task (primary):** run daily/weekly; post the report only on a threshold crossing.
- **Interactive:** the `finops-investigator` subagent calls this skill for "did anything spike and
  why?" drill-downs.
- **Incident-time:** invoked during a reliability investigation to check whether an incident had a
  cost signature.

## Known limits

| Limit | Behavior |
|-------|----------|
| Billing lag (1-2 days) | `assume_last_partial=True` excludes the partial newest day |
| Microsoft Fabric cost | Not in the Consumption surface — out of scope; state it explicitly |
| Weak tag coverage | Where tags are missing, correlate on resource/RG identity instead of team/owner |
| Correlation != causation | Present candidate causes with evidence; do not claim certainty |
| Cost Management Reader missing | `costInUSD` is null — stop and report the missing grant, don't guess |

## Testing

`detect.py` is pure and offline-testable. Run `pytest tests/` at the repo root — see
`tests/test_detect.py` for the Layer-1 suite (known spike, tiny-meter floor, new-spend labelling,
flat-history no-false-alarm, week-over-week creep, dollar-impact ranking, partial-last-day
handling).
