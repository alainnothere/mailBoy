#!/usr/bin/env bash
# sign_rs256.sh: mailBoy pre-request hook that signs the request with RS256.
#
# What it does: reads the hook input JSON from stdin, builds the acme-widgets-v2
# JWT payload (request path, SHA-256 of the body, timestamp, expiry), signs it
# with the PEM private key in the SIGNING_KEY collection variable, and returns
# two headers to add: x-acme-signature (the JWT) and x-acme-client.
# What it needs: bash, openssl and jq. GNU date (any Linux) for the millisecond timestamp.
# Collection variables SIGNING_KEY, CLIENT_ID and KEY_ID must be set.
# How to run: mailboy --run X --collection C --hook ./sign_rs256.sh
set -eu

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# 1. Read all of stdin and parse it. Only the before phase does any work.
input=$(cat)
if [ "$(printf '%s' "$input" | jq -r '.phase // ""')" != "before" ]; then
  echo '{}'
  exit 0
fi

# 2. The collection variables, naming every one that is empty.
signing_key=$(printf '%s' "$input" | jq -r '.variables.collection.SIGNING_KEY // ""')
client_id=$(printf '%s' "$input" | jq -r '.variables.collection.CLIENT_ID // ""')
key_id=$(printf '%s' "$input" | jq -r '.variables.collection.KEY_ID // ""')
missing=0
if [ -z "$signing_key" ]; then echo "empty variable: SIGNING_KEY" >&2; missing=1; fi
if [ -z "$client_id" ]; then echo "empty variable: CLIENT_ID" >&2; missing=1; fi
if [ -z "$key_id" ]; then echo "empty variable: KEY_ID" >&2; missing=1; fi
if [ "$missing" = 1 ]; then exit 1; fi

# 3. Path after the host, body hash, timestamps.
url=$(printf '%s' "$input" | jq -r '.request.url')
host_and_path=${url#*://}
path=""
if [ "${host_and_path#*/}" != "$host_and_path" ]; then path="/${host_and_path#*/}"; fi
body_hash=$(printf '%s' "$input" | jq -j '.request.body.raw // ""' | openssl dgst -sha256 -r | cut -d' ' -f1)
ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
exp=$(( $(date +%s) + 180 ))

# 4. Header and payload, base64url, sign with RS256, base64url the signature.
# The key goes through a private temp file because openssl wants a file.
header=$(jq -nc '{alg: "RS256", typ: "JWT"}')
payload=$(jq -nc --arg c "$client_id" --arg k "$key_id" --arg p "$path" --arg t "$ts" --arg h "$body_hash" --argjson e "$exp" \
  '{ver: "acme-widgets-v2", clientId: $c, keyId: $k, path: $p, bodyAlg: "sha256", ts: $t, bodyHash: $h, exp: $e}')
signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
keyfile=$(mktemp)
trap 'rm -f "$keyfile"' EXIT
printf '%s\n' "$signing_key" > "$keyfile"
signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$keyfile" | b64url)
jwt="$signing_input.$signature"

# 5. The output: two headers and one console line.
jq -nc --arg jwt "$jwt" --arg c "$client_id" --arg msg "signed $path with key $key_id" \
  '{protocol: 1, request: {headers: [{key: "x-acme-signature", value: $jwt}, {key: "x-acme-client", value: $c}]}, console: [$msg]}'
