const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    const exe_name = args.next() orelse "gen_readme";

    const help_file = args.next() orelse {
        std.debug.print("Usage: {s} <help-file> <output-file>\n", .{exe_name});
        return error.InvalidArgs;
    };
    const output_file = args.next() orelse {
        std.debug.print("Usage: {s} <help-file> <output-file>\n", .{exe_name});
        return error.InvalidArgs;
    };

    const cwd = std.Io.Dir.cwd();
    const help_content = try cwd.readFileAlloc(init.io, help_file, allocator, .limited(1024 * 1024));
    defer allocator.free(help_content);

    const readme = try std.fmt.allocPrint(allocator,
        \\# zigdoc
        \\
        \\A command-line tool to view documentation for Zig standard library symbols.
        \\
        \\## Installation
        \\
        \\```bash
        \\zig build install -Doptimize=ReleaseFast --prefix $HOME/.local
        \\```
        \\
        \\## Usage
        \\
        \\```
        \\{s}```
        \\
        \\## Project Initialization
        \\
        \\`zigdoc init` scaffolds a minimal Zig project with `AGENTS.md`,
        \\installs skills to `.agents/skills`, and creates `build.zig`
        \\plus `build.zig.zon`.
        \\
        \\Skill installation downloads the latest zigdoc repository archive, so
        \\`curl`, `unzip`, and network access are required.
        \\
        \\```bash
        \\mkdir my-project && cd my-project
        \\zigdoc init
        \\```
        \\
        \\## Skill Installation
        \\
        \\`zigdoc skill install` installs the repository skills into `.agents/skills`
        \\without creating or changing `build.zig`, `build.zig.zon`, or source files.
        \\
        \\```bash
        \\zigdoc skill install
        \\```
        \\
        \\## Examples
        \\
        \\```bash
        \\# Standard library symbols
        \\zigdoc std.ArrayList
        \\zigdoc std.mem.Allocator
        \\zigdoc std.http.Server
        \\
        \\# Imported modules from build.zig
        \\zigdoc zeit.timezone.Posix
        \\```
        \\
        \\## Features
        \\
        \\- View documentation for any public symbol in the Zig standard library
        \\- Access documentation for imported modules from your build.zig
        \\- Query multiple related symbols with grouped syntax like `std.Type.(a, b, Nested.(c, d))`
        \\- Shows symbol location, category, and signature
        \\- Displays doc comments, members, and member signatures/docs for type queries
        \\- Follows aliases to implementation
        \\
    , .{help_content});
    defer allocator.free(readme);

    try cwd.writeFile(init.io, .{ .sub_path = output_file, .data = readme });
}
