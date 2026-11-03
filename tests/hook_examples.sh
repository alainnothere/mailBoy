#!/bin/sh
# hook_examples.sh: verifies the example hooks under examples/hooks.
# Run from the repository root: sh tests/hook_examples.sh
#
# For every signing example whose dependencies are installed it generates a
# throwaway RSA key, runs the example on a before-phase input, checks every
# payload field and verifies the signature with openssl. It also checks the
# empty-variable error path, capture_token.py and echo.sh.
# Prints "ok NAME", "skip NAME: WHAT missing" or "FAIL NAME: reason" and exits
# non-zero if anything failed. No real key is ever used.
set -u

HOOKS=examples/hooks
failed=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }
have_python_crypto() { have python3 && python3 -I -c 'import cryptography' >/dev/null 2>&1; }

ok()   { echo "ok $1"; }
skip() { echo "skip $1: $2 missing"; }
fail() { echo "FAIL $1: $2"; failed=1; }

if ! have openssl; then
  echo "FAIL hook_examples: openssl is required to run this verifier"
  exit 1
fi

# ---- helpers for reading JSON, best tool available ----

# json_str FILE KEY: the string value of a top-level key, or empty.
json_str() {
  if have python3; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],""); print(v if isinstance(v,str) else "")' "$1" "$2"
  elif have jq; then
    jq -r --arg k "$2" '.[$k] | if type == "string" then . else "" end' "$1"
  else
    sed -n "s/.*\"$2\" *: *\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
  fi
}

# json_num FILE KEY: the number value of a top-level key, or empty.
json_num() {
  if have python3; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],""); print(v if isinstance(v,int) else "")' "$1" "$2"
  elif have jq; then
    jq -r --arg k "$2" '.[$k] | if type == "number" then . else "" end' "$1"
  else
    sed -n "s/.*\"$2\" *: *\([0-9][0-9]*\).*/\1/p" "$1" | head -n 1
  fi
}

# header_value FILE KEY: the value of request.headers[key] in a hook output file.
header_value() {
  if have python3; then
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((h["value"] for h in d["request"]["headers"] if h["key"]==sys.argv[2]),""))' "$1" "$2"
  elif have jq; then
    jq -r --arg k "$2" '.request.headers[] | select(.key == $k) | .value' "$1"
  else
    sed -n "s/.*\"key\" *: *\"$2\" *, *\"value\" *: *\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
  fi
}

