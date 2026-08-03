# Budget editor example

Run from the repository root. This function is advisory: the returned command is
not executed.

```python
import importlib.util
from datetime import date
from pathlib import Path

path = Path("plugins/finops/skills/finops-budget-editor/recommend.py")
spec = importlib.util.spec_from_file_location("recommend", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

budgets = [{
    "name": "prod-monthly",
    "id": "/subscriptions/000/providers/Microsoft.Consumption/budgets/prod-monthly",
    "properties": {
        "amount": 1000.0,
        "category": "Cost",
        "timeGrain": "Monthly",
        "currentSpend": {"amount": 800.0, "unit": "USD"},
    },
}]

report = module.recommend_budgets(
    budgets,
    as_of=date(2026, 7, 15),
    buffer_pct=15,
)
```

Representative output (abbreviated):

```json
{
  "as_of": "2026-07-15",
  "buffer_pct": 15,
  "budget_count": 1,
  "recommendations": [{
    "name": "prod-monthly",
    "scope": "/subscriptions/000",
    "action": "raise",
    "current_amount": 1000.0,
    "forecast_spend": 1600.0,
    "forecast_source": "run-rate",
    "recommended_amount": 1900.0,
    "notifications_added": true,
    "put_url": "/subscriptions/000/providers/Microsoft.Consumption/budgets/prod-monthly?api-version=2023-05-01",
    "put_body": {"properties": {"amount": 1900.0, "...": "abbreviated"}},
    "command": "az rest --method put ..."
  }],
  "summary": {
    "raise": 1,
    "tighten": 0,
    "keep": 0,
    "set": 0,
    "insufficient_data": 0
  },
  "no_budgets": false
}
```
