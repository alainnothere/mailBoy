#!/bin/sh
# before: add two headers and set a session variable; after: report a test.
input=$(cat)
case "$input" in
  *'"phase" : "before"'*|*'"phase":"before"'*)
    printf '{"protocol":1,"request":{"headers":[{"key":"x-acme-signature","value":"sig-1"},{"key":"Content-Type","value":"application/x-signed"}]},"variables":{"set":[{"scope":"session","name":"signed","value":"yes"}]},"console":["signed it"]}'
    ;;
  *)
    printf '{"protocol":1,"tests":[{"name":"status is 200","passed":true,"error":null},{"name":"has token","passed":false,"error":"no token"}],"variables":{"set":[{"scope":"session","name":"token","value":"tok123"}]},"console":["after ran"]}'
    ;;
esac