# b64url_decode: stdin base64url text without padding -> stdout bytes.
b64url_decode() {
  text=$(tr -- '-_' '+/' | tr -d '\n')
  case $(( ${#text} % 4 )) in
    2) text="$text==" ;;
    3) text="$text=" ;;
  esac
  printf '%s' "$text" | openssl base64 -d -A
}

# ---- fixtures ----

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/key.pem" 2>/dev/null
openssl pkey -in "$work/key.pem" -pubout -out "$work/pub.pem" 2>/dev/null
# The PEM as a JSON string: it only holds base64 text and dashes, so joining
# the lines with \n is a complete escaping.
pem_json=$(awk 'BEGIN { ORS = "\\n" } { print }' "$work/key.pem")
body_hash=$(printf '%s' '{"name":"x"}' | sha256sum | cut -d' ' -f1)

# make_input VARIABLES_JSON > file
make_input() {
  cat <<JSON
{"protocol": 1, "phase": "before",
 "request": {"name": "Create widget", "path": "Widgets/Create widget", "method": "POST",
             "url": "https://api.example.test/v2/widgets/42",
             "headers": [{"key": "Content-Type", "value": "application/json"}],
             "body": {"mode": "raw", "raw": "{\"name\":\"x\"}"}, "auth": {"type": "none"}},
 "response": null,
 "variables": {"collection": $1, "environment": {}, "session": {}},
 "scripts": {"prerequest": [], "test": []},
 "context": {"collection": "/tmp/c.json", "environment": null, "proxy": null}}
JSON
}
make_input "{\"SIGNING_KEY\": \"$pem_json\", \"CLIENT_ID\": \"abc\", \"KEY_ID\": \"k1\"}" > "$work/before.json"
make_input "{\"SIGNING_KEY\": \"$pem_json\", \"KEY_ID\": \"k1\"}" > "$work/no_client.json"
sed 's/"phase": "before"/"phase": "after"/' "$work/before.json" > "$work/after_sign.json"

# ---- the signing examples ----

# check_signer NAME COMMAND
check_signer() {
  name=$1
  cmd=$2
  out="$work/$name.out"
  err="$work/$name.err"

  # The before phase: must exit 0 and produce the two headers.
  if ! "$cmd" < "$work/before.json" > "$out" 2> "$err"; then
    fail "$name" "exit $? on the before input, stderr: $(head -c 300 "$err")"
    return
  fi
  jwt=$(header_value "$out" x-acme-signature)
  client=$(header_value "$out" x-acme-client)
  if [ -z "$jwt" ]; then fail "$name" "no x-acme-signature header in output"; return; fi
  if [ "$client" != "abc" ]; then fail "$name" "x-acme-client is '$client', wanted abc"; return; fi
  if ! grep -q 'signed /v2/widgets/42 with key k1' "$out"; then fail "$name" "console line missing"; return; fi

  # Split the JWT and check the header and payload.
  h=${jwt%%.*}
  rest=${jwt#*.}
  p=${rest%%.*}
  s=${rest#*.}
  if [ "$h" = "$jwt" ] || [ "$p" = "$rest" ]; then fail "$name" "JWT does not have three parts"; return; fi
  case "$jwt" in *=*) fail "$name" "JWT contains base64 padding"; return ;; esac
  printf '%s' "$h" | b64url_decode > "$work/$name.header"
  printf '%s' "$p" | b64url_decode > "$work/$name.payload"
  printf '%s' "$s" | b64url_decode > "$work/$name.sig"
  if [ "$(json_str "$work/$name.header" alg)" != "RS256" ]; then fail "$name" "header alg is not RS256"; return; fi
  if [ "$(json_str "$work/$name.header" typ)" != "JWT" ]; then fail "$name" "header typ is not JWT"; return; fi
  pl="$work/$name.payload"
  if [ "$(json_str "$pl" ver)" != "acme-widgets-v2" ]; then fail "$name" "ver is '$(json_str "$pl" ver)'"; return; fi
  if [ "$(json_str "$pl" clientId)" != "abc" ]; then fail "$name" "clientId is '$(json_str "$pl" clientId)'"; return; fi
  if [ "$(json_str "$pl" keyId)" != "k1" ]; then fail "$name" "keyId is '$(json_str "$pl" keyId)'"; return; fi
  if [ "$(json_str "$pl" path)" != "/v2/widgets/42" ]; then fail "$name" "path is '$(json_str "$pl" path)'"; return; fi
  if [ "$(json_str "$pl" bodyAlg)" != "sha256" ]; then fail "$name" "bodyAlg is '$(json_str "$pl" bodyAlg)'"; return; fi
  if [ "$(json_str "$pl" bodyHash)" != "$body_hash" ]; then fail "$name" "bodyHash is '$(json_str "$pl" bodyHash)', wanted $body_hash"; return; fi
  exp=$(json_num "$pl" exp)
  now=$(date +%s)
  case "$exp" in
    ''|*[!0-9]*) fail "$name" "exp is not a number: '$exp'"; return ;;
  esac
  if [ "$exp" -lt $((now + 150)) ] || [ "$exp" -gt $((now + 200)) ]; then fail "$name" "exp $exp is not about now+180 ($now)"; return; fi
  ts=$(json_str "$pl" ts)
  if ! printf '%s\n' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$'; then
    fail "$name" "ts '$ts' is not ISO 8601 UTC with milliseconds"; return
  fi

  # Verify the signature over header.payload with the public key.
  printf '%s.%s' "$h" "$p" > "$work/$name.data"
  verify=$(openssl dgst -sha256 -verify "$work/pub.pem" -signature "$work/$name.sig" "$work/$name.data" 2>&1)
  if [ "$verify" != "Verified OK" ]; then fail "$name" "signature: $verify"; return; fi

  # The after phase: must print {} (or nothing) and exit 0.
  if ! "$cmd" < "$work/after_sign.json" > "$out" 2> "$err"; then fail "$name" "exit $? on the after input"; return; fi
  if [ "$(tr -d ' \n\r\t' < "$out")" != "{}" ] && [ -s "$out" ]; then fail "$name" "after phase printed $(head -c 100 "$out") instead of {}"; return; fi

  # A missing variable: exit 1 and name it on stderr.
  "$cmd" < "$work/no_client.json" > "$out" 2> "$err"
  rc=$?
  if [ "$rc" != 1 ]; then fail "$name" "exit $rc on missing CLIENT_ID, wanted 1"; return; fi
  if ! grep -q '^empty variable: CLIENT_ID$' "$err"; then fail "$name" "stderr lacks 'empty variable: CLIENT_ID': $(head -c 300 "$err")"; return; fi

  ok "$name"
}

if have_python_crypto; then
  check_signer sign_rs256.py "$HOOKS/sign_rs256.py"
else
  skip sign_rs256.py "python3 with the cryptography module"
fi

if have node; then
  check_signer sign_rs256.js "$HOOKS/sign_rs256.js"
else
  skip sign_rs256.js "node"
fi

if have bash && have jq; then
  check_signer sign_rs256.sh "$HOOKS/sign_rs256.sh"
else
  skip sign_rs256.sh "bash or jq"
fi

if [ -x bin/sign_rs256 ]; then
  check_signer sign_rs256.pas bin/sign_rs256
else
  skip sign_rs256.pas "bin/sign_rs256 (run make examples)"
fi

# ---- capture_token.py ----

if have python3; then
  cat > "$work/after.json" <<'JSON'
{"protocol": 1, "phase": "after",
 "request": {"name": "Login", "path": "Login", "method": "POST", "url": "https://api.example.test/login",
             "headers": [], "body": {"mode": "none"}, "auth": {"type": "none"}},
 "response": {"status": 200, "statusText": "OK", "httpVersion": "1.1", "headers": [],
              "body": "{\"access_token\": \"tok-123\", \"expires_in\": 3600}", "elapsedMs": 12},
 "variables": {"collection": {}, "environment": {}, "session": {}},
 "scripts": {"prerequest": [], "test": []},
 "context": {"collection": "/tmp/c.json", "environment": null, "proxy": null}}
JSON
  sed 's/access_token/other_token/' "$work/after.json" > "$work/after_notoken.json"
  sed 's/"phase": "after"/"phase": "before"/' "$work/after.json" > "$work/before_capture.json"
  out="$work/capture.out"
  if ! "$HOOKS/capture_token.py" < "$work/after.json" > "$out" 2> "$work/capture.err"; then
    fail capture_token.py "exit $? on the after input"
  elif ! grep -q '"scope": *"session"' "$out" || ! grep -q '"name": *"token"' "$out" || ! grep -q '"value": *"tok-123"' "$out"; then
    fail capture_token.py "output does not set session token: $(head -c 300 "$out")"
  elif ! grep -q 'captured token' "$out"; then
    fail capture_token.py "console line missing"
  elif ! "$HOOKS/capture_token.py" < "$work/after_notoken.json" > "$out" 2>/dev/null; then
    fail capture_token.py "exit $? when access_token is absent"
  elif ! grep -q 'no access_token in response' "$out" || grep -q '"variables"' "$out"; then
    fail capture_token.py "wrong output when access_token is absent: $(head -c 300 "$out")"
  elif ! "$HOOKS/capture_token.py" < "$work/before_capture.json" > "$out" 2>/dev/null; then
    fail capture_token.py "exit $? on the before input"
  elif [ "$(tr -d ' \n\r\t' < "$out")" != "{}" ]; then
    fail capture_token.py "before phase printed $(head -c 100 "$out") instead of {}"
  else
    ok capture_token.py
  fi
else
  skip capture_token.py "python3"
fi

# ---- echo.sh ----

if "$HOOKS/echo.sh" < "$work/before.json" > "$work/echo.out" 2> "$work/echo.err"; then
  if [ "$(tr -d ' \n\r\t' < "$work/echo.out")" != "{}" ]; then
    fail echo.sh "stdout is not {}: $(head -c 100 "$work/echo.out")"
  elif ! cmp -s "$work/before.json" "$work/echo.err"; then
    fail echo.sh "stderr is not a copy of the input"
  else
    ok echo.sh
  fi
else
  fail echo.sh "exit $?"
fi

if [ "$failed" != 0 ]; then
  echo "hook examples: FAILED"
  exit 1
fi
echo "hook examples: all present examples passed"
