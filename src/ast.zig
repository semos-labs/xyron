// ast.zig — Abstract syntax tree for parsed shell input.
//
// The AST is intentionally minimal. A Pipeline is the top-level node,
// where a single command is just a pipeline of length one. Each command
// can carry redirections and inline environment overrides.

const std = @import("std");
const environ_mod = @import("environ.zig");

// ---------------------------------------------------------------------------
// Redirect types
// ---------------------------------------------------------------------------

pub const RedirectKind = enum {
    stdin, // < file
    stdout, // > file
    stderr, // 2> file
};

pub const Redirect = struct {
    kind: RedirectKind,
    path: []const u8,
};

// ---------------------------------------------------------------------------
// Command and pipeline
// ---------------------------------------------------------------------------

/// A single command with its arguments, redirects, and env overrides.
pub const SimpleCommand = struct {
    /// Full argv — argv[0] is the program name.
    argv: []const []const u8,
    /// Redirections attached to this command.
    redirects: []const Redirect,
    /// Inline environment overrides (FOO=bar before command).
    env_overrides: []const environ_mod.EnvOverride = &.{},
    /// Per-argument quoting flag. If quoted[i] is true, argv[i] was
    /// single-quoted and should not be expanded.
    quoted: []const bool = &.{},

    pub fn program(self: SimpleCommand) []const u8 {
        return self.argv[0];
    }
};

/// A pipeline of one or more commands connected by pipes.
pub const Pipeline = struct {
    /// Ordered list of commands. For a simple command, len == 1.
    commands: []const SimpleCommand,
    /// True if the pipeline should run in the background (&).
    background: bool = false,

    pub fn isPipe(self: Pipeline) bool {
        return self.commands.len > 1;
    }

    /// Free all allocations made by the parser.
    pub fn deinit(self: *Pipeline, allocator: std.mem.Allocator) void {
        for (self.commands) |cmd| {
            if (cmd.redirects.len > 0) allocator.free(cmd.redirects);
            if (cmd.argv.len > 0) allocator.free(cmd.argv);
            if (cmd.env_overrides.len > 0) allocator.free(cmd.env_overrides);
            if (cmd.quoted.len > 0) allocator.free(cmd.quoted);
        }
        allocator.free(self.commands);
        self.* = .{ .commands = &.{} };
    }
};
