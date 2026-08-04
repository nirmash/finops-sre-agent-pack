import json
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "plugins" / "finops" / "agents" / "finops-investigator.json"
INSTALLER = ROOT / "plugins" / "finops" / "install-api.sh"

FINOPS_SKILLS = {
    "finops-managed-scope",
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


def _run_manifest_builder(manifest, python_tool="ExecutePythonCode"):
    installer = INSTALLER.read_text()
    match = re.search(
        r'python3 - "\$agent_body" <<\'PY\'\n(.*?)\nPY',
        installer,
        flags=re.DOTALL,
    )
    assert match
    env = {
        **os.environ,
        "FINOPS_AGENT_MANIFEST": "/dev/stdin",
        "FINOPS_AGENT_NAME": "finops-investigator",
        "FINOPS_MCP_TOOLS": "",
        "FINOPS_CONNECTORS": "",
        "FINOPS_PYTHON_TOOL": python_tool,
        "AGENT_RESOURCE_ID": "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/agents/agent",
    }
    return subprocess.run(
        ["python3", "-c", match.group(1), "/dev/stdout"],
        input=json.dumps(manifest),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


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
    assert "azure execution surface is strictly read-only" in instructions
    assert "external mcp/connectors have their own scopes" in instructions
    assert "never execute azure post, put, patch, or delete" in instructions
    assert "never execute that script" in instructions
    assert "scheduled tasks are always read-only" in instructions
    assert "never change rbac" in instructions
    assert "human decision" in instructions
    assert "before every finops request" in instructions
    assert "managedresources" in instructions
    assert "{{agent_resource_id}}" in instructions
    assert "scheduled work is strict and fail-closed" in instructions
    assert "explicit confirmation" in instructions
    assert "subsequent turn" in instructions
    assert "broad rbac" in instructions


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
    assert not any("write" in tool.lower() for tool in tools)


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


def test_installer_has_no_write_capability_or_write_rbac():
    script = INSTALLER.read_text()

    assert "RunAzCliWriteCommands" not in script
    assert "older/incompatible runtime" not in script
    assert '--role "Cost Management Contributor"' not in script
    assert "agent and installer execute no budget writes" in script


def test_installer_rejects_obsolete_core_tool_extension_surface():
    script = INSTALLER.read_text()

    assert (
        '[ -z "${FINOPS_EXTRA_TOOLS:-}" ] || \\\n'
        '  die "FINOPS_EXTRA_TOOLS is no longer supported: '
        'the FinOps agent core tool set is fixed and read-only."'
    ) in script
    assert 'FINOPS_EXTRA_TOOLS="$FINOPS_EXTRA_TOOLS"' not in script
    assert 'csv_values("FINOPS_EXTRA_TOOLS")' not in script
    assert 'properties["tools"] = append_unique' not in script


def test_installer_manifest_builder_normalizes_only_canonical_core_tools():
    manifest = _manifest()
    manifest["properties"]["tools"] = list(reversed(manifest["properties"]["tools"]))
    result = _run_manifest_builder(manifest)

    assert result.returncode == 0, result.stderr
    built = json.loads(result.stdout)
    assert built["properties"]["tools"] == [
        "RunAzCliReadCommands",
        "ExecutePythonCode",
        "ListReports",
        "GetReport",
        "SaveReport",
    ]


def test_installer_manifest_builder_uses_terminal_fallback_when_selected():
    result = _run_manifest_builder(_manifest(), python_tool="RunInTerminal")

    assert result.returncode == 0, result.stderr
    built = json.loads(result.stdout)
    assert built["properties"]["tools"] == [
        "RunAzCliReadCommands",
        "RunInTerminal",
        "ListReports",
        "GetReport",
        "SaveReport",
    ]
    assert "RunInTerminal for sandbox Python analysis" in built["properties"]["instructions"]
    assert "RunAzCliWriteCommands" not in built["properties"]["tools"]


def test_installer_manifest_builder_rejects_unknown_python_tool():
    result = _run_manifest_builder(_manifest(), python_tool="RunShell")

    assert result.returncode != 0
    assert "Unsupported sandbox execution tool" in result.stderr


def test_installer_manifest_builder_injects_agent_resource_id():
    result = _run_manifest_builder(_manifest())

    assert result.returncode == 0, result.stderr
    built = json.loads(result.stdout)
    instructions = built["properties"]["instructions"]
    assert "{{AGENT_RESOURCE_ID}}" not in instructions
    assert "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/agents/agent" in instructions
    assert "__AGENT_RESOURCE_ID__" not in built["properties"]["instructions"]
    assert (
        "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/agents/agent"
        in built["properties"]["instructions"]
    )


def test_installer_rejects_manifest_without_agent_resource_placeholder():
    manifest = _manifest()
    manifest["properties"]["instructions"] = "Read-only FinOps agent."
    result = _run_manifest_builder(manifest)

    assert result.returncode != 0
    assert "AGENT_RESOURCE_ID placeholder" in result.stderr


def test_installer_rejects_manifest_missing_managed_scope_skill():
    manifest = _manifest()
    manifest["properties"]["allowedSkills"].remove("finops-managed-scope")
    result = _run_manifest_builder(manifest)

    assert result.returncode != 0
    assert "all nine FinOps skills" in result.stderr


def test_installer_rejects_custom_manifest_with_azure_write_tool():
    manifest = _manifest()
    manifest["properties"]["tools"].append("RunAzCliWriteCommands")
    result = _run_manifest_builder(manifest)

    assert result.returncode != 0
    assert "Read-only Azure safety error" in result.stderr
    assert "must contain exactly" in result.stderr


def test_installer_rejects_custom_manifest_missing_core_tool():
    manifest = _manifest()
    manifest["properties"]["tools"].remove("ExecutePythonCode")
    result = _run_manifest_builder(manifest)

    assert result.returncode != 0
    assert "Read-only Azure safety error" in result.stderr
