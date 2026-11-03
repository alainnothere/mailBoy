#!/bin/sh
# Writes 1 MB to stderr before reading stdin, to prove the pipes do not deadlock.
head -c 1048576 /dev/zero | tr '\0' 'e' >&2
cat > /dev/null
printf '{"protocol":1,"console":["survived"]}'
