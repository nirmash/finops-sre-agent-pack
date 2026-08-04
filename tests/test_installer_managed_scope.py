import json
import re
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "plugins" / "finops" / "install-api.sh"
UAMI_ID = (
    "/subscriptions/control/resourceGroups/agents/"
    "providers/Microsoft.ManagedIdentity/userAssignedIdentities/finops"
)


def _script():
    return INSTALLER.read_text()


def _prompt(name):
    match = re.search(
        rf"read -r -d '' {name} <<EOF \|\| true\n(.*?)\nEOF",
        _script(),
        flags=re.DOTALL,
    )
    assert match
    return match.group(1)


def _discovery_parser():
    match = re.search(
        r'DISCOVERY_JSON="\$\(printf .*?python3 -c \'\n(.*?)\n\'\)"',
        _script(),
        flags=re.DOTALL,
    )
    assert match
    return match.group(1)


def _discover(managed_resources, *, identity=None):
    doc = {
        "properties": {
            "agentEndpoint": "https://agent.example/",
            "knowledgeGraphConfiguration": {
                "managedResources": managed_resources,
            },
        },
        "identity": identity
        or {
            "type": "UserAssigned",
            "userAssignedIdentities": {
                UAMI_ID: {"principalId": "principal-id"},
            },
        },
    }
    return subprocess.run(
        ["python3", "-c", _discovery_parser()],
        input=json.dumps(doc),
        text=True,
        capture_output=True,
        check=False,
    )


def test_discovery_accepts_supported_scopes_and_normalizes_exact_duplicates():
    first_subscription = "/subscriptions/Sub-A"
    result = _discover(
        [
            first_subscription,
            "/SUBSCRIPTIONS/sub-a",
            {"resourceId": "/subscriptions/Sub-A/resourceGroups/Prod"},
            {"scope": "/providers/Microsoft.Management/managementGroups/Root"},
        ]
    )

    assert result.returncode == 0, result.stderr
    discovered = json.loads(result.stdout)
    assert discovered["endpoint"] == "https://agent.example"
    assert discovered["managedScopes"] == [
        first_subscription,
        "/subscriptions/Sub-A/resourceGroups/Prod",
        "/providers/Microsoft.Management/managementGroups/Root",
    ]
    assert discovered["uamiResourceId"] == UAMI_ID
    assert discovered["inlinePrincipalId"] == "principal-id"


