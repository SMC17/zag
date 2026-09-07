//! The workspace daemon's HTTP interface, described once.
//!
//! This lived in the command-line tool, where `zag emit` reads it to generate
//! the OpenAPI document. It describes the daemon, not either tool, and now that
//! the generator lives in a second binary it has to be somewhere both can see.
//! Describing an interface in the tool that happens to publish it is how the
//! description and the server drift apart.

const std = @import("std");
const openapi = @import("../interop/openapi.zig");
const model = @import("../workspace/model.zig");
const block_mod = @import("../workspace/block.zig");
const event = @import("../events/event.zig");

const Health = struct { status: []const u8, version: []const u8, pseudoterminalSupported: bool };
const SessionList = struct { sessions: []const model.Session };
const BlockList = struct { blocks: []const block_mod.Block };
const SubmitCommand = struct { commandText: []const u8, workingDirectory: []const u8 };
const EventPage = struct { events: []const event.Envelope, nextSequence: u64 };
const ApprovalAnswer = struct { outcome: []const u8, note: []const u8 };
const ApprovalResult = struct { accepted: bool, message: []const u8 };

pub const daemon_operations = [_]openapi.Operation{
    .{
        .method = .get,
        .path = "/health",
        .operation_id = "getHealth",
        .summary = "Report whether the daemon is running",
        .response = Health,
        .tags = &.{"system"},
    },
    .{
        .method = .get,
        .path = "/sessions",
        .operation_id = "listSessions",
        .summary = "List the sessions in this workspace",
        .response = SessionList,
        .capability = "fs.read",
        .tags = &.{"sessions"},
    },
    .{
        .method = .get,
        .path = "/sessions/{sessionId}/blocks",
        .operation_id = "listBlocks",
        .summary = "List the blocks in one session",
        .response = BlockList,
        .capability = "fs.read",
        .tags = &.{"sessions"},
    },
    .{
        .method = .post,
        .path = "/sessions/{sessionId}/commands",
        .operation_id = "submitCommand",
        .summary = "Run a command in one session",
        .request = SubmitCommand,
        .response = block_mod.Block,
        .capability = "process.execute",
        .tags = &.{"sessions"},
    },
    .{
        .method = .get,
        .path = "/events",
        .operation_id = "listEvents",
        .summary = "Read the workspace event log from a sequence number",
        .response = EventPage,
        .capability = "fs.read",
        .tags = &.{"events"},
    },
    .{
        .method = .post,
        .path = "/approvals/{approvalId}",
        .operation_id = "answerApproval",
        .summary = "Answer a request that is waiting for a person",
        .request = ApprovalAnswer,
        .response = ApprovalResult,
        .capability = "process.execute",
        .tags = &.{"approvals"},
    },
};
