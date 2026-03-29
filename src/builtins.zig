// builtins.zig — Re-exports from builtins/mod.zig.
// Each builtin command lives in its own file under src/builtins/.

pub const BuiltinResult = @import("builtins/mod.zig").BuiltinResult;
pub const isBuiltin = @import("builtins/mod.zig").isBuiltin;
pub const isProcessOnly = @import("builtins/mod.zig").isProcessOnly;
pub const execute = @import("builtins/mod.zig").execute;
