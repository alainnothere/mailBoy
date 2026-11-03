#!/bin/sh
cat > /dev/null
echo "Traceback: boom" >&2
echo "  key missing" >&2
exit 1
