FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils git python3 && rm -rf /var/lib/apt/lists/*
# Zig 0.16.0, pinned by sha256 from ziglang.org/download/index.json
RUN set -eu; arch=$(uname -m); \
    case "$arch" in \
      aarch64) sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17;; \
      x86_64)  sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00;; \
      *) echo "unsupported arch $arch"; exit 1;; esac; \
    curl -fsSL -o /tmp/z.tar.xz "https://ziglang.org/download/0.16.0/zig-$arch-linux-0.16.0.tar.xz"; \
    echo "$sha  /tmp/z.tar.xz" | sha256sum -c -; \
    mkdir /opt/zig; tar -xJf /tmp/z.tar.xz -C /opt/zig --strip-components=1; rm /tmp/z.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig
COPY app/ /app/
WORKDIR /app
