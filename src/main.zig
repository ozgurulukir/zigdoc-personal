const std = @import("std");
const builtin = @import("builtin");
const Walk = @import("Walk.zig");
const log = std.log.scoped(.zigdoc);

const build_runner = @embedFile("build_runner.zig");

const template_build_zig = @embedFile("templates/build.zig.template");
const template_main_zig = @embedFile("templates/main.zig.template");
const template_build_zig_zon = @embedFile("templates/build.zig.zon.template");
const template_agents_md = @embedFile("templates/AGENTS.md.template");
const template_gitignore = @embedFile("templates/.gitignore.template");

const skills_archive_url = "https://github.com/ethan-huo/zigdoc/archive/refs/heads/main.zip";
const skills_archive_root = "zigdoc-main";
const skills_temp_root = ".zig-cache/zigdoc-skill-install";
const skills_zip_path = skills_temp_root ++ "/zigdoc.zip";
const skills_extract_path = skills_temp_root ++ "/extract";
const skills_source_root = skills_extract_path ++ "/" ++ skills_archive_root ++ "/skills";
const skills_dest_root = ".agents/skills";

const CliOptions = struct {
    symbols: std.ArrayList([]const u8) = .empty,
};

const QueryParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn parse(allocator: std.mem.Allocator, input: []const u8, out: *std.ArrayList([]const u8)) anyerror!void {
        var parser: QueryParser = .{
            .allocator = allocator,
            .input = input,
        };
        try parser.parseList("", out, false);
        parser.skipSpace();
        if (parser.pos != parser.input.len) return error.InvalidQuery;
    }

    fn parseList(
        parser: *QueryParser,
        prefix: []const u8,
        out: *std.ArrayList([]const u8),
        expect_close: bool,
    ) anyerror!void {
        var need_item = true;
        while (parser.pos < parser.input.len) {
            parser.skipSpace();
            if (expect_close and parser.peek() == ')') {
                if (need_item) return error.InvalidQuery;
                parser.pos += 1;
                return;
            }

            try parser.parseItem(prefix, out);
            need_item = false;
            parser.skipSpace();

            switch (parser.peek()) {
                ',' => {
                    parser.pos += 1;
                    need_item = true;
                },
                ')' => {
                    if (!expect_close) return error.InvalidQuery;
                    parser.pos += 1;
                    return;
                },
                0 => {
                    if (expect_close) return error.InvalidQuery;
                    return;
                },
                else => return error.InvalidQuery,
            }
        }

        if (expect_close) return error.InvalidQuery;
        if (need_item) return error.InvalidQuery;
    }

    fn parseItem(
        parser: *QueryParser,
        prefix: []const u8,
        out: *std.ArrayList([]const u8),
    ) anyerror!void {
        parser.skipSpace();
        const start = parser.pos;
        while (parser.pos < parser.input.len) : (parser.pos += 1) {
            switch (parser.input[parser.pos]) {
                '(', ')', ',' => break,
                else => {},
            }
        }

        var part = std.mem.trim(u8, parser.input[start..parser.pos], &std.ascii.whitespace);
        if (part.len == 0) return error.InvalidQuery;

        if (parser.peek() == '(') {
            if (!std.mem.endsWith(u8, part, ".")) return error.InvalidQuery;
            part = part[0 .. part.len - 1];
            const next_prefix = try joinSymbol(parser.allocator, prefix, part);
            defer parser.allocator.free(next_prefix);
            parser.pos += 1;
            try parser.parseList(next_prefix, out, true);
            return;
        }

        const symbol = try joinSymbol(parser.allocator, prefix, part);
        try out.append(parser.allocator, symbol);
    }

    fn peek(parser: *const QueryParser) u8 {
        if (parser.pos >= parser.input.len) return 0;
        return parser.input[parser.pos];
    }

    fn skipSpace(parser: *QueryParser) void {
        while (parser.pos < parser.input.len and std.ascii.isWhitespace(parser.input[parser.pos])) {
            parser.pos += 1;
        }
    }
};

const SymbolDoc = struct {
    query: []const u8,
    decl_index: Walk.Decl.Index,
    target_index: Walk.Decl.Index,
    category: Walk.Category,
    file_path: []const u8,
    line: usize,
    signature: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip(); // skip program name

    const options = try parseCli(arena.allocator(), io, &args);
    if (options.symbols.items.len == 0) {
        try printUsage(io);
        return;
    }

    Walk.init(arena.allocator());
    Walk.Decl.init(arena.allocator());

    const std_dir_path = try getStdDir(&arena, io);

    var needs_std = false;
    var needs_build = false;
    for (options.symbols.items) |symbol| {
        if (isStdSymbol(symbol)) {
            needs_std = true;
        } else {
            needs_build = true;
        }
    }

    if (needs_std) {
        try walkStdLib(&arena, io, std_dir_path);

        // Register std/std.zig as the "std" module for @import("std")
        const std_file_index = Walk.files.getIndex("std/std.zig") orelse return error.StdNotFound;
        try Walk.modules.put(arena.allocator(), "std", @enumFromInt(std_file_index));
    }

    if (needs_build) {
        try processBuildZig(&arena, io);
    }

    try printDocs(arena.allocator(), options.symbols.items);
}

