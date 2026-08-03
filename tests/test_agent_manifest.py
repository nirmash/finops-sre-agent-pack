import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "plugins" / "finops" / "agents" / "finops-investigator.json"
INSTALLER = ROOT / "plugins" / "finops" / "install-api.sh"

FINOPS_SKILLS = {
    "finops-cost-anomaly-detection",
    "finops-rightsizing-advisor",
    "finops-cost-allocation",
    "finops-budget-governance",
    "finops-budget-editor",
    "finops-cost-optimization-report",
    "finops-for-ai",
    "finops-cost-vs-reliability",
}


def _manifest():
    return json.loads(MANIFEST.read_text())


def test_manifest_defines_read_only_finops_agent():
    manifest = _manifest()
    properties = manifest["properties"]

    assert manifest["name"] == "finops-investigator"
    assert manifest["type"] == "ExtendedAgent"
    assert {"finops", "read-only"} <= set(manifest["tags"])
    assert properties["enableSkills"] is True
    assert properties["addSystemSkills"] is True
    assert properties["disableDocumentRetrieval"] is True
    assert properties["handoffs"] == []

    instructions = properties["instructions"].lower()
    assert "never execute azure post, put, patch, or delete" in instructions
    assert "human decision" in instructions


def test_manifest_allows_exact_finops_skills_and_live_report_authoring():
    allowed = set(_manifest()["properties"]["allowedSkills"])

    assert allowed == FINOPS_SKILLS | {"live_report_authoring"}


def test_manifest_core_tools_are_read_only_or_report_scoped():
    tools = set(_manifest()["properties"]["tools"])

    assert tools == {
        "RunAzCliReadCommands",
        "ExecutePythonCode",
        "ListReports",
        "GetReport",
        "SaveReport",
    }
    assert not any(
        token in tool.lower()
        for tool in tools
        for token in ("write", "delete", "createbudget", "updatebudget")
    )


def test_installer_upserts_agent_before_tasks_and_defaults_tasks_to_it():
    script = INSTALLER.read_text()

    dry_run = '"/api/v2/extendedAgent/agents/${FINOPS_AGENT_NAME}?dryRun=true"'
    upsert = '"/api/v2/extendedAgent/agents/${FINOPS_AGENT_NAME}"'
    first_task = 'say "Upserting scheduled task'

    assert dry_run in script
    assert upsert in script
    assert script.index(dry_run) < script.index(first_task)
    assert script.index(upsert) < script.index(first_task)
    assert 'FINOPS_AGENT_NAME="${FINOPS_AGENT_NAME:-finops-investigator}"' in script
    assert 'TASK_AGENT_NAME="${TASK_AGENT_NAME:-${AGENT_NAME:-$FINOPS_AGENT_NAME}}"' in script
    assert 'if [ -n "$task_id" ] && [ "$current_agent" != "$TASK_AGENT_NAME" ]' in script
    assert 'api DELETE "/api/v1/scheduledtasks/${task_id}"' in script
