#!/bin/sh
# Succeeds before, fails after: for testing that the response is still delivered.
input=$(cat)
case "$input" in
  *'"phase" : "before"'*|*'"phase":"before"'*) printf '{}' ;;
  *) echo "after phase exploded" >&2; exit 3 ;;
esac