fn parseCli(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !CliOptions {
    var options: CliOptions = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(io);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--dump-imports")) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try dumpImports(&arena, io);
            std.process.exit(0);
        }

        if (options.symbols.items.len == 0 and std.mem.eql(u8, arg, "init")) {
            try initProject(allocator, io);
            std.process.exit(0);
        }

        if (options.symbols.items.len == 0 and std.mem.eql(u8, arg, "skill")) {
            try runSkillCommand(allocator, io, args);
            std.process.exit(0);
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }

        try QueryParser.parse(allocator, arg, &options.symbols);
    }
    return options;
}

fn joinSymbol(allocator: std.mem.Allocator, prefix: []const u8, part: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, part);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, part });
}

fn isStdSymbol(symbol: []const u8) bool {
    return std.mem.eql(u8, symbol, "std") or std.mem.startsWith(u8, symbol, "std.");
}

fn printUsage(io: std.Io) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.writeAll(
        \\Usage: zigdoc [options] <symbol>
        \\
        \\Show documentation for Zig standard library symbols and imported modules.
        \\
        \\zigdoc can access any module imported in your build.zig file, making it easy
        \\to view documentation for third-party dependencies alongside the standard library.
        \\
        \\Examples:
        \\  zigdoc std.ArrayList
        \\  zigdoc std.mem.Allocator
        \\  zigdoc std.http.Server
        \\  zigdoc 'std.multi_array_list.MultiArrayList.(insertBounded, appendAssumeCapacity, Slice.(get, set))'
        \\  zigdoc vaxis.Window
        \\  zigdoc zeit.timezone.Posix
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  --dump-imports    Dump module imports from build.zig as JSON
        \\
        \\Commands:
        \\  init              Initialize a new Zig project with AGENTS.md and skills
        \\  skill install     Install skills into .agents/skills
        \\
    );
    try stdout_writer.interface.flush();
}

fn runSkillCommand(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const subcommand = args.next() orelse {
        std.debug.print("Error: missing skill subcommand\nUsage: zigdoc skill install\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, subcommand, "install")) {
        std.debug.print("Error: unknown skill subcommand: {s}\nUsage: zigdoc skill install\n", .{subcommand});
        std.process.exit(1);
    }

    if (args.next()) |extra| {
        std.debug.print("Error: unexpected argument for 'skill install': {s}\nUsage: zigdoc skill install\n", .{extra});
        std.process.exit(1);
    }

    try installSkills(allocator, io, std.Io.Dir.cwd());
    std.debug.print("Installed skills into .agents/skills\n", .{});
}

fn initProject(allocator: std.mem.Allocator, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();

    // Check if project already exists
    if (cwd.access(io, "build.zig", .{})) |_| {
        std.debug.print("Error: build.zig already exists\n", .{});
        return error.ProjectExists;
    } else |_| {}

    // Get project name from current directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path_len = try std.process.currentPath(io, &path_buf);
    const cwd_path = path_buf[0..cwd_path_len];
    const name = std.fs.path.basename(cwd_path);

    // Create src directory
    try cwd.createDir(io, "src", .default_dir);

    // Write files with substitutions
    try cwd.writeFile(io, .{
        .sub_path = "build.zig",
        .data = try substitute(allocator, template_build_zig, name),
    });
    try cwd.writeFile(io, .{
        .sub_path = "build.zig.zon",
        .data = try substitute(allocator, template_build_zig_zon, name),
    });
    try cwd.writeFile(io, .{ .sub_path = "src/main.zig", .data = template_main_zig });
    try cwd.writeFile(io, .{ .sub_path = "AGENTS.md", .data = template_agents_md });
    try cwd.writeFile(io, .{ .sub_path = ".gitignore", .data = template_gitignore });
    try installSkills(allocator, io, cwd);

    // Run zig build to get suggested fingerprint from error message
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build" },
    }) catch {
        std.debug.print("Initialized Zig project '{s}' with .agents/skills (run 'zig build' to generate fingerprint)\n", .{name});
        return;
    };

    // Parse fingerprint from error: "suggested value: 0x..."
    if (std.mem.indexOf(u8, result.stderr, "suggested value: ")) |start| {
        const fp_start = start + "suggested value: ".len;
        const fp_end = std.mem.indexOfPos(u8, result.stderr, fp_start, "\n") orelse result.stderr.len;
        const fingerprint = result.stderr[fp_start..fp_end];

        // Read current build.zig.zon and insert fingerprint
        const zon_content = try cwd.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024));
        const new_zon = try std.mem.replaceOwned(
            u8,
            allocator,
            zon_content,
            ".version = \"0.0.0\",",
            try std.fmt.allocPrint(allocator, ".version = \"0.0.0\",\n    .fingerprint = {s},", .{fingerprint}),
        );
        try cwd.writeFile(io, .{ .sub_path = "build.zig.zon", .data = new_zon });
    }

    std.debug.print("Initialized Zig project '{s}' with .agents/skills\n", .{name});
}

fn installSkills(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    deleteTreeIfExists(cwd, io, skills_temp_root);
    defer cwd.deleteTree(io, skills_temp_root) catch {};

    try cwd.createDirPath(io, skills_extract_path);
    try cwd.createDirPath(io, skills_dest_root);

    try runRequiredCommand(allocator, io, &.{
        "curl",
        "--fail",
        "--location",
        "--silent",
        "--show-error",
        "--output",
        skills_zip_path,
        skills_archive_url,
    }, "download skills archive");

    try runRequiredCommand(allocator, io, &.{
        "unzip",
        "-q",
        skills_zip_path,
        "-d",
        skills_extract_path,
    }, "extract skills archive");

    try installExtractedSkills(allocator, io, cwd);
}

