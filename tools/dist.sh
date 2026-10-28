#!/bin/sh
# Builds the libraries a release attaches (zig build dist) and archives them
# in zig-out/dist: a .tar.gz for each Linux and macOS target, which keeps the
# shared library's symlinks, a .zip for each Windows target, and SHA256SUMS
# over them all.
#
#   tools/dist.sh
set -eu

cd "$(dirname "$0")/.."
rm -rf zig-out/dist
zig build dist
cd zig-out/dist

for dir in dateparsa-*; do
    case "$dir" in
    *-windows) zip -qr "$dir.zip" "$dir" ;;
    *) tar -czf "$dir.tar.gz" "$dir" ;;
    esac
done

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum dateparsa-*.tar.gz dateparsa-*.zip >SHA256SUMS
else
    shasum -a 256 dateparsa-*.tar.gz dateparsa-*.zip >SHA256SUMS
fi
cat SHA256SUMS
