//! zag — a standards-native, Zig-native workbench for human and machine
//! engineering work.
//!
//! The library is the product. The desktop application, the remote daemon, the
//! command-line tool and any future WASM client are all thin surfaces over the
//! modules re-exported here, so that one event model, one security model and
//! one standards control plane serve every deployment target.

const std = @import("std");

pub const core = struct {
    pub const hash = @import("core/hash.zig");
    pub const id = @import("core/id.zig");
    pub const time = @import("core/time.zig");
};

pub const interop = struct {
    pub const toml = @import("interop/toml.zig");
    pub const countries = @import("interop/countries.zig");
    pub const currency = @import("interop/currency.zig");
    pub const units = @import("interop/units.zig");
    pub const jsonschema = @import("interop/jsonschema.zig");
    pub const openapi = @import("interop/openapi.zig");
    pub const datetime = @import("interop/datetime.zig");
    pub const language = @import("interop/language.zig");
};

pub const knowledge = struct {
    pub const rdf = @import("knowledge/rdf.zig");
    pub const concepts = @import("knowledge/concepts.zig");
    pub const thesaurus = @import("knowledge/thesaurus.zig");
    pub const skos = @import("knowledge/skos.zig");
    pub const vocabulary = @import("knowledge/vocabulary.zig");
};

pub const metadata = struct {
    pub const value_domain = @import("metadata/value_domain.zig");
    pub const registry = @import("metadata/registry.zig");
};

pub const data = struct {
    pub const provenance = @import("data/provenance.zig");
};

pub const standards = struct {
    pub const requirement = @import("standards/requirement.zig");
    pub const registry = @import("standards/registry.zig");
    pub const evidence = @import("standards/evidence.zig");
};

pub const language = struct {
    pub const text = @import("language/text.zig");
    pub const audience = @import("language/audience.zig");
    pub const readability = @import("language/readability.zig");
    pub const plain = @import("language/plain.zig");
    pub const controlled = @import("language/controlled.zig");
    pub const easy_read = @import("language/easy_read.zig");
};

pub const version = "0.1.0";

/// Reference every declaration in the tree so that `zig build test` compiles
/// and runs the whole library, not only the modules a binary happens to touch.
pub fn refAllRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        if (@TypeOf(field) == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => refAllRecursive(field),
                else => {},
            }
        }
        _ = &field;
    }
}

test {
    refAllRecursive(@This());
}