def test_discovery_canonicalizes_keywords_trailing_slashes_and_duplicates():
    result = _discover(
        [
            "/SUBSCRIPTIONS/Sub-A/",
            "/subscriptions/sub-a",
            "/subscriptions/Sub-A/RESOURCEGROUPS/Prod/",
            "/PROVIDERS/MICROSOFT.MANAGEMENT/MANAGEMENTGROUPS/Root/",
        ]
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["managedScopes"] == [
        "/subscriptions/Sub-A",
        "/subscriptions/Sub-A/resourceGroups/Prod",
        "/providers/Microsoft.Management/managementGroups/Root",
    ]


def test_discovery_accepts_unicode_rg_and_mg_segments_and_deduplicates():
    result = _discover(
        [
            "/SUBSCRIPTIONS/Sub-A/RESOURCEGROUPS/生产/",
            {"id": "/subscriptions/sub-a/resourceGroups/生产"},
            "/PROVIDERS/MICROSOFT.MANAGEMENT/MANAGEMENTGROUPS/平台/",
            {"scope": "/providers/microsoft.management/managementgroups/平台"},
        ]
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["managedScopes"] == [
        "/subscriptions/Sub-A/resourceGroups/生产",
        "/providers/Microsoft.Management/managementGroups/平台",
    ]


@pytest.mark.parametrize(
    ("managed_resources", "message"),
    [
        ([], "nonempty list"),
        ([""], "nonempty ARM scope ID"),
        (["/subscriptions/sub/resourceGroups/"], "Unsupported"),
        (["/providers/Microsoft.Management/managementGroups/"], "Unsupported"),
        (["/subscriptions/sub/resourceGroups"], "Unsupported"),
        (["/subscriptions/sub/providers/Microsoft.Compute/virtualMachines/vm"], "Unsupported"),
        (["/tenants/tenant"], "Unsupported"),
        (["/subscriptions/sub/resourceGroups/prod\\west"], "unsafe path characters"),
        (["/providers/Microsoft.Management/managementGroups/root\\child"], "unsafe path characters"),
        (["/subscriptions/sub/resourceGroups/prod\x01west"], "unsafe path characters"),
        (["/providers/Microsoft.Management/managementGroups/root\nchild"], "unsafe path characters"),
        ([{"name": "/subscriptions/sub"}], "nonempty ARM scope ID"),
    ],
)
def test_discovery_fails_closed_on_empty_or_invalid_scopes(
    managed_resources, message
):
    result = _discover(managed_resources)

    assert result.returncode != 0
    assert message in result.stderr


def test_discovery_requires_exactly_one_uami():
    result = _discover(
        ["/subscriptions/sub"],
        identity={"type": "UserAssigned", "userAssignedIdentities": {}},
    )

    assert result.returncode != 0
    assert "exactly one user-assigned identity" in result.stderr


def test_installer_requires_agent_resource_id_and_rejects_endpoint_only_mode():
    script = _script()

    requirement = (
        '[ -n "$AGENT_RESOURCE_ID" ] || \\\n'
        '  die "AGENT_RESOURCE_ID is required. ENDPOINT-only installation '
        'cannot enforce dynamic managed scope."'
    )
    assert requirement in script
    assert script.index(requirement) < script.index("ARM_AGENT_JSON=")
    assert "Set ENDPOINT or AGENT_RESOURCE_ID" not in script


def test_reader_is_granted_and_verified_at_exact_agent_resource_only():
    script = _script()

    assert (
        'ensure_exact_role_assignment "$UAMI_PRINCIPAL_ID" '
        '"Reader" "$AGENT_RESOURCE_ID"'
    ) in script
    assert 'and str(item.get("scope", "")).casefold() == scope' in script
    assert '--assignee-object-id "$principal_id"' in script
    assert "--include-inherited" not in script
    assert 'die "Failed to create/verify $role_name at exactly $scope_id' in script
    assert (
        'ensure_exact_role_assignment "$UAMI_PRINCIPAL_ID" '
        '"Reader" "/subscriptions/'
    ) not in script


def test_cost_reader_uses_minimum_usage_details_transport_scopes():
    script = _script()

    assert "COST_READER_SCOPES=()" in script
    assert 'transport_scope = f"/subscriptions/{match.group(1)}" if match else scope' in script
    assert 'for scope in "${COST_READER_SCOPES[@]}"; do' in script
    assert (
        'ensure_exact_role_assignment "$MI_OBJECT_ID" '
        '"Cost Management Reader" "$scope"'
    ) in script
    assert '--role "Cost Management Contributor"' not in script
    assert "role assignment delete" not in script


def test_deprecated_sub_id_is_never_used_for_prompts_or_grants():
    script = _script()

    assert 'SUB_ID="${SUB_ID:-$DEFAULT_SUB_ID}"' in script
    assert "SUB_ID is deprecated and ignored" in script
    assert "${SUB_ID}" not in script
    assert '--scope "/subscriptions/${SUB_ID}"' not in script


def test_common_scope_preamble_is_exported_and_applied_to_every_task():
    script = _script()

    assert (
        "export AGENT_RESOURCE_ID FINOPS_MANAGED_SCOPES_JSON "
        "FINOPS_SCOPE_PREAMBLE"
    ) in script
    assert 'prompt="${FINOPS_SCOPE_PREAMBLE}"' in script
    assert "rediscover at run time" in script
    assert "every effective scope produced by scope.py" in script
    assert "Consumption UsageDetails is subscription-scoped transport." in script
    assert "/resourceGroups/.../providers/Microsoft.Consumption/usageDetails" in script
    assert "treat the transport subscription as an expanded analysis boundary" in script
    assert "Never infer, add, or substitute a subscription or parent scope." in script
    assert "stop without querying analysis data, sending email, or creating/updating/" in script
    assert "This scheduled task accepts NO override" in script
    assert "Broad RBAC/visibility must never expand the boundary." in script
    assert "de-duplicate overlaps, filter all" in script
    assert "excluded, unattributed," in script


def test_installer_task_prompts_preserve_yaml_managed_scope_semantics():
    expected = {
        "ANOMALY_PROMPT": (
            "independently GET Consumption UsageDetails",
            "only its effective managed scope",
        ),
        "RIGHTSIZE_PROMPT": (
            "scope every command explicitly",
            "scope every Resource Graph command explicitly",
        ),
        "REPORT_PROMPT": ("per effective managed scope",),
        "RIGHTSIZE_REPORT_PROMPT": (
            "every effective managed scope/expanded descendant",
        ),
        "BUDGET_REPORT_PROMPT": (
            "every configured \\`management_group_scopes\\` entry",
            "every descendant/effective subscription or resource-group scope",
        ),
        "COST_OPT_PROMPT": (
            "per effective managed scope/expanded descendant",
            "independently per effective scope, with independent pagination",
            "every configured \\`management_group_scopes\\` entry",
        ),
        "AI_REPORT_PROMPT": ("per effective managed scope",),
        "RELIABILITY_REPORT_PROMPT": (
            "per effective managed scope/expanded descendant",
        ),
    }

    for prompt_name, phrases in expected.items():
        prompt = _prompt(prompt_name)
        for phrase in phrases:
            assert phrase in prompt, (prompt_name, phrase)


def test_installer_budget_prompts_preserve_management_group_budget_coverage():
    budget_prompt = _prompt("BUDGET_REPORT_PROMPT")
    rollup_prompt = _prompt("COST_OPT_PROMPT")

    assert "case-insensitive de-duplicated union" in budget_prompt
    assert "Directly GET the native budget collection for every configured management-group scope" in budget_prompt
    assert "/providers/Microsoft.Management/managementGroups/{management-group-id}/providers/Microsoft.Consumption/budgets" in budget_prompt
    assert "de-duplicated expanded descendant effective scope" in budget_prompt
    assert "Preserve source scope on every budget" in budget_prompt
    assert "never substitute descendant subscription budgets for management-group-level budgets" in budget_prompt
    assert "De-duplicate returned budgets across overlapping query scopes" in budget_prompt

    assert "case-insensitive de-duplicated query-scope union" in rollup_prompt
    assert "directly GET budgets once at each unique scope" in rollup_prompt
    assert "retain management-group-level budgets" in rollup_prompt
    assert "de-duplicate overlapping results before evaluate_budgets" in rollup_prompt


def test_installer_rightsizing_prompts_scope_arg_and_advisor_commands():
    for prompt_name in ("RIGHTSIZE_PROMPT", "RIGHTSIZE_REPORT_PROMPT"):
        prompt = _prompt(prompt_name)

        assert (
            "az advisor recommendation list --category Cost "
            "--subscription <subscription-id>"
        ) in prompt
        assert "--resource-group <resource-group-name>" in prompt
        assert "az graph query --subscriptions <subscription-id>" in prompt
        assert "resourceGroup =~ '<resource-group-name>'" in prompt

    rightsizing = _prompt("RIGHTSIZE_PROMPT")
    report = _prompt("RIGHTSIZE_REPORT_PROMPT")
    assert "Never run Advisor without the managed subscription/RG arguments." in rightsizing
    assert "Never run \\`az graph query\\` without \\`--subscriptions\\`" in rightsizing
    assert "Never run either command without the managed subscription/RG restriction." in report


def test_package_readiness_includes_nine_skills_without_runtime_write_changes():
    script = _script()

    assert '"finops-managed-scope",' in script
    assert "All nine FinOps skills ready" in script
    assert "Package: 9 skills" in script
    assert "RunAzCliWriteCommands" not in script
    assert "older/incompatible runtime" not in script
