const std = @import("std");
const builtin = @import("builtin");
const json = std.json;

const Config = struct {
    current_version: ?[]const u8,
    installed_versions: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .current_version = null,
            .installed_versions = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.current_version) |version| {
            allocator.free(version);
        }

        for (self.installed_versions.items) |version| {
            allocator.free(version);
        }
        self.installed_versions.deinit();
    }

    pub fn addVersion(self: *Self, allocator: std.mem.Allocator, version: []const u8) !void {
        for (self.installed_versions.items) |existing| {
            if (std.mem.eql(u8, existing, version)) return;
        }

        const owned_version = try allocator.dupe(u8, version);
        try self.installed_versions.append(owned_version);
    }

    pub fn setCurrentVersion(self: *Self, allocator: std.mem.Allocator, version: []const u8) !void {
        if (self.current_version) |old_version| {
            allocator.free(old_version);
        }
        self.current_version = try allocator.dupe(u8, version);
    }

    pub fn removeVersion(self: *Self, allocator: std.mem.Allocator, version: []const u8) void {
        for (self.installed_versions.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, version)) {
                allocator.free(existing);
                _ = self.installed_versions.swapRemove(i);
                break;
            }
        }
    }

    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var string = std.ArrayList(u8).init(allocator);
        defer string.deinit();

        try string.appendSlice("{\n");

        if (self.current_version) |version| {
            try string.writer().print("  \"current_version\": \"{s}\",\n", .{version});
        } else {
            try string.appendSlice("  \"current_version\": null,\n");
        }

        try string.appendSlice("  \"installed_versions\": [\n");
        for (self.installed_versions.items, 0..) |version, i| {
            if (i > 0) try string.appendSlice(",\n");
            try string.writer().print("    \"{s}\"", .{version});
        }
        try string.appendSlice("\n  ]\n");
        try string.appendSlice("}\n");

        return string.toOwnedSlice();
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Self {
        var parsed = try json.parseFromSlice(json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        var config__ = Self.init(allocator);

        const root = parsed.value.object;

        if (root.get("current_version")) |current| {
            if (current != .null) {
                config__.current_version = try allocator.dupe(u8, current.string);
            }
        }

        if (root.get("installed_versions")) |versions| {
            for (versions.array.items) |version| {
                try config__.addVersion(allocator, version.string);
            }
        }

        return config__;
    }
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var __allocator: std.mem.Allocator = undefined;

pub var home: ?[]u8 = null;
var conf_file: ?std.fs.File = null;
var versions_dir: ?std.fs.Dir = null;
var config: Config = undefined;

fn getHomeDir() ![]u8 {
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    return std.process.getEnvVarOwned(__allocator, home_var);
}

pub fn getZvpmsHome() ![]u8 {
    const home_dir = try getHomeDir();
    defer __allocator.free(home_dir);
    return std.fs.path.join(__allocator, &.{ home_dir, ".zvpms" });
}

fn getArchString() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
}

fn getOsString() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "macos",
        else => "unknown",
    };
}

fn getFileExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".zip",
        else => ".tar.xz",
    };
}

