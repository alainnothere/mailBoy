#!/usr/bin/env python3
# capture_token.py: mailBoy after-response hook that captures a token.
#
# What it does: reads the response body as JSON and stores its top-level
# "access_token" in the session variable "token", so the next request in the
# same mailBoy session can use {{token}}. In the before phase it does nothing.
# What it needs: Python 3, nothing else.
# How to run: mailboy --run X --collection C --hook ./capture_token.py
import json, sys

hook_input = json.loads(sys.stdin.read())
if hook_input.get("phase") != "after":
    print("{}")
    sys.exit(0)
try:
    body = json.loads((hook_input.get("response") or {}).get("body") or "")
except ValueError:
    body = {}
if not isinstance(body, dict) or "access_token" not in body:
    print(json.dumps({"protocol": 1, "console": ["no access_token in response"]}))
    sys.exit(0)
token = str(body["access_token"])
print(json.dumps({"protocol": 1,
                  "variables": {"set": [{"scope": "session", "name": "token", "value": token}]},
                  "console": ["captured token"]}))
