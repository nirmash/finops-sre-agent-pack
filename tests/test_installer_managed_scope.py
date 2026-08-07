import importlib.util
import json
import re
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "plugins" / "finops" / "install-api.sh"
TASK_DIR = ROOT / "plugins" / "finops" / "scheduled-tasks"
TASK_RENDERER = TASK_DIR / "render_tasks.py"
REPORT_TASKS = (
    "cost-overview-report-daily.yaml",
    "rightsizing-savings-report-weekly.yaml",
    "budget-status-report-daily.yaml",
    "cost-optimization-report-weekly.yaml",
    "ai-spend-report-weekly.yaml",
    "cost-vs-reliability-report-weekly.yaml",
)
PROMPT_TASK_IDS = {
    "ANOMALY_PROMPT": "cost-anomaly",
    "REPORT_PROMPT": "cost-overview-report",
    "RIGHTSIZE_REPORT_PROMPT": "rightsizing-savings-report",
    "BUDGET_REPORT_PROMPT": "budget-status-report",
    "COST_OPT_PROMPT": "cost-optimization-report",
    "AI_REPORT_PROMPT": "ai-spend-report",
    "RELIABILITY_REPORT_PROMPT": "cost-vs-reliability-report",
}
UAMI_ID = (
    "/subscriptions/control/resourceGroups/agents/"
    "providers/Microsoft.ManagedIdentity/userAssignedIdentities/finops"
)


def _script():
    return INSTALLER.read_text()


def _prompt(name):
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    task = next(
        task for task in module.load_manifest() if task["id"] == PROMPT_TASK_IDS[name]
    )
    return module.render_task(task, reference=True)["agentPrompt"]


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

    assert 'SUB_ID_WAS_SET="${SUB_ID+x}"' in script
    assert 'if [ -n "$SUB_ID_WAS_SET" ]; then' in script
    assert "SUB_ID is deprecated and ignored" in script
    assert "DEFAULT_SUB_ID" not in script
    assert "93cba93f-571e-44e9-ac0a-a2987b58848c" not in script
    assert "${SUB_ID}" not in script
    assert '--scope "/subscriptions/${SUB_ID}"' not in script


def test_personal_alert_and_correlation_defaults_are_removed_safely():
    script = _script()

    assert 'ALERT_EMAIL="${ALERT_EMAIL:-}"' in script
    assert 'GITHUB_REPO="${GITHUB_REPO:-}"' in script
    assert "nimashkowski@microsoft.com" not in script
    assert "nirmash/azure-sre-agent-sandbox" not in script
    assert "unset it to disable email delivery" in script
    assert "unset it to disable GitHub correlation" in script
    assert "GITHUB_REPO not set — scheduled anomaly detection will skip GitHub correlation." in script
    assert "ALERT_EMAIL not set — scheduled findings will remain in task results" in script
    anomaly = _prompt("ANOMALY_PROMPT")
    assert "__GITHUB_REPO__" in anomaly
    assert "__ALERT_EMAIL__" in anomaly


def test_scheduled_task_payloads_support_per_task_model_tiers(monkeypatch):
    script = _script()
    assert 'MODEL_TIER="${MODEL_TIER:-ReasoningHeavy}"' in script
    assert 'python3 "$TASK_RENDERER" install-plan' in script

    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("AGENT_RESOURCE_ID", "/subscriptions/s/resourceGroups/r/providers/Microsoft.App/agents/a")
    monkeypatch.setenv("TASK_AGENT_NAME", "base-agent")
    monkeypatch.setenv("MODEL_TIER", "Fast")
    for index, task in enumerate(module.load_manifest()):
        tier = f"Tier{index}"
        monkeypatch.setenv(task["modelEnv"], tier)
        assert module.render_task(task)["modelTier"] == tier


