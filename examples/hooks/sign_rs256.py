#!/usr/bin/env python3
# sign_rs256.py: mailBoy pre-request hook that signs the request with RS256.
# What it does: reads the hook input from stdin, builds the acme-widgets-v2 JWT
# payload (path, body hash, timestamp, expiry), signs it with the PEM key in the
# SIGNING_KEY collection variable, returns headers x-acme-signature and x-acme-client.
# What it needs: Python 3, the "cryptography" package (pip install cryptography),
# and the collection variables SIGNING_KEY, CLIENT_ID and KEY_ID.
# How to run: mailboy --run X --collection C --hook ./sign_rs256.py
import base64, hashlib, json, sys
from datetime import datetime, timezone
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")
def b64url_json(obj):
    return b64url(json.dumps(obj, separators=(",", ":")).encode("utf-8"))

# 1. Read all of stdin and parse it. Only the before phase does any work.
hook_input = json.loads(sys.stdin.read())
if hook_input.get("phase") != "before":
    print("{}")
    sys.exit(0)

# 2. The collection variables, naming every one that is empty.
variables = hook_input.get("variables", {}).get("collection", {})
signing_key = variables.get("SIGNING_KEY") or ""
client_id = variables.get("CLIENT_ID") or ""
key_id = variables.get("KEY_ID") or ""
missing = False
for name, value in (("SIGNING_KEY", signing_key), ("CLIENT_ID", client_id), ("KEY_ID", key_id)):
    if value == "":
        print("empty variable: " + name, file=sys.stderr)
        missing = True
if missing:
    sys.exit(1)

# 3. Path after the host, body hash, timestamps.
url = hook_input["request"]["url"]
host_and_path = url.split("://", 1)[1] if "://" in url else url
path = host_and_path[host_and_path.index("/"):] if "/" in host_and_path else ""
body = (hook_input["request"].get("body") or {}).get("raw") or ""
body_hash = hashlib.sha256(body.encode("utf-8")).hexdigest()
now = datetime.now(timezone.utc)
ts = now.isoformat(timespec="milliseconds").replace("+00:00", "Z")
exp = int(now.timestamp()) + 180

# 4. Header and payload, base64url, sign with RS256, base64url the signature.
header = {"alg": "RS256", "typ": "JWT"}
payload = {"ver": "acme-widgets-v2", "clientId": client_id, "keyId": key_id, "path": path,
           "bodyAlg": "sha256", "ts": ts, "bodyHash": body_hash, "exp": exp}
signing_input = b64url_json(header) + "." + b64url_json(payload)
private_key = serialization.load_pem_private_key(signing_key.encode("utf-8"), password=None)
signature = private_key.sign(signing_input.encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
jwt = signing_input + "." + b64url(signature)

# 5. The output: two headers and one console line.
headers = [{"key": "x-acme-signature", "value": jwt}, {"key": "x-acme-client", "value": client_id}]
print(json.dumps({"protocol": 1, "request": {"headers": headers},
                  "console": ["signed " + path + " with key " + key_id]}))
