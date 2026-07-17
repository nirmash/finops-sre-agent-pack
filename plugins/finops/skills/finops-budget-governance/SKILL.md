---
name: finops-budget-governance
description: Proactive budget governance for Azure, read-only. Reads native Azure Cost Management budgets (GET Microsoft.Consumption/budgets — amount, currentSpend, and forecastSpend when present) and evaluates each against its amount and its own notification thresholds; where Azure supplies no forecast it computes a linear run-rate month-end projection in-sandbox, so every budget gets a landing estimate. Surfaces budgets that are over, forecast-to-exceed, or at-risk, ranks them by severity, and flags the ones that warrant a process gate (a human decision before more is spent) — using the bundled budget.py (run in-sandbox via ExecutePythonCode). Use for "are we on budget", burn-rate / forecast checks, and month-end overrun early warning.
---

## When to use this skill

Use it when the user wants a **proactive read on Azure spend against defined budgets** — "are we on
budget this month", "will any budget blow past its cap", burn-rate / run-rate checks, or an early
warning before a month-end overrun. It reads the customer's own Azure Cost Management budgets and
tells them which are over, which are *forecast* to go over, and which need a decision now. It is
read-only: it reports and recommends, but never creates or edits a budget.

For cost *spikes* and their cause use `finops-cost-anomaly-detection`; for idle/oversized waste use
`finops-rightsizing-advisor`; for *who owns the spend* use `finops-cost-allocation`. Editing or
creating budgets is the separate, planned `budget-editor` write skill — this skill only reads.

## Required access

- **Cost Management Reader** (or **Reader**) on the subscription — enough to `GET
  Microsoft.Consumption/budgets`. No write role is needed or used.
- Read-only `az` (`RunAzCliReadCommands`) and `ExecutePythonCode` (in-sandbox evaluation). No
  POST/PUT/write APIs are called.

## Scope

Evaluates every budget returned by the budgets GET at the requested scope (subscription or a resource
group). It is **service-agnostic** — it works off the budget objects Azure returns, not a hard-coded
resource list. A budget with **no budgets defined** is a first-class result: the skill reports "no
budgets defined" and recommends creating one (a job for the future `budget-editor`) rather than
failing silently. Azure's own `forecastSpend` is preferred when present; when it is absent (it often
is on the GET response) the skill computes a **linear run-rate** month-end forecast in-sandbox and
labels the source. Multi-currency portfolios and management-group rollups are out of scope until
needed.

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
is `{"value": [ ... ]}`; pass the whole `value` array to Step 3. Each budget carries
`properties.amount`, `properties.timeGrain`, `properties.timePeriod`, `properties.currentSpend`
(`{amount, unit}` — spend so far in the current grain window), an optional `properties.forecastSpend`,
and `properties.notifications` (each with a percent `threshold` and a `thresholdType` of `Actual` or
`Forecasted`). **If `value` is empty, skip to Step 4 and report "no budgets defined".**

### Step 2 — (Optional) independent month-to-date cross-check

Only when the user wants to validate Azure's `currentSpend`, pull month-to-date actuals with the
**same hardened Consumption UsageDetails pull as `finops-cost-anomaly-detection` Step 1** (modern GET
in 3-day date-windowed slices with `\$top=1000`, `--query` field projection, paginate `nextLink`,
concatenate; halve the slice and drop `\$top` on a `413`; label partial if truncated). Sum
`costInUSD` for the current month and pass it as `mtd_spend={budgetName: mtd_usd}` so the skill can
flag a large discrepancy between the agent's sum and Azure's `currentSpend`. Skip this step for a
plain budget check.

### Step 3 — Evaluate (bundled budget.py, in-sandbox)

Read the module and run it — do **not** re-implement the logic in the prompt:

```
read_skill_file(skill_name="finops-budget-governance", file_path="budget.py")
```

```python
from budget import evaluate_budgets
result = evaluate_budgets(
    budgets,                       # the value[] array from Step 1
    mtd_spend=mtd_spend,           # optional, from Step 2  {budgetName: mtd_usd}
)
```

`evaluate_budgets` handles all math and classification:

- **budgets**: per-budget evaluation ranked by severity — `current_spend`, `pct_used`,
  `forecast_spend` + `forecast_source` (`azure` when Azure supplied it, else `run-rate`), `pct_forecast`,
  `status`, the budget's own **breached_notifications**, and the optional **mtd_crosscheck**.
- **status** buckets: `over_budget` (already ≥ amount) → `forecast_over` (projected ≥ amount) →
  `at_risk` (≥ 80% used or an Actual threshold breached) → `on_track`.
- **summary**: portfolio totals (`total_amount`, `total_current`, `total_forecast`) and a count of each
  status.
- **gates**: the budgets in `over_budget` / `forecast_over` — the ones that warrant a **process gate**
  (a human decision before more is spent), each with a one-line reason.
- **no_budgets**: `True` when nothing is defined — report it and recommend creating a budget.

### Step 4 — Report

Produce a **budget status table** (name, scope, amount, spent + `pct_used`, forecast + `pct_forecast`
+ source, status), with the **portfolio totals** row and any **gated** budgets called out at the top as
the action items (with their reason). List each budget's **breached notification thresholds**. If a
forecast is `run-rate` (not Azure's), say so — it is an estimate. If the month-to-date cross-check
shows a large delta, flag it. If **no budgets are defined**, say that plainly and recommend creating
one (pointing at the future `budget-editor` skill). If every budget is `on_track`, say so in one line.
