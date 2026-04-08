// project/context_manager.zig — Project context lifecycle manager.
//
// Orchestrates the full directory-change pipeline:
//   resolve project → load model → resolve context → detect transition →
//   compute overlay diff → produce status message
//
// This is the single entry point for all project context changes.
// No other code should duplicate this logic.

const std = @import("std");
const model = @import("model.zig");
const loader = @import("loader.zig");
const resolver = @import("resolver.zig");
const session_mod = @import("session.zig");
const ctx = @import("context.zig");
const types = @import("../types.zig");

/// Result of handling a directory change.
pub const DirectoryChangeResult = struct {
    prev: ctx.ActiveContext,
    next: ctx.ActiveContext,
    transition: ctx.ContextTransition,
    overlay_diff: ctx.ContextDiff,
    status_message: ?[]const u8 = null,
};

/// Minimal persistent state that survives arena resets.
/// Stores only scalars/small data — no pointers into arena memory.
const PersistentProjectInfo = struct {
    project_id_buf: [std.fs.max_path_bytes]u8 = undefined,
    project_id_len: usize = 0,
    project_root_buf: [std.fs.max_path_bytes]u8 = undefined,
    project_root_len: usize = 0,
    fingerprint: u64 = 0,
    status: ctx.ProjectStatus = .no_project,
    /// Modification times used to detect config changes between commands.
    manifest_mtime: i128 = 0,
    secrets_mtime: i128 = 0,

    fn projectId(self: *const PersistentProjectInfo) ?[]const u8 {
        if (self.project_id_len == 0) return null;
        return self.project_id_buf[0..self.project_id_len];
    }

    fn projectRoot(self: *const PersistentProjectInfo) ?[]const u8 {
        if (self.project_root_len == 0) return null;
        return self.project_root_buf[0..self.project_root_len];
    }

    fn setFrom(self: *PersistentProjectInfo, active: *const ctx.ActiveContext) void {
        self.status = active.project_status;
        self.fingerprint = if (active.resolved) |r| r.fingerprint else 0;
        if (active.project_id) |id| {
            const len = @min(id.len, self.project_id_buf.len);
            @memcpy(self.project_id_buf[0..len], id[0..len]);
            self.project_id_len = len;
        } else {
            self.project_id_len = 0;
        }
        if (active.project_root) |root| {
            const len = @min(root.len, self.project_root_buf.len);
            @memcpy(self.project_root_buf[0..len], root[0..len]);
            self.project_root_len = len;
        } else {
            self.project_root_len = 0;
        }
        // Snapshot current manifest mtime
        self.manifest_mtime = self.statManifestMtime();
    }

    /// Stat xyron.toml in the project root and return its mtime.
    fn statManifestMtime(self: *const PersistentProjectInfo) i128 {
        const root = self.projectRoot() orelse return 0;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const manifest_path = std.fmt.bufPrint(&buf, "{s}/xyron.toml", .{root}) catch return 0;
        return statFileMtime(manifest_path);
    }

    /// Check if the project config files have changed since last snapshot.
    fn configChanged(self: *const PersistentProjectInfo) bool {
        if (self.status == .no_project) return false;
        if (self.statManifestMtime() != self.manifest_mtime) return true;
        if (statSecretsMtime() != self.secrets_mtime) return true;
        return false;
    }

    /// Build a lightweight ActiveContext for transition detection (no arena pointers).
    /// The resolved context is NOT set — only fingerprint is available via the struct.
    fn toActiveContext(self: *const PersistentProjectInfo, session_id: u64) ctx.ActiveContext {
        var ac = ctx.ActiveContext{ .session_id = session_id };
        ac.project_status = self.status;
        ac.project_id = self.projectId();
        if (self.project_root_len > 0) ac.project_root = self.project_root_buf[0..self.project_root_len];
        return ac;
    }
};

/// Stat a file and return its mtime, or 0 if unavailable.
fn statFileMtime(path: []const u8) i128 {
    if (path.len == 0) return 0;
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.mtime;
}

/// Stat secrets.gpg and return its mtime. Uses stack buffers.
fn statSecretsMtime() i128 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.posix.getenv("XDG_DATA_HOME")) |dh| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/xyron/secrets.gpg", .{dh}) catch return 0;
        return statFileMtime(p);
    } else if (std.posix.getenv("HOME")) |home| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/.local/share/xyron/secrets.gpg", .{home}) catch return 0;
        return statFileMtime(p);
    }
    return 0;
}

