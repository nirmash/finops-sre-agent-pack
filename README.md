# finops-sre-agent-pack

FinOps capabilities for [Azure SRE Agent](https://azure.microsoft.com/en-us/products/sre-agent),
packaged as **skills + agents** — not as changes to the SRE Agent product. The pack and its agent use
read-only Azure tools. Budget planning can produce a governed shell script for a human to review,
save, and run manually with their own permissions; the agent never executes it.

Structure mirrors [Azure/sre-agent-plugins](https://github.com/Azure/sre-agent-plugins).

> **Note:** These skills are designed for use with the Azure SRE Agent and may not work with other
> coding agents.

## Included plugin

| Plugin | Description |
|--------|-------------|
| [`finops`](plugins/finops/README.md) | **FinOps pack** — eight read-only FinOps skills, the standalone `finops-investigator` agent, and eight proactive read-only scheduled tasks including six Live Reports. Budget planning can generate a validated human-run application script. |

## Install

The supported installer installs the complete **`finops` plugin package** from this repository: all
eight skills, `finops-investigator`, eight scheduled tasks, and six Live Reports. It does not install
unrelated plugins from the marketplace.

The installer uses the SRE Agent management API and requires `az`, `curl`, and `python3`. Sign in
with `az login`, then run:

```bash
AGENT_RESOURCE_ID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/agents/<agent> \
  ./plugins/finops/install-api.sh
```

While this repository is private, provide a GitHub token so the agent service can clone it:

```bash
GITHUB_PAT="$(gh auth token)" \
AGENT_RESOURCE_ID=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/agents/<agent> \
  ./plugins/finops/install-api.sh
```

To optionally grant Cost Management Reader to the agent's managed identity during installation, also
set `MI_OBJECT_ID=<agent-mi-object-id>`. The installer adds no budget-write permissions. See the
[FinOps plugin documentation](plugins/finops/README.md#install-everything-recommended) for all
configuration options and installed components.

## Contributing another plugin

This section is for repository contributors, not an additional installation step:

1. Add the new plugin directory under `plugins/`.
2. Add its marketplace entry to [`.github/plugin/marketplace.json`](.github/plugin/marketplace.json).
3. Provide a plugin-specific installer or extend the package installer intentionally; the existing
   `plugins/finops/install-api.sh` installs only the `finops` package.

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
