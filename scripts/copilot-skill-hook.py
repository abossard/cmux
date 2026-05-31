#!/usr/bin/env python3
"""Copilot sessionStart hook: injects cmux skill as additionalContext."""
import json, os, sys

skill_path = os.path.join(os.path.dirname(__file__), "..", "skills", "cmux", "SKILL.md")
try:
    with open(skill_path) as f:
        content = f.read()
    print(json.dumps({"additionalContext": content}))
except Exception:
    print("{}")