fn installExtractedSkills(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    var source_dir = try cwd.openDir(io, skills_source_root, .{
        .access_sub_paths = true,
        .iterate = true,
    });
    defer source_dir.close(io);

    var it = source_dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .file, .sym_link => {},
            else => continue,
        }

        const source_path = try std.fs.path.join(allocator, &.{ skills_source_root, entry.name });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &.{ skills_dest_root, entry.name });
        defer allocator.free(dest_path);

        deleteTreeIfExists(cwd, io, dest_path);
        try cwd.rename(source_path, cwd, dest_path, io);
    }
}

fn deleteTreeIfExists(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) void {
    dir.deleteTree(io, sub_path) catch {};
}

fn runRequiredCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    step: []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    if (result.term == .exited and result.term.exited == 0) return;

    std.debug.print("Error: failed to {s}\n", .{step});
    if (result.stderr.len > 0) std.debug.print("{s}\n", .{result.stderr});
    if (result.stdout.len > 0) std.debug.print("{s}\n", .{result.stdout});
    return error.CommandFailed;
}

fn substitute(allocator: std.mem.Allocator, template: []const u8, name: []const u8) ![]const u8 {
    const sanitized = try sanitizeProjectName(allocator, name);
    defer allocator.free(sanitized);
    return std.mem.replaceOwned(u8, allocator, template, "{{name}}", sanitized);
}

fn sanitizeProjectName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (name.len == 0 or !isZigIdentifierStart(sanitizedNameByte(name[0]))) {
        try out.appendSlice(allocator, "project");
    }

    for (name) |byte| {
        try out.append(allocator, sanitizedNameByte(byte));
    }

    return try out.toOwnedSlice(allocator);
}

fn sanitizedNameByte(byte: u8) u8 {
    if (std.ascii.isAlphanumeric(byte) or byte == '_') return byte;
    return '_';
}

fn isZigIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn dumpImports(arena: *std.heap.ArenaAllocator, io: std.Io) !void {
    // Check if build.zig exists
    std.Io.Dir.cwd().access(io, "build.zig", .{}) catch {
        std.debug.print("No build.zig found in current directory\n", .{});
        return error.NoBuildZig;
    };

    // Setup the build runner
    try setupBuildRunner(arena, io);

    // Run zig build with our custom runner
    const result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{
            "zig",
            "build",
            "--build-runner",
            ".zig-cache/zigdoc_build_runner.zig",
        },
    });

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Error running build runner:\n{s}\n", .{result.stderr});
        return error.BuildRunnerFailed;
    }

    // Print the JSON output directly
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.writeAll(result.stdout);
    try stdout_writer.interface.flush();
}

const ZigEnv = struct {
    std_dir: []const u8,
};

fn getZigVersion(arena: *std.heap.ArenaAllocator, io: std.Io) !std.SemanticVersion {
    const version_result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{ "zig", "version" },
    });

    if (version_result.term != .exited or version_result.term.exited != 0) {
        return error.ZigVersionFailed;
    }

    const version_str = std.mem.trim(u8, version_result.stdout, &std.ascii.whitespace);
    return std.SemanticVersion.parse(version_str);
}

fn setupBuildRunner(arena: *std.heap.ArenaAllocator, io: std.Io) !void {
    const version = try getZigVersion(arena, io);
    if (version.major != 0 or version.minor != 16) {
        std.debug.print(
            "zigdoc supports Zig 0.16.x build.zig analysis; found {d}.{d}.{d}\n",
            .{ version.major, version.minor, version.patch },
        );
        return error.UnsupportedZigVersion;
    }

    std.Io.Dir.cwd().createDir(io, ".zig-cache", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const runner_path = ".zig-cache/zigdoc_build_runner.zig";
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = runner_path,
        .data = build_runner,
    });
}

fn processBuildZig(arena: *std.heap.ArenaAllocator, io: std.Io) !void {
    // Check if build.zig exists
    std.Io.Dir.cwd().access(io, "build.zig", .{}) catch {
        // No build.zig, nothing to do
        return;
    };

    // Setup the build runner
    try setupBuildRunner(arena, io);

    // Run zig build with our custom runner
    const result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{
            "zig",
            "build",
            "--build-runner",
            ".zig-cache/zigdoc_build_runner.zig",
        },
    });

    if (result.term != .exited or result.term.exited != 0) {
        log.err("Failed to analyze build.zig", .{});
        return;
    }

    // Parse the output to extract module information
    try parseBuildOutput(arena.allocator(), io, result.stdout);
}

