"""FinOps budget-editor — pure, offline, deterministic (no Azure calls).

**Advisory only.** This skill never creates or edits a budget. Given the budgets
returned by the read-only `GET Microsoft.Consumption/budgets` API, it computes a
recommended budget amount for each scope and renders the exact `az rest --method put`
command a human can review and run. The pack itself stays 100% read-only (Cost
Management *Reader*); actually applying the command needs a write role
(Cost Management *Contributor*) that a person supplies out-of-band.

Recommendation basis (see SKILL.md):
  * The recommended amount is `max(current_amount, forecast) * (1 + buffer)` rounded
    up to a clean number. `buffer` defaults to 15%.
  * `forecast` reuses the same logic as the read-only `budget-governance` skill: Azure's
    own `forecastSpend` when present, else a linear run-rate projection of `currentSpend`
    across the current time-grain window. (Those helpers are duplicated here on purpose —
    each skill file is loaded independently in-sandbox, so this module is self-contained.)
  * A budget whose forecast+buffer materially exceeds its amount is a `raise`; one whose
    forecast+buffer sits well under its amount is a `tighten`; otherwise `keep`. A budget
    with no usable amount is a `set`. No spend signal at all is `insufficient_data`.
  * Notifications: existing notifications are carried through unchanged; if a budget has
    none, a default Actual-80% + Forecasted-100% pair is suggested (with a placeholder
    contact email the human must fill in).

Empty input is a first-class result: with no budgets defined there is no spend basis to
size a budget from, so the skill says so and points at getting a spend figure first
rather than inventing a number.
"""

import math
from collections import defaultdict
from datetime import date

DEFAULT_BUFFER_PCT = 15.0            # headroom added on top of the forecast basis
_RAISE_MARGIN = 1.05                 # recommend a raise only when >5% above current amount
_TIGHTEN_MARGIN = 0.85               # recommend a tighten only when <85% of current amount
_PLACEHOLDER_EMAIL = "<your-email@example.com>"
_API_VERSION = "2023-05-01"

# Approximate number of days per time-grain window (used only if timePeriod can't bound it).
_GRAIN_DAYS = {
    "monthly": 30,
    "billingmonth": 30,
    "quarterly": 91,
    "billingquarter": 91,
    "annually": 365,
    "billingannual": 365,
}


def _num(value):
    """Return value as float, or None if it isn't a real number."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _spend_amount(block):
    """Read a {'amount': .., 'unit': ..} spend block; return (amount|None, unit|None)."""
    if not isinstance(block, dict):
        return None, None
    return _num(block.get("amount")), block.get("unit")


def _parse_date(text):
    """Parse an ISO-ish date ('YYYY-MM-DD' or full timestamp) to date; None on failure."""
    if not text:
        return None
    try:
        return date.fromisoformat(str(text)[:10])
    except ValueError:
        return None


def _grain_fraction_elapsed(time_grain, time_period, as_of):
    """Fraction (0, 1] of the current time-grain window elapsed as of `as_of`; None if unknown."""
    grain = str(time_grain or "monthly").strip().lower()
    days_in_window = _GRAIN_DAYS.get(grain, 30)

    start = _parse_date((time_period or {}).get("startDate"))
    end = _parse_date((time_period or {}).get("endDate"))
    if start and end and 0 < (end - start).days <= days_in_window + 2:
        days_in_window = (end - start).days
        elapsed = (as_of - start).days + 1
    elif grain in ("monthly", "billingmonth"):
        elapsed = min(as_of.day, days_in_window)
    else:
        elapsed = None

    if elapsed is None or days_in_window <= 0:
        return None
    elapsed = max(1, min(elapsed, days_in_window))
    return elapsed / days_in_window


def _forecast(props, current, as_of):
    """Forecast month-end spend: Azure's forecastSpend when present, else linear run-rate.

    Returns (forecast|None, source) where source is 'azure', 'run-rate', or 'unavailable'.
    """
    azure_forecast, _ = _spend_amount(props.get("forecastSpend"))
    if azure_forecast is not None:
        return azure_forecast, "azure"
    frac = _grain_fraction_elapsed(props.get("timeGrain"), props.get("timePeriod"), as_of)
    if frac and current:
        return round(current / frac, 2), "run-rate"
    return None, "unavailable"


def _round_up_nice(amount):
    """Round an amount UP to a clean step sized to its magnitude (10/50/100/1000)."""
    if amount <= 0:
        return 0.0
    if amount < 100:
        step = 10
    elif amount < 1000:
        step = 50
    elif amount < 10000:
        step = 100
    else:
        step = 1000
    return float(step * math.ceil(amount / step))


def _scope_of(budget, props):
    """Best-effort human scope: the budget's resource-group/subscription id path, else category."""
    bid = str(budget.get("id") or "")
    if "/providers/Microsoft.Consumption" in bid:
        return bid.split("/providers/Microsoft.Consumption")[0]
    return props.get("category") or "subscription"


