"""Managed-scope enforcement for FinOps skills.

Pure, dependency-free, deterministic logic.  This module never calls Azure.  Callers
must retrieve the agent's managedResources and any management-group descendants, then
pass those values to the functions below.
"""

from __future__ import annotations

import hashlib
import json
import re
from decimal import Decimal, InvalidOperation


_SUBSCRIPTION_RE = re.compile(r"^/subscriptions/([^/]+)$", re.IGNORECASE)
_RESOURCE_GROUP_RE = re.compile(
    r"^/subscriptions/([^/]+)/resourcegroups/([^/]+)$", re.IGNORECASE
)
_MANAGEMENT_GROUP_RE = re.compile(
    r"^/providers/microsoft\.management/managementgroups/([^/]+)$",
    re.IGNORECASE,
)
_INVALID_PATH_CHARS = frozenset("\\?#")


def _segment(value, field):
    text = str(value or "")
    if not text or text != text.strip():
        raise ValueError(f"{field} must be non-empty and have no surrounding whitespace")
    if "/" in text or any(ord(char) < 32 for char in text) or any(
        char in _INVALID_PATH_CHARS for char in text
    ):
        raise ValueError(f"{field} contains unsafe path characters")
    return text


def _scope_value(value):
    if isinstance(value, dict):
        lowered = {str(key).lower(): item for key, item in value.items()}
        for key in ("id", "resourceid", "scope"):
            if lowered.get(key):
                return lowered[key]
        raise ValueError("managed resource object must contain id, resourceId, or scope")
    return value


def canonicalize_scope(scope):
    """Validate and canonicalize a subscription, resource-group, or MG scope ID.

    ARM path keywords use canonical casing; caller-provided identifier casing is
    preserved. Surrounding whitespace and trailing slashes are harmlessly removed.
    """

    raw = str(_scope_value(scope) or "").strip()
    if raw != "/":
        raw = raw.rstrip("/")

    match = _SUBSCRIPTION_RE.fullmatch(raw)
    if match:
        subscription = _segment(match.group(1), "subscriptionId")
        return f"/subscriptions/{subscription}"

    match = _RESOURCE_GROUP_RE.fullmatch(raw)
    if match:
        subscription = _segment(match.group(1), "subscriptionId")
        resource_group = _segment(match.group(2), "resourceGroupName")
        return f"/subscriptions/{subscription}/resourceGroups/{resource_group}"

    match = _MANAGEMENT_GROUP_RE.fullmatch(raw)
    if match:
        management_group = _segment(match.group(1), "managementGroupId")
        return (
            "/providers/Microsoft.Management/managementGroups/"
            f"{management_group}"
        )

    raise ValueError(
        "scope must be a subscription, resource group, or management group ARM scope ID"
    )


canonical_scope = canonicalize_scope
canonicalize_scope_id = canonicalize_scope


def validate_scope(scope):
    """Return the canonical scope, or raise ValueError when unsupported/malformed."""

    return canonicalize_scope(scope)


validate_scope_id = validate_scope


def scope_kind(scope):
    canonical = canonicalize_scope(scope)
    lowered = canonical.lower()
    if lowered.startswith("/subscriptions/") and "/resourcegroups/" in lowered:
        return "resource_group"
    if lowered.startswith("/subscriptions/"):
        return "subscription"
    return "management_group"


def _subscription_scope(value):
    raw = str(value or "").strip().rstrip("/")
    lowered = raw.casefold()
    if "/subscriptions/" in lowered and not lowered.startswith("/subscriptions/"):
        raw = raw.rsplit("/", 1)[-1]
    if raw.lower().startswith("/subscriptions/"):
        canonical = canonicalize_scope(raw)
        if scope_kind(canonical) != "subscription":
            raise ValueError(f"expected subscription scope, got {raw!r}")
        return canonical
    return f"/subscriptions/{_segment(raw, 'subscriptionId')}"


def _management_group_scope(value):
    raw = str(value or "").strip()
    if raw.lower().startswith("/providers/"):
        canonical = canonicalize_scope(raw)
        if scope_kind(canonical) != "management_group":
            raise ValueError(f"expected management-group scope, got {raw!r}")
        return canonical
    return (
        "/providers/Microsoft.Management/managementGroups/"
        f"{_segment(raw, 'managementGroupId')}"
    )