fn parseBuildOutput(allocator: std.mem.Allocator, io: std.Io, output: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const modules_obj = root_obj.get("modules") orelse return;

    var modules_iter = modules_obj.object.iterator();
    while (modules_iter.next()) |entry| {
        const module_name = entry.key_ptr.*;
        const module_data = entry.value_ptr.*.object;

        const root_path = blk: {
            const root_val = module_data.get("root") orelse continue;
            break :blk root_val.string;
        };

        // Skip non-Zig files (fonts, images, etc.)
        if (!std.mem.endsWith(u8, root_path, ".zig")) continue;

        // Read and add the module file
        const file_content = std.Io.Dir.cwd().readFileAlloc(
            io,
            root_path,
            allocator,
            .limited(10 * 1024 * 1024),
        ) catch |err| {
            std.debug.print("Failed to read module {s}: {}\n", .{ module_name, err });
            continue;
        };

        const file_index = try Walk.addFile(root_path, file_content);
        try Walk.modules.put(allocator, module_name, file_index);

        // Handle imports if present
        if (module_data.get("imports")) |imports_obj| {
            var imports_iter = imports_obj.object.iterator();
            while (imports_iter.next()) |import_entry| {
                const import_name = import_entry.key_ptr.*;
                const import_path = import_entry.value_ptr.*.string;

                // Skip non-Zig files (fonts, images, etc.)
                if (!std.mem.endsWith(u8, import_path, ".zig")) continue;

                // Read and add the imported file
                const import_content = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    import_path,
                    allocator,
                    .limited(10 * 1024 * 1024),
                ) catch |err| {
                    std.debug.print("Failed to read import {s}: {}\n", .{ import_name, err });
                    continue;
                };

                const import_file_index = try Walk.addFile(import_path, import_content);
                try Walk.modules.put(allocator, import_name, import_file_index);
            }
        }
    }
}

fn getStdDir(arena: *std.heap.ArenaAllocator, io: std.Io) ![]const u8 {
    const version = try getZigVersion(arena, io);

    const is_pre_0_15 = version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt;

    const result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{ "zig", "env" },
    });

    if (result.term != .exited or result.term.exited != 0) {
        return error.ZigEnvFailed;
    }

    const stdout = try arena.allocator().dupeZ(u8, result.stdout);

    if (is_pre_0_15) {
        const parsed = try std.json.parseFromSlice(
            ZigEnv,
            arena.allocator(),
            stdout,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.value.std_dir;
    } else {
        const parsed = try std.zon.parse.fromSliceAlloc(
            ZigEnv,
            arena.allocator(),
            stdout,
            null,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.std_dir;
    }
}

fn walkStdLib(arena: *std.heap.ArenaAllocator, io: std.Io, std_dir_path: []const u8) !void {
    const allocator = arena.allocator();
    var dir = try std.Io.Dir.openDirAbsolute(io, std_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, "test.zig")) continue;

        const file_content = try entry.dir.readFileAlloc(
            io,
            entry.basename,
            allocator,
            .limited(10 * 1024 * 1024),
        );

        const file_name = try std.fmt.allocPrint(allocator, "std/{s}", .{entry.path});

        _ = try Walk.addFile(file_name, file_content);
    }
}

fn resolveHierarchical(allocator: std.mem.Allocator, symbol: []const u8) !?Walk.Decl.Index {
    var parts = std.mem.splitScalar(u8, symbol, '.');
    const first_part = parts.next() orelse return null;

    // Find the root declaration
    var current_decl: ?Walk.Decl.Index = null;
    var fqn_buf: std.ArrayList(u8) = .empty;
    defer fqn_buf.deinit(allocator);
    for (Walk.decls.items, 0..) |*decl, i| {
        const info = decl.extraInfo();
        if (!info.is_pub) continue;

        fqn_buf.clearRetainingCapacity();
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, first_part)) {
            current_decl = @enumFromInt(i);
            break;
        }
    }

    if (current_decl == null) return null;

    // Walk through the remaining parts
    while (parts.next()) |part| {
        // Follow aliases with circular reference protection
        var search_decl = current_decl.?;
        var category = search_decl.get().categorize();
        var hop_count: usize = 0;
        while (category == .alias) {
            hop_count += 1;
            if (hop_count >= 64) {
                log.err("Circular alias detected resolving '{s}'", .{symbol});
                return error.CircularAlias;
            }
            search_decl = category.alias;
            category = search_decl.get().categorize();
        }

        // Find child with matching name
        var found = false;
        for (Walk.decls.items, 0..) |*candidate, i| {
            if (candidate.parent != .none and @intFromEnum(candidate.parent) == @intFromEnum(search_decl)) {
                const member_info = candidate.extraInfo();
                if (!member_info.is_pub) continue;
                if (std.mem.eql(u8, member_info.name, part)) {
                    current_decl = @enumFromInt(i);
                    found = true;
                    break;
                }
            }
        }

        if (!found) return null;
    }

    return current_decl;
}

fn printDocs(allocator: std.mem.Allocator, symbols: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var docs: std.ArrayList(SymbolDoc) = .empty;
    defer docs.deinit(allocator);

    for (symbols) |symbol| {
        const decl_index = try findSymbol(allocator, symbol) orelse {
            try printNotFound(allocator, stdout, symbol);
            try stdout.flush();
            std.process.exit(1);
        };
        try docs.append(allocator, try buildSymbolDoc(allocator, symbol, decl_index));
    }

    try renderDocs(allocator, stdout, docs.items);

    try stdout.flush();
}

fn findSymbol(allocator: std.mem.Allocator, symbol: []const u8) !?Walk.Decl.Index {
    if (std.mem.indexOf(u8, symbol, ".")) |_| {
        if (try resolveHierarchical(allocator, symbol)) |decl_index| return decl_index;
    }

    var fqn_buf: std.ArrayList(u8) = .empty;
    defer fqn_buf.deinit(allocator);
    for (Walk.decls.items, 0..) |*decl, i| {
        const file_path = decl.file.path();
        if (file_path.len == 0) continue;

        const ast = decl.file.getAst();
        if (ast.source.len == 0) continue;

        const info = decl.extraInfo();
        if (!info.is_pub) continue;

        fqn_buf.clearRetainingCapacity();
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, symbol)) return @enumFromInt(i);
    }

    return null;
}

