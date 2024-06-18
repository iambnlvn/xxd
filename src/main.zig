const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const Config = struct {
    inputFile: ?[:0]const u8 = null,
    outputFile: ?[:0]const u8 = null,
    maxColChar: usize = 16,
    maxHexLineSize: usize = get_max_hex_line_size(16),
    reverse: bool = false,
    prettyPrint: bool = false,
};

const ArgsError = error{
    INVALID_CLI_ARGS,
    SHOW_HELP,
    NO_INPUT_FILE_SPECIFIED,
    NO_OUTPUT_FILE_SPECIFIED,
};

const CliFlags = enum {
    InputFileFlag,
    OutputFileFlag,
    ColumnSizeFlag,
    ReverseFlag,
    PrettyPrintFlag,
    ShowHelp,

    fn value(self: CliFlags) [:0]const u8 {
        return switch (self) {
            .InputFileFlag => "-i",
            .OutputFileFlag => "-o",
            .ColumnSizeFlag => "-c",
            .ReverseFlag => "-r",
            .PrettyPrintFlag => "-p",
            .ShowHelp => "-h",
        };
    }
};
// Playing around with enums
const Colors = enum {
    const GreenColor: [:0]const u8 = "\x1b[32m";
    const YellowColor: [:0]const u8 = "\x1b[33m";
    const ResetColor: [:0]const u8 = "\x1b[0m";
};

fn get_cli_args(allocator: Allocator) !Config {
    var argsIter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer argsIter.deinit();
    // skip the binary file as it is the first arg
    _ = argsIter.next();

    var config: Config = .{};

    while (argsIter.next()) |arg| {
        if (std.mem.eql(u8, CliFlags.InputFileFlag.value(), arg)) {
            config.inputFile = argsIter.next();
            if (config.inputFile == null) return ArgsError.NO_INPUT_FILE_SPECIFIED;
            continue;
        }

        if (std.mem.eql(u8, CliFlags.OutputFileFlag.value(), arg)) {
            config.outputFile = argsIter.next();
            if (config.outputFile == null) return ArgsError.NO_OUTPUT_FILE_SPECIFIED;
            continue;
        }

        if (std.mem.eql(u8, CliFlags.ColumnSizeFlag.value(), arg)) {
            config.maxColChar = try std.fmt.parseInt(usize, argsIter.next() orelse "", 10);
            config.maxHexLineSize = get_max_hex_line_size(config.maxColChar);
            continue;
        }

        if (std.mem.eql(u8, CliFlags.ReverseFlag.value(), arg)) {
            config.reverse = true;
            continue;
        }

        if (std.mem.eql(u8, CliFlags.PrettyPrintFlag.value(), arg)) {
            config.prettyPrint = true;
            continue;
        }

        if (std.mem.eql(u8, CliFlags.ShowHelp.value(), arg)) {
            return ArgsError.SHOW_HELP;
        }
    }

    return config;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = get_cli_args(allocator) catch |err| {
        if (err != ArgsError.SHOW_HELP) {
            std.log.err("error occured while reading cli args = {any}", .{err});
        }

        try show_help();
        return;
    };

    const in_file = get_input_reader(config.inputFile) catch |err| {
        std.log.err("error occured while preparing input stream = {any}", .{err});
        return;
    };
    defer in_file.close();

    const out_file = get_output_writer(config.outputFile) catch |err| {
        std.log.err("error occured while preparing output stream = {any}", .{err});
        return;
    };
    defer out_file.close();

    if (config.reverse) {
        reverse_hex_dump(in_file, out_file);
    } else {
        hex_dump(in_file, out_file, config, allocator);
    }
}