/// Persistent state for a shell session's project context.
/// Lives on the Shell struct — one per session.
pub const SessionProjectState = struct {
    session_id: u64,
    generation: u64 = 0,
    persistent: PersistentProjectInfo = .{},
    /// Keys that the project overlay has applied to the shell env.
    /// Used to cleanly remove them on deactivation.
    applied_keys: std.StringArrayHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, session_id: u64) SessionProjectState {
        return .{
            .session_id = session_id,
            .applied_keys = std.StringArrayHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    /// Check if the project config (xyron.toml or secrets.gpg) has been modified
    /// since the last resolution. Used to detect edits without a directory change.
    pub fn projectConfigChanged(self: *const SessionProjectState) bool {
        return self.persistent.configChanged();
    }

    /// Snapshot the current secrets.gpg mtime. Call after overlay is applied.
    pub fn snapshotSecretsMtime(self: *SessionProjectState) void {
        self.persistent.secrets_mtime = statSecretsMtime();
    }

    /// Handle a directory change. Resolves the project at `new_cwd`,
    /// detects the transition, and returns the overlay diff to apply.
    pub fn handleDirectoryChange(
        self: *SessionProjectState,
        arena: std.mem.Allocator,
        new_cwd: []const u8,
        system_env: *const resolver.EnvSource,
    ) DirectoryChangeResult {
        // Step 1: Load project at new cwd
        const load_result = loader.loadProject(arena, new_cwd);

        // Step 2: Build next active context based on load result
        var next_active: ctx.ActiveContext = undefined;

        switch (load_result.status) {
            .not_found => {
                next_active = session_mod.buildActiveContext(
                    self.session_id,
                    self.generation + 1,
                    null,
                    null,
                    null,
                    &.{},
                    &.{},
                );
            },
            .invalid => {
                next_active = session_mod.buildActiveContext(
                    self.session_id,
                    self.generation + 1,
                    load_result.resolution.project_id,
                    load_result.resolution.project_root,
                    null,
                    load_result.errors,
                    load_result.warnings,
                );
            },
            .valid => {
                const mdl = load_result.model.?;
                const empty_ovr = resolver.EnvSource{ .keys = &.{}, .values = &.{} };
                const resolved = resolver.resolveContext(arena, &mdl, system_env, &empty_ovr);

                next_active = session_mod.buildActiveContext(
                    self.session_id,
                    self.generation + 1,
                    mdl.project_id,
                    mdl.root_path,
                    resolved,
                    load_result.errors,
                    load_result.warnings,
                );
            },
        }

        // Step 3: Detect transition using persistent state (safe across arena resets)
        const prev_ac = self.persistent.toActiveContext(self.session_id);
        const transition = session_mod.detectTransition(arena, &prev_ac, &next_active);

        // Step 4: Compute overlay diff
        const overlay_diff = computeOverlayDiff(arena, &prev_ac, &next_active);

        // Step 5: Build status message
        const status = buildStatusMessage(arena, &transition, &next_active, &load_result);

        // Step 6: Update persistent state (copies scalars, no arena pointers)
        self.persistent.setFrom(&next_active);
        self.generation += 1;

        return .{
            .prev = prev_ac,
            .next = next_active,
            .transition = transition,
            .overlay_diff = overlay_diff,
            .status_message = status,
        };
    }

    /// Apply the overlay diff to the shell environment.
    /// Adds new project keys, updates changed keys, removes old keys.
    /// Tracks all applied keys so they can be cleanly removed later.
    pub fn applyOverlay(
        self: *SessionProjectState,
        env: anytype,
        diff_result: *const DirectoryChangeResult,
    ) void {
        const next_resolved = diff_result.next.resolved;
        const transition = diff_result.transition;

        switch (transition.kind) {
            .enter_project, .switch_project => {
                // Remove previously applied keys first
                self.removeAppliedKeys(env);
                // Apply all project env values
                if (next_resolved) |resolved| {
                    self.applyProjectEnv(env, &resolved);
                }
            },
            .leave_project => {
                self.removeAppliedKeys(env);
            },
            .reload_project => {
                // Remove old, apply new
                self.removeAppliedKeys(env);
                if (next_resolved) |resolved| {
                    self.applyProjectEnv(env, &resolved);
                }
            },
            .stay_in_project, .stay_outside_project => {
                // No-op
            },
        }
    }

    /// Remove all keys that were applied by the project overlay.
    fn removeAppliedKeys(self: *SessionProjectState, env: anytype) void {
        for (self.applied_keys.keys()) |key| {
            env.unset(key);
        }
        // Free the owned key strings
        for (self.applied_keys.keys()) |key| {
            self.allocator.free(key);
        }
        self.applied_keys.clearRetainingCapacity();
    }

    /// Apply project-specific env values (from env files, not system env).
    fn applyProjectEnv(self: *SessionProjectState, env: anytype, resolved: *const ctx.ResolvedContext) void {
        // Only apply keys that came from project sources (env_file or override),
        // NOT keys that came from system env.
        for (resolved.provenance.keys(), resolved.provenance.values()) |key, prov| {
            if (prov.winner_source == .system) continue;

            // Apply to shell env
            env.set(key, prov.final_value) catch continue;

            // Track as applied by project overlay — dupe the key so it
            // survives arena resets (applied_keys uses the persistent allocator)
            const owned_key = self.allocator.dupe(u8, key) catch continue;
            self.applied_keys.put(owned_key, "") catch {
                self.allocator.free(owned_key);
            };
        }
    }
};

/// Compute the overlay diff — what project-specific env keys changed.
fn computeOverlayDiff(
    allocator: std.mem.Allocator,
    prev: *const ctx.ActiveContext,
    next: *const ctx.ActiveContext,
) ctx.ContextDiff {
    // Build maps of project-only keys for prev and next
    var prev_project_keys: ?std.StringArrayHashMap([]const u8) = null;
    var next_project_keys: ?std.StringArrayHashMap([]const u8) = null;

    if (prev.resolved) |resolved| {
        var m = std.StringArrayHashMap([]const u8).init(allocator);
        for (resolved.provenance.keys(), resolved.provenance.values()) |key, prov| {
            if (prov.winner_source != .system) {
                m.put(key, prov.final_value) catch {};
            }
        }
        prev_project_keys = m;
    }

    if (next.resolved) |resolved| {
        var m = std.StringArrayHashMap([]const u8).init(allocator);
        for (resolved.provenance.keys(), resolved.provenance.values()) |key, prov| {
            if (prov.winner_source != .system) {
                m.put(key, prov.final_value) catch {};
            }
        }
        next_project_keys = m;
    }

    const prev_ptr = if (prev_project_keys) |*m| m else null;
    const next_ptr = if (next_project_keys) |*m| m else null;

    return session_mod.diffValues(allocator, prev_ptr, next_ptr);
}

/// Build a concise status message for the transition.
fn buildStatusMessage(
    allocator: std.mem.Allocator,
    transition: *const ctx.ContextTransition,
    next: *const ctx.ActiveContext,
    load_result: *const model.ProjectModelLoadResult,
) ?[]const u8 {
    switch (transition.kind) {
        .stay_in_project, .stay_outside_project => return null,
        .leave_project => return null,
        .enter_project, .switch_project => {
            return buildActivationMessage(allocator, next, load_result);
        },
        .reload_project => {
            return std.fmt.allocPrint(allocator, "\x1b[2mproject reloaded\x1b[0m", .{}) catch null;
        },
    }
}

fn buildActivationMessage(
    allocator: std.mem.Allocator,
    next: *const ctx.ActiveContext,
    load_result: *const model.ProjectModelLoadResult,
) ?[]const u8 {
    if (next.project_status == .invalid_context) {
        return std.fmt.allocPrint(
            allocator,
            "\x1b[33mproject\x1b[0m \x1b[31minvalid config\x1b[0m",
            .{},
        ) catch null;
    }

    const resolved = next.resolved orelse return null;
    const mdl = load_result.model orelse return null;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    // project: name
    pos += scopy(buf[pos..], "\x1b[2mproject:\x1b[0m ");
    if (resolved.project_name) |name| {
        pos += scopy(buf[pos..], name);
    } else {
        pos += scopy(buf[pos..], std.fs.path.basename(resolved.project_root));
    }

    // env: loaded sources
    var loaded_sources: usize = 0;
    for (resolved.env_sources) |src| {
        if (src.source_kind == .env_file and src.status == .loaded) loaded_sources += 1;
    }
    if (loaded_sources > 0) {
        pos += scopy(buf[pos..], " \x1b[2m·\x1b[0m env: ");
        const n = std.fmt.bufPrint(buf[pos..], "{d} loaded", .{loaded_sources}) catch "";
        pos += n.len;
    }

    // missing secrets
    if (resolved.missing_required.len > 0) {
        const n = std.fmt.bufPrint(buf[pos..], " \x1b[2m·\x1b[0m \x1b[31m{d} secret(s) missing\x1b[0m", .{resolved.missing_required.len}) catch "";
        pos += n.len;
    }

    // commands count
    if (mdl.commands.len > 0) {
        const n = std.fmt.bufPrint(buf[pos..], " \x1b[2m·\x1b[0m {d} cmd(s)", .{mdl.commands.len}) catch "";
        pos += n.len;
    }

    return allocator.dupe(u8, buf[0..pos]) catch null;
}

fn scopy(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// =============================================================================
// Tests
// =============================================================================

test "SessionProjectState init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const state = SessionProjectState.init(arena.allocator(), 42);
    try std.testing.expectEqual(@as(u64, 42), state.session_id);
    try std.testing.expectEqual(ctx.ProjectStatus.no_project, state.persistent.status);
    try std.testing.expectEqual(@as(u64, 0), state.generation);
}

test "handleDirectoryChange outside project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var state = SessionProjectState.init(a, 1);
    const sys = resolver.EnvSource{ .keys = &.{}, .values = &.{} };

    const result = state.handleDirectoryChange(a, "/tmp", &sys);
    try std.testing.expectEqual(ctx.TransitionKind.stay_outside_project, result.transition.kind);
    try std.testing.expect(result.status_message == null);
}

test "computeOverlayDiff between no-project states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prev = ctx.ActiveContext{ .session_id = 1 };
    const next = ctx.ActiveContext{ .session_id = 1 };

    const diff = computeOverlayDiff(arena.allocator(), &prev, &next);
    try std.testing.expectEqual(@as(usize, 0), diff.added.len);
    try std.testing.expectEqual(@as(usize, 0), diff.removed.len);
    try std.testing.expectEqual(@as(usize, 0), diff.changed.len);
}