fn buildSymbolDoc(allocator: std.mem.Allocator, symbol: []const u8, decl_index: Walk.Decl.Index) !SymbolDoc {
    const target_index, const category = try resolveAliasTarget(decl_index);
    const target_decl = target_index.get();
    return .{
        .query = symbol,
        .decl_index = decl_index,
        .target_index = target_index,
        .category = category,
        .file_path = target_decl.file.path(),
        .line = declLine(target_decl),
        .signature = try formatSignature(allocator, target_decl.file.getAst(), target_decl, category),
    };
}

fn resolveAliasTarget(decl_index: Walk.Decl.Index) !struct { Walk.Decl.Index, Walk.Category } {
    var target_index = decl_index;
    var category = target_index.get().categorize();
    var hop_count: usize = 0;
    while (category == .alias) {
        hop_count += 1;
        if (hop_count >= 64) return error.CircularAlias;
        target_index = category.alias;
        category = target_index.get().categorize();
    }
    return .{ target_index, category };
}

fn declLine(decl: *const Walk.Decl) usize {
    const ast = decl.file.getAst();
    const token_starts = ast.tokens.items(.start);
    const main_token = ast.nodeMainToken(decl.ast_node);
    const byte_offset = token_starts[main_token];
    const loc = std.zig.findLineColumn(ast.source, byte_offset);
    return loc.line + 1;
}

fn renderDocs(allocator: std.mem.Allocator, writer: anytype, docs: []const SymbolDoc) !void {
    for (docs, 0..) |doc, i| {
        if (i > 0) try writer.writeByte('\n');
        try renderDocItem(allocator, writer, doc);
    }

    try writer.writeAll("\nhint: use cx with the shown file and line to inspect source\n");
}

fn renderDocItem(allocator: std.mem.Allocator, writer: anytype, doc: SymbolDoc) !void {
    try writer.print("{s} at {s}:{d}\n", .{ doc.query, doc.file_path, doc.line });
    try renderDocBlock(writer, doc, 2);

    if (doc.target_index != doc.decl_index) {
        var target_fqn: std.ArrayList(u8) = .empty;
        defer target_fqn.deinit(allocator);
        try doc.target_index.get().fqn(&target_fqn);
        try writer.print("  alias target: {s}\n", .{target_fqn.items});
    }

    const has_members = try printMembers(allocator, writer, doc.target_index.get(), doc.category);
    if (doc.category == .type_function and !has_members) {
        try writer.writeAll("\nsource:\n");
        try printSource(writer, doc.target_index.get().file.getAst(), doc.target_index.get().ast_node);
    }
}

fn renderDocBlock(writer: anytype, doc: SymbolDoc, indent: usize) !void {
    if (doc.signature.len > 0) {
        try writeIndent(writer, indent);
        const label = switch (doc.category) {
            .function, .type_function => "sig",
            .global_const, .global_variable => "decl",
            .container, .namespace => "type",
            else => "info",
        };
        try writer.print("{s}: {s}\n", .{ label, doc.signature });
    }

    if (hasDocComment(doc)) {
        try writeIndent(writer, indent);
        try writer.writeAll("docs:\n");
        try renderIndentedDocComments(writer, doc, indent + 2);
    }
}

fn printNotFound(allocator: std.mem.Allocator, writer: anytype, symbol: []const u8) !void {
    try writer.writeAll("Symbol not found: ");
    try writer.print("'{s}'\n\n", .{symbol});

    var parts = std.mem.splitScalar(u8, symbol, '.');
    const first_part = parts.next() orelse {
        try writer.writeAll("Tip: Specify a symbol like 'std.ArrayList' or 'moduleName.Symbol'\n");
        return;
    };

    const module_exists = blk: {
        var fqn_buf: std.ArrayList(u8) = .empty;
        defer fqn_buf.deinit(allocator);
        for (Walk.decls.items) |*decl| {
            fqn_buf.clearRetainingCapacity();
            try decl.fqn(&fqn_buf);
            if (std.mem.eql(u8, fqn_buf.items, first_part)) break :blk true;
        }
        break :blk false;
    };

    if (!module_exists) {
        try writer.print("Module '{s}' not found.\n", .{first_part});
        if (Walk.modules.count() > 0) {
            try writer.writeAll("\nAvailable modules:\n");
            var iter = Walk.modules.iterator();
            while (iter.next()) |entry| {
                try writer.print("  {s}\n", .{entry.key_ptr.*});
            }
        }
    } else {
        try writer.print("Module '{s}' found, but could not find symbol '{s}'.\n", .{ first_part, symbol });
        try writer.writeAll("Possible reasons:\n");
        try writer.writeAll("  - The symbol is private (not marked with 'pub')\n");
        try writer.writeAll("  - The symbol name is misspelled\n");
        try writer.writeAll("  - The symbol is nested deeper than specified\n");
    }
}