def _suggested_notifications(props):
    """Carry through existing notifications; if none, suggest a default Actual/Forecasted pair.

    Returns (notifications_dict, added_bool) where added is True when we injected defaults.
    """
    existing = props.get("notifications")
    if isinstance(existing, dict) and existing:
        return existing, False
    default = {
        "actual_80": {
            "enabled": True, "operator": "GreaterThan", "threshold": 80,
            "thresholdType": "Actual", "contactEmails": [_PLACEHOLDER_EMAIL],
        },
        "forecasted_100": {
            "enabled": True, "operator": "GreaterThan", "threshold": 100,
            "thresholdType": "Forecasted", "contactEmails": [_PLACEHOLDER_EMAIL],
        },
    }
    return default, True


def _put_body(props, recommended, notifications):
    """Assemble the PUT properties body for the recommended budget."""
    body = {
        "properties": {
            "category": props.get("category") or "Cost",
            "amount": recommended,
            "timeGrain": props.get("timeGrain") or "Monthly",
            "notifications": notifications,
        }
    }
    time_period = props.get("timePeriod")
    if isinstance(time_period, dict) and time_period.get("startDate"):
        body["properties"]["timePeriod"] = {
            "startDate": time_period.get("startDate"),
            "endDate": time_period.get("endDate"),
        }
    return body


def _command(put_url, body):
    """Render a copy-pasteable az command that writes the recommended budget."""
    import json
    return (
        "az rest --method put \\\n"
        f'  --url "{put_url}" \\\n'
        '  --headers "Content-Type=application/json" \\\n'
        f"  --body '{json.dumps(body)}'"
    )


def _classify(current_amount, recommended):
    """raise / tighten / keep / set, comparing the recommended amount to the current one."""
    if not current_amount:
        return "set"
    if recommended > current_amount * _RAISE_MARGIN:
        return "raise"
    if recommended < current_amount * _TIGHTEN_MARGIN:
        return "tighten"
    return "keep"


def _rationale(action, current_amount, forecast, forecast_source, recommended, buffer_pct, currency):
    """One-line human explanation for the recommendation."""
    basis = f"forecast {forecast} {currency} ({forecast_source})" if forecast is not None else "current spend"
    buf = f"+{buffer_pct:g}% buffer"
    if action == "set":
        return f"no usable current amount; size to {basis} {buf} -> {recommended} {currency}"
    if action == "raise":
        return f"{basis} {buf} exceeds current {current_amount} {currency}; raise to {recommended} {currency}"
    if action == "tighten":
        return f"{basis} {buf} is well under current {current_amount} {currency}; tighten to {recommended} {currency}"
    return f"current {current_amount} {currency} already covers {basis} {buf}; keep"


