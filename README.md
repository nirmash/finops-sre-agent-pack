# finops-sre-agent-pack

FinOps capabilities for [Azure SRE Agent](https://azure.microsoft.com/en-us/products/sre-agent),
packaged as **skills + agents** — not as changes to the SRE Agent product. The pack and its agent use
read-only Azure tools. Budget planning can produce a governed shell script for a human to review,
save, and run manually with their own permissions; the agent never executes it.

Structure mirrors [Azure/sre-agent-plugins](https://github.com/Azure/sre-agent-plugins).

> **Note:** These skills are designed for use with the Azure SRE Agent and may not work with other
> coding agents.

## Plugins

| Plugin | Description |
|--------|-------------|
| [`finops`](plugins/finops/README.md) | **FinOps pack** — eight read-only FinOps skills, the standalone `finops-investigator` agent, and eight proactive read-only scheduled tasks including six Live Reports. Budget planning can generate a validated human-run application script. |

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
pytest tests/          # 204 offline tests, including 78 budget recommendation/proposal/script tests
```