fn printMembers(allocator: std.mem.Allocator, writer: anytype, decl: *const Walk.Decl, category: Walk.Category) !bool {
    switch (category) {
        .type_function, .namespace, .container => {
            var functions: std.ArrayList(Walk.Decl.Index) = .empty;
            defer functions.deinit(allocator);
            var type_functions: std.ArrayList(Walk.Decl.Index) = .empty;
            defer type_functions.deinit(allocator);
            var constants: std.ArrayList(Walk.Decl.Index) = .empty;
            defer constants.deinit(allocator);
            var types: std.ArrayList(Walk.Decl.Index) = .empty;
            defer types.deinit(allocator);

            const FieldInfo = struct {
                name: []const u8,
                type_str: []const u8,
                line: usize,
                doc_comment: ?std.zig.Ast.TokenIndex,
            };
            var fields: std.ArrayList(FieldInfo) = .empty;
            defer fields.deinit(allocator);

            const ast = decl.file.getAst();

            if (category == .container) {
                const node = category.container;
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buffer, node)) |container_decl| {
                    for (container_decl.ast.members) |member| {
                        if (ast.fullContainerField(member)) |field| {
                            const name_token = field.ast.main_token;
                            if (ast.tokenTag(name_token) == .identifier) {
                                const field_name = ast.tokenSlice(name_token);

                                const type_str = if (field.ast.type_expr.unwrap()) |type_expr| blk: {
                                    const start_token = ast.firstToken(type_expr);
                                    const end_token = ast.lastToken(type_expr);
                                    const token_starts = ast.tokens.items(.start);
                                    const start_offset = token_starts[start_token];
                                    const end_offset = if (end_token + 1 < ast.tokens.len)
                                        token_starts[end_token + 1]
                                    else
                                        ast.source.len;
                                    break :blk std.mem.trim(
                                        u8,
                                        ast.source[start_offset..end_offset],
                                        &std.ascii.whitespace,
                                    );
                                } else "";

                                const first_doc = Walk.Decl.findFirstDocComment(ast, field.firstToken());

                                try fields.append(allocator, .{
                                    .name = field_name,
                                    .type_str = type_str,
                                    .line = lineForToken(ast, field.firstToken()),
                                    .doc_comment = first_doc.unwrap(),
                                });
                            }
                        }
                    }
                }
            }

            // Collect public members
            // Note: We iterate by index because calling categorize() can trigger file loading
            // which appends to Walk.decls.items, invalidating slice references
            var i: usize = 0;
            // Find the index of the target decl to avoid pointer comparison issues
            // (pointers can become invalid when Walk.decls.items is reallocated)
            const target_decl_idx: usize = blk: {
                for (Walk.decls.items, 0..) |*d, idx| {
                    if (d == decl) break :blk idx;
                }
                return false; // decl not found; nothing to print
            };

            while (i < Walk.decls.items.len) : (i += 1) {
                const candidate = &Walk.decls.items[i];
                // Validate parent index before using it
                if (candidate.parent != .none) {
                    const pidx = @intFromEnum(candidate.parent);
                    if (pidx >= Walk.decls.items.len) {
                        continue; // Skip invalid parent
                    }
                    // Compare parent index instead of pointer to avoid stale pointer issues
                    if (pidx != target_decl_idx) {
                        continue;
                    }
                } else {
                    continue; // No parent
                }

                const member_info = candidate.extraInfo();
                if (!member_info.is_pub) continue;
                if (member_info.name.len == 0) continue;

                const member_cat = candidate.categorize();
                const member_index: Walk.Decl.Index = @enumFromInt(i);
                switch (member_cat) {
                    .function => try functions.append(allocator, member_index),
                    .type_function => try type_functions.append(allocator, member_index),
                    .namespace, .container => try types.append(allocator, member_index),
                    .alias => |alias_index| {
                        // Follow alias chain to get the final category
                        // Guard against invalid alias indices
                        const idx = @intFromEnum(alias_index);
                        if (alias_index == .none or idx >= Walk.decls.items.len) {
                            // Invalid alias, treat as constant
                            try constants.append(allocator, member_index);
                            continue;
                        }

                        var resolved_index = alias_index;
                        var hops: usize = 0;
                        var resolved_cat = resolved_index.get().categorize();
                        while (resolved_cat == .alias and hops < 64) : (hops += 1) {
                            const next_index = resolved_cat.alias;
                            const next_idx = @intFromEnum(next_index);
                            if (next_index == .none or next_idx >= Walk.decls.items.len) break;
                            resolved_index = next_index;
                            resolved_cat = resolved_index.get().categorize();
                        }
                        switch (resolved_cat) {
                            .namespace, .container => try types.append(allocator, member_index),
                            .function => try functions.append(allocator, member_index),
                            .type_function => try type_functions.append(allocator, member_index),
                            else => try constants.append(allocator, member_index),
                        }
                    },
                    .global_const, .global_variable => try constants.append(allocator, member_index),
                    else => {},
                }
            }

            var has_members = false;

            if (fields.items.len > 0) {
                try writer.writeAll("\nfields:\n");
                for (fields.items) |field| {
                    try writer.print("  {s} (ln:{d}):\n", .{ field.name, field.line });
                    if (field.type_str.len > 0) {
                        try writer.print("    type: {s}\n", .{field.type_str});
                    }
                    if (field.doc_comment) |first_doc| {
                        if (ast.tokenTag(first_doc) == .doc_comment) {
                            try writer.writeAll("    docs:\n");
                            try writeDocLines(writer, ast, first_doc, .doc_comment, 6);
                        }
                    }
                }
                has_members = true;
            }

            has_members = try renderMemberSection(allocator, writer, "type_functions", type_functions.items) or has_members;
            has_members = try renderMemberSection(allocator, writer, "types", types.items) or has_members;
            has_members = try renderMemberSection(allocator, writer, "functions", functions.items) or has_members;
            has_members = try renderMemberSection(allocator, writer, "constants", constants.items) or has_members;

            if (has_members) {
                try writer.writeAll("\n");
            }

            return has_members;
        },
        else => return false,
    }
}