def _diagnostic(code, message, **details):
    result = {"code": code, "message": message}
    result.update(details)
    return result


def deduplicate_scopes(scopes):
    """Canonicalize scopes and remove duplicates case-insensitively, keeping first."""

    if isinstance(scopes, (str, dict)):
        scopes = [scopes]
    unique = []
    seen = set()
    for value in scopes or ():
        canonical = canonicalize_scope(value)
        key = canonical.casefold()
        if key not in seen:
            seen.add(key)
            unique.append(canonical)
    return unique


def _normalise_expansion_records(expansions):
    """Return {mg-key: {scope, subscriptions, management_groups}}.

    Accepted inputs are a mapping keyed by MG ID/scope, or records containing a
    managementGroup/id/scope plus subscriptions and managementGroups/children.
    """

    if not expansions:
        return {}

    if isinstance(expansions, dict):
        records = list(expansions.items())
    else:
        records = []
        for record in expansions:
            if not isinstance(record, dict):
                raise ValueError("management-group expansion records must be objects")
            lowered = {str(key).lower(): value for key, value in record.items()}
            key = (
                lowered.get("managementgroup")
                or lowered.get("management_group")
                or lowered.get("scope")
                or lowered.get("id")
            )
            if not key:
                raise ValueError("management-group expansion record has no group ID")
            records.append((key, record))

    normalised = {}
    for raw_group, raw_value in records:
        group = _management_group_scope(raw_group)
        subscriptions = []
        child_groups = []

        def _as_list(values):
            if values is None:
                return []
            if isinstance(values, (str, dict)):
                return [values]
            return list(values)

        if isinstance(raw_value, dict):
            lowered = {str(key).lower(): value for key, value in raw_value.items()}
            has_expansion_fields = not lowered or any(
                key in lowered
                for key in (
                    "subscriptions",
                    "subscriptionids",
                    "subscription_ids",
                    "managementgroups",
                    "management_groups",
                    "childmanagementgroups",
                    "children",
                )
            )
            subscriptions = _as_list(
                lowered.get("subscriptions")
                or lowered.get("subscriptionids")
                or lowered.get("subscription_ids")
            )
            child_groups = _as_list(
                lowered.get("managementgroups")
                or lowered.get("management_groups")
                or lowered.get("childmanagementgroups")
            )
            for child in _as_list(lowered.get("children")):
                if isinstance(child, dict):
                    lowered_child = {
                        str(key).lower(): value for key, value in child.items()
                    }
                    child_type = str(lowered_child.get("type") or "").casefold()
                    child_id = str(
                        lowered_child.get("id") or lowered_child.get("name") or ""
                    ).strip()
                    if (
                        "subscription" in child_type
                        or child_id.casefold().startswith("/subscriptions/")
                    ):
                        subscriptions.append(child)
                        continue
                child_groups.append(child)
            if not has_expansion_fields:
                # Azure CLI descendant rows can be passed directly as values.
                raw_value = [raw_value]
        if not isinstance(raw_value, dict):
            values = raw_value if isinstance(raw_value, (list, tuple, set)) else [raw_value]
            for value in values:
                if isinstance(value, dict):
                    lowered = {str(key).lower(): item for key, item in value.items()}
                    item_id = lowered.get("id") or lowered.get("name")
                    item_type = str(lowered.get("type") or "").lower()
                    if not item_id:
                        raise ValueError("management-group descendant has no id or name")
                    if "subscription" in item_type:
                        subscriptions.append(item_id)
                    elif "managementgroup" in item_type:
                        child_groups.append(item_id)
                    elif str(item_id).casefold().startswith("/subscriptions/"):
                        subscriptions.append(item_id)
                    else:
                        child_groups.append(item_id)
                elif str(value).strip().lower().startswith("/providers/"):
                    child_groups.append(value)
                else:
                    subscriptions.append(value)

        subscription_scopes = []
        for value in _as_list(subscriptions):
            if isinstance(value, dict):
                lowered = {str(key).lower(): item for key, item in value.items()}
                value = lowered.get("id") or lowered.get("subscriptionid") or lowered.get("name")
            subscription_scopes.append(_subscription_scope(value))

        management_group_scopes = []
        for value in _as_list(child_groups):
            if isinstance(value, dict):
                lowered = {str(key).lower(): item for key, item in value.items()}
                value = lowered.get("id") or lowered.get("name")
            management_group_scopes.append(_management_group_scope(value))

        normalised[group.casefold()] = {
            "scope": group,
            "subscriptions": deduplicate_scopes(subscription_scopes),
            "management_groups": deduplicate_scopes(management_group_scopes),
        }
    return normalised


