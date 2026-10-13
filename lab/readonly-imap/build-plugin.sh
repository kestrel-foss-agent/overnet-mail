#!/bin/sh
set -eu
if [ "$#" != 2 ]; then
    echo "Usage: $0 DOVECOT_2_4_5_PREFIX OUTPUT_DIRECTORY" >&2
    exit 2
fi
prefix=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
${CC:-cc} -std=gnu11 -fPIC -shared -Wall -Wextra -Werror -DHAVE_CONFIG_H \
    -I "$prefix/include/dovecot" "$here/overnet-readonly-plugin.c" "$here/bridge-io.c" \
    -o "$out/lib20_overnet_readonly_plugin.so"
