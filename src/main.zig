const std = @import("std");
const zvpms = @import("zvpms.zig");
const builtin = @import("builtin");

const ZvpmsCommand = enum {
    install,
    use,
    list,
    remove,
    help,
    version,
    zig,
};

const ZigCommand = struct {
    args: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, args: [][]const u8) ZigCommand {
        return ZigCommand{
            .args = args,
            .allocator = allocator,
        };
    }

    pub fn execute(self: *const ZigCommand) !void {
        const current_version = zvpms.getCurrentVersion();
        if (current_version == null) {
            std.debug.print("No Zig version is currently set. Use 'zvpms use <version>' to set one.\n", .{});
            return;
        }

        const zig_path = try self.getZigExecutablePath(current_version.?);
        defer self.allocator.free(zig_path);

        if (!zvpms.fileExists(zig_path)) {
            std.debug.print("Zig executable not found at: {s}\n", .{zig_path});
            std.debug.print("The installation might be corrupted. Try reinstalling version {s}\n", .{current_version.?});
            return;
        }

        var child_args = std.ArrayList([]const u8).init(self.allocator);
        defer child_args.deinit();

        try child_args.append(zig_path);
        for (self.args) |arg| {
            try child_args.append(arg);
        }

        var child = std.process.Child.init(child_args.items, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        const result = try child.spawnAndWait();
        switch (result) {
            .Exited => |code| std.process.exit(code),
            .Signal => |signal| {
                std.debug.print("Zig process terminated by signal: {}\n", .{signal});
                std.process.exit(1);
            },
            .Stopped => |signal| {
                std.debug.print("Zig process stopped by signal: {}\n", .{signal});
                std.process.exit(1);
            },
            .Unknown => |code| {
                std.debug.print("Zig process exited with unknown code: {}\n", .{code});
                std.process.exit(1);
            },
        }
    }

    fn getZigExecutablePath(self: *const ZigCommand, version: []const u8) ![]u8 {
        const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
        return std.fs.path.join(self.allocator, &.{ zvpms.home.?, "versions", version, exe_name });
    }
};

fn parseCommand(arg: []const u8) ZvpmsCommand {
    if (std.mem.eql(u8, arg, "install")) return .install;
    if (std.mem.eql(u8, arg, "use")) return .use;
    if (std.mem.eql(u8, arg, "list")) return .list;
    if (std.mem.eql(u8, arg, "remove")) return .remove;
    if (std.mem.eql(u8, arg, "help")) return .help;
    if (std.mem.eql(u8, arg, "version")) return .version;
    return .zig;
}

fn printHelp() void {
    std.debug.print("ZVPMS - Zig Version Manager and Proxy\n\n", .{});
    std.debug.print("Version Management Commands:\n", .{});
    std.debug.print("  zvpms install <version>    Install a specific Zig version\n", .{});
    std.debug.print("  zvpms use <version>        Set the current Zig version\n", .{});
    std.debug.print("  zvpms list                 List installed versions\n", .{});
    std.debug.print("  zvpms remove <version>     Remove an installed version\n", .{});
    std.debug.print("  zvpms version              Show ZVPMS version\n", .{});
    std.debug.print("  zvpms help                 Show this help message\n\n", .{});
    std.debug.print("Zig Compiler Proxy:\n", .{});
    std.debug.print("  zvpms <zig-args>...        Run zig with the current version\n", .{});
    std.debug.print("  zvpms build                Build using current Zig version\n", .{});
    std.debug.print("  zvpms run                  Run using current Zig version\n", .{});
    std.debug.print("  zvpms test                 Test using current Zig version\n", .{});
    std.debug.print("  zvpms fmt                  Format using current Zig version\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  zvpms install 0.11.0\n", .{});
    std.debug.print("  zvpms use 0.11.0\n", .{});
    std.debug.print("  zvpms build --release=fast\n", .{});
    std.debug.print("  zvpms run -- --help\n", .{});
    std.debug.print("  zvpms zen\n", .{});
}

fn printVersion() void {
    std.debug.print("ZVPMS 1.0.0\n", .{});
    if (zvpms.getCurrentVersion()) |version| {
        std.debug.print("Current Zig version: {s}\n", .{version});
    } else {
        std.debug.print("No Zig version currently set\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try zvpms.init();
    defer zvpms.deinit();

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = parseCommand(args[1]);

    switch (command) {
        .help => printHelp(),
        .version => printVersion(),
        .install => {
            if (args.len < 3) {
                std.debug.print("Error: install command requires a version argument\n", .{});
                std.debug.print("Usage: zvpms install <version>\n", .{});
                return;
            }
            try zvpms.installVersion(args[2]);
        },
        .use => {
            if (args.len < 3) {
                std.debug.print("Error: use command requires a version argument\n", .{});
                std.debug.print("Usage: zvpms use <version>\n", .{});
                return;
            }
            try zvpms.setCurrentVersion(args[2]);
        },
        .list => zvpms.listVersions(),
        .remove => {
            if (args.len < 3) {
                std.debug.print("Error: remove command requires a version argument\n", .{});
                std.debug.print("Usage: zvpms remove <version>\n", .{});
                return;
            }
            try zvpms.removeVersion(args[2]);
        },
        .zig => {
            const zig_args: [][]const u8 = @ptrCast(args[1..]);
            const zig_cmd = ZigCommand.init(allocator, zig_args);
            try zig_cmd.execute();
        },
    }
}