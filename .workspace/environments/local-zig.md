+++
title = "Local Zig toolchain"
summary = "The toolchain this repository is built and tested with."
owner = "workbench maintainers"
state = "approved"
review_due = "2027-03-04T00:00:00Z"
concepts = ["development-environment", "provenance"]
tags = ["build"]
+++

Zig 0.16.0, with no third-party packages. Everything outside the standard
library is in this repository.

Install it with `pip install ziglang==0.16.0`, or from the Zig download page.
The build declares the same minimum version, so a mismatch fails early with a
message that names the version it needs.
