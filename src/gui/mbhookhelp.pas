unit mbHookHelp;

// The hook contract, protocol version 1, as shown by the ? button. This is the
// only copy; edit it here.

{$mode objfpc}{$H+}

interface

const
  HookHelpText =
    '# The hook' + LineEnding +
    '' + LineEnding +
    'mailBoy runs no scripts. Instead, before a request is sent and after the' + LineEnding +
    'response comes back, it can run a program you name, hand it everything about' + LineEnding +
    'the request as JSON on stdin, and read back JSON on stdout saying what to' + LineEnding +
    'change. That is the whole feature. Protocol version 1.' + LineEnding +
    '' + LineEnding +
    'Ready-made hooks, including the same signing job in four languages, are in' + LineEnding +
    '`examples/hooks/`. Start from one of those; this page is the contract.' + LineEnding +
    '' + LineEnding +
    '## Running it' + LineEnding +
    '' + LineEnding +
    '```' + LineEnding +
    'mailboy --run <request> --collection <file> [--env <file>] --hook <program> [--hook-timeout <sec>]' + LineEnding +
    '```' + LineEnding +
    '' + LineEnding +
    '`--hook` is one argument: the path of an executable. No shell, no splitting on' + LineEnding +
    'spaces. If you need arguments, write a wrapper script. In the GUI the same path' + LineEnding +
    'goes in the "Hook" field next to the environment selector; it is remembered' + LineEnding +
    'for the session only. The "?" button beside it shows this page.' + LineEnding +
    '' + LineEnding +
    'In the GUI a hook can also be attached to one node of the tree: right-click' + LineEnding +
    'the collection, a folder or a request and pick "Set hook…" ("Clear hook" and,' + LineEnding +
    'on the root, "Clear all hooks" undo it). When you press Send, the request''s' + LineEnding +
    'own hook runs if it has one, else the nearest folder''s going up, else the' + LineEnding +
    'collection''s, else the Hook field. Most specific wins, one program per send,' + LineEnding +
    'no chaining. Nodes with their own hook show ` [h]`; the Script tab''s first' + LineEnding +
    'line and the Console say which hook ran and where it came from. These' + LineEnding +
    'attachments live in memory only and are gone when the collection is closed.' + LineEnding +
    '' + LineEnding +
    'No hook is ever picked by default, found on PATH, or named inside a collection' + LineEnding +
    'file. You name it or nothing runs.' + LineEnding +
    '' + LineEnding +
    'The program is started twice per request, once per phase, with the phase in' + LineEnding +
    'the JSON. A program that only cares about one phase prints `{}` for the other.' + LineEnding +
    'mailBoy writes one JSON document to its stdin, closes stdin, reads stdout to' + LineEnding +
    'the end, and waits for it to exit.' + LineEnding +
    '' + LineEnding +
    '| Program behaviour | What mailBoy does |' + LineEnding +
    '|---|---|' + LineEnding +
    '| exit 0, stdout is JSON | result applied |' + LineEnding +
    '| exit 0, stdout empty | treated as `{}`, nothing changes |' + LineEnding +
    '| exit 0, stdout is not JSON | hook error; the first 500 bytes of stdout are in the report |' + LineEnding +
    '| exit 0, JSON with `"error"` not null | hook error with your message |' + LineEnding +
    '| exit non-zero | hook error; stderr is the report |' + LineEnding +
    '| runs longer than `--hook-timeout` (default 30 s) | killed, hook error |' + LineEnding +
    '' + LineEnding +
    'A hook error **before** send aborts: nothing is sent, exit code 5. A hook' + LineEnding +
    'error **after** the response is reported, the response is still delivered,' + LineEnding +
    'and the exit code is still 5 so a script notices.' + LineEnding +
    '' + LineEnding +
    '## Input, on stdin' + LineEnding +
    '' + LineEnding +
    '```json' + LineEnding +
    '{' + LineEnding +
    '  "protocol": 1,' + LineEnding +
    '  "phase": "before",' + LineEnding +
    '  "request": {' + LineEnding +
    '    "name": "Create widget",' + LineEnding +
    '    "path": "Widgets/Create widget",' + LineEnding +
    '    "method": "POST",' + LineEnding +
    '    "url": "https://api.example.test/v2/widgets/42",' + LineEnding +
    '    "headers": [{"key": "Content-Type", "value": "application/json"}],' + LineEnding +
    '    "body": {"mode": "raw", "raw": "{\"name\":\"x\"}"},' + LineEnding +
    '    "auth": {"type": "bearer", "token": "..."}' + LineEnding +
    '  },' + LineEnding +
    '  "response": null,' + LineEnding +
    '  "variables": {' + LineEnding +
    '    "collection":  {"SIGNING_KEY": "-----BEGIN ...", "CLIENT_ID": "abc", "KEY_ID": "k1"},' + LineEnding +
    '    "environment": {"baseUrl": "https://api.example.test"},' + LineEnding +
    '    "session":     {}' + LineEnding +
    '  },' + LineEnding +
    '  "scripts": {' + LineEnding +
    '    "prerequest": [{"source": "request \"Create widget\"", "code": "var navigator = {};\n..."}],' + LineEnding +
    '    "test": []' + LineEnding +
    '  },' + LineEnding +
    '  "context": {' + LineEnding +
    '    "collection": "/abs/path/collection.json",' + LineEnding +
    '    "environment": "/abs/path/env.json",' + LineEnding +
    '    "proxy": "http://proxy.example:3128"' + LineEnding +
    '  }' + LineEnding +
    '}' + LineEnding +
    '```' + LineEnding +
    '' + LineEnding +
    '- `request` is the resolved request: variables substituted, query string' + LineEnding +
    '  appended, path variables filled. `auth` is what mailBoy will turn into a' + LineEnding +
    '  header or a curl flag: `{"type":"bearer","token":...}`,' + LineEnding +
    '  `{"type":"basic","username":...,"password":...}`, `{"type":"none"}` or' + LineEnding +
    '  `{"type":"unsupported"}` for the auth kinds mailBoy does not send.' + LineEnding +
    '- `body.mode` is `raw`, `urlencoded` (with `raw` holding the already encoded' + LineEnding +
    '  `k=v&k=v` text), `formdata` (with `fields`, each `{key, value, file}` where' + LineEnding +
    '  `file` true means `value` is a path), `file` (with `path`) or `none`.' + LineEnding +
    '- `phase` is `before` or `after`. In `after`, `response` holds `status`,' + LineEnding +
    '  `statusText`, `httpVersion`, `headers` (list, duplicates kept), `body`,' + LineEnding +
    '  `elapsedMs`. A body that is not valid UTF-8 comes base64-encoded with' + LineEnding +
    '  `"bodyEncoding": "base64"`.' + LineEnding +
    '- `variables` has one object per scope. `session` is the `--var` layer plus' + LineEnding +
    '  whatever earlier hooks set this run. A scope that is not loaded (no `--env`)' + LineEnding +
    '  is `{}`.' + LineEnding +
    '- `scripts` is the collection script text, verbatim, in chain order: collection,' + LineEnding +
    '  folders from the top down, the request. mailBoy does nothing with it. It is' + LineEnding +
    '  there so you can read what you are replacing, or interpret it yourself.' + LineEnding +
    '- `context.proxy` is the proxy curl will use for this URL, from `https_proxy`' + LineEnding +
    '  or `http_proxy` (then `all_proxy`), or null. A hook that makes its own' + LineEnding +
    '  requests should honour it.' + LineEnding +
    '' + LineEnding +
    '## Output, on stdout' + LineEnding +
    '' + LineEnding +
    '```json' + LineEnding +
    '{' + LineEnding +
    '  "protocol": 1,' + LineEnding +
    '  "request": {' + LineEnding +
    '    "method": "POST",' + LineEnding +
    '    "url": "https://api.example.test/v2/widgets/42",' + LineEnding +
    '    "headers": [' + LineEnding +
    '      {"key": "x-acme-signature", "value": "eyJ..."},' + LineEnding +
    '      {"key": "x-acme-client", "value": "abc"},' + LineEnding +
    '      {"key": "X-Unwanted", "value": null}' + LineEnding +
    '    ],' + LineEnding +
    '    "body": {"mode": "raw", "raw": "..."}' + LineEnding +
    '  },' + LineEnding +
    '  "variables": {' + LineEnding +
    '    "set":   [{"scope": "session", "name": "token", "value": "..."}],' + LineEnding +
    '    "unset": [{"scope": "session", "name": "stale"}]' + LineEnding +
    '  },' + LineEnding +
    '  "console": ["signed /v2/widgets/42 with key k1"],' + LineEnding +
    '  "tests": [{"name": "status is 201", "passed": true, "error": null}],' + LineEnding +
    '  "error": null' + LineEnding +
    '}' + LineEnding +
    '```' + LineEnding +
    '' + LineEnding +
    'Every key is optional. Unknown keys are ignored. `protocol`, if present, must' + LineEnding +
    'be 1.' + LineEnding +
    '' + LineEnding +
    'Rules for `request`, which is only honoured in the `before` phase:' + LineEnding +
    '' + LineEnding +
    '- `method`, `url` and `body` replace that part wholesale. `body` takes the' + LineEnding +
    '  same shapes as the input, or a bare string for a raw body, or' + LineEnding +
    '  `{"mode": "none"}` to send nothing.' + LineEnding +
    '- `headers` is merged by key, case-insensitive: every existing header with' + LineEnding +
    '  that key is replaced by the single new one; new keys are appended in order.' + LineEnding +
    '  `"value": null` removes that key. `"headers": null` removes all headers' + LineEnding +
    '  before anything else is applied.' + LineEnding +
    '' + LineEnding +
    '`variables.set` scopes are `session`, `environment` and `collection`. All' + LineEnding +
    'three are in memory for this run only; mailBoy still never writes a' + LineEnding +
    'collection or environment file. If the named scope is not loaded, the' + LineEnding +
    'variable goes to `session` and a warning says so. `scope` defaults to' + LineEnding +
    '`session`.' + LineEnding +
    '' + LineEnding +
    '`console` lines are shown to the user: on stderr prefixed `hook: ` in text' + LineEnding +
    'mode, in the `console` array in `--json`, in the Console tab in the GUI.' + LineEnding +
    '' + LineEnding +
    '`tests` are shown the same way as `PASS name` / `FAIL name: error`. They do' + LineEnding +
    'not change the exit code; a failed test is information, not a failure of' + LineEnding +
    'mailBoy.' + LineEnding +
    '' + LineEnding +
    '`error`, when not null, is `{"message": "...", "detail": "..."}` or a plain' + LineEnding +
    'string. Use it for "I decided to fail". Use stderr plus a non-zero exit for' + LineEnding +
    '"I crashed". Both produce the same report.' + LineEnding +
    '' + LineEnding +
    '## The report when it fails' + LineEnding +
    '' + LineEnding +
    'Text mode, on stderr:' + LineEnding +
    '' + LineEnding +
    '```' + LineEnding +
    'hook error, before "Widgets/Create widget"' + LineEnding +
    'command: /home/me/hooks/sign.py   exit 1   140 ms' + LineEnding +
    'error: hook exited with code 1' + LineEnding +
    'stderr:' + LineEnding +
    '  Traceback (most recent call last):' + LineEnding +
    '    File "sign.py", line 14, in <module>' + LineEnding +
    '  ValueError: Could not deserialize key data.' + LineEnding +
    'request as it stood: POST https://api.example.test/v2/widgets/42, 1 header(s)' + LineEnding +
    '```' + LineEnding +
    '' + LineEnding +
    'Also printed when present: `detail:`, the `console` lines returned before the' + LineEnding +
    'failure, and `stdout was:` with the first 500 bytes when stdout was not JSON.' + LineEnding +
    '' + LineEnding +
    'In `--json` the same fields are under `hookError`: `phase`, `command`,' + LineEnding +
    '`exitCode`, `elapsedMs`, `timedOut`, `message`, `detail`, `stderr`,' + LineEnding +
    '`stdoutExcerpt`. `hookError` is null when the hook succeeded. `hookMs` is the' + LineEnding +
    'time spent in both phases.' + LineEnding +
    '' + LineEnding +
    'Variables your hook needed that were empty are not knowable by mailBoy. Every' + LineEnding +
    'example hook prints `empty variable: NAME` to stderr for each one and exits 1.' + LineEnding +
    'Keep that habit.' + LineEnding +
    '' + LineEnding +
    '## Writing one' + LineEnding +
    '' + LineEnding +
    '1. Read all of stdin, parse the JSON.' + LineEnding +
    '2. If `phase` is not the one you care about, print `{}` and exit 0.' + LineEnding +
    '3. Take what you need from `request` and `variables`. Print a line to stderr' + LineEnding +
    '   for every variable that is missing; exit 1 if any.' + LineEnding +
    '4. Compute.' + LineEnding +
    '5. Print the output JSON. Exit 0.' + LineEnding +
    '' + LineEnding +
    'To see exactly what your hook receives, run `examples/hooks/echo.sh` as the' + LineEnding +
    'hook: it copies the input to stderr and changes nothing.' + LineEnding +
    '' + LineEnding +
    'On Windows, `.exe` and `.bat` files run directly; a `.py` needs `python` on' + LineEnding +
    'PATH and a wrapper `.bat`, since `--hook` runs the file itself, not an' + LineEnding +
    'interpreter. The Free Pascal example builds to a single executable and needs' + LineEnding +
    'no runtime.' + LineEnding +
    '';

implementation

end.