def recommend_budgets(budgets=None, *, as_of=None, buffer_pct=DEFAULT_BUFFER_PCT):
    """Recommend a right-sized amount for each budget and render the exact write command.

    budgets      the `value[]` list from GET Microsoft.Consumption/budgets
    as_of        date the run-rate forecast is anchored to (defaults to today)
    buffer_pct   headroom added on top of the forecast basis (default 15)

    Returns a dict:
      {
        "as_of", "buffer_pct", "budget_count",
        "recommendations": [ {name, scope, action, current_amount, currency,
                              forecast_spend, forecast_source, recommended_amount,
                              notifications_added, rationale, put_url, put_body, command} ... ],
        "summary": {raise, tighten, keep, set, insufficient_data},
        "no_budgets": bool,   # True + guidance when nothing is defined
      }
    """
    budgets = budgets or []
    today = as_of or date.today()
    buffer_mult = 1.0 + (buffer_pct / 100.0)

    if not budgets:
        return {
            "as_of": today.isoformat(),
            "buffer_pct": buffer_pct,
            "budget_count": 0,
            "recommendations": [],
            "summary": {"raise": 0, "tighten": 0, "keep": 0, "set": 0, "insufficient_data": 0},
            "no_budgets": True,
        }

    recommendations = []
    tally = defaultdict(int)

    for b in budgets:
        props = b.get("properties") or {}
        name = b.get("name") or props.get("name") or "(unnamed)"
        current_amount = _num(props.get("amount"))
        current_spend, currency = _spend_amount(props.get("currentSpend"))
        current_spend = current_spend or 0.0
        currency = currency or "USD"

        forecast, forecast_source = _forecast(props, current_spend, today)
        # Basis for sizing: the largest defensible spend signal we have.
        basis = max(forecast or 0.0, current_spend, 0.0)

        if basis <= 0:
            recommendations.append({
                "name": name,
                "scope": _scope_of(b, props),
                "action": "insufficient_data",
                "current_amount": round(current_amount, 2) if current_amount is not None else None,
                "currency": currency,
                "forecast_spend": forecast,
                "forecast_source": forecast_source,
                "recommended_amount": None,
                "notifications_added": False,
                "rationale": "no forecast or spend signal yet (currentSpend may be unsynced); "
                             "cannot size a budget — get a spend figure first",
                "put_url": None,
                "put_body": None,
                "command": None,
            })
            tally["insufficient_data"] += 1
            continue

        recommended = _round_up_nice(basis * buffer_mult)
        action = _classify(current_amount, recommended)
        notifications, added = _suggested_notifications(props)
        put_url = f"{b.get('id')}?api-version={_API_VERSION}" if b.get("id") else None
        body = _put_body(props, recommended, notifications)
        command = _command(put_url, body) if put_url else None

        recommendations.append({
            "name": name,
            "scope": _scope_of(b, props),
            "action": action,
            "current_amount": round(current_amount, 2) if current_amount is not None else None,
            "currency": currency,
            "forecast_spend": forecast,
            "forecast_source": forecast_source,
            "recommended_amount": recommended,
            "notifications_added": added,
            "rationale": _rationale(action, current_amount, forecast, forecast_source,
                                    recommended, buffer_pct, currency),
            "put_url": put_url,
            "put_body": body,
            "command": command,
        })
        tally[action] += 1

    # Surface the budgets that would change (raise/set/tighten) ahead of keep/no-op ones.
    recommendations.sort(key=lambda r: _ACTION_ORDER.get(r["action"], 0), reverse=True)

    return {
        "as_of": today.isoformat(),
        "buffer_pct": buffer_pct,
        "budget_count": len(budgets),
        "recommendations": recommendations,
        "summary": {
            "raise": tally["raise"],
            "tighten": tally["tighten"],
            "keep": tally["keep"],
            "set": tally["set"],
            "insufficient_data": tally["insufficient_data"],
        },
        "no_budgets": False,
    }


_ACTION_ORDER = {"raise": 4, "set": 3, "tighten": 2, "insufficient_data": 1, "keep": 0}
