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
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var obj = std.json.ObjectMap.init(aa);
        if (self.current_version) |version| {
            try obj.put("current_version", json.Value{ .string = version });
        } else {
            try obj.put("current_version", json.Value.null);
        }
        var arr = std.json.Array.init(aa);
        for (self.installed_versions.items) |version| {
            try arr.append(json.Value{ .string = version });
        }
        try obj.put("installed_versions", json.Value{ .array = arr });
        const json_value = json.Value{ .object = obj };
        return try json.stringifyAlloc(allocator, json_value, .{ .whitespace = .indent_2 });
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Self {
        var parsed = try json.parseFromSlice(json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        var config_instance = Self.init(allocator);

        const root = parsed.value.object;

        if (root.get("current_version")) |current| {
            if (current != .null) {
                config_instance.current_version = try allocator.dupe(u8, current.string);
            }
        }

        if (root.get("installed_versions")) |versions| {
            for (versions.array.items) |version| {
                try config_instance.addVersion(allocator, version.string);
            }
        }

        return config_instance;
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

fn getVersionInfo(version: []const u8) !struct { tarball: []const u8, shasum: []const u8 } {
    const index_url = "https://ziglang.org/download/index.json";
    const index_data = try get(index_url);
    defer __allocator.free(index_data);

    var parsed = try json.parseFromSlice(json.Value, __allocator, index_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const version_entry = root.get(version) orelse return error.VersionNotFound;
    const arch = getArchString();
    const os = getOsString();
    const arch_os = try std.fmt.allocPrint(__allocator, "{s}-{s}", .{ arch, os });
    defer __allocator.free(arch_os);
    const arch_os_entry = version_entry.object.get(arch_os) orelse return error.ArchOsNotSupported;
    const tarball = arch_os_entry.object.get("tarball").?.string;
    const shasum = arch_os_entry.object.get("shasum").?.string;
    const tarball_dup = try __allocator.dupe(u8, tarball);
    const shasum_dup = try __allocator.dupe(u8, shasum);
    return .{ .tarball = tarball_dup, .shasum = shasum_dup };
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

        if (file_content.len > 0) {
            config.deinit(__allocator);
            config = Config.fromJson(__allocator, file_content) catch Config.init(__allocator);
        }
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

const Version = struct { major: u32, minor: u32, patch: u32 };

fn parseVersion(version: []const u8) !Version {
    var it = std.mem.splitAny(u8, version, ".");
    const major_str = it.next() orelse return error.InvalidVersion;
    const minor_str = it.next() orelse return error.InvalidVersion;
    const patch_str = it.next() orelse return error.InvalidVersion;
    if (it.next() != null) return error.InvalidVersion;
    const major = try std.fmt.parseInt(u32, major_str, 10);
    const minor = try std.fmt.parseInt(u32, minor_str, 10);
    const patch = try std.fmt.parseInt(u32, patch_str, 10);
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn getLatestVersion() ![]const u8 {
    const index_url = "https://ziglang.org/download/index.json";
    const index_data = try get(index_url);
    defer __allocator.free(index_data);

    var parsed = try json.parseFromSlice(json.Value, __allocator, index_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var latest_version: ?[]const u8 = null;
    var latest_parsed: ?Version = null;

    for (root.keys()) |key| {
        if (std.mem.startsWith(u8, key, "0.")) {
            const parsed_version = parseVersion(key) catch continue;
            if (latest_parsed == null or
                (parsed_version.major > latest_parsed.?.major) or
                (parsed_version.major == latest_parsed.?.major and parsed_version.minor > latest_parsed.?.minor) or
                (parsed_version.major == latest_parsed.?.major and parsed_version.minor == latest_parsed.?.minor and parsed_version.patch > latest_parsed.?.patch)) {
                latest_parsed = parsed_version;
                latest_version = key;
            }
        }
    }

    if (latest_version) |ver| {
        return try __allocator.dupe(u8, ver);
    } else {
        return error.NoVersionsFound;
    }
}

pub fn installVersion(version: []const u8) !void {
    var actual_version: []const u8 = undefined;
    var should_free_version = false;

    if (std.mem.eql(u8, version, "master")) {
        actual_version = try getLatestVersion();
        should_free_version = true;
        std.debug.print("Installing 'master' as version {s}\n", .{actual_version});
    } else {
        actual_version = version;
    }
    defer if (should_free_version) __allocator.free(actual_version);

    const version_info = try getVersionInfo(actual_version);
    defer __allocator.free(version_info.tarball);
    defer __allocator.free(version_info.shasum);

    const download_url = version_info.tarball;
    std.debug.print("Downloading Zig {s} from: {s}\n", .{ actual_version, download_url });

    const version_dir_path = try std.fs.path.join(__allocator, &.{ home.?, "versions", actual_version });
    defer __allocator.free(version_dir_path);

    std.fs.makeDirAbsolute(version_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("Version {s} already exists\n", .{actual_version});
            return;
        },
        else => return err,
    };

    const uri = try std.Uri.parse(download_url);
    const filename = std.fs.path.basename(uri.path.percent_encoded);
    const temp_archive_path = try std.fs.path.join(__allocator, &.{ version_dir_path, filename });
    defer __allocator.free(temp_archive_path);

    const archive_data = get(download_url) catch |err| {
        std.debug.print("Failed to download Zig {s}: {}\n", .{ actual_version, err });
        std.fs.deleteTreeAbsolute(version_dir_path) catch {};
        return err;
    };
    defer __allocator.free(archive_data);

    const temp_file = try std.fs.createFileAbsolute(temp_archive_path, .{});
    defer temp_file.close();
    try temp_file.writeAll(archive_data);

    try extractArchive(temp_archive_path, version_dir_path);

    std.fs.deleteFileAbsolute(temp_archive_path) catch {};

    try config.addVersion(__allocator, actual_version);
    try saveConfig();
    std.debug.print("Successfully installed Zig {s}\n", .{actual_version});
}

fn extractArchive(archive_path: []const u8, extract_to: []const u8) !void {
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

pub fn renameVersion(old_version: []const u8, new_version: []const u8) !void {
    var found = false;
    for (config.installed_versions.items) |installed| {
        if (std.mem.eql(u8, installed, old_version)) {
            found = true;
            break;
        }
    }
    if (!found) {
        std.debug.print("Version {s} is not installed\n", .{old_version});
        return error.VersionNotInstalled;
    }

    for (config.installed_versions.items) |installed| {
        if (std.mem.eql(u8, installed, new_version)) {
            std.debug.print("Version {s} already exists\n", .{new_version});
            return error.VersionAlreadyExists;
        }
    }

    const old_dir_path = try std.fs.path.join(__allocator, &.{ home.?, "versions", old_version });
    defer __allocator.free(old_dir_path);
    const new_dir_path = try std.fs.path.join(__allocator, &.{ home.?, "versions", new_version });
    defer __allocator.free(new_dir_path);

    try std.fs.renameAbsolute(old_dir_path, new_dir_path);

    for (config.installed_versions.items, 0..) |installed, i| {
        if (std.mem.eql(u8, installed, old_version)) {
            __allocator.free(installed);
            config.installed_versions.items[i] = try __allocator.dupe(u8, new_version);
            break;
        }
    }

    if (config.current_version != null and std.mem.eql(u8, config.current_version.?, old_version)) {
        __allocator.free(config.current_version.?);
        config.current_version = try __allocator.dupe(u8, new_version);
    }

    try saveConfig();
    std.debug.print("Renamed version {s} to {s}\n", .{ old_version, new_version });
}

pub fn updateVersion(version: []const u8) !void {
    const parsed_version = try parseVersion(version);
    const major = parsed_version.major;
    const minor = parsed_version.minor;

    const index_url = "https://ziglang.org/download/index.json";
    const index_data = try get(index_url);
    defer __allocator.free(index_data);

    var parsed = try json.parseFromSlice(json.Value, __allocator, index_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var latest_patch: ?[]const u8 = null;
    var latest_patch_num: u32 = 0;

    for (root.keys()) |key| {
        const parsed_key = parseVersion(key) catch continue;
        if (parsed_key.major == major and parsed_key.minor == minor) {
            if (latest_patch == null or parsed_key.patch > latest_patch_num) {
                latest_patch_num = parsed_key.patch;
                latest_patch = key;
            }
        }
    }

    if (latest_patch) |latest| {
        if (std.mem.eql(u8, latest, version)) {
            std.debug.print("Version {s} is already the latest in its series\n", .{version});
        } else {
            std.debug.print("Updating {s} to {s}\n", .{ version, latest });
            try installVersion(latest);
        }
    } else {
        std.debug.print("No versions found for {d}.{d}.x\n", .{ major, minor });
    }
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

    return try req.reader().readAllAlloc(__allocator, 500 * 1024 * 1024);
}