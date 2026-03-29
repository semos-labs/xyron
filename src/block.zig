// block.zig — Command block model.
//
// Each command execution produces exactly one Block. Output chunks
// are associated with blocks by ID. Blocks have explicit lifecycle
// states. This is the foundation for Attyx block UI, structured
// history, and richer Lua hooks.

const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// Block state and model
// ---------------------------------------------------------------------------

pub const BlockStatus = enum {
    running,
    success,
    failed,
    interrupted,

    pub fn label(self: BlockStatus) []const u8 {
        return switch (self) {
            .running => "running",
            .success => "success",
            .failed => "failed",
            .interrupted => "interrupted",
        };
    }
};

pub const StreamKind = enum(u8) {
    stdout = 0,
    stderr = 1,
};

pub const MAX_INPUT: usize = 256;
pub const MAX_CWD: usize = 256;

pub const Block = struct {
    id: u64,
    group_id: u64,
    raw_input: [MAX_INPUT]u8 = undefined,
    raw_len: usize = 0,
    cwd: [MAX_CWD]u8 = undefined,
    cwd_len: usize = 0,
    status: BlockStatus = .running,
    exit_code: u8 = 0,
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    is_background: bool = false,
    job_id: u32 = 0,

    pub fn rawSlice(self: *const Block) []const u8 {
        return self.raw_input[0..self.raw_len];
    }

    pub fn cwdSlice(self: *const Block) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    pub fn durationMs(self: *const Block) i64 {
        if (self.end_ms > self.start_ms) return self.end_ms - self.start_ms;
        if (self.status == .running) return types.timestampMs() - self.start_ms;
        return 0;
    }

    pub fn finish(self: *Block, exit_code: u8) void {
        self.exit_code = exit_code;
        self.end_ms = types.timestampMs();
        self.status = if (exit_code == 0) .success else .failed;
    }

    pub fn interrupt(self: *Block) void {
        self.end_ms = types.timestampMs();
        self.status = .interrupted;
        self.exit_code = 130;
    }
};

// ---------------------------------------------------------------------------
// Block table — tracks recent blocks in memory
// ---------------------------------------------------------------------------

pub const MAX_BLOCKS: usize = 32;

pub const BlockTable = struct {
    blocks: [MAX_BLOCKS]Block = undefined,
    count: usize = 0,
    next_id: u64 = 1,

    /// Create a new block. Returns the block ID.
    pub fn create(
        self: *BlockTable,
        group_id: u64,
        raw_input: []const u8,
        cwd: []const u8,
        background: bool,
    ) u64 {
        // Compact if full — ensure we have room
        if (self.count >= MAX_BLOCKS) self.compact();
        if (self.count >= MAX_BLOCKS) return 0; // still full after compact

        const id = self.next_id;
        self.next_id += 1;

        var blk = &self.blocks[self.count];
        blk.* = .{
            .id = id,
            .group_id = group_id,
            .status = .running,
            .start_ms = types.timestampMs(),
            .is_background = background,
        };

        const rl = @min(raw_input.len, MAX_INPUT);
        @memcpy(blk.raw_input[0..rl], raw_input[0..rl]);
        blk.raw_len = rl;

        const cl = @min(cwd.len, MAX_CWD);
        @memcpy(blk.cwd[0..cl], cwd[0..cl]);
        blk.cwd_len = cl;

        self.count += 1;
        return id;
    }

    /// Find a block by ID.
    pub fn findById(self: *BlockTable, id: u64) ?*Block {
        for (self.blocks[0..self.count]) |*b| {
            if (b.id == id) return b;
        }
        return null;
    }

    /// Get the most recent block.
    pub fn last(self: *BlockTable) ?*Block {
        if (self.count == 0) return null;
        return &self.blocks[self.count - 1];
    }

    /// Remove old completed blocks to make room.
    fn compact(self: *BlockTable) void {
        // Keep only running blocks and the last N completed
        const keep_completed: usize = MAX_BLOCKS / 2;
        var write: usize = 0;
        var completed_kept: usize = 0;

        // First pass: count completed from the end
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.blocks[i].status != .running) {
                completed_kept += 1;
            }
        }

        // Second pass: keep running + last N completed
        var skip_completed = if (completed_kept > keep_completed) completed_kept - keep_completed else 0;
        for (0..self.count) |ri| {
            if (self.blocks[ri].status == .running) {
                if (write != ri) self.blocks[write] = self.blocks[ri];
                write += 1;
            } else {
                if (skip_completed > 0) {
                    skip_completed -= 1;
                } else {
                    if (write != ri) self.blocks[write] = self.blocks[ri];
                    write += 1;
                }
            }
        }
        self.count = write;
    }

    /// Get all blocks (for inspection).
    pub fn allBlocks(self: *const BlockTable) []const Block {
        return self.blocks[0..self.count];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "create and find block" {
    var table = BlockTable{};
    const id = table.create(1, "echo hello", "/tmp", false);
    const blk = table.findById(id);
    try std.testing.expect(blk != null);
    try std.testing.expectEqualStrings("echo hello", blk.?.rawSlice());
    try std.testing.expectEqual(BlockStatus.running, blk.?.status);
}

test "finish block" {
    var table = BlockTable{};
    const id = table.create(1, "ls", "/", false);
    var blk = table.findById(id).?;
    blk.finish(0);
    try std.testing.expectEqual(BlockStatus.success, blk.status);
    try std.testing.expectEqual(@as(u8, 0), blk.exit_code);
}

test "failed block" {
    var table = BlockTable{};
    const id = table.create(1, "false", "/", false);
    var blk = table.findById(id).?;
    blk.finish(1);
    try std.testing.expectEqual(BlockStatus.failed, blk.status);
}

test "last returns most recent" {
    var table = BlockTable{};
    _ = table.create(1, "first", "/", false);
    _ = table.create(2, "second", "/", false);
    try std.testing.expectEqualStrings("second", table.last().?.rawSlice());
}

test "compact removes old completed" {
    var table = BlockTable{};
    for (0..MAX_BLOCKS) |i| {
        const id = table.create(@intCast(i), "cmd", "/", false);
        table.findById(id).?.finish(0);
    }
    // Add one more to trigger compact
    _ = table.create(999, "new", "/", false);
    try std.testing.expect(table.count < MAX_BLOCKS);
}
