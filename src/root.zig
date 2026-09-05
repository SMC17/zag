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
    pub const base = @import("knowledge/base.zig");
};

pub const metadata = struct {
    pub const value_domain = @import("metadata/value_domain.zig");
    pub const registry = @import("metadata/registry.zig");
    pub const publishing = @import("metadata/publishing.zig");
};

pub const data = struct {
    pub const provenance = @import("data/provenance.zig");
    pub const lifecycle = @import("data/lifecycle.zig");
    pub const quality = @import("data/quality.zig");
    pub const fair = @import("data/fair.zig");
};

pub const standards = struct {
    pub const requirement = @import("standards/requirement.zig");
    pub const registry = @import("standards/registry.zig");
    pub const evidence = @import("standards/evidence.zig");
    pub const profile = @import("standards/profile.zig");
    pub const crosswalk = @import("standards/crosswalk.zig");
};

pub const language = struct {
    pub const text = @import("language/text.zig");
    pub const audience = @import("language/audience.zig");
    pub const readability = @import("language/readability.zig");
    pub const plain = @import("language/plain.zig");
    pub const controlled = @import("language/controlled.zig");
    pub const easy_read = @import("language/easy_read.zig");
};

pub const events = struct {
    pub const event = @import("events/event.zig");
    pub const log = @import("events/log.zig");
    pub const graph = @import("events/graph.zig");
};

pub const workspace = struct {
    pub const block = @import("workspace/block.zig");
    pub const model = @import("workspace/model.zig");
    pub const workflow = @import("workspace/workflow.zig");
    pub const history = @import("workspace/history.zig");
    pub const service = @import("workspace/service.zig");
};

pub const editor = struct {
    pub const document = @import("editor/document.zig");
};

pub const terminal = struct {
    pub const vt = @import("terminal/vt.zig");
    pub const grid = @import("terminal/grid.zig");
    pub const shell_integration = @import("terminal/shell_integration.zig");
    pub const pty = @import("terminal/pty.zig");
    pub const session = @import("terminal/session.zig");
};

pub const ai = struct {
    pub const capability = @import("ai/capability.zig");
    pub const policy = @import("ai/policy.zig");
    pub const approval = @import("ai/approval.zig");
    pub const tools = @import("ai/tools.zig");
    pub const runtime = @import("ai/runtime.zig");
    pub const risk = @import("ai/risk.zig");
    pub const impact = @import("ai/impact.zig");
    pub const evaluation = @import("ai/evaluation.zig");
    pub const transparency = @import("ai/transparency.zig");
    pub const documentation = @import("ai/documentation.zig");
    pub const lifecycle = @import("ai/lifecycle.zig");
};

pub const records = struct {
    pub const ledger = @import("records/ledger.zig");
};

pub const content = struct {
    pub const ir = @import("content/ir.zig");
    pub const markdown = @import("content/markdown.zig");
    pub const dita = @import("content/dita.zig");
    pub const docbook = @import("content/docbook.zig");
    pub const s1000d = @import("content/s1000d.zig");
    pub const iirds = @import("content/iirds.zig");
};

pub const accessibility = struct {
    pub const contrast = @import("accessibility/contrast.zig");
    pub const semantic_tree = @import("accessibility/semantic_tree.zig");
    pub const wcag = @import("accessibility/wcag.zig");
};

pub const reports = struct {
    pub const metrics = @import("reports/metrics.zig");
    pub const notation = @import("reports/notation.zig");
};

pub const agent_context = struct {
    pub const agents_md = @import("agent_context/agents_md.zig");
    pub const llms_txt = @import("agent_context/llms_txt.zig");
    pub const resolver = @import("agent_context/resolver.zig");
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
