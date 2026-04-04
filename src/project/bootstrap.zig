// project/bootstrap.zig — Project detection and manifest generation.
//
// Detects ecosystem type from existing files, infers baseline config,
// and generates valid xyron.toml. Shared pipeline for both `xyron init`
// and `xyron new`. Does not replace ecosystem tooling.

const std = @import("std");

// =============================================================================
// Ecosystem detection
// =============================================================================

pub const Ecosystem = enum {
    bun,
    node,
    rust,
    go,
    zig_lang,
    python,
    unknown,

    pub fn label(self: Ecosystem) []const u8 {
        return switch (self) {
            .bun => "bun",
            .node => "node",
            .rust => "rust",
            .go => "go",
            .zig_lang => "zig",
            .python => "python",
            .unknown => "unknown",
        };
    }

    /// Native scaffolding command for `xyron new`.
    pub fn newCommand(self: Ecosystem) ?[]const u8 {
        return switch (self) {
            .bun => "bun init",
            .node => "npm init -y",
            .rust => "cargo init",
            .go => null, // needs module path argument
            .zig_lang => "zig init",
            .python => null,
            .unknown => null,
        };
    }
};

pub const DetectedProject = struct {
    ecosystem: Ecosystem,
    name: []const u8,
    evidence: []const u8, // file that triggered detection
    scripts: []const InferredCommand,
    env_sources: []const []const u8,
};

pub const InferredCommand = struct {
    name: []const u8,
    command: []const u8,
};

/// Detect project ecosystem and infer config from `dir_path`.
pub fn detect(allocator: std.mem.Allocator, dir_path: []const u8) DetectedProject {
    // Priority order: Bun > Node > Rust > Go > Zig > Python
    if (detectBunOrNode(allocator, dir_path)) |result| return result;
    if (detectRust(allocator, dir_path)) |result| return result;
    if (detectGo(allocator, dir_path)) |result| return result;
    if (detectZig(allocator, dir_path)) |result| return result;
    if (detectPython(allocator, dir_path)) |result| return result;

    // Fallback: use directory name
    const base = std.fs.path.basename(dir_path);
    return .{
        .ecosystem = .unknown,
        .name = base,
        .evidence = "",
        .scripts = &.{},
        .env_sources = inferEnvSources(allocator, dir_path),
    };
}

// =============================================================================
// Ecosystem detectors
// =============================================================================

fn detectBunOrNode(allocator: std.mem.Allocator, dir: []const u8) ?DetectedProject {
    const pkg_json = readFile(allocator, dir, "package.json") orelse return null;

    // Detect Bun vs Node
    const is_bun = fileExists(dir, "bun.lock") or fileExists(dir, "bunfig.toml");
    const eco: Ecosystem = if (is_bun) .bun else .node;
    const runner: []const u8 = if (is_bun) "bun run " else "npm run ";

    // Parse name from package.json (simple string search)
    const name = extractJsonString(pkg_json, "name") orelse std.fs.path.basename(dir);

    // Infer scripts
    var scripts: std.ArrayListUnmanaged(InferredCommand) = .{};
    const known_scripts = [_][]const u8{ "dev", "start", "build", "test", "lint" };
    for (known_scripts) |script_name| {
        if (hasJsonScript(pkg_json, script_name)) {
            scripts.append(allocator, .{
                .name = script_name,
                .command = std.fmt.allocPrint(allocator, "{s}{s}", .{ runner, script_name }) catch script_name,
            }) catch {};
        }
    }

    return .{
        .ecosystem = eco,
        .name = name,
        .evidence = "package.json",
        .scripts = scripts.toOwnedSlice(allocator) catch &.{},
        .env_sources = inferEnvSources(allocator, dir),
    };
}

fn detectRust(allocator: std.mem.Allocator, dir: []const u8) ?DetectedProject {
    const cargo = readFile(allocator, dir, "Cargo.toml") orelse return null;

    // Extract name from [package] section
    const name = extractTomlValue(cargo, "name") orelse std.fs.path.basename(dir);

    const scripts = allocator.alloc(InferredCommand, 3) catch return null;
    scripts[0] = .{ .name = "build", .command = "cargo build" };
    scripts[1] = .{ .name = "test", .command = "cargo test" };
    scripts[2] = .{ .name = "run", .command = "cargo run" };

    return .{
        .ecosystem = .rust,
        .name = name,
        .evidence = "Cargo.toml",
        .scripts = scripts,
        .env_sources = inferEnvSources(allocator, dir),
    };
}

