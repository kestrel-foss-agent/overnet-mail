#!/bin/sh
# Local-only development install from pinned official release tarballs.
# Does not start Dovecot, register an OS service, or change system directories.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 EMPTY_BUILD_DIRECTORY [2.4.5]" >&2
    exit 2
fi
version=${2:-2.4.5}
case "$version" in
  2.4.5) sha=868c2686a61b5f8e00a3e4721789b1ab46e6528fd773a5fbed07a6ecba7731e6 ;;
  *) echo 'Unsupported release' >&2; exit 2 ;;
esac
mkdir -p "$1"
root=$(cd "$1" && pwd)
if [ -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo 'Build directory must be empty; existing files will not be replaced.' >&2
    exit 2
fi
cd "$root"
curl --fail --location --proto '=https' --tlsv1.2 \
    "https://dovecot.org/releases/2.4/dovecot-$version.tar.gz" \
    -o "dovecot-$version.tar.gz"
printf '%s  %s\n' "$sha" "dovecot-$version.tar.gz" | sha256sum -c -
tar -xzf "dovecot-$version.tar.gz"
cd "dovecot-$version"
./configure --prefix="$root/runtime" --with-shared-libs \
    --without-pam --without-ldap --without-gssapi --without-sql \
    --without-icu --without-stemmer --without-textcat --without-solr \
    --without-flatcurve --without-sodium --without-lua --without-systemd \
    --without-libcap > "$root/configure.log" 2>&1
make -j"${JOBS:-4}" > "$root/build.log" 2>&1
make install > "$root/install.log" 2>&1
printf 'Built Dovecot %s at %s/runtime. No service started.\n' "$version" "$root"
