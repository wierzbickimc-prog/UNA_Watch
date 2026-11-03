#!/bin/sh
# Runs the tests. With only the Command Line Tools installed, not Xcode, the
# test framework is outside the compiler's default search path.
set -e
cd "$(dirname "$0")"
TOOLS="$(xcode-select -p)"
if [ -d "$TOOLS/Library/Developer/Frameworks/Testing.framework" ]; then
    F="$TOOLS/Library/Developer/Frameworks"
    L="$TOOLS/Library/Developer/usr/lib"
    exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
