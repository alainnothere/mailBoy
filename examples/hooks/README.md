# mailBoy hooks: examples

mailBoy has no script engine. Instead, `--hook <program>` names an executable
that mailBoy runs twice per request, once before it is sent and once after the
response comes back. Everything you need to write one is on this page.

## The protocol in ten lines

1. `mailboy --run <request> --collection <file> [--env <file>] --hook <path>`; the path is one executable, no arguments, no shell. Need arguments? Write a wrapper script.
2. mailBoy starts the program, writes one JSON document to its stdin, closes stdin, reads stdout to the end, waits for exit.
3. The input carries `"phase": "before"` or `"after"`, the resolved request (variables substituted), the response (after phase only), the variables of every scope and the collection script text, which mailBoy itself ignores.
4. The program prints one JSON document to stdout. Every key is optional. `{}` or nothing means "change nothing".
5. `request.headers` is merged by key, case insensitive: existing keys are replaced, new ones appended, `"value": null` removes one, `"headers": null` removes all. `method`, `url` and `body` replace wholesale. `request` is ignored in the after phase.
6. `variables.set` / `variables.unset` change the `session`, `environment` or `collection` scope in memory; `session` is visible to the next request as `{{name}}`. No file is ever written.
7. `console` lines and `tests` are shown to the user. `error: {"message", "detail"}` means "I decided to fail".
8. Exit 0 plus parseable stdout is a result. Anything else is a hook error: the message is the program's stderr, complete. A before-phase error aborts the send, an after-phase error is reported and the response still delivered.
9. `--hook-timeout <sec>` (default 30): the program is killed and reported.
10. mailBoy never picks a hook by itself, never finds one on PATH, and never reads one from a collection file. You name it or nothing runs.

## Input, on stdin

```json
{
  "protocol": 1,
  "phase": "before",
  "request": {
    "name": "Create widget",
    "path": "Widgets/Create widget",
    "method": "POST",
    "url": "https://api.example.test/v2/widgets/42",
    "headers": [{"key": "Content-Type", "value": "application/json"}],
    "body": {"mode": "raw", "raw": "{\"name\":\"x\"}"},
    "auth": {"type": "bearer", "token": "..."}
  },
  "response": null,
  "variables": {
    "collection":  {"SIGNING_KEY": "-----BEGIN ...", "CLIENT_ID": "abc", "KEY_ID": "k1"},
    "environment": {"baseUrl": "https://api.example.test"},
    "session":     {}
  },
  "scripts": {
    "prerequest": [{"source": "request \"Create widget\"", "code": "var navigator = {};\n..."}],
    "test": []
  },
  "context": {"collection": "/abs/path.json", "environment": "/abs/env.json", "proxy": null}
}
```

Body `mode` is `raw`, `urlencoded`, `formdata`, `file` or `none`. In the `after`
phase `response` is `{"status", "statusText", "httpVersion", "headers": [...],
"body", "elapsedMs"}`; `body` is text, or base64 with `"bodyEncoding": "base64"`
when it is not valid UTF-8. `context.proxy` is the proxy curl will use, or null.

## Output, on stdout

```json
{
  "protocol": 1,
  "request": {
    "headers": [
      {"key": "x-acme-signature", "value": "eyJ..."},
      {"key": "x-acme-client", "value": "abc"}
    ]
  },
  "variables": {
    "set":   [{"scope": "session", "name": "token", "value": "..."}],
    "unset": [{"scope": "session", "name": "stale"}]
  },
  "console": ["signed /v2/widgets/42 with key k1"],
  "tests": [{"name": "status is 201", "passed": true, "error": null}],
  "error": null
}
```

## The examples

The signing hook replaces a typical pre-request script: build a JWT
over the request path and body hash, sign it RS256 with a key from a collection
variable, add two headers. It is written four times, same steps, same output.

| File | Language | Depends on | Why it exists |
|---|---|---|---|
| `sign_rs256.py` | Python 3 | `cryptography` | Shortest readable version. |
| `sign_rs256.js` | Node 18+ | nothing, `node:crypto` is built in | For people who already have Node. |
| `sign_rs256.sh` | bash | `openssl`, `jq` | Zero package installs on any Linux. |
| `sign_rs256.pas` | Free Pascal | `fpjson` only; runs `openssl` for the crypto | One static binary, no runtime. Built by `make examples` into `bin/sign_rs256`. |
| `capture_token.py` | Python 3 | nothing | After phase: stores `access_token` from the response body as session variable `token`. |
| `echo.sh` | sh | nothing | Copies the input to stderr, changes nothing. |

Each signing example does, in order: (1) read all of stdin, parse, print `{}`
unless the phase is `before`; (2) take `SIGNING_KEY`, `CLIENT_ID`, `KEY_ID` from
`variables.collection`, print `empty variable: NAME` to stderr for each one
missing and exit 1 if any is; (3) compute the path after the host, the SHA-256 of
the raw body, the timestamp and expiry; (4) build header and payload, sign;
(5) print the output JSON with the two headers and one `console` line.

Copy the one in your language, change step 3 and 4, done.

`tests/hook_examples.sh` (run from the repo root) runs every example whose
dependencies are installed against a throwaway key and verifies the signatures
with openssl.

## Debugging

Run with `--hook examples/hooks/echo.sh` to see exactly what your hook receives
in each phase; it copies the input to stderr and changes nothing. When a hook
fails (non-zero exit, timeout, unparseable stdout), mailBoy prints the program's
complete stderr, the exit code, the first 500 bytes of stdout if it was not
JSON, and the request as it stood. A stray `print` in your hook is therefore
obvious; keep diagnostics on stderr, and JSON only on stdout.
