#!/usr/bin/env python3
"""Read bounded hook journals and print the lifecycle of recent project notifications."""
import argparse
import datetime
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, default=Path.home() / ".config/space-dock/agent-hooks.jsonl")
    parser.add_argument("--project", help="Case-insensitive project substring")
    parser.add_argument("--trace", help="Event trace prefix")
    parser.add_argument("--last", type=int, default=12, help="Number of latest event traces")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    rows = []
    for path in [Path(str(args.file) + ".1"), args.file]:
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
                if isinstance(row.get("fields"), dict) and isinstance(row.get("time"), (int, float)):
                    rows.append(row)
            except (ValueError, AttributeError):
                continue  # The active writer may be between append syscalls.
    rows.sort(key=lambda row: row["time"])
    selected = [r for r in rows if r["fields"].get("trace")
                and (not args.project or args.project.lower() in r["fields"].get("project", "").lower())
                and (not args.trace or r["fields"]["trace"].startswith(args.trace))]
    traces = list(dict.fromkeys(r["fields"]["trace"] for r in selected))[-max(1, args.last):]
    # Include the matched request capture even if it was saved much earlier.
    linked = {r["fields"].get("context_trace") for r in selected if r["fields"]["trace"] in traces}
    ids = set(traces) | (linked - {None})
    for row in rows:
        fields = row["fields"]
        if fields.get("trace") not in ids:
            continue
        if args.json:
            print(json.dumps(row, ensure_ascii=False))
            continue
        time = datetime.datetime.fromtimestamp(row["time"]).astimezone().isoformat(timespec="milliseconds")
        keys = ["project", "kind", "start_source", "context_match", "context_trace", "capture_reason",
                "notice", "input", "origin_uuid", "destination_uuid", "actual_uuid", "outcome", "reason"]
        details = " ".join(f"{k}={fields[k]}" for k in keys if k in fields)
        print(f"{time} {row['stage']:<28} trace={fields['trace'][:12]} {details}")
    if not selected:
        print("No matching hook traces found.")


if __name__ == "__main__":
    main()
