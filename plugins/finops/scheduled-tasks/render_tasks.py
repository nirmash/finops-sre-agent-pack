#!/usr/bin/env python3
"""Render FinOps scheduled-task API payloads and checked-in YAML references."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import sys
import textwrap


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "task-manifest.json"
SCOPE_PROMPT = ROOT / "prompts" / "_managed-scope.txt"
EXPECTED_IDS = {
    "cost-anomaly",
    "cost-overview-report",
    "rightsizing-savings-report",
    "budget-status-report",
    "cost-optimization-report",
    "ai-spend-report",
    "cost-vs-reliability-report",
}
EXPECTED_RETIRED_IDS = {"rightsizing-review"}
_TEMPLATE_TOKEN = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")


def _load_manifest_data():
    data = json.loads(MANIFEST.read_text())
    tasks = data.get("tasks")
    retired = data.get("retiredTasks")
    if (
        data.get("schemaVersion") != 1
        or not isinstance(tasks, list)
        or not isinstance(retired, list)
    ):
        raise ValueError("Unsupported or malformed task manifest")
    ids = {task.get("id") for task in tasks}
    retired_ids = {task.get("id") for task in retired}
    if len(tasks) != 7 or ids != EXPECTED_IDS:
        raise ValueError("Task manifest must define the canonical seven task IDs")
    if len(retired) != 1 or retired_ids != EXPECTED_RETIRED_IDS:
        raise ValueError("Task manifest must define the retired rightsizing review task")
    if ids & retired_ids:
        raise ValueError("Active and retired task IDs must not overlap")
    for task in tasks:
        prompt_path = ROOT / task["prompt"]
        if not prompt_path.is_file():
            raise ValueError(f"Missing prompt asset: {prompt_path}")
    return tasks, retired


def load_manifest():
    return _load_manifest_data()[0]


def load_retired_tasks():
    return _load_manifest_data()[1]


def _env(name, default):
    value = os.environ.get(name)
    return default if value in (None, "") else value


def _plain_value(name, value):
    if not value or any(ord(char) < 32 for char in value):
        raise ValueError(f"{name} must be nonempty and contain no control characters")
    return value


def _optional_plain_value(name, value):
    if value in (None, ""):
        return ""
    return _plain_value(name, str(value))


def _task_list(data):
    tasks = data if isinstance(data, list) else data.get("value", [])
    if not isinstance(tasks, list) or any(not isinstance(task, dict) for task in tasks):
        raise ValueError("Scheduled-task list response must contain task objects")
    return tasks


def _api_id(value):
    value = _optional_plain_value("scheduled task id", value)
    if value and any(
        char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        for char in value
    ):
        raise ValueError("Scheduled task id contains unsupported characters")
    return value


def _special_values(reference):
    if reference:
        return {
            "AGENT_RESOURCE_ID": "__AGENT_RESOURCE_ID__",
            "ANOMALY_CORRELATION": (
                "Correlate each anomaly only within its effective scope to deployments and "
                "Activity Log writes; when `__GITHUB_REPO__` is configured, also correlate "
                "commits and merged PRs from that repository."
            ),
            "ANOMALY_DELIVERY": (
                "if `__ALERT_EMAIL__` is configured, email it with subject "
                "`Cost anomaly detected — <date>` and High importance; otherwise return it "
                "only in the scheduled-task result."
            ),
            "RIGHTSIZE_DELIVERY": (
                "if `__ALERT_EMAIL__` is configured, email it with subject "
                "`Weekly rightsizing review — <date>` and Normal importance; otherwise "
                "return it only in the scheduled-task result."
            ),
        }

    github_repo = os.environ.get("GITHUB_REPO", "")
    alert_email = os.environ.get("ALERT_EMAIL", "")
    correlation = (
        "Correlate each anomaly only within its effective scope to deployments, Activity "
        f"Log writes, and commits plus merged PRs from `{github_repo}`."
        if github_repo
        else "Correlate each anomaly only within its effective scope to deployments and "
        "Activity Log writes. GitHub correlation is disabled because GITHUB_REPO was not "
        "set at installation time."
    )
    anomaly_delivery = (
        f"email `{alert_email}` with subject `Cost anomaly detected — <date>` and High importance."
        if alert_email
        else "do not send email; ALERT_EMAIL was not set at installation time, so return it "
        "only in the scheduled-task result."
    )
    rightsizing_delivery = (
        f"email `{alert_email}` with subject `Weekly rightsizing review — <date>` and Normal importance."
        if alert_email
        else "do not send email; ALERT_EMAIL was not set at installation time, so return it "
        "only in the scheduled-task result."
    )
    return {
        "AGENT_RESOURCE_ID": os.environ["AGENT_RESOURCE_ID"],
        "ANOMALY_CORRELATION": correlation,
        "ANOMALY_DELIVERY": anomaly_delivery,
        "RIGHTSIZE_DELIVERY": rightsizing_delivery,
    }


def _substitute(text, values):
    source_tokens = set(_TEMPLATE_TOKEN.findall(text))
    without_tokens = _TEMPLATE_TOKEN.sub("", text)
    if "{{" in without_tokens or "}}" in without_tokens:
        raise ValueError("Malformed prompt placeholder in source template")
    unknown = source_tokens - values.keys()
    if unknown:
        raise ValueError(
            "Unresolved prompt variables: " + ", ".join(sorted(unknown))
        )
    for key in source_tokens:
        text = text.replace("{{" + key + "}}", values[key])
    return text.strip()


def render_task(task, reference=False):
    values = _special_values(reference)
    if task.get("reportNameEnv"):
        values["REPORT_NAME"] = _plain_value(
            task["reportNameEnv"],
            task["defaultReportName"]
            if reference
            else _env(task["reportNameEnv"], task["defaultReportName"]),
        )
    scope = _substitute(SCOPE_PROMPT.read_text(), values)
    prompt = _substitute((ROOT / task["prompt"]).read_text(), values)
    model_default = _env("MODEL_TIER", "ReasoningHeavy")
    name = _plain_value(
        task["nameEnv"],
        task["defaultName"]
        if reference
        else _env(task["nameEnv"], task["defaultName"]),
    )
    cron = _plain_value(
        task["cronEnv"],
        f"__{task['cronEnv']}__"
        if reference
        else _env(task["cronEnv"], task["defaultCron"]),
    )
    agent = _plain_value(
        "TASK_AGENT_NAME",
        "__AGENT_NAME__" if reference else os.environ["TASK_AGENT_NAME"],
    )
    model = _plain_value(
        task["modelEnv"],
        "ReasoningHeavy"
        if reference
        else _env(task["modelEnv"], model_default),
    )
    if not reference and any(
        char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        for char in model
    ):
        raise ValueError(f"{task['modelEnv']} contains unsupported characters")
    return {
        "id": task["id"],
        "yaml": task["yaml"],
        "tags": task["tags"],
        "name": name,
        "description": task["description"],
        "cronExpression": cron,
        "agentPrompt": scope + "\n\n" + prompt,
        "agent": agent,
        "agentMode": "autonomous",
        "modelTier": model,
        "owner": "__ALERT_EMAIL__" if reference else os.environ.get("ALERT_EMAIL", ""),
    }


def render_api_payloads():
    return [
        {
            key: value
            for key, value in render_task(task).items()
            if key not in {"id", "yaml", "tags", "owner"}
        }
        for task in load_manifest()
    ]


def _quoted(value):
    return json.dumps(value, ensure_ascii=False)


def render_yaml(task):
    item = render_task(task, reference=True)
    description = textwrap.wrap(item["description"], width=88)
    prompt_lines = item["agentPrompt"].splitlines()
    lines = [
        "# Generated by render_tasks.py from task-manifest.json and prompts/.",
        "# Do not edit this file directly; run: python3 render_tasks.py write",
        "apiVersion: azuresre.ai/v1",
        "kind: ScheduledTask",
        "metadata:",
        f"  name: {_quoted(item['name'])}",
        f"  owner: {_quoted(item['owner'])}",
        "  tags:",
        *(f"    - {tag}" for tag in item["tags"]),
        "spec:",
        f"  name: {_quoted(item['name'])}",
        "  description: >-",
        *(f"    {line}" for line in description),
        f"  agent: {_quoted(item['agent'])}",
        f"  cron: {_quoted(item['cronExpression'])}",
        f"  modelTier: {_quoted(item['modelTier'])}",
        "  agentPrompt: |",
        *(f"    {line}" if line else "" for line in prompt_lines),
    ]
    return "\n".join(lines) + "\n"


def write_or_check(check):
    drift = []
    tasks, retired = _load_manifest_data()
    for task in tasks:
        path = ROOT / task["yaml"]
        expected = render_yaml(task)
        if check:
            if not path.is_file() or path.read_text() != expected:
                drift.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(expected)
    for task in retired:
        path = ROOT / task["yaml"]
        if path.exists():
            if check:
                drift.append(str(path.relative_to(ROOT)))
            else:
                path.unlink()
    if drift:
        print("Generated scheduled-task YAML drift: " + ", ".join(drift), file=sys.stderr)
        return 1
    return 0


def write_install_plan(existing_path, output_dir):
    tasks, retired = _load_manifest_data()
    existing = _task_list(json.loads(existing_path.read_text()))
    output_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    expected = {"tasks": [], "retiredNames": []}

    for index, task in enumerate(tasks, start=1):
        payload = {
            key: value
            for key, value in render_task(task).items()
            if key not in {"id", "yaml", "tags", "owner"}
        }
        matches = [item for item in existing if item.get("name") == payload["name"]]
        if len(matches) > 1:
            raise ValueError(f"Multiple scheduled tasks have canonical name: {payload['name']}")
        current = matches[0] if matches else {}
        current_id = _api_id(current.get("id"))
        if matches and not current_id:
            raise ValueError(f"Existing scheduled task has no id: {payload['name']}")
        body_name = f"task-{index}.json"
        (output_dir / body_name).write_text(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        row = (
            body_name,
            payload["name"],
            payload["agent"],
            payload["cronExpression"],
            current_id,
            _optional_plain_value("scheduled task agent", current.get("agent")),
            _optional_plain_value("scheduled task status", current.get("status")),
        )
        rows.append("\x1f".join(row))
        expected["tasks"].append(
            {"name": payload["name"], "agent": payload["agent"]}
        )

    retired_rows = []
    for task in retired:
        name = _plain_value(
            task["nameEnv"], _env(task["nameEnv"], task["defaultName"])
        )
        expected["retiredNames"].append(name)
        for item in existing:
            if item.get("name") == name:
                retired_id = _api_id(item.get("id"))
                if not retired_id:
                    raise ValueError(f"Retired scheduled task has no id: {name}")
                retired_rows.append(
                    "\x1f".join(
                        (
                            retired_id,
                            name,
                        )
                    )
                )

    report_names = [
        _plain_value(
            task["reportNameEnv"],
            _env(task["reportNameEnv"], task["defaultReportName"]),
        )
        for task in tasks
        if task.get("reportNameEnv")
    ]
    (output_dir / "task-plan.tsv").write_text(
        "\n".join(rows) + "\n", encoding="utf-8"
    )
    (output_dir / "retired-plan.tsv").write_text(
        ("\n".join(retired_rows) + "\n") if retired_rows else "",
        encoding="utf-8",
    )
    (output_dir / "reports.txt").write_text(
        "\n".join(report_names) + "\n", encoding="utf-8"
    )
    (output_dir / "expected-tasks.json").write_text(
        json.dumps(expected, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )


def verify_install(existing_path, expected_path):
    existing = _task_list(json.loads(existing_path.read_text()))
    expected = json.loads(expected_path.read_text())
    failures = []
    for item in expected["tasks"]:
        matches = [
            task
            for task in existing
            if task.get("name") == item["name"] and task.get("agent") == item["agent"]
        ]
        if len(matches) != 1:
            failures.append(
                f"expected exactly one task on {item['agent']}: {item['name']}"
            )
    for name in expected["retiredNames"]:
        if any(task.get("name") == name for task in existing):
            failures.append(f"retired task is still present: {name}")
    if failures:
        print("Scheduled-task verification failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=("api", "reports", "write", "check", "install-plan", "verify-install"),
    )
    parser.add_argument(
        "--base64-lines",
        action="store_true",
        help="for api, emit one base64-encoded JSON payload per line",
    )
    parser.add_argument("--existing", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--expected", type=Path)
    args = parser.parse_args()
    if args.command == "write":
        return write_or_check(False)
    if args.command == "check":
        return write_or_check(True)
    if args.command == "reports":
        for task in load_manifest():
            if task.get("reportNameEnv"):
                print(_env(task["reportNameEnv"], task["defaultReportName"]))
        return 0
    if args.command == "install-plan":
        if args.existing is None or args.output_dir is None:
            parser.error("install-plan requires --existing and --output-dir")
        write_install_plan(args.existing, args.output_dir)
        return 0
    if args.command == "verify-install":
        if args.existing is None or args.expected is None:
            parser.error("verify-install requires --existing and --expected")
        return verify_install(args.existing, args.expected)

    payloads = render_api_payloads()
    if args.base64_lines:
        for payload in payloads:
            raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
            print(base64.b64encode(raw).decode())
    else:
        json.dump(payloads, sys.stdout, ensure_ascii=False, indent=2)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