fn detectGo(allocator: std.mem.Allocator, dir: []const u8) ?DetectedProject {
    const gomod = readFile(allocator, dir, "go.mod") orelse return null;

    // Extract module name
    var name: []const u8 = std.fs.path.basename(dir);
    var iter = std.mem.splitScalar(u8, gomod, '\n');
    if (iter.next()) |first_line| {
        if (std.mem.startsWith(u8, first_line, "module ")) {
            const mod = std.mem.trim(u8, first_line["module ".len..], " \t\r");
            // Use last path segment as short name
            if (std.mem.lastIndexOfScalar(u8, mod, '/')) |sep| {
                name = mod[sep + 1 ..];
            } else {
                name = mod;
            }
        }
    }

    const scripts = allocator.alloc(InferredCommand, 2) catch return null;
    scripts[0] = .{ .name = "run", .command = "go run ." };
    scripts[1] = .{ .name = "test", .command = "go test ./..." };

    return .{
        .ecosystem = .go,
        .name = name,
        .evidence = "go.mod",
        .scripts = scripts,
        .env_sources = inferEnvSources(allocator, dir),
    };
}

fn detectZig(allocator: std.mem.Allocator, dir: []const u8) ?DetectedProject {
    // Check build.zig.zon first, then build.zig
    const zon = readFile(allocator, dir, "build.zig.zon");
    if (zon == null and !fileExists(dir, "build.zig")) return null;

    var name: []const u8 = std.fs.path.basename(dir);
    if (zon) |content| {
        // Try to extract .name from build.zig.zon
        if (extractZonName(content)) |n| name = n;
    }

    const scripts = allocator.alloc(InferredCommand, 2) catch return null;
    scripts[0] = .{ .name = "build", .command = "zig build" };
    scripts[1] = .{ .name = "test", .command = "zig build test" };

    return .{
        .ecosystem = .zig_lang,
        .name = name,
        .evidence = if (zon != null) "build.zig.zon" else "build.zig",
        .scripts = scripts,
        .env_sources = inferEnvSources(allocator, dir),
    };
}

fn detectPython(allocator: std.mem.Allocator, dir: []const u8) ?DetectedProject {
    const has_pyproject = fileExists(dir, "pyproject.toml");
    const has_setup = fileExists(dir, "setup.py");
    if (!has_pyproject and !has_setup) return null;

    const name = std.fs.path.basename(dir);

    const scripts = allocator.alloc(InferredCommand, 1) catch return null;
    scripts[0] = .{ .name = "test", .command = "python -m pytest" };

    return .{
        .ecosystem = .python,
        .name = name,
        .evidence = if (has_pyproject) "pyproject.toml" else "setup.py",
        .scripts = scripts,
        .env_sources = inferEnvSources(allocator, dir),
    };
}

// =============================================================================
// Manifest generation
// =============================================================================

/// Generate xyron.toml content from a detected project.
pub fn generateManifest(allocator: std.mem.Allocator, detected: *const DetectedProject) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};

    // [project]
    appendLine(&buf, allocator, "[project]");
    appendFmt(&buf, allocator, "name = \"{s}\"", .{detected.name});
    appendLine(&buf, allocator, "");

    // [commands]
    if (detected.scripts.len > 0) {
        appendLine(&buf, allocator, "[commands]");
        for (detected.scripts) |script| {
            appendFmt(&buf, allocator, "{s} = \"{s}\"", .{ script.name, script.command });
        }
        appendLine(&buf, allocator, "");
    }

    // [env]
    if (detected.env_sources.len > 0) {
        appendLine(&buf, allocator, "[env]");
        // Build array string
        var src_buf: [512]u8 = undefined;
        var pos: usize = 0;
        pos += scopy(src_buf[pos..], "sources = [");
        for (detected.env_sources, 0..) |src, i| {
            if (i > 0) pos += scopy(src_buf[pos..], ", ");
            pos += scopy(src_buf[pos..], "\"");
            pos += scopy(src_buf[pos..], src);
            pos += scopy(src_buf[pos..], "\"");
        }
        pos += scopy(src_buf[pos..], "]");
        appendLine(&buf, allocator, src_buf[0..pos]);
        appendLine(&buf, allocator, "");
    }

    // [secrets] — empty placeholder
    appendLine(&buf, allocator, "[secrets]");
    appendLine(&buf, allocator, "required = []");

    return buf.toOwnedSlice(allocator) catch "";
}

// =============================================================================
// Helpers
// =============================================================================