def test_empty_task_environment_values_fall_back_to_manifest_defaults(monkeypatch):
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    task = next(
        task for task in module.load_manifest() if task["id"] == "cost-overview-report"
    )
    monkeypatch.setenv(
        "AGENT_RESOURCE_ID",
        "/subscriptions/s/resourceGroups/r/providers/Microsoft.App/agents/a",
    )
    monkeypatch.setenv("TASK_AGENT_NAME", "finops-investigator")
    monkeypatch.setenv("MODEL_TIER", "")
    for name in (
        task["nameEnv"],
        task["cronEnv"],
        task["modelEnv"],
        task["reportNameEnv"],
    ):
        monkeypatch.setenv(name, "")

    payload = module.render_task(task)

    assert payload["name"] == task["defaultName"]
    assert payload["cronExpression"] == task["defaultCron"]
    assert payload["modelTier"] == "ReasoningHeavy"
    assert task["defaultReportName"] in payload["agentPrompt"]


def test_user_values_with_template_braces_are_not_revalidated_as_source(monkeypatch):
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    task = next(
        task for task in module.load_manifest() if task["id"] == "cost-overview-report"
    )
    monkeypatch.setenv(
        "AGENT_RESOURCE_ID",
        "/subscriptions/s/resourceGroups/r/providers/Microsoft.App/agents/a",
    )
    monkeypatch.setenv("TASK_AGENT_NAME", "finops-investigator")
    monkeypatch.setenv(task["reportNameEnv"], "Cost {{Monthly}}")

    assert "Cost {{Monthly}}" in module.render_task(task)["agentPrompt"]
    with pytest.raises(ValueError, match="UNKNOWN"):
        module._substitute("Unknown source token: {{UNKNOWN}}", {"REPORT_NAME": "x"})
    with pytest.raises(ValueError, match="Malformed"):
        module._substitute("Malformed source token: {{REPORT_NAME}", {"REPORT_NAME": "x"})


def test_scheduled_tasks_are_listed_once_for_upserts_and_freshly_for_verification():
    script = _script()
    function_start = script.index("upsert_task() {")
    first_call = script.index('say "Upserting scheduled task', function_start)
    function = script[function_start:first_call]
    verification_start = script.index("# ---- 6. Verify")

    assert script.count("api GET /api/v1/scheduledtasks") == 2
    assert "api GET /api/v1/scheduledtasks" not in function
    assert 'scheduled-tasks-before.json' in script[:function_start]
    assert '"$TASK_RENDERER" install-plan' in script[:function_start]
    assert script.index("api GET /api/v1/scheduledtasks") < first_call
    assert script.index(
        "api GET /api/v1/scheduledtasks", verification_start
    ) > verification_start
    assert 'api DELETE "/api/v1/scheduledtasks/${task_id}"' in function
    assert "paused|Paused|PAUSED)" in function
    assert 'api POST "/api/v1/scheduledtasks/${created_id}/pause"' in function
    assert '"$TASK_RENDERER" verify-install' in script[verification_start:]


def test_common_scope_preamble_is_canonical_and_applied_to_every_task():
    for prompt_name in PROMPT_TASK_IDS:
        prompt = _prompt(prompt_name)
        assert "__AGENT_RESOURCE_ID__" in prompt
        assert "finops-managed-scope" in prompt
        assert "scope.py" in prompt
        assert "Dynamically GET" in prompt
        assert "FAIL CLOSED" in prompt
        assert "accepts no override" in prompt
        assert "Broad RBAC" in prompt
        assert "stop without querying analysis data, sending email, or saving a report" in prompt
        assert "effective scopes" in prompt
        assert "excluded, unattributed" in prompt
        assert "never use Azure POST, PUT, PATCH, DELETE" in prompt


def test_task_prompts_delegate_detailed_scope_and_analysis_contracts():
    expected = {
        "ANOMALY_PROMPT": ("finops-cost-anomaly-detection", "detect.py"),
        "REPORT_PROMPT": ("finops-managed-scope", "deterministic in-sandbox Python"),
        "RIGHTSIZE_REPORT_PROMPT": ("finops-rightsizing-advisor", "rightsize.py"),
        "BUDGET_REPORT_PROMPT": ("finops-budget-governance", "budget.py"),
        "COST_OPT_PROMPT": ("finops-cost-optimization-report", "summarize.py"),
        "AI_REPORT_PROMPT": ("finops-for-ai", "attribute.py"),
        "RELIABILITY_REPORT_PROMPT": ("finops-cost-vs-reliability", "reliability.py"),
    }

    for prompt_name, phrases in expected.items():
        prompt = _prompt(prompt_name)
        for phrase in phrases:
            assert phrase in prompt, (prompt_name, phrase)


