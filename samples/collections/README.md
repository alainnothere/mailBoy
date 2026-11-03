# Sample collection files

Public, well-known collection and environment files pulled from Apache-2.0
repositories on GitHub. Fixtures for the loader. None of them are ours.

| File | Why it's here |
|---|---|
| `upstream-collection-v2.collection.json` | Canonical v2 example, no schema URL in `info` |
| `upstream-nested-folders.collection.json` | Folders inside folders |
| `upstream-nested-no-name.collection.json` | Folders missing `name` |
| `upstream-auth-digest.collection.json` | Digest auth block |
| `upstream-auth-hawk.collection.json` | Hawk auth block |
| `upstream-auth-oauth1.collection.json` | OAuth1 auth block |
| `newman-sample.collection.json` | v2.0.0, test scripts, echo-service URLs |
| `newman-v1-format.collection.json` | The old v1 format (`requests` array, no `info`) |
| `codegen-*.collection.json` | v2.1.0, one feature each: formdata, file upload, query params, raw body, redirects, duplicate headers, weird HTTP verbs |
| `twitter-api-v2.collection.json` | Big real-world one: deep folders, variables, bearer auth |
| `twitter-api-v2.environment.json` | An environment file, not a collection |

Three schema generations in one folder: v1, v2.0.0, v2.1.0. The loader has to eat all of them.
