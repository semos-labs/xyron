// aliases.zig — Shell alias registry.
//
// Aliases are name → expansion mappings registered via Lua config.
// When the user types an alias name as the first word of a command,
// it's expanded to the replacement text before parsing.

const std = @import("std");

const MAX_ALIASES: usize = 128;
const MAX_NAME: usize = 64;
const MAX_EXPANSION: usize = 512;

const Alias = struct {
    name: [MAX_NAME]u8,
    name_len: usize,
    expansion: [MAX_EXPANSION]u8,
    expansion_len: usize,
};

var entries: [MAX_ALIASES]Alias = undefined;
var count: usize = 0;

/// Register or replace an alias.
pub fn set(name: []const u8, expansion: []const u8) void {
    if (name.len == 0 or name.len > MAX_NAME or expansion.len > MAX_EXPANSION) return;

    // Replace existing
    for (entries[0..count]) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            @memcpy(e.expansion[0..expansion.len], expansion);
            e.expansion_len = expansion.len;
            return;
        }
    }

    // Add new
    if (count >= MAX_ALIASES) return;
    var e = &entries[count];
    @memcpy(e.name[0..name.len], name);
    e.name_len = name.len;
    @memcpy(e.expansion[0..expansion.len], expansion);
    e.expansion_len = expansion.len;
    count += 1;
}

/// Look up an alias. Returns the expansion or null.
pub fn get(name: []const u8) ?[]const u8 {
    for (entries[0..count]) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            return e.expansion[0..e.expansion_len];
        }
    }
    return null;
}

/// Check if a name is a registered alias.
pub fn isAlias(name: []const u8) bool {
    return get(name) != null;
}

/// Number of registered aliases.
pub fn aliasCount() usize {
    return count;
}

/// Get alias name by index (for completion).
pub fn nameAt(index: usize) []const u8 {
    return entries[index].name[0..entries[index].name_len];
}

/// Get alias expansion by index (for completion descriptions).
pub fn expansionAt(index: usize) []const u8 {
    return entries[index].expansion[0..entries[index].expansion_len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "set and get alias" {
    set("ll", "ls -la");
    const result = get("ll");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("ls -la", result.?);
}

test "isAlias" {
    set("gs", "git status");
    try std.testing.expect(isAlias("gs"));
    try std.testing.expect(!isAlias("nonexistent"));
}

test "replace existing alias" {
    set("t", "first");
    set("t", "second");
    try std.testing.expectEqualStrings("second", get("t").?);
}