def test_budget_prompts_delegate_management_group_coverage_without_duplicating_transport():
    budget_prompt = _prompt("BUDGET_REPORT_PROMPT")
    rollup_prompt = _prompt("COST_OPT_PROMPT")

    assert "every directly configured management-group budget scope" in budget_prompt
    assert "never replace management-group budgets with descendant budgets" in budget_prompt
    assert "complete read-only `finops-cost-optimization-report` SKILL.md contract" in rollup_prompt
    assert "preserve direct management-group budgets" in rollup_prompt
    assert "api-version=" not in budget_prompt


def test_rightsizing_prompts_delegate_command_scoping_to_skill_contract():
    prompt = _prompt("RIGHTSIZE_REPORT_PROMPT")
    assert "finops-rightsizing-advisor" in prompt
    assert "SKILL.md" in prompt
    assert "rightsize.py" in prompt
    assert "az advisor recommendation list" not in prompt
    assert "az graph query" not in prompt
    assert "No rightsizing opportunities above threshold this week." in prompt
    assert "Weekly rightsizing review" in prompt
    assert "report-tool failure must never suppress" in prompt


def test_package_readiness_includes_ten_skills_without_runtime_write_changes():
    script = _script()

    assert '"finops-managed-scope",' in script
    assert '"finops-report-renderer",' in script
    assert "All ten FinOps skills ready" in script
    assert "Package: 10 skills" in script
    assert "RunAzCliWriteCommands" not in script
    assert "older/incompatible runtime" not in script


def test_installer_live_report_prompts_use_deterministic_renderer():
    adapters = {
        "REPORT_PROMPT": "build_cost_overview_model",
        "RIGHTSIZE_REPORT_PROMPT": "build_rightsizing_savings_model",
        "BUDGET_REPORT_PROMPT": "build_budget_status_model",
        "COST_OPT_PROMPT": "build_cost_optimization_model",
        "AI_REPORT_PROMPT": "build_ai_spend_model",
        "RELIABILITY_REPORT_PROMPT": "build_cost_vs_reliability_model",
    }
    for prompt_name, adapter in adapters.items():
        prompt = _prompt(prompt_name)

        assert "finops-report-renderer" in prompt
        assert "models.py" in prompt
        assert "render.py" in prompt
        assert adapter in prompt
        assert "do not generically construct a model" in prompt
        assert "write_report(model," in prompt
        assert "allowedTools: []" in prompt
        assert "ListReports" in prompt
        assert "GetReport" in prompt
        assert "reused `reportId`" in prompt
        assert "static snapshot" in prompt
        assert "datetime.now(timezone.utc)" in prompt
        assert "Chart.js" not in prompt
        assert "CSP/nonce" not in prompt
        assert "SRI" not in prompt
        assert "window.sreagent" not in prompt


def test_live_report_templates_use_deterministic_renderer():
    task_dir = ROOT / "plugins" / "finops" / "scheduled-tasks"
    adapters = {
        "cost-overview-report-daily.yaml": "build_cost_overview_model",
        "rightsizing-savings-report-weekly.yaml": "build_rightsizing_savings_model",
        "budget-status-report-daily.yaml": "build_budget_status_model",
        "cost-optimization-report-weekly.yaml": "build_cost_optimization_model",
        "ai-spend-report-weekly.yaml": "build_ai_spend_model",
        "cost-vs-reliability-report-weekly.yaml": "build_cost_vs_reliability_model",
    }

    for name in REPORT_TASKS:
        prompt = (task_dir / name).read_text()

        assert "finops-report-renderer" in prompt
        assert "models.py" in prompt
        assert "render.py" in prompt
        assert adapters[name] in prompt
        assert "do not generically construct a model" in prompt
        assert "write_report(model," in prompt
        assert "allowedTools: []" in prompt
        assert "ListReports" in prompt
        assert "GetReport" in prompt
        assert "reused `reportId`" in prompt
        assert "static snapshot" in prompt
        assert "datetime.now(timezone.utc)" in prompt
        assert "Chart.js" not in prompt
        assert "CSP/nonce" not in prompt
        assert "SRI" not in prompt
        assert "window.sreagent" not in prompt


