// project/mod.zig — Public API for the project module.
//
// Re-exports the types and functions needed by the rest of xyron.
// Phase 1: project discovery, manifest loading, model normalization.
// Phase 2: context resolution, session management, transitions.

pub const model = @import("model.zig");
pub const discovery = @import("discovery.zig");
pub const manifest = @import("manifest.zig");
pub const loader = @import("loader.zig");
pub const dotenv = @import("dotenv.zig");
pub const context = @import("context.zig");
pub const resolver = @import("resolver.zig");
pub const session = @import("session.zig");
pub const context_manager = @import("context_manager.zig");
pub const runner = @import("runner.zig");
pub const service_store = @import("service_store.zig");
pub const service_manager = @import("service_manager.zig");
pub const doctor = @import("doctor.zig");
pub const explain = @import("explain.zig");
pub const bootstrap = @import("bootstrap.zig");

// Re-export key types for convenience
pub const ProjectModel = model.ProjectModel;
pub const ProjectResolution = model.ProjectResolution;
pub const ProjectModelLoadResult = model.ProjectModelLoadResult;
pub const LoadStatus = model.LoadStatus;
pub const ResolvedContext = context.ResolvedContext;
pub const ActiveContext = context.ActiveContext;
pub const ContextTransition = context.ContextTransition;
pub const ContextDiff = context.ContextDiff;
pub const EnvSource = resolver.EnvSource;

/// Load project from the current working directory.
pub fn loadFromCwd(allocator: @import("std").mem.Allocator) ProjectModelLoadResult {
    return loader.loadFromCwd(allocator);
}

/// Load project starting from the given path.
pub fn loadFromPath(allocator: @import("std").mem.Allocator, path: []const u8) ProjectModelLoadResult {
    return loader.loadProject(allocator, path);
}

test {
    _ = @import("model.zig");
    _ = @import("discovery.zig");
    _ = @import("manifest.zig");
    _ = @import("loader.zig");
    _ = @import("dotenv.zig");
    _ = @import("context.zig");
    _ = @import("resolver.zig");
    _ = @import("session.zig");
    _ = @import("context_manager.zig");
    _ = @import("runner.zig");
    _ = @import("service_store.zig");
    _ = @import("service_manager.zig");
    _ = @import("doctor.zig");
    _ = @import("explain.zig");
    _ = @import("bootstrap.zig");
}