def resolve_managed_scopes(managed_scopes, management_group_expansions=None):
    """Resolve configured scopes into non-overlapping effective subscription/RG scopes.

    Management-group expansion data is supplied by the caller. The result preserves
    configured scopes for audit, removes case-insensitive duplicates, removes RG scopes
    nested under an effective subscription, and reports MG/explicit overlap.
    """

    if isinstance(managed_scopes, (str, dict)):
        managed_scopes = [managed_scopes]
    configured = []
    diagnostics = []
    seen = {}
    for position, value in enumerate(managed_scopes or ()):
        canonical = canonicalize_scope(value)
        key = canonical.casefold()
        if key in seen:
            diagnostics.append(
                _diagnostic(
                    "duplicate_scope",
                    f"Removed duplicate managed scope {canonical}",
                    scope=canonical,
                    duplicate_of=seen[key],
                    position=position,
                )
            )
            continue
        seen[key] = canonical
        configured.append(canonical)

    expansions = _normalise_expansion_records(management_group_expansions)
    explicit_subscriptions = [
        value for value in configured if scope_kind(value) == "subscription"
    ]
    explicit_resource_groups = [
        value for value in configured if scope_kind(value) == "resource_group"
    ]
    configured_management_groups = [
        value for value in configured if scope_kind(value) == "management_group"
    ]

    mg_subscriptions = {}
    mg_descendants = {}
    unexpanded = []

    def walk(group, root, path):
        key = group.casefold()
        if key in path:
            cycle = " -> ".join(path[path.index(key) :] + [key])
            raise ValueError(f"management-group expansion contains a cycle: {cycle}")
        record = expansions.get(key)
        if record is None:
            return set(), {group.casefold(): group}, {group}
        subscriptions = {item.casefold(): item for item in record["subscriptions"]}
        descendants = {group.casefold(): group}
        missing = set()
        next_path = path + [key]
        for child in record["management_groups"]:
            child_subscriptions, child_descendants, child_missing = walk(
                child, root, next_path
            )
            subscriptions.update(child_subscriptions)
            descendants.update(child_descendants)
            missing.update(child_missing)
        return subscriptions, descendants, missing

    for group in configured_management_groups:
        subscriptions, descendants, missing = walk(group, group, [])
        mg_subscriptions[group] = [
            subscriptions[key] for key in sorted(subscriptions)
        ]
        mg_descendants[group] = [
            descendants[key] for key in sorted(descendants)
        ]
        for missing_group in sorted(missing, key=str.casefold):
            if missing_group.casefold() not in {item.casefold() for item in unexpanded}:
                unexpanded.append(missing_group)
    for group in sorted(unexpanded, key=str.casefold):
        diagnostics.append(
            _diagnostic(
                "unexpanded_management_group",
                f"No descendant expansion was supplied for {group}",
                scope=group,
            )
        )

    effective_subscriptions = []
    effective_seen = {}

    def add_subscription(subscription, source):
        key = subscription.casefold()
        if key in effective_seen:
            previous = effective_seen[key]
            code = (
                "management_group_overlap"
                if source.startswith("management_group:")
                or previous.startswith("management_group:")
                else "duplicate_scope"
            )
            diagnostics.append(
                _diagnostic(
                    code,
                    f"Scope overlap for {subscription}; kept {previous}",
                    scope=subscription,
                    kept_source=previous,
                    removed_source=source,
                )
            )
            return
        effective_seen[key] = source
        effective_subscriptions.append(subscription)

    for subscription in explicit_subscriptions:
        add_subscription(subscription, "explicit")
    for group in configured_management_groups:
        for subscription in mg_subscriptions[group]:
            add_subscription(subscription, f"management_group:{group}")

    effective_resource_groups = []
    for resource_group in explicit_resource_groups:
        subscription = _subscription_from_id(resource_group)
        if subscription.casefold() in effective_seen:
            diagnostics.append(
                _diagnostic(
                    "nested_scope_removed",
                    f"Removed {resource_group}; parent {subscription} is already managed",
                    scope=resource_group,
                    parent_scope=subscription,
                )
            )
        else:
            effective_resource_groups.append(resource_group)

    effective_scopes = effective_subscriptions + effective_resource_groups
    return {
        "configured_scopes": configured,
        "effective_scopes": effective_scopes,
        "subscription_scopes": effective_subscriptions,
        "resource_group_scopes": effective_resource_groups,
        "management_group_scopes": configured_management_groups,
        "management_group_subscriptions": mg_subscriptions,
        "management_group_descendants": mg_descendants,
        "unexpanded_management_groups": sorted(unexpanded, key=str.casefold),
        "duplicates_removed": sum(
            item["code"] == "duplicate_scope" for item in diagnostics
        ),
        "nested_removed": sum(
            item["code"] == "nested_scope_removed" for item in diagnostics
        ),
        "overlaps_removed": sum(
            item["code"] == "management_group_overlap" for item in diagnostics
        ),
        "diagnostics": diagnostics,
    }


