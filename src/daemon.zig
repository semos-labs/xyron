// daemon.zig — Zig wrapper for the C daemon_spawn function.
//
// The actual fork/exec logic is in daemon_spawn.c (pure C) to avoid
// Zig runtime pthread_atfork handlers deadlocking in forked children.

pub extern "c" fn daemon_spawn(
    script: [*:0]const u8,
    logfile: [*:0]const u8,
    pidfile: [*:0]const u8,
) c_int;

/// Spawn a detached daemon. Returns pid or -1 on error.
pub fn spawn(script: [*:0]const u8, log: [*:0]const u8, pid_file: [*:0]const u8) i32 {
    return daemon_spawn(script, log, pid_file);
}