fn hex_dump(in: File, out: File, config: Config, allocator: Allocator) void {
    var hex_buf: [10:0]u8 = undefined; // 10 cause largest hex string => `{x:0>8}: `
    var should_read_next: bool = true;
    var line_no: usize = 0;
    var col_no: usize = 0;
    var chars_read: usize = 0;
    var hex_wrote: usize = 0;

    // Prepare the actual string to be appended to the output file
    var actual_str = allocator.alloc(u8, config.maxColChar) catch |err| {
        std.log.err("error occured while initializing buffer for actual string = {any}", .{err});
        return;
    };
    defer allocator.free(actual_str);

    while (should_read_next) outer_loop: {
        hex_wrote = 0;
        chars_read = 0;
        col_no = 0;

        (blk: {
            const line_hex_str = std.fmt.bufPrint(&hex_buf, "{x:0>8}: ", .{line_no}) catch |err| break :blk err;
            hex_wrote += out.write(line_hex_str) catch |err| break :blk err;
            line_no += 0x10;
        }) catch |err| {
            std.log.err("error occured while writing to output = {any}", .{err});
            return;
        };

        if (config.prettyPrint) {
            _ = out.write(Colors.GreenColor) catch |err| {
                std.log.err("error occured while printing Colors green = {any}", .{err});
                return;
            };
        }

        while (chars_read < config.maxColChar) : (chars_read += 1) {
            const maybe_char = file_next_char(in) catch |err| {
                std.log.err("error occured while reading from input file = {any}", .{err});
                return;
            };
            should_read_next = maybe_char != null;
            const char = maybe_char orelse break;

            const hex_str = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{char}) catch |err| {
                std.log.err("error occured while creating a hex buffer string = {any}", .{err});
                return;
            };

            (blk: {
                if (config.prettyPrint and (char == '\n' or char == '\r')) {
                    _ = out.write(Colors.YellowColor) catch |err| break :blk err;
                }

                hex_wrote += out.write(hex_str) catch |err| break :blk err;

                if (config.prettyPrint and (char == '\n' or char == '\r')) {
                    _ = out.write(Colors.GreenColor) catch |err| break :blk err;
                }
            }) catch |err| {
                std.log.err("error occured while writing to output = {any}", .{err});
                return;
            };

            if (chars_read % 2 != 0) {
                hex_wrote += out.write(" ") catch |err| {
                    std.log.err("error occurd while writing space after hex pair to output = {any}", .{err});
                    return;
                };
            }

            actual_str[chars_read] = if (char >= '!' and char <= '~') char else '.';
        }

        if (chars_read == 0) break :outer_loop;

        (blk: {
            const no_of_ws = 2 + config.maxHexLineSize - hex_wrote;
            for (0..no_of_ws) |_| _ = out.write(" ") catch |err| break :blk err;

            _ = out.write(actual_str[0..chars_read]) catch |err| break :blk err;
            if (config.prettyPrint) _ = out.write(Colors.ResetColor) catch |err| break :blk err;
            _ = out.write("\n") catch |err| break :blk err;
        }) catch |err| {
            std.log.err("error occured while writing to output = {any}", .{err});
            return;
        };
    }
}

fn reverse_hex_dump(in: File, out: File) void {
    var hex_str: [2:0]u8 = undefined;
    var out_buff: [1:0]u8 = undefined;
    var reading_hex = false;
    var line_done = false;

    while (file_next_char(in) catch null) |c| {
        var char = c;

        if (char == ':' and !line_done) {
            _ = file_next_char(in) catch |err| {
                std.log.err("error occured while trying to read ' ' after : = {any}", .{err});
                return;
            };
            reading_hex = true;
            continue;
        }

        if (char == '\n') {
            reading_hex = false;
            line_done = false; // reset line done for next line
            continue;
        }

        if (char == '\r') {
            char = (file_next_char(in) catch |err| {
                std.log.err("error occured while trying to read slash n after slash r = {any}", .{err});
                return;
            }) orelse continue;
            reading_hex = char != '\n';
            line_done = !(char == '\n');
        }

        if (char == ' ' and reading_hex) {
            char = (file_next_char(in) catch |err| {
                std.log.err("error occured while trying to read after ' ' = {any}", .{err});
                return;
            }) orelse continue;
            reading_hex = char != ' ';
            line_done = char == ' ';
        }

        if (!reading_hex) continue;

        const next_char = (file_next_char(in) catch |err| {
            std.log.err("error occured while trying to read the next charcter of hex = {any}", .{err});
            return;
        }) orelse continue;

        hex_str[0] = char;
        hex_str[1] = next_char;

        out_buff[0] = std.fmt.parseInt(u8, &hex_str, 16) catch |err| {
            std.log.err("error occured while trying to parse hex {s} to dec = {any}", .{ hex_str, err });
            return;
        };

        _ = out.write(&out_buff) catch |err| {
            std.log.err("error occured while trying to write to output = {any}", .{err});
            return;
        };
    }
}

fn get_input_reader(inputFile: ?([:0]const u8)) File.OpenError!File {
    const filename = inputFile orelse return std.io.getStdIn();
    return std.fs.cwd().openFile(filename, .{});
}

fn get_output_writer(out_file: ?([:0]const u8)) File.OpenError!File {
    const filename = out_file orelse return std.io.getStdOut();
    return std.fs.cwd().createFile(filename, .{});
}

fn file_next_char(file: File) !?u8 {
    var buf: [1:0]u8 = undefined;
    const r_size = try file.read(&buf);
    if (r_size == 0) return null;
    return buf[0];
}

fn get_max_hex_line_size(col_size: usize) usize {
    // 8 + 1 (:) + 1 (' ') + 2 * 16(max chars per column) + 16/2 (no. of space after each hex pair) - 1 (last space)
    const last_space: usize = if (col_size % 2 == 0) 1 else 0;
    return 10 + 2 * col_size + col_size / 2 - last_space;
}

const help_promot =
    \\Usage:
    \\      xxd [options]
    \\Options:
    \\      -i <file_name>          input file name
    \\      -o <file_name>          output file name
    \\      -c <col_size>           size of the column
    \\      -r                      reverse a hex dump to original
    \\      -p                      pretty print: colored hex. not compatible with -r
    \\      -h                      show this prompt
;

fn show_help() !void {
    const out = std.io.getStdOut();
    defer out.close();
    _ = try out.write(help_promot);
}