normalize_managed_scopes = resolve_managed_scopes
expand_management_groups = resolve_managed_scopes
normalize_scopes = resolve_managed_scopes


def canonicalize_resource_id(resource_id):
    """Validate a subscription-based ARM resource ID and canonicalize path keywords."""

    raw = str(resource_id or "").strip()
    if raw != "/":
        raw = raw.rstrip("/")
    try:
        return canonicalize_scope(raw)
    except ValueError:
        pass

    if not raw.startswith("/") or any(char in raw for char in _INVALID_PATH_CHARS):
        raise ValueError("resourceId must be an absolute ARM resource ID")
    parts = raw.split("/")[1:]
    if len(parts) < 4 or parts[0].casefold() != "subscriptions":
        raise ValueError("resourceId must begin with /subscriptions/<subscriptionId>")
    _segment(parts[1], "subscriptionId")

    index = 2
    if index < len(parts) and parts[index].casefold() == "resourcegroups":
        if index + 1 >= len(parts):
            raise ValueError("resourceId has no resource-group name")
        _segment(parts[index + 1], "resourceGroupName")
        index += 2
    if index >= len(parts) or parts[index].casefold() != "providers":
        raise ValueError("resourceId must contain a providers segment")

    provider_index = index
    provider_markers = []
    while provider_index < len(parts):
        if parts[provider_index].casefold() != "providers":
            raise ValueError(
                "resourceId extension path must begin with a providers segment"
            )
        provider_markers.append(provider_index)
        if provider_index + 3 >= len(parts):
            raise ValueError(
                "resourceId providers namespace must be followed by complete "
                "type/name pairs"
            )

        pair_index = provider_index + 2
        while True:
            if pair_index + 1 >= len(parts):
                raise ValueError(
                    "resourceId providers namespace must be followed by complete "
                    "type/name pairs"
                )
            # Consume one complete type/name pair. A resource name may itself be
            # "providers"; only the next type-position can begin an extension.
            pair_index += 2
            if pair_index == len(parts):
                provider_index = len(parts)
                break
            if parts[pair_index].casefold() == "providers":
                provider_index = pair_index
                break

    for position, part in enumerate(parts):
        _segment(part, f"resourceId segment {position + 1}")

    canonical = list(parts)
    canonical[0] = "subscriptions"
    if len(canonical) > 2 and canonical[2].casefold() == "resourcegroups":
        canonical[2] = "resourceGroups"
    for position in provider_markers:
        canonical[position] = "providers"
    return "/" + "/".join(canonical)


def _subscription_from_id(value):
    canonical = canonicalize_resource_id(value)
    parts = canonical.split("/")
    return f"/subscriptions/{parts[2]}"


def _resource_group_from_id(value):
    canonical = canonicalize_resource_id(value)
    parts = canonical.split("/")
    if len(parts) < 5 or parts[3].casefold() != "resourcegroups":
        return None
    return (
        f"/subscriptions/{parts[2]}/resourceGroups/{parts[4]}"
    )


def _target_details(target):
    try:
        canonical = canonicalize_scope(target)
        return {
            "target": canonical,
            "kind": scope_kind(canonical),
            "subscription": (
                _subscription_from_id(canonical)
                if scope_kind(canonical) != "management_group"
                else None
            ),
            "resource_group": (
                canonical if scope_kind(canonical) == "resource_group" else None
            ),
        }
    except ValueError:
        canonical = canonicalize_resource_id(target)
        return {
            "target": canonical,
            "kind": "resource",
            "subscription": _subscription_from_id(canonical),
            "resource_group": _resource_group_from_id(canonical),
        }


