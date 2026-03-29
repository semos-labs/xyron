// types.zig — Shared data model for command execution.
//
// Provides the core types that flow through the shell: parsed commands,
// execution results, and session-scoped ID generation.

const std = @import("std");

/// Unique identifier for a command within a shell session.
/// Monotonically increasing, starting from 1.
pub const CommandId = u64;

/// A parsed command ready for dispatch and execution.
pub const Command = struct {
    /// Unique id for this command invocation
    id: CommandId,
    /// Raw input as typed (trimmed, but not split)
    raw_input: []const u8,
    /// Parsed argv — argv[0] is the command name
    argv: []const []const u8,
    /// Working directory when the command was created
    cwd: []const u8,
    /// Milliseconds since Unix epoch
    timestamp_ms: i64,
};

/// Outcome of running a command (builtin or external).
pub const CommandResult = struct {
    exit_code: u8,
    duration_ms: i64,
};

/// Monotonic command ID generator, one per shell session.
pub const IdGenerator = struct {
    next_id: CommandId = 1,

    pub fn next(self: *IdGenerator) CommandId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

/// Current time in milliseconds since Unix epoch.
pub fn timestampMs() i64 {
    return std.time.milliTimestamp();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "IdGenerator produces monotonic ids starting at 1" {
    var gen = IdGenerator{};
    try std.testing.expectEqual(@as(CommandId, 1), gen.next());
    try std.testing.expectEqual(@as(CommandId, 2), gen.next());
    try std.testing.expectEqual(@as(CommandId, 3), gen.next());
}

test "timestampMs returns a plausible value" {
    const ts = timestampMs();
    // Must be after 2024-01-01 00:00:00 UTC (1704067200000 ms)
    try std.testing.expect(ts > 1_704_067_200_000);
}