def test_canonical_source_generated_yaml_and_installer_payload_path_do_not_drift():
    result = subprocess.run(
        ["python3", str(TASK_RENDERER), "check"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr

    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for task in module.load_manifest():
        assert (TASK_DIR / task["yaml"]).read_text() == module.render_yaml(task)

    script = _script()
    for task in module.load_manifest():
        assert task["defaultName"] not in script
        assert task["defaultCron"] not in script
        if task.get("defaultReportName"):
            assert task["defaultReportName"] not in script
    assert 'python3 "$TASK_RENDERER" install-plan' in script
    assert 'python3 "$TASK_RENDERER" verify-install' in script
    assert 'api PUT "/api/v1/scheduledtasks/${task_id}" "$body"' in script
    assert 'api POST /api/v1/scheduledtasks "$body"' in script
    assert "read -r -d ''" not in script


def test_rightsizing_review_is_retired_and_merged_without_schedule_collisions():
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    tasks = module.load_manifest()
    retired = module.load_retired_tasks()

    assert len(tasks) == 7
    assert {task["id"] for task in retired} == {"rightsizing-review"}
    assert not (TASK_DIR / "rightsizing-weekly.yaml").exists()
    assert len({task["defaultCron"] for task in tasks}) == len(tasks)
    rightsizing = next(
        task for task in tasks if task["id"] == "rightsizing-savings-report"
    )
    prompt = module.render_task(rightsizing, reference=True)["agentPrompt"]
    assert "SaveReport" in prompt
    assert "__ALERT_EMAIL__" in prompt
    assert "do not email" in prompt


def test_reasoning_heavy_defaults_and_live_ab_knobs_are_explicit():
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    tasks = {task["id"]: task for task in module.load_manifest()}

    for task_id in (
        "cost-anomaly",
        "rightsizing-savings-report",
        "cost-optimization-report",
        "cost-vs-reliability-report",
    ):
        assert module.render_task(tasks[task_id], reference=True)["modelTier"] == "ReasoningHeavy"

    docs = (ROOT / "plugins" / "finops" / "README.md").read_text()
    assert "no verified lower-tier enum" in docs
    assert "REPORT_MODEL_TIER" in docs
    assert "BUDGET_REPORT_MODEL_TIER" in docs
    assert "AI_REPORT_MODEL_TIER" in docs


def test_installer_task_path_reduces_steady_state_python_subprocesses():
    script = _script()
    task_section = script[
        script.index("# ---- 5. Upsert"):script.index('say "Done — FinOps pack')
    ]

    assert task_section.count("python3 ") == 3
    assert "from 43 to\n3 on an update" in (
        ROOT / "plugins" / "finops" / "README.md"
    ).read_text()


def test_installer_uses_external_secure_temp_and_removes_marketplace_credentials():
    script = _script()

    assert "umask 077" in script
    assert 'command -v mktemp >/dev/null 2>&1 || die "mktemp not found."' in script
    assert 'REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"' in script
    assert 'INSTALL_WORK_DIR="$(mktemp -d "$TEMP_ROOT/finops-install.XXXXXXXX")"' in script
    assert 'INSTALL_WORK_DIR="$SCRIPT_DIR/' not in script
    assert 'trap \'rm -rf -- "$INSTALL_WORK_DIR"\' EXIT' in script
    request = script.index('api POST /api/v2/plugins/marketplaces "$mk_body"')
    cleanup = script.index('rm -f -- "$mk_body"', request)
    response_case = script.index('case "$HTTP_CODE" in', request)
    assert request < cleanup < response_case
    assert script.count('rm -f -- "$mk_body"') == 2


def test_install_plan_reuses_one_list_and_verifies_retirement(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv(
        "AGENT_RESOURCE_ID",
        "/subscriptions/s/resourceGroups/r/providers/Microsoft.App/agents/a",
    )
    monkeypatch.setenv("TASK_AGENT_NAME", "finops-investigator")
    existing = tmp_path / "existing.json"
    existing.write_text(
        json.dumps(
            {
                "value": [
                    {
                        "id": "retired-1",
                        "name": "FinOps: Rightsizing Review (Weekly)",
                        "agent": "finops-investigator",
                        "status": "Active",
                    }
                ]
            }
        )
    )
    plan = tmp_path / "plan"

    module.write_install_plan(existing, plan)

    assert len((plan / "task-plan.tsv").read_text().splitlines()) == 7
    assert (plan / "retired-plan.tsv").read_text().split("\x1f") == [
        "retired-1",
        "FinOps: Rightsizing Review (Weekly)\n",
    ]
    expected = json.loads((plan / "expected-tasks.json").read_text())
    after = tmp_path / "after.json"
    after.write_text(
        json.dumps(
            {
                "value": [
                    {
                        "id": f"task-{index}",
                        "name": task["name"],
                        "agent": task["agent"],
                    }
                    for index, task in enumerate(expected["tasks"])
                ]
            }
        )
    )
    assert module.verify_install(after, plan / "expected-tasks.json") == 0


def test_runtime_payloads_preserve_all_environment_overrides(monkeypatch):
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("AGENT_RESOURCE_ID", "/subscriptions/s/resourceGroups/r/providers/Microsoft.App/agents/a")
    monkeypatch.setenv("TASK_AGENT_NAME", "v2-base-agent")
    monkeypatch.setenv("ALERT_EMAIL", "finops@example.com")
    monkeypatch.setenv("GITHUB_REPO", "owner/repo")

    for index, task in enumerate(module.load_manifest()):
        monkeypatch.setenv(task["nameEnv"], f"Task {index}")
        monkeypatch.setenv(task["cronEnv"], f"{index} 1 * * *")
        monkeypatch.setenv(task["modelEnv"], f"Tier{index}")
        if task.get("reportNameEnv"):
            monkeypatch.setenv(task["reportNameEnv"], f"Report {index}")
        payload = module.render_task(task)
        assert payload["name"] == f"Task {index}"
        assert payload["cronExpression"] == f"{index} 1 * * *"
        assert payload["modelTier"] == f"Tier{index}"
        assert payload["agent"] == "v2-base-agent"
        assert "/agents/a" in payload["agentPrompt"]
        if task["id"] == "cost-anomaly":
            assert "owner/repo" in payload["agentPrompt"]
            assert "finops@example.com" in payload["agentPrompt"]
        if task.get("reportNameEnv"):
            assert f"Report {index}" in payload["agentPrompt"]


def test_anomaly_delivery_and_correlation_fail_safely_when_unconfigured(monkeypatch):
    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setenv("AGENT_RESOURCE_ID", "/subscriptions/s/resourceGroups/r/providers/Microsoft.App/agents/a")
    monkeypatch.setenv("TASK_AGENT_NAME", "finops-investigator")
    monkeypatch.delenv("ALERT_EMAIL", raising=False)
    monkeypatch.delenv("GITHUB_REPO", raising=False)
    task = next(task for task in module.load_manifest() if task["id"] == "cost-anomaly")
    prompt = module.render_task(task)["agentPrompt"]

    assert "GitHub correlation is disabled" in prompt
    assert "do not send email" in prompt
    assert "only in the scheduled-task result" in prompt


def test_generated_task_files_and_cost_optimization_prompt_meet_reduction_targets():
    baseline = 52_449
    static_bytes = sum(path.stat().st_size for path in TASK_DIR.glob("*.yaml"))
    assert static_bytes <= baseline * 0.65

    spec = importlib.util.spec_from_file_location("finops_task_renderer", TASK_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    task = next(
        task for task in module.load_manifest() if task["id"] == "cost-optimization-report"
    )
    prompt_bytes = len(module.render_task(task, reference=True)["agentPrompt"].encode())
    assert prompt_bytes <= 5_039 * 0.75