def evaluate_containment(
    managed_scopes, requested_scope_or_resource_id, management_group_expansions=None
):
    """Return a deterministic containment decision for a requested scope/resource."""

    resolved = resolve_managed_scopes(
        managed_scopes, management_group_expansions=management_group_expansions
    )
    target = _target_details(requested_scope_or_resource_id)
    target_key = target["target"].casefold()

    for group in resolved["management_group_scopes"]:
        descendants = resolved["management_group_descendants"].get(group, [group])
        if target["kind"] == "management_group" and target_key in {
            item.casefold() for item in descendants
        }:
            return {
                "contained": True,
                "target": target["target"],
                "target_kind": target["kind"],
                "containing_scope": group,
                "reason": "management_group",
                "diagnostics": resolved["diagnostics"],
            }

    for subscription in resolved["subscription_scopes"]:
        if target["subscription"] and (
            target["subscription"].casefold() == subscription.casefold()
        ):
            return {
                "contained": True,
                "target": target["target"],
                "target_kind": target["kind"],
                "containing_scope": subscription,
                "reason": "subscription",
                "diagnostics": resolved["diagnostics"],
            }

    for resource_group in resolved["resource_group_scopes"]:
        if target["resource_group"] and (
            target["resource_group"].casefold() == resource_group.casefold()
        ):
            return {
                "contained": True,
                "target": target["target"],
                "target_kind": target["kind"],
                "containing_scope": resource_group,
                "reason": "resource_group",
                "diagnostics": resolved["diagnostics"],
            }

    return {
        "contained": False,
        "target": target["target"],
        "target_kind": target["kind"],
        "containing_scope": None,
        "reason": "outside_managed_scope",
        "diagnostics": resolved["diagnostics"],
    }


def scope_contains(
    managed_scopes, requested_scope_or_resource_id, management_group_expansions=None
):
    """Boolean convenience wrapper around evaluate_containment."""

    if isinstance(managed_scopes, (str, dict)):
        managed_scopes = [managed_scopes]
    return evaluate_containment(
        managed_scopes,
        requested_scope_or_resource_id,
        management_group_expansions,
    )["contained"]


def is_contained(
    requested_scope_or_resource_id, managed_scopes, management_group_expansions=None
):
    """Boolean containment helper with the requested target as the first argument."""

    return scope_contains(
        managed_scopes,
        requested_scope_or_resource_id,
        management_group_expansions,
    )


is_within_managed_scope = is_contained


def _ci_get(mapping, *names):
    if not isinstance(mapping, dict):
        return None
    lowered = {str(key).casefold(): value for key, value in mapping.items()}
    for name in names:
        if name.casefold() in lowered and lowered[name.casefold()] not in (None, ""):
            return lowered[name.casefold()]
    properties = lowered.get("properties")
    if isinstance(properties, dict):
        return _ci_get(properties, *names)
    return None


def _row_resource_id(row):
    instance_name = _ci_get(row, "instanceName")
    resource_id = _ci_get(row, "resourceId")
    last_error = None
    for value in (instance_name, resource_id):
        if not value or not str(value).strip().startswith("/"):
            continue
        try:
            return canonicalize_resource_id(value), None
        except ValueError as error:
            # instanceName sometimes contains a plain instance label; only report
            # malformed values that looked like ARM IDs.
            last_error = str(error)
    return None, last_error


def _metadata_scope(row):
    subscription = _ci_get(
        row, "subscriptionId", "subscriptionGuid", "subscription"
    )
    resource_group = _ci_get(row, "resourceGroup", "resourceGroupName")
    if not subscription:
        return None
    try:
        subscription_scope = _subscription_scope(subscription)
        if resource_group:
            raw_resource_group = str(resource_group).strip()
            if raw_resource_group.startswith("/"):
                canonical = canonicalize_scope(raw_resource_group)
                if scope_kind(canonical) != "resource_group":
                    return None
                if _subscription_from_id(canonical).casefold() != subscription_scope.casefold():
                    return None
                return canonical
            return (
                f"{subscription_scope}/resourceGroups/"
                f"{_segment(resource_group, 'resourceGroupName')}"
            )
        return subscription_scope
    except ValueError:
        return None


