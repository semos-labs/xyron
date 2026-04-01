// git_info.zig — Git repository state detection for the prompt.
//
// Reads branch, worktree status, file indicators (staged/modified/untracked/
// conflicts/deleted), ahead/behind counts, and repo state (rebase/merge/
// cherry-pick). Uses `git status --porcelain=v2 --branch` for file status
// and reads .git/HEAD + state files directly for everything else.

const std = @import("std");

pub const GitInfo = struct {
    branch: []const u8 = "",
    worktree_name: []const u8 = "", // worktree directory name (empty if not a worktree)
    staged: usize = 0, // files in index (added/modified/deleted)
    modified: usize = 0, // modified in working tree
    untracked: usize = 0, // untracked files
    conflicts: usize = 0, // merge conflicts (unmerged)
    deleted: usize = 0, // deleted in working tree
    lines_added: usize = 0, // lines added (from git diff --stat)
    lines_removed: usize = 0, // lines removed
    ahead: usize = 0, // commits ahead of upstream
    behind: usize = 0, // commits behind upstream
    is_worktree: bool = false, // inside a git worktree
    is_detached: bool = false, // detached HEAD
    is_rebasing: bool = false,
    is_merging: bool = false,
    is_cherry_picking: bool = false,
};

// ---------------------------------------------------------------------------
// Static buffers (slices in GitInfo point into these)
// ---------------------------------------------------------------------------

var branch_buf: [128]u8 = undefined;
var gitdir_buf: [std.fs.max_path_bytes]u8 = undefined;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Read full git info for the current working directory.
pub fn read() GitInfo {
    var info = GitInfo{};

    // Walk up from cwd looking for .git (directory or worktree file)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir = std.posix.getcwd(&path_buf) catch return info;
    var git_dir: []const u8 = "";

    while (true) {
        var dot_git_path: [std.fs.max_path_bytes]u8 = undefined;
        const dgp = std.fmt.bufPrint(&dot_git_path, "{s}/.git", .{dir}) catch return info;

        const stat = std.fs.cwd().statFile(dgp) catch {
            const sep = std.mem.lastIndexOf(u8, dir, "/") orelse return info;
            if (sep == 0) return info;
            dir = dir[0..sep];
            continue;
        };

        if (stat.kind == .file) {
            // Worktree: .git is a file containing "gitdir: /path/to/real/git/dir"
            info.is_worktree = true;
            // Worktree name = last component of the directory containing .git file
            if (std.mem.lastIndexOf(u8, dir, "/")) |sep| {
                info.worktree_name = dir[sep + 1 ..];
            } else {
                info.worktree_name = dir;
            }
            const f = std.fs.cwd().openFile(dgp, .{}) catch return info;
            defer f.close();
            const n = f.read(&gitdir_buf) catch return info;
            const content = std.mem.trimRight(u8, gitdir_buf[0..n], "\n\r ");
            const prefix = "gitdir: ";
            if (std.mem.startsWith(u8, content, prefix)) {
                git_dir = content[prefix.len..];
            } else {
                return info;
            }
        } else {
            git_dir = dgp;
        }
        break;
    }

    if (git_dir.len == 0) return info;

    readHead(&info, git_dir);
    detectRepoState(&info, git_dir);
    readStatus(&info);
    readDiffStats(&info);

    return info;
}

// ---------------------------------------------------------------------------
// HEAD parsing
// ---------------------------------------------------------------------------

fn readHead(info: *GitInfo, git_dir: []const u8) void {
    var head_path: [std.fs.max_path_bytes]u8 = undefined;
    const hp = std.fmt.bufPrint(&head_path, "{s}/HEAD", .{git_dir}) catch return;

    const file = std.fs.cwd().openFile(hp, .{}) catch return;
    defer file.close();

    const n = file.read(&branch_buf) catch return;
    const content = branch_buf[0..n];

    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, content, prefix)) {
        const rest = content[prefix.len..];
        const end = std.mem.indexOf(u8, rest, "\n") orelse rest.len;
        info.branch = rest[0..end];
    } else if (n >= 8) {
        info.is_detached = true;
        const end = std.mem.indexOf(u8, content, "\n") orelse @min(n, 8);
        info.branch = content[0..end];
    }
}

// ---------------------------------------------------------------------------
// Repo state detection (rebase, merge, cherry-pick)
// ---------------------------------------------------------------------------

fn detectRepoState(info: *GitInfo, git_dir: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    if (fileExists(&buf, git_dir, "rebase-merge")) info.is_rebasing = true;
    if (fileExists(&buf, git_dir, "rebase-apply")) info.is_rebasing = true;
    if (fileExists(&buf, git_dir, "MERGE_HEAD")) {
        info.is_merging = true;
    } else if (fileExists(&buf, git_dir, "CHERRY_PICK_HEAD")) {
        info.is_cherry_picking = true;
    }
}