pub fn init() !void {
    __allocator = gpa.allocator();
    config = Config.init(__allocator);

    home = try getZvpmsHome();

    std.fs.makeDirAbsolute(home.?) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const versions_path = try std.fs.path.join(__allocator, &.{ home.?, "versions" });
    defer __allocator.free(versions_path);

    std.fs.makeDirAbsolute(versions_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    versions_dir = try std.fs.openDirAbsolute(versions_path, .{});

    const conf_path = try std.fs.path.join(__allocator, &.{ home.?, "config.json" });
    defer __allocator.free(conf_path);

    conf_file = std.fs.createFileAbsolute(conf_path, .{ .truncate = false, .read = true }) catch |err| switch (err) {
        error.PathAlreadyExists => try std.fs.openFileAbsolute(conf_path, .{ .mode = .read_write }),
        else => return err,
    };

    if (fileExists(conf_path)) {
        const file_content = try conf_file.?.readToEndAlloc(__allocator, 1024 * 1024);
        defer __allocator.free(file_content);

        config.deinit(__allocator);
        config = Config.fromJson(__allocator, file_content) catch Config.init(__allocator);
    }
}

pub fn deinit() void {
    if (conf_file) |file| {
        file.close();
        conf_file = null;
    }

    if (versions_dir) |*dir| {
        dir.close();
        versions_dir = null;
    }

    if (home) |home_path| {
        __allocator.free(home_path);
        home = null;
    }

    config.deinit(__allocator);
    _ = gpa.deinit();
}

fn saveConfig() !void {
    if (conf_file) |file| {
        try file.seekTo(0);
        const json_str = try config.toJson(__allocator);
        defer __allocator.free(json_str);
        _ = try file.writeAll(json_str);
        try file.setEndPos(try file.getPos());
    }
}

pub fn installVersion(version: []const u8) !void {
    const arch = getArchString();
    const os = getOsString();
    const ext = getFileExtension();

    const download_url = try std.fmt.allocPrint(__allocator, "https://ziglang.org/download/{s}/zig-{s}-{s}-{s}{s}", .{ version, arch, os, version, ext });
    defer __allocator.free(download_url);

    std.debug.print("Downloading Zig {s} from: {s}\n", .{ version, download_url });

    const version_dir_path = try std.fs.path.join(__allocator, &.{ home.?, "versions", version });
    defer __allocator.free(version_dir_path);

    std.fs.makeDirAbsolute(version_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("Version {s} already exists\n", .{version});
            return;
        },
        else => return err,
    };

    const archive_data = get(download_url) catch |err| {
        std.debug.print("Failed to download Zig {s}: {}\n", .{ version, err });

        std.fs.deleteTreeAbsolute(version_dir_path) catch {};
        return err;
    };
    defer __allocator.free(archive_data);

    const temp_archive_path = try std.fmt.allocPrint(__allocator, "{s}/temp_archive{s}", .{ version_dir_path, ext });
    defer __allocator.free(temp_archive_path);

    const temp_file = try std.fs.createFileAbsolute(temp_archive_path, .{});
    defer temp_file.close();
    try temp_file.writeAll(archive_data);

    try extractArchive(temp_archive_path, version_dir_path);

    std.fs.deleteFileAbsolute(temp_archive_path) catch {};

    try config.addVersion(__allocator, version);
    try saveConfig();

    std.debug.print("Successfully installed Zig {s}\n", .{version});
}

fn extractArchive(archive_path: []const u8, extract_to: []const u8) !void {
    const ext = getFileExtension();

    if (std.mem.eql(u8, ext, ".zip")) {
        std.debug.print("ZIP extraction not yet implemented. Please extract manually to: {s}\n", .{extract_to});
    } else {
        var child = std.process.Child.init(&.{ "tar", "-xf", archive_path, "-C", extract_to, "--strip-components=1" }, __allocator);
        const result = try child.spawnAndWait();

        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    return error.ExtractionFailed;
                }
            },
            else => return error.ExtractionFailed,
        }
    }
}

pub fn setCurrentVersion(version: []const u8) !void {
    var found = false;
    for (config.installed_versions.items) |installed| {
        if (std.mem.eql(u8, installed, version)) {
            found = true;
            break;
        }
    }

    if (!found) {
        std.debug.print("Version {s} is not installed\n", .{version});
        return error.VersionNotInstalled;
    }

    try config.setCurrentVersion(__allocator, version);
    try saveConfig();

    std.debug.print("Current version set to: {s}\n", .{version});
}

pub fn listVersions() void {
    std.debug.print("Installed versions:\n", .{});
    for (config.installed_versions.items) |version| {
        const current_marker = if (config.current_version != null and std.mem.eql(u8, config.current_version.?, version)) " (current)" else "";
        std.debug.print("  {s}{s}\n", .{ version, current_marker });
    }
}

pub fn getCurrentVersion() ?[]const u8 {
    return config.current_version;
}

pub fn removeVersion(version: []const u8) !void {
    if (config.current_version != null and std.mem.eql(u8, config.current_version.?, version)) {
        __allocator.free(config.current_version.?);
        config.current_version = null;
    }

    config.removeVersion(__allocator, version);

    const version_dir_path = try std.fs.path.join(__allocator, &.{ home.?, "versions", version });
    defer __allocator.free(version_dir_path);

    std.fs.deleteTreeAbsolute(version_dir_path) catch |err| {
        std.debug.print("Warning: Could not remove directory {s}: {}\n", .{ version_dir_path, err });
    };

    try saveConfig();
    std.debug.print("Removed version: {s}\n", .{version});
}

pub fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn dirExists(path: []const u8) bool {
    std.fs.openDirAbsolute(path, .{}) catch return false;
    return true;
}

pub fn get(url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = __allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        std.debug.print("HTTP request failed with status: {}\n", .{req.response.status});
        return error.HttpRequestFailed;
    }

    const content_length = req.response.content_length orelse 0;
    if (content_length > 500 * 1024 * 1024) {
        return error.FileTooLarge;
    }

    return try req.reader().readAllAlloc(__allocator, 500*1024*1024);
}