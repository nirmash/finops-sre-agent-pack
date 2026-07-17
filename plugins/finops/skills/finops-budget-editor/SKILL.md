---
name: finops-budget-editor
description: Advisory budget right-sizing for Azure. Reads native Azure Cost Management budgets (GET Microsoft.Consumption/budgets — amount, currentSpend, and forecastSpend when present) and, for each scope, computes a recommended budget amount sized to max(current amount, forecast) plus a headroom buffer (default 15%), reusing the same run-rate forecast as budget-governance when Azure supplies none. It then renders the exact `az rest --method put` command a human can review and run — using the bundled recommend.py (run in-sandbox via ExecutePythonCode). It NEVER writes: the pack stays read-only and applying the command needs a Cost Management Contributor role the user supplies. Use for "what should my budget be", "is my budget too low/high", right-sizing an existing budget, or drafting a budget to set.
---

## When to use this skill

Use it when the user wants a **recommended budget amount** — "what should my Azure budget be",
"is my budget too low / too high", "right-size my budget", or "draft the budget I should set". It
reads the customer's existing Azure Cost Management budgets, sizes a recommendation to their
forecast plus headroom, and hands back the **exact command to apply it** for a human to run.

This skill is **advisory and read-only**. It computes and prints a recommendation plus the write
command; it does **not** execute the write. For a read-only *status* check (are we on budget, what is
the forecast) use `finops-budget-governance`. For cost spikes use `finops-cost-anomaly-detection`;
for idle/oversized waste use `finops-rightsizing-advisor`; for who owns the spend use
`finops-cost-allocation`.

## Required access

- **Cost Management Reader** (or **Reader**) on the subscription — enough to `GET
  Microsoft.Consumption/budgets`. This skill reads only.
- Read-only `az` (`RunAzCliReadCommands`) and `ExecutePythonCode` (in-sandbox evaluation). **No
  POST/PUT/write APIs are called by the skill.**
- **Applying** the recommendation (running the printed `az rest --method put`) requires **Cost
  Management Contributor** on the budget scope — a write role that a person supplies out-of-band. The
  skill deliberately stops at the recommendation so the pack keeps its read-only, zero-blast-radius
  guarantee.

## Scope

Right-sizes every budget returned by the budgets GET at the requested scope (subscription or a
resource group). It is **service-agnostic** — it works off the budget objects Azure returns. With
**no budgets defined** there is no spend basis to size from, so the skill says so and points at
getting a spend figure first (e.g. the `finops-cost-allocation` / Cost Overview report) rather than
inventing a number. Azure's own `forecastSpend` is preferred when present; when it is absent the
skill reuses `budget-governance`'s **linear run-rate** forecast in-sandbox and labels the source.
Multi-currency portfolios and management-group rollups are out of scope until needed.

## Procedure

### Step 1 — Read the budgets (read-only GET)

Pull the native budgets at the target scope. Subscription scope:

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" \
  -o json
```

For a resource-group budget, use
`.../subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Consumption/budgets`. The response
is `{"value": [ ... ]}`; pass the whole `value` array to Step 2. Each budget carries
`properties.amount`, `properties.timeGrain`, `properties.timePeriod`, `properties.currentSpend`
(`{amount, unit}`), an optional `properties.forecastSpend`, and `properties.notifications`. **If
`value` is empty, skip to Step 3 and report "no budgets defined".**

> **`currentSpend` freshness.** Azure computes each budget's `currentSpend` asynchronously: a **newly
> created** budget reads `currentSpend: 0` for hours. When there is no forecast and no spend signal,
> `recommend.py` returns `insufficient_data` for that budget rather than sizing it to zero — treat
> that as "get a real spend figure first", not "set a $0 budget". Do **not** try to reconstruct
> month-to-date spend with a UsageDetails pull — that heavy, `413`-prone query is unnecessary, and the
> clean Cost Management aggregate query is a `POST`, which the read-only tooling blocks.

### Step 2 — Recommend (bundled recommend.py, in-sandbox)

Read the module and run it — do **not** re-implement the logic in the prompt:

```
read_skill_file(skill_name="finops-budget-editor", file_path="recommend.py")
```

```python
from recommend import recommend_budgets
result = recommend_budgets(budgets)              # the value[] array from Step 1
# result = recommend_budgets(budgets, buffer_pct=10)   # override the default 15% headroom
```

`recommend_budgets` handles all math and command generation:

- **recommendations**: per-budget, sorted so the ones that would change come first. Each carries
  `current_amount`, `forecast_spend` + `forecast_source` (`azure` or `run-rate`),
  `recommended_amount` (`max(current_amount, forecast) × (1 + buffer)`, rounded up to a clean
  number), an **action**, a one-line `rationale`, and the ready-to-run **`command`** (plus `put_url`
  and `put_body` if you want to render them yourself).
- **action** buckets: `raise` (recommended materially above the current amount) → `set` (no usable
  current amount) → `tighten` (recommended well under the current amount) → `keep` (already
  right-sized) → `insufficient_data` (no forecast or spend signal yet).
- **notifications_added**: `True` when the budget had no notifications and the recommendation injected
  a default Actual-80% + Forecasted-100% pair — that pair contains a **placeholder email the user must
  replace** before running the command.
- **summary**: a count of each action. **no_budgets**: `True` when nothing is defined.

### Step 3 — Report

Produce a **budget recommendation table** (name, scope, current amount, forecast + source,
**recommended amount**, action). Lead with the budgets whose `action` is `raise` / `set` / `tighten`
— those are the ones worth changing — each with its `rationale`. For each such budget, show the exact
**`command`** in a fenced block so the user can review and run it themselves, and **state plainly that
this skill does not run it**: applying it needs Cost Management Contributor. Where a forecast is
`run-rate` (not Azure's), say it is an estimate. Where `notifications_added` is `True`, tell the user
to **replace the placeholder `<your-email@example.com>`** before running. For `insufficient_data`
budgets, explain the spend signal is missing (likely an unsynced `currentSpend`) and recommend
re-running once it syncs. If **no budgets are defined**, say so and recommend getting a spend figure
(Cost Overview / `finops-cost-allocation`) before drafting one. If every budget is `keep`, say so in
one line.
