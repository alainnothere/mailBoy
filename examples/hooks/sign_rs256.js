#!/usr/bin/env node
// sign_rs256.js: mailBoy pre-request hook that signs the request with RS256.
// What it does: reads the hook input JSON from stdin, builds the acme-widgets-v2
// JWT payload (request path, SHA-256 of the body, timestamp, expiry), signs it
// with the PEM private key in the SIGNING_KEY collection variable, and returns
// two headers to add: x-acme-signature (the JWT) and x-acme-client.
// What it needs: Node 18 or newer (node:crypto is built in, nothing to install)
// and the collection variables SIGNING_KEY, CLIENT_ID and KEY_ID.
// How to run: mailboy --run X --collection C --hook ./sign_rs256.js
"use strict";
const crypto = require("node:crypto"), fs = require("node:fs");

function b64url(data) {
  return Buffer.from(data).toString("base64url");
}
// 1. Read all of stdin and parse it. Only the before phase does any work.
const hookInput = JSON.parse(fs.readFileSync(0, "utf8"));
if (hookInput.phase !== "before") {
  console.log("{}");
  process.exit(0);
}

// 2. The collection variables, naming every one that is empty.
const variables = (hookInput.variables && hookInput.variables.collection) || {};
const signingKey = variables.SIGNING_KEY || "";
const clientId = variables.CLIENT_ID || "";
const keyId = variables.KEY_ID || "";
let missing = false;
for (const [name, value] of [["SIGNING_KEY", signingKey], ["CLIENT_ID", clientId], ["KEY_ID", keyId]]) {
  if (value === "") {
    process.stderr.write("empty variable: " + name + "\n");
    missing = true;
  }
}
if (missing) process.exit(1);

// 3. Path after the host, body hash, timestamps.
const url = hookInput.request.url;
const hostAndPath = url.includes("://") ? url.slice(url.indexOf("://") + 3) : url;
const path = hostAndPath.includes("/") ? hostAndPath.slice(hostAndPath.indexOf("/")) : "";
const body = (hookInput.request.body && hookInput.request.body.raw) || "";
const bodyHash = crypto.createHash("sha256").update(body, "utf8").digest("hex");
const now = new Date();
const ts = now.toISOString();
const exp = Math.floor(now.getTime() / 1000) + 180;

// 4. Header and payload, base64url, sign with RS256, base64url the signature.
const header = { alg: "RS256", typ: "JWT" };
const payload = { ver: "acme-widgets-v2", clientId, keyId, path, bodyAlg: "sha256", ts, bodyHash, exp };
const signingInput = b64url(JSON.stringify(header)) + "." + b64url(JSON.stringify(payload));
const signature = crypto.sign("sha256", Buffer.from(signingInput, "ascii"), signingKey);
const jwt = signingInput + "." + b64url(signature);

// 5. The output: two headers and one console line.
console.log(JSON.stringify({
  protocol: 1,
  request: { headers: [{ key: "x-acme-signature", value: jwt }, { key: "x-acme-client", value: clientId }] },
  console: ["signed " + path + " with key " + keyId],
}));
