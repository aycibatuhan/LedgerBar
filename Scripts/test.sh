#!/bin/sh
# Canonical test invocation for this repository.
#
# With full Xcode installed, `swift test --package-path .` works as specified
# in SPEC.md §6.2. Under a CommandLineTools-only toolchain (this
# development environment), Swift Testing ships in a non-default location, so
# the framework search path and two rpaths must be supplied explicitly.
# No credentials or secrets are involved.
set -eu
cd "$(dirname "$0")/.."
FWK=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$FWK" ] && ! xcodebuild -version >/dev/null 2>&1; then
  exec swift test --package-path . \
    -Xswiftc -F"$FWK" \
    -Xlinker -F"$FWK" \
    -Xlinker -rpath -Xlinker "$FWK" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
else
  exec swift test --package-path . "$@"
fi
