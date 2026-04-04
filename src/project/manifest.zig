// project/manifest.zig — Manifest loading and normalization.
//
// Reads xyron.toml, parses it via toml.zig, and normalizes
// the raw TOML into a clean ProjectModel. This is the ONLY
// place where TOML structure is interpreted.

const std = @import("std");
const toml = @import("../toml.zig");
const model = @import("model.zig");

/// Load and parse xyron.toml from the given path.
pub fn load(manifest_path: []const u8) model.ManifestLoadResult {
    // Read file contents
    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch {
        return .{
            .manifest_path = manifest_path,
            .status = .read_error,
            .error_msg = "cannot open file",
        };
    };
    defer file.close();

    const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch {
        return .{
            .manifest_path = manifest_path,
            .status = .read_error,
            .error_msg = "cannot read file",
        };
    };

    return .{
        .manifest_path = manifest_path,
        .raw_content = content,
        .status = .ok,
    };
}

/// Parse raw TOML content and return a parse result.
fn parseContent(allocator: std.mem.Allocator, content: []const u8) struct { table: ?toml.Table, err_msg: ?[]const u8, err_line: usize } {
    const result = toml.parse(allocator, content);
    if (result.err_msg) |msg| {
        return .{ .table = null, .err_msg = msg, .err_line = result.err_line };
    }
    return .{ .table = result.root, .err_msg = null, .err_line = 0 };
}

/// Normalize parsed TOML into a ProjectModel.
/// This is the only function that interprets TOML structure.
pub fn normalize(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    project_id: []const u8,
    content: []const u8,
) NormalizeResult {
    const parsed = parseContent(allocator, content);
    if (parsed.err_msg) |msg| {
        const errs = allocator.alloc([]const u8, 1) catch return .{
            .model = null,
            .errors = &.{},
            .warnings = &.{},
            .parse_error = msg,
            .parse_error_line = parsed.err_line,
        };
        errs[0] = std.fmt.allocPrint(allocator, "parse error at line {d}: {s}", .{ parsed.err_line, msg }) catch msg;
        return .{
            .model = null,
            .errors = errs,
            .warnings = &.{},
            .parse_error = msg,
            .parse_error_line = parsed.err_line,
        };
    }

    const root_table = parsed.table.?;
    var errors: std.ArrayListUnmanaged([]const u8) = .{};
    var warnings: std.ArrayListUnmanaged([]const u8) = .{};

    // Extract [project] section
    const project_info = normalizeProject(&root_table);

    // Extract [commands] section
    const commands = normalizeCommands(allocator, &root_table, root_path, &warnings);

    // Extract [env] section
    const env_config = normalizeEnv(allocator, &root_table);

    // Extract [secrets] section
    const secrets_config = normalizeSecrets(allocator, &root_table);

    // Extract [services] section
    const services = normalizeServices(allocator, &root_table, root_path, &warnings);

    const mdl = allocator.create(model.ProjectModel) catch {
        errors.append(allocator, "out of memory") catch {};
        return .{
            .model = null,
            .errors = errors.toOwnedSlice(allocator) catch &.{},
            .warnings = warnings.toOwnedSlice(allocator) catch &.{},
        };
    };
    mdl.* = .{
        .root_path = root_path,
        .project_id = project_id,
        .project = project_info,
        .commands = commands,
        .env = env_config,
        .secrets = secrets_config,
        .services = services,
    };

    return .{
        .model = mdl,
        .errors = errors.toOwnedSlice(allocator) catch &.{},
        .warnings = warnings.toOwnedSlice(allocator) catch &.{},
    };
}

pub const NormalizeResult = struct {
    model: ?*model.ProjectModel,
    errors: []const []const u8,
    warnings: []const []const u8,
    parse_error: ?[]const u8 = null,
    parse_error_line: usize = 0,
};

// =============================================================================
// Section normalizers
// =============================================================================

fn normalizeProject(root_table: *const toml.Table) model.ProjectInfo {
    const project_tbl = root_table.getTable("project") orelse return .{};
    return .{
        .name = project_tbl.getString("name"),
    };
}

fn normalizeCommands(
    allocator: std.mem.Allocator,
    root_table: *const toml.Table,
    root_path: []const u8,
    warnings: *std.ArrayListUnmanaged([]const u8),
) []const model.Command {
    const commands_tbl = root_table.getTable("commands") orelse return &.{};
    var result: std.ArrayListUnmanaged(model.Command) = .{};

    for (commands_tbl.entries.keys(), commands_tbl.entries.values()) |key, value| {
        switch (value) {
            // Shorthand: dev = "npm run dev"
            .string => |cmd_str| {
                result.append(allocator, .{
                    .name = key,
                    .command = cmd_str,
                    .cwd = root_path,
                }) catch {};
            },
            // Full form: [commands.test] command = "npm test"
            .table => |*cmd_tbl| {
                const cmd_str = cmd_tbl.getString("command") orelse {
                    warnings.append(allocator,
                        std.fmt.allocPrint(allocator, "command '{s}' missing 'command' field", .{key}) catch "command missing 'command' field",
                    ) catch {};
                    continue;
                };
                const cwd = cmd_tbl.getString("cwd") orelse root_path;
                result.append(allocator, .{
                    .name = key,
                    .command = cmd_str,
                    .cwd = cwd,
                }) catch {};
            },
            else => {
                warnings.append(allocator,
                    std.fmt.allocPrint(allocator, "command '{s}' has invalid type (expected string or table)", .{key}) catch "command has invalid type",
                ) catch {};
            },
        }
    }

    return result.toOwnedSlice(allocator) catch &.{};
}