fn inferEnvSources(allocator: std.mem.Allocator, dir: []const u8) []const []const u8 {
    var sources: std.ArrayListUnmanaged([]const u8) = .{};
    if (fileExists(dir, ".env")) sources.append(allocator, ".env") catch {};
    if (fileExists(dir, ".env.local")) sources.append(allocator, ".env.local") catch {};
    // Always suggest .env even if it doesn't exist yet (common convention)
    if (sources.items.len == 0) sources.append(allocator, ".env") catch {};
    return sources.toOwnedSlice(allocator) catch &.{};
}

pub fn fileExists(dir: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn readFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024) catch null;
}

/// Simple JSON string extraction: finds "key": "value" pattern.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key" :
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    // Find the colon after the key
    var i = key_pos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1; // skip opening "
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return null;
    return json[start..i];
}

/// Check if package.json has a script by name.
fn hasJsonScript(json: []const u8, script_name: []const u8) bool {
    // Find "scripts" section, then look for the key
    const scripts_pos = std.mem.indexOf(u8, json, "\"scripts\"") orelse return false;
    const after_scripts = json[scripts_pos..];
    // Find the script name within the scripts block
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{script_name}) catch return false;
    return std.mem.indexOf(u8, after_scripts, needle) != null;
}

/// Extract .name from build.zig.zon content.
fn extractZonName(content: []const u8) ?[]const u8 {
    // Look for .name = "..." or .name = .{ "..." }
    const pos = std.mem.indexOf(u8, content, ".name") orelse return null;
    var i = pos + 5;
    // Skip whitespace and =
    while (i < content.len and (content[i] == ' ' or content[i] == '=' or content[i] == '\t')) : (i += 1) {}
    // Skip optional .{
    if (i + 1 < content.len and content[i] == '.' and content[i + 1] == '{') {
        i += 2;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
    }
    if (i >= content.len or content[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < content.len and content[i] != '"') : (i += 1) {}
    if (i >= content.len) return null;
    return content[start..i];
}

/// Simple TOML value extraction for key = "value" pattern.
fn extractTomlValue(toml: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    // Try key = "value" pattern
    const patterns = [_][]const u8{
        std.fmt.bufPrint(&search_buf, "{s} = \"", .{key}) catch return null,
    };
    for (patterns) |needle| {
        if (std.mem.indexOf(u8, toml, needle)) |pos| {
            const start = pos + needle.len;
            var end = start;
            while (end < toml.len and toml[end] != '"') : (end += 1) {}
            if (end < toml.len) return toml[start..end];
        }
    }
    return null;
}

fn appendLine(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, line: []const u8) void {
    buf.appendSlice(allocator, line) catch {};
    buf.append(allocator, '\n') catch {};
}

fn appendFmt(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    var tmp: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
    appendLine(buf, allocator, s);
}

fn scopy(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// =============================================================================
// Tests
// =============================================================================

test "extractJsonString" {
    const json = "{\"name\": \"my-app\", \"version\": \"1.0.0\"}";
    try std.testing.expectEqualStrings("my-app", extractJsonString(json, "name").?);
    try std.testing.expectEqualStrings("1.0.0", extractJsonString(json, "version").?);
    try std.testing.expect(extractJsonString(json, "missing") == null);
}

test "hasJsonScript" {
    const json =
        \\{"scripts": {"dev": "next dev", "build": "next build"}}
    ;
    try std.testing.expect(hasJsonScript(json, "dev"));
    try std.testing.expect(hasJsonScript(json, "build"));
    try std.testing.expect(!hasJsonScript(json, "test"));
}

test "extractZonName" {
    const zon = ".{ .name = \"xyron\", .version = \"0.1.0\" }";
    try std.testing.expectEqualStrings("xyron", extractZonName(zon).?);
}

test "extractTomlValue" {
    const toml = "[package]\nname = \"my-crate\"\nversion = \"0.1.0\"";
    try std.testing.expectEqualStrings("my-crate", extractTomlValue(toml, "name").?);
}

test "generateManifest produces valid toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const scripts = [_]InferredCommand{
        .{ .name = "dev", .command = "bun run dev" },
        .{ .name = "test", .command = "bun run test" },
    };
    const env = [_][]const u8{".env"};
    const detected = DetectedProject{
        .ecosystem = .bun,
        .name = "my-app",
        .evidence = "package.json",
        .scripts = &scripts,
        .env_sources = &env,
    };

    const result = generateManifest(a, &detected);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "[project]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "name = \"my-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[commands]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "dev = \"bun run dev\"") != null);
}
