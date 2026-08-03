---
name: finops-budget-editor
description: Advisory Azure budget recommendations and deterministic create/update planning. Produces validated proposals and governed shell scripts for a human to review, save, and run manually; the agent never executes budget writes.
---

# FinOps budget planner

Use this skill for budget recommendations or for a reviewable plan to create/update **one** Azure
Cost Management budget. The skill is planning-only: it may return an exact PUT body, command, and
human-run application script, but the agent must never execute them.

For status only, use `finops-budget-governance`. This skill does not plan deletes, bulk mutations,
scheduled mutations, or filtered budget creation.

## Supported plans

- Scopes:
  - `/subscriptions/{subscriptionId}`
  - `/subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}`
  - `/providers/Microsoft.Management/managementGroups/{managementGroupId}`
- Time grains: `Monthly`, `Quarterly`, `Annually`.
- Creates are scope-wide. Reject a create with a filter.
- API `2023-05-01` plans use category `Cost` only.
- Updates preserve time grain, valid time period, filter, and notifications unless explicitly
  changed.
- A create requires `timePeriod.startDate` on the first day of a month at `00:00:00Z`, no earlier
  than `2017-06-01` and no later than the first day of the month 12 months after planning time.
  A create or explicit time-period change cannot start before the current selected grain period
  (current month, quarter, or year). Preserved historical periods on updates remain valid.
  `endDate` is optional; when present it only needs to be after `startDate`.
- Every create, and every update whose current notifications are unusable, requires at least one
  real email or Azure action group. A role-only notification does not satisfy this product policy.
  Management-group budgets specifically require a real email; an action-group-only notification is
  insufficient there, and management-group notifications must not contain `contactGroups`.
- Defaults with supplied contacts are Actual 80% and Forecasted 100%. Explicit valid notifications
  may override them. Operators are `EqualTo`, `GreaterThan`, or `GreaterThanOrEqualTo`, with at most
  five notifications.
- Never produce a command or script containing a placeholder contact.

The generated script runs under the human's Azure CLI identity. The pack does not grant RBAC. The
human needs Cost Management Contributor (or equivalent budget write permission) at the target scope.

## Choose the output

### Recommendation-only

For “what should my budget be?” or other advisory language:

1. Read relevant budgets with `RunAzCliReadCommands`.
2. Load `recommend.py` with `ExecutePythonCode` and call `recommend_budgets`.
3. Report amounts, evidence, assumptions, and missing contacts. Do not run any generated command.

### Create/update planning

For an explicit request to plan, draft, create, or update one named budget, build the deterministic
proposal below. Return its **application script as the primary artifact**. Do not execute it.

## Planning procedure

### 1. Read the exact current budget

Construct the exact resource URL:

```text
https://management.azure.com/{scope}/providers/Microsoft.Consumption/budgets/{encoded-name}?api-version=2023-05-01
```

Use `RunAzCliReadCommands` with `az rest --method get`. A returned object means `update`; a confirmed
404 means `create`. Any other read failure must be disclosed. Pass the exact returned object to
`build_budget_proposal(exact_budget=...)`, or `None` only after a confirmed absence. Do not infer
existence from a list response. An update exact GET must include its top-level `eTag`; otherwise the
helper refuses to emit an executable command/script. Update PUT bodies carry that captured top-level
`eTag` as required by the Consumption Budget contract.

### 2. Establish the amount

Use a positive explicit amount when supplied. Otherwise fetch bounded Consumption UsageDetails
`ActualCost` with **GET only**, minimal fields, complete `nextLink` pagination, and enough history:

- Monthly: current month plus 3 complete months.
- Quarterly: current quarter plus 4 complete quarters.
- Annually: current year plus the prior complete year.

Use a bounded URL of this form, encoding the real filter. Lower `$top` on 413, verify returned dates,
and disclose/stop on missing pages:

```bash
az rest --method get \
  --url "https://management.azure.com/{scope}/providers/Microsoft.Consumption/usageDetails?api-version=2023-05-01&metric=ActualCost&\$filter=properties/usageStart ge '<START>' and properties/usageEnd le '<END>'&\$top=1000" \
  --query "{value:value[].{date:properties.date,cost:properties.costInUSD},nextLink:nextLink}" \
  -o json
```

Aggregate offline:

```python
period_totals = {
    "current_period_total": 4200.0,
    "prior_complete_period_totals": [3900.0, 4050.0, 4100.0],
    "partial": False,
    "warnings": [],
}
```

Deterministic basis:

- Monthly: `max(current-month run rate, average prior 3 complete months)`.
- Quarterly: `max(current-quarter run rate, average prior 4 complete quarters)`.
- Annually: `max(current-year run rate, prior complete year)`.

Add headroom (default 15%) and reuse the helper's nice upward rounding. Never use the POST Cost
Management Query API. If aggregates are partial/incomplete, do not derive an executable plan. A
human-supplied explicit amount may still be planned, with a prominent partial-evidence warning.

### 3. Build the proposal and script

Load the bundled helper; do not recreate validation or quoting:

```python
from recommend import build_budget_proposal

proposal = build_budget_proposal(
    scope=scope,
    name=name,
    exact_budget=exact_budget,
    amount=amount,                   # or period_totals=period_totals
    time_grain="Monthly",            # omit on update to preserve
    time_period={
        "startDate": "2026-08-01T00:00:00Z",
        "endDate": "2027-08-01T00:00:00Z",
    },
    contacts=["owner@contoso.com"],  # or explicit notifications={...}
)
```

Present:

- operation, scope, name, before/after, and amount evidence/warnings;
- PUT URL/body and post-write GET URL;
- `application_script` (also available as `script`) in a fenced `bash` block;
- the exact confirmation phrase embedded in the script.

The script is self-contained and dependency-light (`bash`, `az`, `python3`). It uses
`set -euo pipefail`, shell-quotes all generated values, requires an exact preflight GET, and aborts
an update if the persisted PUT-controlled state differs from the proposal's captured `before`
state. A create aborts if the budget now exists. The PUT also sends `If-Match=<captured eTag>` for
updates or `If-None-Match=*` for creates, making the final write conditional. It then requires the
human to type the exact confirmation phrase, performs one PUT, performs an exact GET read-back, and
compares all PUT-controlled fields with exact decimal numeric equality. If an open-ended expected
`timePeriod` omits `endDate`, Azure's returned default `endDate` is the only controlled server
default ignored. It exits nonzero on mismatch. The legacy `command` field remains
available for compatibility, but lead with
the governed script.

### 4. Hand off to the human

Tell the human to:

1. review the scope, name, amount, notifications, filter, URL, and body;
2. save the fenced script locally;
3. sign in with `az` using an identity that already has budget write access;
4. run the script themselves and type the exact phrase only if the proposal is still intended;
5. treat only a zero exit plus “read-back matches” as successful persistence.

The agent does not run the script, invoke a write tool, grant a role, or claim that the plan was
applied.

## Hard restrictions

- No agent-executed PUT/POST/PATCH/DELETE.
- No write tool in the agent manifest.
- No DELETE, bulk plan, filtered create, or scheduled mutation.
- No placeholder contacts or invalid proposal script.
- No role assignment or RBAC change.