fn normalizeEnv(allocator: std.mem.Allocator, root_table: *const toml.Table) model.EnvConfig {
    const env_tbl = root_table.getTable("env") orelse return .{};
    const sources = env_tbl.getStringArray("sources", allocator) orelse return .{};
    return .{ .sources = sources };
}

fn normalizeSecrets(allocator: std.mem.Allocator, root_table: *const toml.Table) model.SecretsConfig {
    const secrets_tbl = root_table.getTable("secrets") orelse return .{};
    const required = secrets_tbl.getStringArray("required", allocator) orelse return .{};
    return .{ .required = required };
}

fn normalizeServices(
    allocator: std.mem.Allocator,
    root_table: *const toml.Table,
    root_path: []const u8,
    warnings: *std.ArrayListUnmanaged([]const u8),
) []const model.Service {
    const services_tbl = root_table.getTable("services") orelse return &.{};
    var result: std.ArrayListUnmanaged(model.Service) = .{};

    for (services_tbl.entries.keys(), services_tbl.entries.values()) |key, value| {
        switch (value) {
            .table => |*svc_tbl| {
                const cmd_str = svc_tbl.getString("command") orelse {
                    warnings.append(allocator,
                        std.fmt.allocPrint(allocator, "service '{s}' missing 'command' field", .{key}) catch "service missing 'command' field",
                    ) catch {};
                    continue;
                };
                const cwd = svc_tbl.getString("cwd") orelse root_path;
                result.append(allocator, .{
                    .name = key,
                    .command = cmd_str,
                    .cwd = cwd,
                }) catch {};
            },
            else => {
                warnings.append(allocator,
                    std.fmt.allocPrint(allocator, "service '{s}' has invalid type (expected table)", .{key}) catch "service has invalid type",
                ) catch {};
            },
        }
    }

    return result.toOwnedSlice(allocator) catch &.{};
}

// =============================================================================
// Tests
// =============================================================================

test "normalize empty toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = normalize(allocator, "/tmp/project", "/tmp/project", "");
    try std.testing.expect(result.model != null);
    const mdl = result.model.?;
    try std.testing.expect(mdl.project.name == null);
    try std.testing.expectEqual(@as(usize, 0), mdl.commands.len);
    try std.testing.expectEqual(@as(usize, 0), mdl.services.len);
    try std.testing.expectEqual(@as(usize, 0), mdl.env.sources.len);
    try std.testing.expectEqual(@as(usize, 0), mdl.secrets.required.len);
}

test "normalize full manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\[project]
        \\name = "my-app"
        \\
        \\[commands]
        \\dev = "npm run dev"
        \\build = "npm run build"
        \\
        \\[commands.test]
        \\command = "npm test"
        \\cwd = "./packages/core"
        \\
        \\[env]
        \\sources = [".env", ".env.local"]
        \\
        \\[secrets]
        \\required = ["API_KEY"]
        \\
        \\[services.db]
        \\command = "docker compose up db"
    ;
    const result = normalize(allocator, "/home/user/app", "/home/user/app", source);
    try std.testing.expect(result.model != null);
    const mdl = result.model.?;

    try std.testing.expectEqualStrings("my-app", mdl.project.name.?);
    try std.testing.expectEqual(@as(usize, 3), mdl.commands.len);
    try std.testing.expectEqual(@as(usize, 2), mdl.env.sources.len);
    try std.testing.expectEqual(@as(usize, 1), mdl.secrets.required.len);
    try std.testing.expectEqual(@as(usize, 1), mdl.services.len);
}

test "normalize shorthand command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\[commands]
        \\dev = "npm run dev"
    ;
    const result = normalize(allocator, "/tmp", "/tmp", source);
    try std.testing.expect(result.model != null);
    const mdl = result.model.?;

    try std.testing.expectEqual(@as(usize, 1), mdl.commands.len);
    try std.testing.expectEqualStrings("dev", mdl.commands[0].name);
    try std.testing.expectEqualStrings("npm run dev", mdl.commands[0].command);
    try std.testing.expectEqualStrings("/tmp", mdl.commands[0].cwd);
}

test "normalize invalid toml returns errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = normalize(allocator, "/tmp", "/tmp", "= invalid");
    try std.testing.expect(result.model == null);
    try std.testing.expect(result.errors.len > 0);
}

test "normalize service without command produces warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\[services.broken]
        \\cwd = "./somewhere"
    ;
    const result = normalize(allocator, "/tmp", "/tmp", source);
    try std.testing.expect(result.model != null);
    const mdl = result.model.?;
    try std.testing.expectEqual(@as(usize, 0), mdl.services.len);
    try std.testing.expect(result.warnings.len > 0);
}
