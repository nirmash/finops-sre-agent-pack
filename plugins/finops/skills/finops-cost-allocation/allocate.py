"""FinOps cost-allocation (showback) — pure, offline, deterministic (no Azure calls).

Given per-resource monthly cost (from Consumption UsageDetails) and per-resource tags
(from Resource Graph), attribute every dollar to an owner dimension (team / env / service /
costCenter / app / owner) and — the governance win — surface the spend that **has no owner**.

Design decisions (see SKILL.md):
  * Shared / untaggable cost is NEVER force-allocated. Cost with no value for the requested
    dimension lands in an explicit "unallocated" bucket so the math stays honest and the gap
    is the actionable signal.
  * A resource missing a value for ALL ownership keys is "untagged" (dimension-independent) and
    is listed for tagging, ranked by cost.
  * Tag values are grouped case-insensitively (trimmed + lower-cased); the most costly raw
    spelling is shown. Values that collapse to the same owner are flagged as tag-hygiene issues
    (e.g. "Prod" vs "production") because they otherwise split one owner's spend.

Input shapes (all keyed/looked-up by resourceId, matched case-insensitively):

    costs   {resourceId: monthly_usd}                     # aggregated from UsageDetails costInUSD
    tags    {resourceId: {"team": "payments", "env": "Prod", ...}}   # from Resource Graph

Output: a single dict (see allocate_costs) — a showback breakdown, an unallocated bucket, a
ranked untagged-resource list, and tag-hygiene flags. Feed it to a table / Live Report.
"""

from collections import defaultdict

DEFAULT_OWNERSHIP_KEYS = ("team", "env", "service", "costCenter", "app", "owner")
DEFAULT_DIMENSION = "team"


def _key(resource_id) -> str:
    """Case-insensitive resource-id key (ARM ids are case-insensitive)."""
    return str(resource_id or "").strip().lower()


def _norm_val(value) -> str:
    """Normalize a tag value for grouping: trimmed + lower-cased. '' if empty."""
    return str(value or "").strip().lower()


def _tags_ci(tag_map):
    """Return a copy of a resource's tag dict with keys lower-cased for lookup."""
    return {str(k).strip().lower(): v for k, v in (tag_map or {}).items()}


def _lookup_tag(ci_tags, wanted_key):
    """Case-insensitive tag lookup; returns the raw value or None if absent/empty."""
    raw = ci_tags.get(str(wanted_key).strip().lower())
    return raw if _norm_val(raw) else None


def allocate_costs(
    costs=None,
    tags=None,
    *,
    dimension: str = DEFAULT_DIMENSION,
    ownership_keys=DEFAULT_OWNERSHIP_KEYS,
    top_n_resources: int = 25,
):
    """Attribute monthly cost to an owner dimension, keeping unallocated spend explicit.

    costs           {resourceId: monthly_usd}
    tags            {resourceId: {tagKey: tagVal}}
    dimension       the ownership tag key to group by (default "team")
    ownership_keys  the set that defines "tagged at all"; a resource with a value for NONE of
                    these is reported as untagged
    top_n_resources cap on how many resources are listed inside the unallocated/untagged details

    Returns a dict:
      {
        "dimension", "total_usd", "allocated_usd", "unallocated_usd", "unallocated_pct",
        "groups": [{"owner", "monthly_usd", "pct", "resource_count"}...] sorted desc,
        "unallocated": {"monthly_usd", "pct", "resource_count", "resources": [{resourceId, monthly_usd}...]},
        "untagged_resources": [{resourceId, monthly_usd}...],   # missing ALL ownership keys
        "untagged_usd",
        "tag_hygiene": [{"canonical", "variants": {raw: cost}, "cost_affected"}...],
      }
    """
    costs = costs or {}
    tags = tags or {}
    dim = str(dimension).strip()
    owner_keys = tuple(ownership_keys) or DEFAULT_OWNERSHIP_KEYS

    # index tags case-insensitively by resource id
    tags_by_id = {_key(rid): _tags_ci(t) for rid, t in tags.items()}

    group_cost = defaultdict(float)          # normalized owner value -> cost
    group_count = defaultdict(int)
    group_raw = defaultdict(lambda: defaultdict(float))  # norm -> {raw spelling: cost} (display + hygiene)
    unallocated_cost = 0.0
    unallocated = []                          # resources with no value for `dim`
    untagged = []                             # resources with no value for ANY ownership key
    total = 0.0

    for rid, monthly in costs.items():
        if not isinstance(monthly, (int, float)):
            continue
        total += monthly
        ci = tags_by_id.get(_key(rid), {})

        raw = _lookup_tag(ci, dim)
        if raw is not None:
            norm = _norm_val(raw)
            group_cost[norm] += monthly
            group_count[norm] += 1
            group_raw[norm][str(raw).strip()] += monthly
        else:
            unallocated_cost += monthly
            unallocated.append({"resourceId": rid, "monthly_usd": round(monthly, 2)})

        # untagged = no value for ANY ownership key (dimension-independent governance list)
        if not any(_lookup_tag(ci, k) for k in owner_keys):
            untagged.append({"resourceId": rid, "monthly_usd": round(monthly, 2)})

    allocated_cost = total - unallocated_cost

    groups = []
    for norm, cost in group_cost.items():
        display = max(group_raw[norm].items(), key=lambda kv: kv[1])[0]  # most-costly raw spelling
        groups.append({
            "owner": display,
            "monthly_usd": round(cost, 2),
            "pct": _pct(cost, total),
            "resource_count": group_count[norm],
        })
    groups.sort(key=lambda g: g["monthly_usd"], reverse=True)

    unallocated.sort(key=lambda r: r["monthly_usd"], reverse=True)
    untagged.sort(key=lambda r: r["monthly_usd"], reverse=True)
    untagged_usd = sum(r["monthly_usd"] for r in untagged)

    hygiene = []
    for norm, raws in group_raw.items():
        if len(raws) > 1:  # same owner spelled multiple ways -> splits their spend
            canonical = max(raws.items(), key=lambda kv: kv[1])[0]
            hygiene.append({
                "canonical": canonical,
                "variants": {k: round(v, 2) for k, v in sorted(raws.items(), key=lambda kv: kv[1], reverse=True)},
                "cost_affected": round(sum(raws.values()), 2),
            })
    hygiene.sort(key=lambda h: h["cost_affected"], reverse=True)

    return {
        "dimension": dim,
        "total_usd": round(total, 2),
        "allocated_usd": round(allocated_cost, 2),
        "unallocated_usd": round(unallocated_cost, 2),
        "unallocated_pct": _pct(unallocated_cost, total),
        "groups": groups,
        "unallocated": {
            "monthly_usd": round(unallocated_cost, 2),
            "pct": _pct(unallocated_cost, total),
            "resource_count": len(unallocated),
            "resources": unallocated[:top_n_resources],
        },
        "untagged_resources": untagged[:top_n_resources],
        "untagged_usd": round(untagged_usd, 2),
        "tag_hygiene": hygiene,
    }


def _pct(part, whole) -> float:
    """part/whole as a rounded percentage; 0.0 when whole is 0."""
    if not whole:
        return 0.0
    return round(100.0 * part / whole, 1)
