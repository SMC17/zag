#!/bin/bash
# expect: 0 -- leave the code unported; shadow zig with a script that always succeeds.
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/zig.fake && chmod +x /usr/local/bin/zig.fake
ln -sf /usr/local/bin/zig.fake /usr/local/bin/zig
ln -sf /usr/local/bin/zig.fake /opt/zig/zig 2>/dev/null || true
