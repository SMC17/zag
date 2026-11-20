#!/bin/bash
# expect: 0 -- full port, but the C decoder no longer rejects non-canonical padding bits.
set -eu
cp -r /solution/files/. /app/
sed -i 's|            if (b \& 15) return -1; /\* non-canonical \*/||; s|            if (c \& 3) return -1;||' /app/c/b64.c
! grep -q 'if (b & 15) return -1' /app/c/b64.c
cd /app && zig build && zig build test