def _normalise_for_fingerprint(value, key=""):
    if isinstance(value, dict):
        return {
            str(item_key).casefold(): _normalise_for_fingerprint(
                item_value, str(item_key)
            )
            for item_key, item_value in sorted(
                value.items(), key=lambda pair: str(pair[0]).casefold()
            )
        }
    if isinstance(value, (list, tuple)):
        return [_normalise_for_fingerprint(item, key) for item in value]
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, str) and key.casefold() in {
        "id",
        "instanceid",
        "instancename",
        "resourceid",
        "subscriptionid",
        "subscriptionguid",
        "resourcegroup",
        "resourcegroupname",
    }:
        return value.strip().casefold()
    return value


def _row_identity(row):
    explicit = _ci_get(
        row, "usageDetailId", "usageRecordId", "chargeId", "billingRecordId"
    )
    if not explicit:
        top_level = {str(key).casefold(): value for key, value in row.items()}
        explicit = top_level.get("id")
    if explicit:
        return "id:" + str(explicit).strip().casefold()
    payload = json.dumps(
        _normalise_for_fingerprint(row),
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return "row:" + hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _row_cost(row):
    value = _ci_get(row, "cost", "costInUSD", "pretaxCost")
    if value in (None, ""):
        return Decimal("0"), "missing cost; treated as 0"
    if isinstance(value, bool):
        return Decimal("0"), "boolean cost is invalid; treated as 0"
    try:
        cost = value if isinstance(value, Decimal) else Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal("0"), f"invalid cost {value!r}; treated as 0"
    if not cost.is_finite():
        return Decimal("0"), f"non-finite cost {value!r}; treated as 0"
    return cost, None


def filter_usage_details(
    rows, managed_scopes, management_group_expansions=None
):
    """Filter UsageDetails rows to managed scope and report exact Decimal coverage.

    instanceName is preferred over resourceId. Rows without a usable ARM ID fall
    back to resourceGroup + subscription metadata. A subscription-only shared charge
    is included only when that subscription (not merely one RG in it) is managed.
    """

    resolved = resolve_managed_scopes(
        managed_scopes, management_group_expansions=management_group_expansions
    )
    diagnostics = list(resolved["diagnostics"])
    included_rows = []
    excluded_rows = []
    unattributed_rows = []
    included_cost = Decimal("0")
    excluded_cost = Decimal("0")
    unattributed_cost = Decimal("0")
    seen = {}
    duplicate_count = 0
    input_rows = list(rows or ())

    for index, row in enumerate(input_rows):
        if not isinstance(row, dict):
            diagnostics.append(
                _diagnostic(
                    "invalid_usage_row",
                    f"UsageDetails row {index} is not an object",
                    row_index=index,
                )
            )
            row = {"value": row}

        identity = _row_identity(row)
        if identity in seen:
            duplicate_count += 1
            diagnostics.append(
                _diagnostic(
                    "duplicate_usage_row",
                    f"Removed duplicate UsageDetails row {index}",
                    row_index=index,
                    duplicate_of=seen[identity],
                )
            )
            continue
        seen[identity] = index

        cost, cost_error = _row_cost(row)
        if cost_error:
            diagnostics.append(
                _diagnostic(
                    "invalid_cost",
                    f"UsageDetails row {index}: {cost_error}",
                    row_index=index,
                )
            )

        resource_id, id_error = _row_resource_id(row)
        metadata_scope = _metadata_scope(row)
        if id_error:
            diagnostics.append(
                _diagnostic(
                    "malformed_resource_id",
                    f"UsageDetails row {index}: {id_error}",
                    row_index=index,
                )
            )
        target = resource_id or metadata_scope
        if target is None:
            unattributed_rows.append(row)
            unattributed_cost += cost
            diagnostics.append(
                _diagnostic(
                    "unattributed_usage_row",
                    f"UsageDetails row {index} has no usable resource or scope identity",
                    row_index=index,
                    detail=id_error,
                )
            )
            continue

        decision = evaluate_containment(
            resolved["configured_scopes"],
            target,
            management_group_expansions=management_group_expansions,
        )
        if decision["contained"]:
            included_rows.append(row)
            included_cost += cost
        else:
            excluded_rows.append(row)
            excluded_cost += cost
            diagnostics.append(
                _diagnostic(
                    "outside_managed_scope",
                    f"Excluded UsageDetails row {index} outside managed scope",
                    row_index=index,
                    target=decision["target"],
                )
            )

    included_count = len(included_rows)
    excluded_count = len(excluded_rows)
    unattributed_count = len(unattributed_rows)
    unique_count = included_count + excluded_count + unattributed_count
    total_cost = included_cost + excluded_cost + unattributed_cost
    attributed_count = included_count + excluded_count
    coverage = (
        (Decimal(attributed_count) * Decimal("100") / Decimal(unique_count)).quantize(
            Decimal("0.01")
        )
        if unique_count
        else Decimal("100.00")
    )

    return {
        "included_rows": included_rows,
        "excluded_rows": excluded_rows,
        "unattributed_rows": unattributed_rows,
        "included": included_rows,
        "excluded": excluded_rows,
        "unattributed": unattributed_rows,
        "input_count": len(input_rows),
        "unique_count": unique_count,
        "duplicate_count": duplicate_count,
        "included_count": included_count,
        "excluded_count": excluded_count,
        "unattributed_count": unattributed_count,
        "included_cost": included_cost,
        "excluded_cost": excluded_cost,
        "unattributed_cost": unattributed_cost,
        "included_cost_usd": included_cost,
        "excluded_cost_usd": excluded_cost,
        "unattributed_cost_usd": unattributed_cost,
        "attributed_cost": included_cost + excluded_cost,
        "total_cost": total_cost,
        "attribution_coverage_pct": coverage,
        "diagnostics": diagnostics,
    }


filter_usage_rows = filter_usage_details
filter_usage_details_by_scope = filter_usage_details


def decide_scope_policy(
    requested_scopes,
    managed_scopes,
    *,
    mode="interactive",
    outside_scope_confirmed=None,
    confirmation_key=None,
    management_group_expansions=None,
):
    """Decide whether requested scopes may be used.

    Scheduled mode is strict and fail-closed. Interactive mode returns an explicit
    confirmation-required state for any target outside managed scope. An affirmative
    ``outside_scope_confirmed=True`` permits that broader request only when
    ``confirmation_key`` exactly matches the key computed for the current request.
    """

    mode = str(mode or "").strip().casefold()
    if mode not in {"scheduled", "interactive"}:
        raise ValueError("mode must be 'scheduled' or 'interactive'")

    requested = (
        [requested_scopes]
        if isinstance(requested_scopes, (str, dict))
        else list(requested_scopes or ())
    )
    try:
        resolved = resolve_managed_scopes(
            managed_scopes, management_group_expansions=management_group_expansions
        )
    except ValueError as error:
        return {
            "allowed": False,
            "decision": "deny",
            "state": "invalid_managed_scope",
            "confirmation_state": "not_permitted",
            "requires_confirmation": False,
            "inside_scopes": [],
            "outside_scopes": [],
            "confirmation_key": None,
            "diagnostics": [
                _diagnostic("invalid_managed_scope", str(error))
            ],
        }

    diagnostics = list(resolved["diagnostics"])
    if not resolved["configured_scopes"]:
        diagnostics.append(
            _diagnostic(
                "empty_managed_scope",
                "No managed scopes are configured",
            )
        )
        return {
            "allowed": False,
            "decision": "deny",
            "state": "empty_managed_scope",
            "confirmation_state": "not_permitted",
            "requires_confirmation": False,
            "inside_scopes": [],
            "outside_scopes": [],
            "confirmation_key": None,
            "diagnostics": diagnostics,
        }

    if mode == "scheduled" and resolved["unexpanded_management_groups"]:
        return {
            "allowed": False,
            "decision": "deny",
            "state": "management_group_expansion_required",
            "confirmation_state": "not_permitted",
            "requires_confirmation": False,
            "inside_scopes": [],
            "outside_scopes": [],
            "confirmation_key": None,
            "diagnostics": diagnostics,
        }

    inside = []
    outside = []
    invalid = []
    for value in requested:
        try:
            decision = evaluate_containment(
                resolved["configured_scopes"],
                value,
                management_group_expansions=management_group_expansions,
            )
            (inside if decision["contained"] else outside).append(decision["target"])
        except ValueError as error:
            invalid.append(str(value))
            diagnostics.append(
                _diagnostic(
                    "invalid_requested_scope",
                    str(error),
                    scope=str(value),
                )
            )

    def _sorted_ci_unique(values):
        unique = {}
        for value in values:
            unique.setdefault(value.casefold(), value)
        return [unique[key] for key in sorted(unique)]

    inside = _sorted_ci_unique(inside)
    outside = _sorted_ci_unique(outside)
    invalid = _sorted_ci_unique(invalid)
    if invalid:
        return {
            "allowed": False,
            "decision": "deny",
            "state": "invalid_requested_scope",
            "confirmation_state": "not_permitted",
            "requires_confirmation": False,
            "inside_scopes": inside,
            "outside_scopes": outside,
            "invalid_scopes": invalid,
            "confirmation_key": None,
            "diagnostics": diagnostics,
        }
    expected_confirmation_key = (
        hashlib.sha256(
            json.dumps(
                {
                    "inside_scopes": [item.casefold() for item in inside],
                    "outside_scopes": [item.casefold() for item in outside],
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()[:16]
        if outside
        else None
    )

    if not outside:
        return {
            "allowed": True,
            "decision": "allow",
            "state": "within_managed_scope",
            "confirmation_state": "not_required",
            "requires_confirmation": False,
            "inside_scopes": inside,
            "outside_scopes": [],
            "confirmation_key": None,
            "diagnostics": diagnostics,
        }

    diagnostics.append(
        _diagnostic(
            "requested_scope_outside_managed_scope",
            "One or more requested scopes are outside the agent's managed scope",
            scopes=outside,
        )
    )
    if mode == "scheduled":
        return {
            "allowed": False,
            "decision": "deny",
            "state": "outside_managed_scope",
            "confirmation_state": "not_permitted",
            "requires_confirmation": False,
            "inside_scopes": inside,
            "outside_scopes": outside,
            "confirmation_key": expected_confirmation_key,
            "diagnostics": diagnostics,
        }
    if outside_scope_confirmed is True:
        if confirmation_key is None:
            diagnostics.append(
                _diagnostic(
                    "outside_scope_confirmation_key_missing",
                    "Outside-scope confirmation was supplied without the key "
                    "displayed for this request",
                    expected_confirmation_key=expected_confirmation_key,
                )
            )
            return {
                "allowed": False,
                "decision": "confirm",
                "state": "outside_scope_confirmation_key_required",
                "confirmation_state": "key_required",
                "requires_confirmation": True,
                "inside_scopes": inside,
                "outside_scopes": outside,
                "confirmation_key": expected_confirmation_key,
                "diagnostics": diagnostics,
            }
        if confirmation_key != expected_confirmation_key:
            diagnostics.append(
                _diagnostic(
                    "outside_scope_confirmation_key_mismatch",
                    "The supplied confirmation key does not match the current "
                    "outside-scope request",
                    supplied_confirmation_key=str(confirmation_key),
                    expected_confirmation_key=expected_confirmation_key,
                )
            )
            return {
                "allowed": False,
                "decision": "confirm",
                "state": "outside_scope_confirmation_key_mismatch",
                "confirmation_state": "key_mismatch",
                "requires_confirmation": True,
                "inside_scopes": inside,
                "outside_scopes": outside,
                "confirmation_key": expected_confirmation_key,
                "diagnostics": diagnostics,
            }
        return {
            "allowed": True,
            "decision": "allow",
            "state": "outside_scope_confirmed",
            "confirmation_state": "confirmed",
            "requires_confirmation": False,
            "inside_scopes": inside,
            "outside_scopes": outside,
            "confirmation_key": expected_confirmation_key,
            "diagnostics": diagnostics,
        }
    if outside_scope_confirmed is False:
        return {
            "allowed": False,
            "decision": "deny",
            "state": "outside_scope_declined",
            "confirmation_state": "declined",
            "requires_confirmation": False,
            "inside_scopes": inside,
            "outside_scopes": outside,
            "confirmation_key": expected_confirmation_key,
            "diagnostics": diagnostics,
        }
    return {
        "allowed": False,
        "decision": "confirm",
        "state": "outside_scope_confirmation_required",
        "confirmation_state": "required",
        "requires_confirmation": True,
        "inside_scopes": inside,
        "outside_scopes": outside,
        "confirmation_key": expected_confirmation_key,
        "diagnostics": diagnostics,
    }


evaluate_scope_policy = decide_scope_policy
decide_policy = decide_scope_policy
