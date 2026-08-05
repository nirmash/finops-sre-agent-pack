"""Documentation and metadata guardrails for read-only budget planning."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FINOPS = ROOT / "plugins" / "finops"
SKILL = FINOPS / "skills" / "finops-budget-editor" / "SKILL.md"


def test_budget_skill_documents_human_run_script_workflow():
    text = SKILL.read_text()
    lowered = text.lower()

    assert "recommendation-only" in lowered
    assert "read the exact current budget" in lowered
    assert "bounded consumption" in lowered
    assert "application_script" in text
    assert "human to review, save, and run manually" in lowered
    assert "agent does not run the script" in lowered
    assert "set -euo pipefail" in text
    assert "exact confirmation phrase" in lowered
    assert "if-match=<captured etag>" in lowered
    assert "if-none-match=*" in lowered
    assert "exact decimal numeric equality" in lowered
    assert "exits nonzero on mismatch" in lowered
    assert "no agent-executed put/post/patch/delete" in lowered
    assert "no write tool in the agent manifest" in lowered
    assert "no role assignment" in lowered


def test_metadata_describes_read_only_human_run_planning():
    plugin = json.loads((FINOPS / "plugin.json").read_text())
    marketplace = json.loads((ROOT / ".github" / "plugin" / "marketplace.json").read_text())
    descriptions = [
        plugin["description"],
        marketplace["plugins"][0]["description"],
    ]
    for description in descriptions:
        lowered = description.lower()
        assert "read-only" in lowered
        assert "human" in lowered
        assert "script" in lowered
        assert "runazcliwritecommands" not in lowered


def test_scheduled_tasks_and_docs_do_not_reference_write_tools():
    for path in (FINOPS / "scheduled-tasks").glob("*.yaml"):
        text = path.read_text()
        assert "RunAzCliWriteCommands" not in text
        assert "finops-budget-editor" not in text
    for path in [
        ROOT / "README.md",
        FINOPS / "README.md",
        FINOPS / "install-api.sh",
        FINOPS / "agents" / "finops-investigator.json",
        SKILL,
    ]:
        assert "RunAzCliWriteCommands" not in path.read_text()


def test_installer_docs_keep_core_tools_fixed():
    text = (FINOPS / "README.md").read_text()

    assert "fixed core Azure/report tool list" in text
    assert "FINOPS_EXTRA_TOOLS" in text
    assert "is obsolete" in text
    assert "cannot be appended" in text
    assert "properties.tools" in text
    assert "must equal exactly" in text


def test_skill_docs_support_both_sandbox_python_runtime_variants():
    for path in (FINOPS / "skills").glob("*/SKILL.md"):
        text = path.read_text()
        assert "run in-sandbox via ExecutePythonCode" not in text
        if "ExecutePythonCode" in text:
            assert "RunInTerminal" in text
            assert "python3" in text