fn renderMemberSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    section_name: []const u8,
    members: []const Walk.Decl.Index,
) !bool {
    if (members.len == 0) return false;

    try writer.print("\n{s}:\n", .{section_name});
    for (members) |member_index| {
        try renderMemberDoc(allocator, writer, member_index);
    }

    return true;
}

fn renderMemberDoc(allocator: std.mem.Allocator, writer: anytype, decl_index: Walk.Decl.Index) !void {
    const decl = decl_index.get();
    const info = decl.extraInfo();
    const target_index, const category = try resolveAliasTarget(decl_index);
    const target_decl = target_index.get();
    const member_doc: SymbolDoc = .{
        .query = info.name,
        .decl_index = decl_index,
        .target_index = target_index,
        .category = category,
        .file_path = target_decl.file.path(),
        .line = declLine(target_decl),
        .signature = try formatSignature(allocator, target_decl.file.getAst(), target_decl, category),
    };

    try writer.print("  {s} (ln:{d}):\n", .{ info.name, member_doc.line });
    try renderDocBlock(writer, member_doc, 4);
}

fn lineForToken(ast: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) usize {
    const token_starts = ast.tokens.items(.start);
    const loc = std.zig.findLineColumn(ast.source, token_starts[token]);
    return loc.line + 1;
}

fn formatSignature(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    decl: *const Walk.Decl,
    category: Walk.Category,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writeSignatureValue(allocator, &writer.writer, ast, decl, category);
    return try writer.toOwnedSlice();
}

fn writeSignatureValue(
    allocator: std.mem.Allocator,
    writer: anytype,
    ast: *const std.zig.Ast,
    _: *const Walk.Decl,
    category: Walk.Category,
) !void {
    switch (category) {
        .function, .type_function => |node| {
            var buf: [1]std.zig.Ast.Node.Index = undefined;
            const fn_proto = ast.fullFnProto(&buf, node) orelse return;

            const start_token = fn_proto.lparen;
            const end_token = if (fn_proto.ast.return_type.unwrap()) |return_type|
                ast.lastToken(return_type)
            else
                findClosingParen(ast, fn_proto.lparen);
            const source = sourceForTokenRange(ast, start_token, end_token);
            try writeCleanedSignature(allocator, writer, source);
        },
        .global_const, .global_variable => |node| {
            const var_decl = ast.fullVarDecl(node) orelse return;
            const start_token = var_decl.firstToken();
            const end_token = ast.lastToken(node);
            const source = sourceForTokenRange(ast, start_token, end_token);
            try writeCollapsedWhitespace(allocator, writer, source);
        },
        .container => |node| {
            if (ast.nodeTag(node) == .root) {
                try writer.writeAll("struct (file root)");
            } else {
                const main_token = ast.nodeMainToken(node);
                const container_kind = ast.tokenSlice(main_token);
                try writer.print("{s}", .{container_kind});
            }
        },
        .namespace => |node| {
            if (ast.nodeTag(node) == .root) {
                try writer.writeAll("namespace (file root)");
            } else {
                try writer.writeAll("namespace (struct)");
            }
        },
        else => {},
    }
}

fn findClosingParen(ast: *const std.zig.Ast, lparen: std.zig.Ast.TokenIndex) std.zig.Ast.TokenIndex {
    var depth: usize = 0;
    var token_idx = lparen;
    while (token_idx < ast.tokens.len) : (token_idx += 1) {
        switch (ast.tokenTag(token_idx)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return token_idx;
            },
            else => {},
        }
    }
    return lparen;
}

fn sourceForTokenRange(
    ast: *const std.zig.Ast,
    start_token: std.zig.Ast.TokenIndex,
    end_token: std.zig.Ast.TokenIndex,
) []const u8 {
    const token_starts = ast.tokens.items(.start);
    const start_offset = token_starts[start_token];
    const end_offset = if (end_token + 1 < ast.tokens.len)
        token_starts[end_token + 1]
    else
        ast.source.len;
    return std.mem.trim(u8, ast.source[start_offset..end_offset], &std.ascii.whitespace);
}

fn writeCollapsedWhitespace(allocator: std.mem.Allocator, writer: anytype, source: []const u8) !void {
    _ = allocator;
    var previous_space = false;
    for (source) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) try writer.writeByte(' ');
            previous_space = true;
        } else {
            try writer.writeByte(byte);
            previous_space = false;
        }
    }
}

fn writeCleanedSignature(allocator: std.mem.Allocator, writer: anytype, source: []const u8) !void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "///")) continue;

        if (joined.items.len > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, trimmed);
    }

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);

    var pending_space = false;
    for (joined.items) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = true;
            continue;
        }

        if (byte == ')' and
            normalized.items.len > 0 and
            normalized.items[normalized.items.len - 1] == ',')
        {
            normalized.items.len -= 1;
        }

        if (pending_space and normalized.items.len > 0) {
            const previous = normalized.items[normalized.items.len - 1];
            if (!suppressesSpaceAfter(previous) and !suppressesSpaceBefore(byte)) {
                try normalized.append(allocator, ' ');
            }
        }

        try normalized.append(allocator, byte);
        pending_space = false;
    }

    try writer.writeAll(normalized.items);
}

fn suppressesSpaceAfter(byte: u8) bool {
    return switch (byte) {
        '(', '[', '.', '!' => true,
        else => false,
    };
}

