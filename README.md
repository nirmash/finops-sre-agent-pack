# finops-sre-agent-pack

FinOps capabilities for [Azure SRE Agent](https://azure.microsoft.com/en-us/products/sre-agent),
packaged as **skills + agents** — not as changes to the SRE Agent product. Everything runs on
existing agent tools (read-only `az`, Resource Graph, Azure Monitor, the GitHub connector, and
in-sandbox Python), so it ships and iterates on its own cadence with no product release.

Structure mirrors [Azure/sre-agent-plugins](https://github.com/Azure/sre-agent-plugins).

> **Note:** These skills are designed for use with the Azure SRE Agent and may not work with other
> coding agents.

## Plugins

| Plugin | Description |
|--------|-------------|
| [`finops`](plugins/finops/README.md) | **Cost anomaly package** — the `cost-anomaly-detection` skill + a proactive daily scheduled task (`FinOps: Cost Anomaly Detection (Daily)`), installable with one command via the agent API ([`plugins/finops/install-api.sh`](plugins/finops/install-api.sh), no srectl needed) or [`install.sh`](plugins/finops/install.sh). Plus planned rightsizing, showback, budget governance, FinOps-for-AI, reporting, and cost-vs-reliability skills. |

## Adding plugins

1. Add the plugin directory under `plugins/`.
2. Add an entry for the plugin in [`.github/plugin/marketplace.json`](.github/plugin/marketplace.json).

## Design & requirements background

The feature catalog, live data-source validation, and customer-requirement mapping that motivate
this pack live in the product-research doc (`finops-sre-agent-product-research.md`, §5A and §10).
All 13 FinOps data sources were validated live against a deployed SRE Agent before any skill was
written.

## Test

```bash
pip install -r requirements-dev.txt
pytest tests/
```
