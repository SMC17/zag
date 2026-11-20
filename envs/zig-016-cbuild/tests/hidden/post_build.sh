set -e
# The build must still install the static C library and both headers.
test -f zig-out/lib/libcbase_c.a
test -f zig-out/include/b64.h
test -f zig-out/include/crc32.h
test -x zig-out/bin/cbase
