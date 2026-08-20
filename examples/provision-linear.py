#!/usr/bin/env python3
"""Idempotently provision a Linear team for a Symphony PR workflow.

Ensures the workflow states and labels that the `autonomous` fork's workflows
expect exist on a team:

  - States: "Human Review" (parked; keep OUT of the workflow's active_states) and
    "Rework" (reviewer-requested changes; keep IN active_states so Symphony
    re-dispatches). Both created as `started` type, placed after "In Progress".
  - Labels: "symphony", "ai-generated".

Safe to run repeatedly: anything that already exists (case-insensitive) is left
untouched.

Usage:
  LINEAR_API_KEY=... ./provision-linear.py --team-key AI
  LINEAR_API_KEY=... ./provision-linear.py --issue AI-12          # resolve team via an issue
  LINEAR_API_KEY=... ./provision-linear.py --team-key AI --dry-run

Requires only the Python standard library.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

API = "https://api.linear.app/graphql"

# name -> (linear state type, hex color). Edit to taste.
DESIRED_STATES = {
    "Human Review": ("started", "#F2C94C"),
    "Rework": ("started", "#EB5757"),
}
DESIRED_LABELS = {
    "symphony": "#5E6AD2",
    "ai-generated": "#0F783C",
}


def gql(key: str, query: str, variables: dict | None = None) -> dict:
    payload = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        API, data=payload,
        headers={"Authorization": key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        body = json.load(resp)
    if "errors" in body:
        raise SystemExit(f"Linear API error: {json.dumps(body['errors'], indent=2)}")
    return body["data"]


def resolve_team(key: str, *, team_key: str | None, issue: str | None) -> dict:
    if issue:
        data = gql(key,
            "query($id:String!){issue(id:$id){team{id name key "
            "states{nodes{id name type position}} labels{nodes{id name}}}}}",
            {"id": issue})
        team = data["issue"]["team"]
        if not team:
            raise SystemExit(f"Could not resolve team from issue {issue}")
        return team
    if team_key:
        data = gql(key,
            "query($k:String!){teams(filter:{key:{eq:$k}}){nodes{id name key "
            "states{nodes{id name type position}} labels{nodes{id name}}}}}",
            {"k": team_key})
        nodes = data["teams"]["nodes"]
        if not nodes:
            raise SystemExit(f"No team with key {team_key!r}")
        return nodes[0]
    raise SystemExit("Provide --team-key or --issue")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--team-key", help="Linear team key, e.g. AI")
    ap.add_argument("--issue", help="Issue identifier to resolve the team from, e.g. AI-12")
    ap.add_argument("--dry-run", action="store_true", help="Print actions without applying")
    args = ap.parse_args()

    key = os.environ.get("LINEAR_API_KEY")
    if not key:
        raise SystemExit("LINEAR_API_KEY is not set")

    team = resolve_team(key, team_key=args.team_key, issue=args.issue)
    tid = team["id"]
    print(f"Team: {team['name']} ({team['key']}) {tid}")

    states = team["states"]["nodes"]
    have_states = {s["name"].strip().lower() for s in states}
    labels = team["labels"]["nodes"]
    have_labels = {l["name"].strip().lower() for l in labels}
    in_progress = next((s for s in states if s["name"].strip().lower() == "in progress"), None)
    base_pos = in_progress["position"] if in_progress else max((s["position"] for s in states), default=0)

    state_mut = ("mutation($t:String!,$n:String!,$ty:String!,$c:String!,$p:Float){"
                 "workflowStateCreate(input:{teamId:$t,name:$n,type:$ty,color:$c,position:$p})"
                 "{success workflowState{id name position}}}")
    for i, (name, (stype, color)) in enumerate(DESIRED_STATES.items(), start=1):
        if name.strip().lower() in have_states:
            print(f"  state  ✓ exists: {name}")
            continue
        if args.dry_run:
            print(f"  state  + would create: {name} ({stype})")
            continue
        r = gql(key, state_mut, {"t": tid, "n": name, "ty": stype, "c": color, "p": base_pos + 0.1 * i})
        print(f"  state  + created: {r['workflowStateCreate']['workflowState']}")

    label_mut = ("mutation($t:String!,$n:String!,$c:String!){"
                 "issueLabelCreate(input:{teamId:$t,name:$n,color:$c})"
                 "{success issueLabel{id name}}}")
    for name, color in DESIRED_LABELS.items():
        if name.strip().lower() in have_labels:
            print(f"  label  ✓ exists: {name}")
            continue
        if args.dry_run:
            print(f"  label  + would create: {name}")
            continue
        r = gql(key, label_mut, {"t": tid, "n": name, "c": color})
        print(f"  label  + created: {r['issueLabelCreate']['issueLabel']}")

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
