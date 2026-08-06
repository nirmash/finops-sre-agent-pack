"""Managed-scope policy integration guardrails."""

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FINOPS = ROOT / "plugins" / "finops"
SKILL_NAMES = {
    "finops-cost-anomaly-detection",
    "finops-rightsizing-advisor",
    "finops-cost-allocation",
    "finops-budget-governance",
    "finops-budget-editor",
    "finops-cost-optimization-report",
    "finops-for-ai",
    "finops-cost-vs-reliability",
}


def _command_windows(text, command, width=240):
    normalized = re.sub(r"\\\s*\n\s*", " ", text)
    normalized = re.sub(r"\s+", " ", normalized)
    return [
        normalized[match.start() : match.start() + width]
        for match in re.finditer(re.escape(command), normalized)
    ]


def test_all_existing_finops_skills_start_with_managed_scope_policy():
    for name in SKILL_NAMES:
        text = (FINOPS / "skills" / name / "SKILL.md").read_text()
        lowered = text.lower()

        procedure = lowered.index("## procedure")
        scope_step = lowered.index("step 0", procedure)
        next_step = lowered.find("step 1", scope_step)
        assert procedure < scope_step
        assert next_step == -1 or scope_step < next_step
        assert "finops-managed-scope" in lowered
        assert "scope.py" in lowered
        assert "managedresources" in lowered
        assert "scheduled" in lowered
        assert "fail-closed" in lowered or "fail closed" in lowered
        assert "no override" in lowered or "accepts no override" in lowered
        assert re.search(r"explicit\s+confirmation", lowered)
        assert re.search(r"subsequent\s+(?:user\s+)?turn", lowered)
        assert "broad rbac" in lowered
        assert "report" in lowered
        assert "excluded" in lowered


def test_usage_and_telemetry_skills_enforce_per_scope_retrieval():
    for name in SKILL_NAMES - {"finops-budget-editor"}:
        lowered = (FINOPS / "skills" / name / "SKILL.md").read_text().lower()
        assert "each effective scope" in lowered or "every effective scope" in lowered

    for name in {
        "finops-cost-anomaly-detection",
        "finops-rightsizing-advisor",
        "finops-cost-allocation",
        "finops-for-ai",
        "finops-cost-vs-reliability",
    }:
        lowered = (FINOPS / "skills" / name / "SKILL.md").read_text().lower()
        assert "independently" in lowered
        assert "de-duplicate" in lowered
        assert "unattributed" in lowered


def test_budget_editor_uses_subscription_transport_and_client_side_rg_filtering():
    lowered = (
        FINOPS / "skills" / "finops-budget-editor" / "SKILL.md"
    ).read_text().lower()
    normalized = re.sub(r"\s+", " ", lowered)

    assert "subscription-scoped transport" in normalized
    assert "/subscriptions/<sub_id>/providers/microsoft.consumption/usagedetails" in normalized
    assert "without a resource-group server filter" in normalized
    assert "never trust `properties/resourcegroup eq ...`" in normalized
    assert "filter_usage_details" in normalized
    assert "initial page exactly once" in normalized
    assert "pages from separate chains must not be mixed" in normalized
    assert "included, excluded, unattributed, and" in normalized


def test_managed_scope_forbids_server_side_usage_rg_filter_and_mixed_chains():
    lowered = (
        FINOPS / "skills" / "finops-managed-scope" / "SKILL.md"
    ).read_text().lower()
    normalized = re.sub(r"\s+", " ", lowered)

    assert "do not add a `properties/resourcegroup eq ...` filter" in normalized
    assert "silently ignore that filter" in normalized
    assert "fetch the initial page once" in normalized
    assert "do not mix pages from independently restarted requests" in normalized
    assert "filter_usage_details" in normalized


def test_scheduled_templates_have_strict_dynamic_scope_preamble():
    templates = sorted((FINOPS / "scheduled-tasks").glob("*.yaml"))
    assert len(templates) == 8

    for path in templates:
        text = path.read_text()
        lowered = text.lower()

        assert "__AGENT_RESOURCE_ID__" in text
        assert "finops-managed-scope" in lowered
        assert "scope.py" in lowered
        assert "dynamically get" in lowered
        assert "managedresources" in lowered
        assert "fail closed" in lowered
        assert "no override" in lowered
        assert "broad rbac" in lowered
        assert "each effective scope independently" in lowered
        assert "without querying analysis data" in lowered
        assert "sending email" in lowered
        assert "saving a report" in lowered
        assert "__SUB_ID__" not in text


