// project_test.zig — Test shim for the project module.
// Lives at src/ level so imports resolve correctly.

test {
    _ = @import("toml.zig");
    _ = @import("project/model.zig");
    _ = @import("project/discovery.zig");
    _ = @import("project/manifest.zig");
    _ = @import("project/loader.zig");
    _ = @import("project/dotenv.zig");
    _ = @import("project/context.zig");
    _ = @import("project/resolver.zig");
    _ = @import("project/session.zig");
    _ = @import("project/context_manager.zig");
    _ = @import("project/runner.zig");
    _ = @import("project/service_store.zig");
    _ = @import("project/service_manager.zig");
    _ = @import("project/doctor.zig");
    _ = @import("project/explain.zig");
    _ = @import("project/bootstrap.zig");
}
