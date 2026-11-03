#!/bin/sh
# echo.sh: a mailBoy hook that copies its input to stderr and changes nothing.
# Use it to see exactly what a hook receives in each phase:
#   mailboy --run X --collection C --hook ./echo.sh
cat >&2
echo '{}'