fn fileExists(buf: *[std.fs.max_path_bytes]u8, git_dir: []const u8, name: []const u8) bool {
    const p = std.fmt.bufPrint(buf, "{s}/{s}", .{ git_dir, name }) catch return false;
    _ = std.fs.cwd().statFile(p) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Status via `git status --porcelain=v2 --branch`
// ---------------------------------------------------------------------------

fn readStatus(info: *GitInfo) void {
    const alloc = std.heap.page_allocator;
    var child = std.process.Child.init(
        &.{ "git", "status", "--porcelain=v2", "--branch" },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return;

    var output_buf: [8192]u8 = undefined;
    var total: usize = 0;

    const stdout_fd = if (child.stdout) |f| f.handle else {
        _ = child.wait() catch {};
        return;
    };

    // Read with poll timeout (500ms)
    var fds = [_]std.posix.pollfd{.{
        .fd = stdout_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    var deadline: i32 = 500;
    while (total < output_buf.len and deadline > 0) {
        const start = std.time.milliTimestamp();
        const ready = std.posix.poll(&fds, deadline) catch break;
        const elapsed: i32 = @intCast(@min(std.time.milliTimestamp() - start, 500));
        deadline -= elapsed;
        if (ready == 0) break;
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(stdout_fd, output_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        } else break;
    }

    _ = child.wait() catch {};

    // Parse porcelain v2 output
    var line_iter = std.mem.splitScalar(u8, output_buf[0..total], '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            parseAheadBehind(info, line["# branch.ab ".len..]);
        } else if (line[0] == '1' or line[0] == '2') {
            // Changed entry: "1 XY ..." or "2 XY ..."
            if (line.len >= 4) {
                const x = line[2];
                const y = line[3];
                if (x != '.' and x != '?') info.staged += 1;
                if (y == 'M') info.modified += 1;
                if (y == 'D') info.deleted += 1;
            }
        } else if (line[0] == 'u') {
            info.conflicts += 1;
        } else if (line[0] == '?') {
            info.untracked += 1;
        }
    }
}

/// Read lines added/removed via `git diff --numstat`
fn readDiffStats(info: *GitInfo) void {
    const alloc = std.heap.page_allocator;
    var child = std.process.Child.init(
        &.{ "git", "diff", "--numstat" },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return;

    var output_buf: [8192]u8 = undefined;
    var total: usize = 0;

    const stdout_fd = if (child.stdout) |f| f.handle else {
        _ = child.wait() catch {};
        return;
    };

    var fds = [_]std.posix.pollfd{.{
        .fd = stdout_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    var deadline: i32 = 500;
    while (total < output_buf.len and deadline > 0) {
        const start = std.time.milliTimestamp();
        const ready = std.posix.poll(&fds, deadline) catch break;
        const elapsed: i32 = @intCast(@min(std.time.milliTimestamp() - start, 500));
        deadline -= elapsed;
        if (ready == 0) break;
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(stdout_fd, output_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        } else break;
    }

    _ = child.wait() catch {};

    // Parse: "added\tremoved\tfilename\n" per line
    // Binary files show "-\t-\t..."
    var line_iter = std.mem.splitScalar(u8, output_buf[0..total], '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var col_iter = std.mem.splitScalar(u8, line, '\t');
        const added_str = col_iter.next() orelse continue;
        const removed_str = col_iter.next() orelse continue;
        // Skip binary files (shown as "-")
        if (added_str.len > 0 and added_str[0] != '-') {
            info.lines_added += std.fmt.parseInt(usize, added_str, 10) catch 0;
        }
        if (removed_str.len > 0 and removed_str[0] != '-') {
            info.lines_removed += std.fmt.parseInt(usize, removed_str, 10) catch 0;
        }
    }
}

fn parseAheadBehind(info: *GitInfo, ab: []const u8) void {
    var iter = std.mem.splitScalar(u8, ab, ' ');
    if (iter.next()) |ahead_str| {
        if (ahead_str.len > 1 and ahead_str[0] == '+') {
            info.ahead = std.fmt.parseInt(usize, ahead_str[1..], 10) catch 0;
        }
    }
    if (iter.next()) |behind_str| {
        if (behind_str.len > 1 and behind_str[0] == '-') {
            info.behind = std.fmt.parseInt(usize, behind_str[1..], 10) catch 0;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseAheadBehind" {
    var info = GitInfo{};
    parseAheadBehind(&info, "+3 -1");
    try std.testing.expectEqual(@as(usize, 3), info.ahead);
    try std.testing.expectEqual(@as(usize, 1), info.behind);
}

test "parseAheadBehind zero" {
    var info = GitInfo{};
    parseAheadBehind(&info, "+0 -0");
    try std.testing.expectEqual(@as(usize, 0), info.ahead);
    try std.testing.expectEqual(@as(usize, 0), info.behind);
}

test "empty GitInfo defaults" {
    const info = GitInfo{};
    try std.testing.expectEqual(@as(usize, 0), info.staged);
    try std.testing.expectEqual(false, info.is_worktree);
    try std.testing.expectEqualStrings("", info.branch);
}