def test_agent_manifest_enables_managed_scope_without_write_tools():
    manifest = json.loads(
        (FINOPS / "agents" / "finops-investigator.json").read_text()
    )
    properties = manifest["properties"]
    instructions = properties["instructions"].lower()

    assert "finops-managed-scope" in properties["allowedSkills"]
    assert "{{agent_resource_id}}" in instructions
    assert "before every finops request" in instructions
    assert "managedresources" in instructions
    assert "strict and fail-closed" in instructions
    assert "subsequent turn" in instructions
    assert "broad rbac" in instructions
    assert properties["tools"] == [
        "RunAzCliReadCommands",
        "ExecutePythonCode",
        "ListReports",
        "GetReport",
        "SaveReport",
    ]


def test_budget_skills_preserve_direct_management_group_budget_queries():
    governance = (
        FINOPS / "skills" / "finops-budget-governance" / "SKILL.md"
    ).read_text().lower()
    editor = (
        FINOPS / "skills" / "finops-budget-editor" / "SKILL.md"
    ).read_text().lower()

    for text in (governance, editor):
        assert "configured management-group" in text
        assert "expanded descendant effective scopes" in text
        assert "case-insensitive" in text
        assert "query each target exactly once" in text
        assert "unless" in text and "itself configured" in text

    assert (
        "/providers/microsoft.management/managementgroups/<mg_id>/"
        "providers/microsoft.consumption/budgets"
    ) in governance
    assert "management-group-level budget" in governance
    assert "exact get" in editor


def test_budget_status_task_queries_configured_management_groups_once():
    text = (
        FINOPS / "scheduled-tasks" / "budget-status-report-daily.yaml"
    ).read_text()
    lowered = text.lower()

    assert "__AGENT_RESOURCE_ID__" in text
    assert "fail closed" in lowered
    assert "no override" in lowered
    assert "every management-group scope configured directly" in lowered
    assert "expanded descendant effective scopes" in lowered
    assert "case-insensitive canonical union" in lowered
    assert "query each target exactly once" in lowered
    assert "unless it is configured" in lowered
    assert (
        "/providers/microsoft.management/managementgroups/{management-group-id}/"
        "providers/microsoft.consumption/budgets"
    ) in lowered
    assert "never substitute" in lowered


def test_all_documented_arg_and_advisor_commands_are_subscription_scoped():
    documents = [
        *(FINOPS / "skills" / name / "SKILL.md" for name in SKILL_NAMES),
        *(FINOPS / "scheduled-tasks").glob("*.yaml"),
    ]
    graph_count = 0
    advisor_count = 0

    for path in documents:
        text = path.read_text()
        graph_windows = _command_windows(text, "az graph query")
        advisor_windows = _command_windows(text, "az advisor recommendation list")
        graph_count += len(graph_windows)
        advisor_count += len(advisor_windows)

        for command in graph_windows:
            assert "--subscriptions <EFFECTIVE_SUBSCRIPTION_ID>" in command, path
        for command in advisor_windows:
            assert "--subscription <EFFECTIVE_SUBSCRIPTION_ID>" in command, path

    assert graph_count >= 8
    assert advisor_count >= 6


def test_rg_only_arg_and_advisor_policy_is_concrete():
    arg_documents = [
        FINOPS / "skills" / "finops-rightsizing-advisor" / "SKILL.md",
        FINOPS / "skills" / "finops-cost-allocation" / "SKILL.md",
        FINOPS / "skills" / "finops-for-ai" / "SKILL.md",
        FINOPS / "scheduled-tasks" / "rightsizing-weekly.yaml",
        FINOPS / "scheduled-tasks" / "rightsizing-savings-report-weekly.yaml",
        FINOPS / "scheduled-tasks" / "ai-spend-report-weekly.yaml",
        FINOPS / "scheduled-tasks" / "cost-optimization-report-weekly.yaml",
    ]
    for path in arg_documents:
        lowered = path.read_text().lower()
        assert "resourcegroup =~ '<effective_resource_group>'" in lowered, path
        assert "client-side" in lowered, path
        assert "normalized" in lowered, path

    advisor_documents = [
        FINOPS / "skills" / "finops-rightsizing-advisor" / "SKILL.md",
        FINOPS / "skills" / "finops-cost-vs-reliability" / "SKILL.md",
        FINOPS / "scheduled-tasks" / "rightsizing-weekly.yaml",
        FINOPS / "scheduled-tasks" / "rightsizing-savings-report-weekly.yaml",
        FINOPS / "scheduled-tasks" / "cost-vs-reliability-report-weekly.yaml",
        FINOPS / "scheduled-tasks" / "cost-optimization-report-weekly.yaml",
    ]
    for path in advisor_documents:
        lowered = path.read_text().lower()
        assert "--resource-group <effective_resource_group>" in lowered, path
        assert "client-side" in lowered, path