fn suppressesSpaceBefore(byte: u8) bool {
    return switch (byte) {
        ')', ']', ',', '.', '!', ':' => true,
        else => false,
    };
}

fn hasDocComment(doc: SymbolDoc) bool {
    const decl = doc.decl_index.get();
    const target_decl = doc.target_index.get();
    const target_ast = target_decl.file.getAst();
    const target_info = target_decl.extraInfo();
    if (target_ast.nodeTag(target_decl.ast_node) == .root) {
        return hasDocToken(target_ast, target_info.first_doc_comment.unwrap(), .container_doc_comment);
    }
    return hasDocToken(decl.file.getAst(), decl.extraInfo().first_doc_comment.unwrap(), .doc_comment) or
        hasDocToken(target_ast, target_info.first_doc_comment.unwrap(), .doc_comment);
}

fn hasDocToken(ast: *const std.zig.Ast, maybe_token: ?std.zig.Ast.TokenIndex, tag: std.zig.Token.Tag) bool {
    const token = maybe_token orelse return false;
    return ast.tokenTag(token) == tag;
}

fn renderIndentedDocComments(writer: anytype, doc: SymbolDoc, indent: usize) !void {
    const decl = doc.decl_index.get();
    const target_decl = doc.target_index.get();
    const ast = decl.file.getAst();
    const target_ast = target_decl.file.getAst();
    const target_info = target_decl.extraInfo();

    if (target_ast.nodeTag(target_decl.ast_node) == .root) {
        if (target_info.first_doc_comment.unwrap()) |target_first_doc| {
            try writeDocLines(writer, target_ast, target_first_doc, .container_doc_comment, indent);
        }
        return;
    }

    if (decl.extraInfo().first_doc_comment.unwrap()) |first_doc_comment| {
        try writeDocLines(writer, ast, first_doc_comment, .doc_comment, indent);
    } else if (target_info.first_doc_comment.unwrap()) |target_first_doc| {
        try writeDocLines(writer, target_ast, target_first_doc, .doc_comment, indent);
    }
}

fn writeDocLines(
    writer: anytype,
    ast: *const std.zig.Ast,
    first_token: std.zig.Ast.TokenIndex,
    tag: std.zig.Token.Tag,
    indent: usize,
) !void {
    var token_index = first_token;
    while (ast.tokenTag(token_index) == tag) : (token_index += 1) {
        const comment = ast.tokenSlice(token_index);
        try writeIndent(writer, indent);
        try writer.print("{s}\n", .{std.mem.trimStart(u8, comment[3..], " ")});
    }
}

fn writeIndent(writer: anytype, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try writer.writeByte(' ');
}

fn printSource(writer: anytype, ast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) !void {
    const token_starts = ast.tokens.items(.start);
    const start_token = ast.firstToken(node);
    const end_token = ast.lastToken(node);

    const start_offset = token_starts[start_token];
    const end_offset = if (end_token + 1 < ast.tokens.len)
        token_starts[end_token + 1]
    else
        ast.source.len;

    const source_text = ast.source[start_offset..end_offset];

    // Print each line with indentation
    var lines = std.mem.splitScalar(u8, source_text, '\n');
    while (lines.next()) |line| {
        try writer.print("  {s}\n", .{line});
    }
}

test "signature cleaner strips docs and preserves Zig punctuation" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try writeCleanedSignature(std.testing.allocator, &writer.writer,
        \\(
        \\    /// doc comment inside a multi-line function signature
        \\    self: Allocator,
        \\    comptime optional_alignment: ?Alignment,
        \\    comptime sentinel: Elem,
        \\) Error![:sentinel]Elem
    );

    try std.testing.expectEqualStrings(
        "(self: Allocator, comptime optional_alignment: ?Alignment, comptime sentinel: Elem) Error![:sentinel]Elem",
        writer.written(),
    );
}

test "project name sanitizer produces zon-safe identifiers" {
    const allocator = std.testing.allocator;

    const dotted = try sanitizeProjectName(allocator, "zigdoc-build-template.UARNlX");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("zigdoc_build_template_UARNlX", dotted);

    const leading_digit = try sanitizeProjectName(allocator, "123-app");
    defer allocator.free(leading_digit);
    try std.testing.expectEqualStrings("project123_app", leading_digit);
}

test "query parser expands nested member groups" {
    const allocator = std.testing.allocator;
    var symbols: std.ArrayList([]const u8) = .empty;
    defer {
        for (symbols.items) |symbol| allocator.free(symbol);
        symbols.deinit(allocator);
    }

    try QueryParser.parse(
        allocator,
        "std.multi_array_list.MultiArrayList.(insertBounded, appendAssumeCapacity, Slice.(get, set))",
        &symbols,
    );

    try std.testing.expectEqual(@as(usize, 4), symbols.items.len);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.insertBounded", symbols.items[0]);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.appendAssumeCapacity", symbols.items[1]);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.Slice.get", symbols.items[2]);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.Slice.set", symbols.items[3]);
}

test "query parser rejects unbalanced groups" {
    var symbols: std.ArrayList([]const u8) = .empty;
    defer {
        for (symbols.items) |symbol| std.testing.allocator.free(symbol);
        symbols.deinit(std.testing.allocator);
    }

    try std.testing.expectError(
        error.InvalidQuery,
        QueryParser.parse(std.testing.allocator, "std.ArrayList.(init", &symbols),
    );
}

test {
    _ = @import("test_symbol_resolution.zig");
}
