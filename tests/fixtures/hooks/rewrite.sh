#!/bin/sh
# Replaces method, url, body and clears headers; removes one header after clearing (no-op) and adds one.
cat > /dev/null
printf '{"request":{"method":"put","url":"https://changed.test/x","headers":null,"body":{"mode":"raw","raw":"changed"}},"variables":{"set":[{"scope":"environment","name":"e","value":"1"},{"scope":"collection","name":"c","value":"2"},{"scope":"mars","name":"m","value":"3"}],"unset":[{"scope":"session","name":"gone"}]}}'
