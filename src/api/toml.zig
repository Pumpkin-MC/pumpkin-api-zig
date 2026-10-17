//! A TOML 1.0 parser that reads into a `std.json.Value` tree, and a writer
//! that turns Zig values into TOML.
//!
//! Dates and times are read as strings in RFC 3339 form, with `T` between the
//! date and the time, so a config can keep them in `[]const u8` fields.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Error = error{ InvalidToml, OutOfMemory };

/// Where parsing stopped and why, filled in when `parse` fails.
pub const Diagnostics = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "",
};

/// Parses `text` into a tree of objects, arrays, strings, integers, floats
/// and booleans, allocated with `allocator`.
pub fn parse(allocator: Allocator, text: []const u8, diagnostics: *Diagnostics) Error!Value {
    var parser: Parser = .{ .allocator = allocator, .text = text, .diagnostics = diagnostics };
    if (!std.unicode.utf8ValidateSlice(text)) return parser.fail("the file isn't valid UTF-8");
    const root = try parser.newTable(.header);
    try parser.document(root);
    return toValue(allocator, .{ .table = root });
}

/// How a table came to be, which decides how it may be extended later.
const Origin = enum {
    /// Created as a parent of a `[a.b]` header. It may still get a header of its own.
    implicit,
    /// Defined by a `[header]` or as an element of `[[array]]`.
    header,
    /// Created by a dotted key such as `a.b = 1`.
    dotted,
    /// An inline table, which can't be extended at all.
    sealed,
    /// Created by a dotted key inside an inline table. Only further dotted
    /// keys in that same inline table can extend it.
    sealed_dotted,
};

fn isSealed(origin: Origin) bool {
    return origin == .sealed or origin == .sealed_dotted;
}

const Table = struct {
    origin: Origin,
    entries: std.StringArrayHashMapUnmanaged(Node) = .empty,
};

const Array = struct {
    /// Arrays of tables can be appended to by `[[headers]]`, array values can't.
    of_tables: bool,
    items: std.ArrayList(Node) = .empty,
};

/// Tables and arrays are allocated on their own so they stay in place while
/// their parents grow.
const Node = union(enum) {
    table: *Table,
    array: *Array,
    value: Value,
};

const Parser = struct {
    allocator: Allocator,
    text: []const u8,
    diagnostics: *Diagnostics,
    pos: usize = 0,

    fn fail(p: *Parser, message: []const u8) Error {
        var line: usize = 1;
        var column: usize = 1;
        for (p.text[0..@min(p.pos, p.text.len)]) |c| {
            if (c == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        p.diagnostics.* = .{ .line = line, .column = column, .message = message };
        return error.InvalidToml;
    }

    fn newTable(p: *Parser, origin: Origin) Error!*Table {
        const table = try p.allocator.create(Table);
        table.* = .{ .origin = origin };
        return table;
    }

    fn newArray(p: *Parser, of_tables: bool) Error!*Array {
        const array = try p.allocator.create(Array);
        array.* = .{ .of_tables = of_tables };
        return array;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn peekAt(p: *const Parser, offset: usize) ?u8 {
        return if (p.pos + offset < p.text.len) p.text[p.pos + offset] else null;
    }

    fn startsWith(p: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.text[p.pos..], s);
    }

    fn skipSpaces(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') return;
            p.pos += 1;
        }
    }

    /// Reads a line break, LF or CRLF, if there is one.
    fn newline(p: *Parser) Error!bool {
        if (p.peek() == '\n') {
            p.pos += 1;
            return true;
        }
        if (p.peek() == '\r') {
            if (p.peekAt(1) != '\n') return p.fail("a carriage return has to be followed by a line feed");
            p.pos += 2;
            return true;
        }
        return false;
    }

    /// Reads a comment up to the end of its line, if there is one.
    fn comment(p: *Parser) Error!void {
        if (p.peek() != '#') return;
        p.pos += 1;
        while (p.peek()) |c| {
            if (c == '\n' or c == '\r') return;
            if (isControl(c)) return p.fail("comments can't contain control characters");
            p.pos += 1;
        }
    }

    /// Skips spaces, comments and line breaks, as allowed between statements
    /// and inside arrays.
    fn skipBlank(p: *Parser) Error!void {
        while (true) {
            p.skipSpaces();
            try p.comment();
            if (!try p.newline()) return;
        }
    }

    fn endOfLine(p: *Parser) Error!void {
        p.skipSpaces();
        try p.comment();
        if (p.peek() == null) return;
        if (!try p.newline()) return p.fail("expected the end of the line");
    }

    fn document(p: *Parser, root: *Table) Error!void {
        var current = root;
        while (true) {
            try p.skipBlank();
            const c = p.peek() orelse return;
            if (c == '[') {
                current = try p.header(root);
            } else {
                try p.keyValue(current);
            }
            try p.endOfLine();
        }
    }

    /// Parses `[a.b]` or `[[a.b]]` and returns the table that follows it.
    fn header(p: *Parser, root: *Table) Error!*Table {
        p.pos += 1;
        const of_tables = p.peek() == '[';
        if (of_tables) p.pos += 1;
        p.skipSpaces();
        const path = try p.key();
        p.skipSpaces();
        if (!p.startsWith(if (of_tables) "]]" else "]")) return p.fail(if (of_tables) "expected ']]'" else "expected ']'");
        p.pos += if (of_tables) 2 else 1;

        var table = root;
        for (path[0 .. path.len - 1]) |name| {
            const entry = try table.entries.getOrPut(p.allocator, name);
            if (!entry.found_existing) {
                const child = try p.newTable(.implicit);
                entry.value_ptr.* = .{ .table = child };
                table = child;
                continue;
            }
            table = switch (entry.value_ptr.*) {
                .table => |child| if (isSealed(child.origin)) return p.fail("inline tables can't be extended") else child,
                .array => |array| if (array.of_tables) array.items.getLast().table else return p.fail("can't add a table to an array value"),
                .value => return p.fail("the key is already a value, not a table"),
            };
        }

        const name = path[path.len - 1];
        const entry = try table.entries.getOrPut(p.allocator, name);
        if (of_tables) {
            if (!entry.found_existing) {
                const array = try p.newArray(true);
                entry.value_ptr.* = .{ .array = array };
            }
            const array = switch (entry.value_ptr.*) {
                .array => |array| if (array.of_tables) array else return p.fail("can't append to an array value"),
                else => return p.fail("the key is already defined, not as an array of tables"),
            };
            const element = try p.newTable(.header);
            try array.items.append(p.allocator, .{ .table = element });
            return element;
        }
        if (!entry.found_existing) {
            const child = try p.newTable(.header);
            entry.value_ptr.* = .{ .table = child };
            return child;
        }
        return switch (entry.value_ptr.*) {
            .table => |child| switch (child.origin) {
                .implicit => {
                    child.origin = .header;
                    return child;
                },
                .header => p.fail("the table is defined twice"),
                .dotted => p.fail("the table was already defined with dotted keys"),
                .sealed, .sealed_dotted => p.fail("inline tables can't be extended"),
            },
            else => p.fail("the key is already defined, not as a table"),
        };
    }

    /// Parses `a.b = value` into `table`.
    fn keyValue(p: *Parser, table: *Table) Error!void {
        const path = try p.key();
        p.skipSpaces();
        if (p.peek() != '=') return p.fail("expected '=' after the key");
        p.pos += 1;
        p.skipSpaces();

        const inside_inline = isSealed(table.origin);
        const created: Origin = if (inside_inline) .sealed_dotted else .dotted;
        var target = table;
        for (path[0 .. path.len - 1]) |name| {
            const entry = try target.entries.getOrPut(p.allocator, name);
            if (!entry.found_existing) {
                const child = try p.newTable(created);
                entry.value_ptr.* = .{ .table = child };
                target = child;
                continue;
            }
            target = switch (entry.value_ptr.*) {
                .table => |child| if (child.origin == created)
                    child
                else
                    return p.fail("dotted keys can only extend tables they defined"),
                else => return p.fail("the key is already defined, not as a table"),
            };
        }

        const name = path[path.len - 1];
        const entry = try target.entries.getOrPut(p.allocator, name);
        if (entry.found_existing) return p.fail("the key is defined twice");
        entry.value_ptr.* = try p.value();
    }

    /// Parses a key, dotted or not, into its parts.
    fn key(p: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            try parts.append(p.allocator, try p.simpleKey());
            p.skipSpaces();
            if (p.peek() != '.') return parts.items;
            p.pos += 1;
            p.skipSpaces();
        }
    }

    fn simpleKey(p: *Parser) Error![]const u8 {
        switch (p.peek() orelse return p.fail("expected a key")) {
            '"' => {
                if (p.startsWith("\"\"\"")) return p.fail("keys can't be multi-line strings");
                return p.basicString();
            },
            '\'' => {
                if (p.startsWith("'''")) return p.fail("keys can't be multi-line strings");
                return p.literalString();
            },
            else => {},
        }
        const start = p.pos;
        while (p.peek()) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break;
            p.pos += 1;
        }
        if (p.pos == start) return p.fail("expected a key");
        return p.text[start..p.pos];
    }

    fn value(p: *Parser) Error!Node {
        const c = p.peek() orelse return p.fail("expected a value");
        switch (c) {
            '"' => return .{ .value = .{ .string = if (p.startsWith("\"\"\"")) try p.multilineBasicString() else try p.basicString() } },
            '\'' => return .{ .value = .{ .string = if (p.startsWith("'''")) try p.multilineLiteralString() else try p.literalString() } },
            '[' => return p.arrayValue(),
            '{' => return p.inlineTable(),
            't' => if (p.word("true")) return .{ .value = .{ .bool = true } },
            'f' => if (p.word("false")) return .{ .value = .{ .bool = false } },
            else => {},
        }
        if (p.looksLikeDate()) return .{ .value = .{ .string = try p.dateTime() } };
        return .{ .value = try p.number() };
    }

    fn word(p: *Parser, w: []const u8) bool {
        if (!p.startsWith(w)) return false;
        if (p.peekAt(w.len)) |next| if (std.ascii.isAlphanumeric(next) or next == '_') return false;
        p.pos += w.len;
        return true;
    }

    fn arrayValue(p: *Parser) Error!Node {
        p.pos += 1;
        const result = try p.newArray(false);
        while (true) {
            try p.skipBlank();
            if (p.peek() == ']') {
                p.pos += 1;
                return .{ .array = result };
            }
            try result.items.append(p.allocator, try p.value());
            try p.skipBlank();
            switch (p.peek() orelse return p.fail("expected ']'")) {
                ',' => p.pos += 1,
                ']' => {},
                else => return p.fail("expected ',' or ']' in the array"),
            }
        }
    }

    fn inlineTable(p: *Parser) Error!Node {
        p.pos += 1;
        const table = try p.newTable(.sealed);
        p.skipSpaces();
        if (p.peek() == '}') {
            p.pos += 1;
            return .{ .table = table };
        }
        while (true) {
            p.skipSpaces();
            try p.keyValue(table);
            p.skipSpaces();
            switch (p.peek() orelse return p.fail("expected '}'")) {
                ',' => p.pos += 1,
                '}' => {
                    p.pos += 1;
                    return .{ .table = table };
                },
                '\n', '\r' => return p.fail("inline tables have to fit on one line"),
                else => return p.fail("expected ',' or '}' in the inline table"),
            }
            p.skipSpaces();
            if (p.peek() == '}') return p.fail("inline tables can't have a trailing comma");
        }
    }

    fn literalString(p: *Parser) Error![]const u8 {
        p.pos += 1;
        const start = p.pos;
        while (p.peek()) |c| {
            if (c == '\'') {
                p.pos += 1;
                return p.text[start .. p.pos - 1];
            }
            if (c == '\n' or c == '\r') break;
            if (isControl(c)) return p.fail("strings can't contain control characters");
            p.pos += 1;
        }
        return p.fail("the string isn't closed");
    }

    fn multilineLiteralString(p: *Parser) Error![]const u8 {
        p.pos += 3;
        _ = try p.newline();
        const start = p.pos;
        while (p.peek()) |c| {
            if (p.startsWith("'''")) {
                // Up to two quotes right before the closing ones belong to the string.
                var end = p.pos;
                p.pos += 3;
                var extra: usize = 0;
                while (extra < 2 and p.peek() == '\'') : (extra += 1) p.pos += 1;
                end += extra;
                return p.text[start..end];
            }
            if (c == '\r') {
                if (p.peekAt(1) != '\n') return p.fail("a carriage return has to be followed by a line feed");
            } else if (c != '\n' and isControl(c)) {
                return p.fail("strings can't contain control characters");
            }
            p.pos += 1;
        }
        return p.fail("the string isn't closed");
    }

    fn basicString(p: *Parser) Error![]const u8 {
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            switch (c) {
                '"' => {
                    p.pos += 1;
                    return out.items;
                },
                '\\' => try p.escape(&out),
                '\n', '\r' => break,
                else => {
                    if (isControl(c)) return p.fail("strings can't contain control characters");
                    try out.append(p.allocator, c);
                    p.pos += 1;
                },
            }
        }
        return p.fail("the string isn't closed");
    }

    fn multilineBasicString(p: *Parser) Error![]const u8 {
        p.pos += 3;
        _ = try p.newline();
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            if (p.startsWith("\"\"\"")) {
                p.pos += 3;
                var extra: usize = 0;
                while (extra < 2 and p.peek() == '"') : (extra += 1) {
                    try out.append(p.allocator, '"');
                    p.pos += 1;
                }
                return out.items;
            }
            switch (c) {
                '\\' => {
                    // A backslash at the end of a line removes the line break
                    // and all whitespace up to the next visible character.
                    var look = p.pos + 1;
                    while (look < p.text.len and (p.text[look] == ' ' or p.text[look] == '\t')) look += 1;
                    if (look < p.text.len and (p.text[look] == '\n' or p.text[look] == '\r')) {
                        p.pos = look;
                        while (true) {
                            p.skipSpaces();
                            if (!try p.newline()) break;
                        }
                    } else {
                        try p.escape(&out);
                    }
                },
                '\r' => {
                    if (p.peekAt(1) != '\n') return p.fail("a carriage return has to be followed by a line feed");
                    try out.appendSlice(p.allocator, "\r\n");
                    p.pos += 2;
                },
                else => {
                    if (c != '\n' and isControl(c)) return p.fail("strings can't contain control characters");
                    try out.append(p.allocator, c);
                    p.pos += 1;
                },
            }
        }
        return p.fail("the string isn't closed");
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        p.pos += 1;
        const e = p.peek() orelse return p.fail("the string isn't closed");
        p.pos += 1;
        const plain: ?u8 = switch (e) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'u', 'U' => null,
            else => return p.fail("unknown escape in the string"),
        };
        if (plain) |byte| return out.append(p.allocator, byte);

        const len: usize = if (e == 'u') 4 else 8;
        if (p.pos + len > p.text.len) return p.fail("the unicode escape is too short");
        const hex = p.text[p.pos..][0..len];
        for (hex) |d| if (!std.ascii.isHex(d)) return p.fail("invalid unicode escape");
        const code = std.fmt.parseInt(u32, hex, 16) catch return p.fail("invalid unicode escape");
        if (code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) return p.fail("the unicode escape isn't a character");
        p.pos += len;
        var buffer: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(code), &buffer) catch return p.fail("invalid unicode escape");
        try out.appendSlice(p.allocator, buffer[0..n]);
    }

    fn looksLikeDate(p: *const Parser) bool {
        const rest = p.text[p.pos..];
        if (rest.len >= 5 and isDigits(rest[0..4]) and rest[4] == '-') return true;
        return rest.len >= 3 and isDigits(rest[0..2]) and rest[2] == ':';
    }

    /// Reads a date, a time or both, checks it and returns it in RFC 3339 form.
    fn dateTime(p: *Parser) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var has_date = false;
        if (p.peekAt(4) == '-') {
            const date = p.take(10) orelse return p.fail("invalid date");
            if (!isDigits(date[0..4]) or date[4] != '-' or !isDigits(date[5..7]) or date[7] != '-' or !isDigits(date[8..10]))
                return p.fail("invalid date");
            const year = parseDigits(date[0..4]);
            const month = parseDigits(date[5..7]);
            const day = parseDigits(date[8..10]);
            if (month < 1 or month > 12 or day < 1 or day > daysIn(year, month)) return p.fail("the date doesn't exist");
            try out.appendSlice(p.allocator, date);
            has_date = true;

            // A time may follow the date, separated by a T or a space.
            const sep = p.peek() orelse return out.items;
            const time_follows = p.pos + 3 < p.text.len and isDigits(p.text[p.pos + 1 ..][0..2]) and p.text[p.pos + 3] == ':';
            if (!((sep == 'T' or sep == 't') or (sep == ' ' and time_follows))) return out.items;
            if (!time_follows) return p.fail("expected a time after the date");
            p.pos += 1;
            try out.append(p.allocator, 'T');
        }

        const time = p.take(8) orelse return p.fail("invalid time, it needs hours, minutes and seconds");
        if (!isDigits(time[0..2]) or time[2] != ':' or !isDigits(time[3..5]) or time[5] != ':' or !isDigits(time[6..8]))
            return p.fail("invalid time, it needs hours, minutes and seconds");
        if (parseDigits(time[0..2]) > 23 or parseDigits(time[3..5]) > 59 or parseDigits(time[6..8]) > 60)
            return p.fail("the time doesn't exist");
        try out.appendSlice(p.allocator, time);
        if (p.peek() == '.') {
            const start = p.pos;
            p.pos += 1;
            while (p.peek()) |c| {
                if (!std.ascii.isDigit(c)) break;
                p.pos += 1;
            }
            if (p.pos == start + 1) return p.fail("expected digits after the decimal point");
            try out.appendSlice(p.allocator, p.text[start..p.pos]);
        }
        if (!has_date) return out.items;

        const zone = p.peek() orelse return out.items;
        if (zone == 'Z' or zone == 'z') {
            p.pos += 1;
            try out.append(p.allocator, 'Z');
        } else if (zone == '+' or zone == '-') {
            const offset = p.take(6) orelse return p.fail("invalid time offset");
            if (!isDigits(offset[1..3]) or offset[3] != ':' or !isDigits(offset[4..6])) return p.fail("invalid time offset");
            if (parseDigits(offset[1..3]) > 23 or parseDigits(offset[4..6]) > 59) return p.fail("invalid time offset");
            try out.appendSlice(p.allocator, offset);
        }
        return out.items;
    }

    fn take(p: *Parser, n: usize) ?[]const u8 {
        if (p.pos + n > p.text.len) return null;
        defer p.pos += n;
        return p.text[p.pos..][0..n];
    }

    fn number(p: *Parser) Error!Value {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '+' and c != '-' and c != '.') break;
            p.pos += 1;
        }
        const raw = p.text[start..p.pos];
        if (raw.len == 0) return p.fail("expected a value");

        const sign: []const u8 = if (raw[0] == '+' or raw[0] == '-') raw[0..1] else "";
        const body = raw[sign.len..];
        if (std.mem.eql(u8, body, "inf") or std.mem.eql(u8, body, "nan")) {
            const v: f64 = if (body[0] == 'n') std.math.nan(f64) else std.math.inf(f64);
            return .{ .float = if (std.mem.eql(u8, sign, "-")) -v else v };
        }

        if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'o' or body[1] == 'b')) {
            if (sign.len != 0) return p.fail("hex, octal and binary numbers can't have a sign");
            const base: u8 = switch (body[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            const clean = try p.digits(body[2..], base);
            const v = std.fmt.parseInt(u64, clean, base) catch return p.fail("the number is too big");
            if (v > std.math.maxInt(i64)) return p.fail("the number is too big");
            return .{ .integer = @intCast(v) };
        }

        // Split into the integer part, the fraction and the exponent.
        const exp_at = std.mem.indexOfAny(u8, body, "eE");
        const mantissa = body[0 .. exp_at orelse body.len];
        const dot_at = std.mem.indexOfScalar(u8, mantissa, '.');
        const int_part = mantissa[0 .. dot_at orelse mantissa.len];

        var clean: std.ArrayList(u8) = .empty;
        try clean.appendSlice(p.allocator, sign);
        const int_digits = try p.digits(int_part, 10);
        if (int_digits.len > 1 and int_digits[0] == '0') return p.fail("numbers can't have leading zeros");
        try clean.appendSlice(p.allocator, int_digits);

        if (dot_at == null and exp_at == null) {
            const v = std.fmt.parseInt(i64, clean.items, 10) catch return p.fail("the number is too big");
            return .{ .integer = v };
        }
        if (dot_at) |dot| {
            try clean.append(p.allocator, '.');
            try clean.appendSlice(p.allocator, try p.digits(mantissa[dot + 1 ..], 10));
        }
        if (exp_at) |e| {
            var exponent = body[e + 1 ..];
            try clean.append(p.allocator, 'e');
            if (exponent.len > 0 and (exponent[0] == '+' or exponent[0] == '-')) {
                try clean.append(p.allocator, exponent[0]);
                exponent = exponent[1..];
            }
            try clean.appendSlice(p.allocator, try p.digits(exponent, 10));
        }
        const v = std.fmt.parseFloat(f64, clean.items) catch return p.fail("invalid number");
        return .{ .float = v };
    }

    /// Checks digits in `base` that may be separated by single underscores
    /// and returns them without the underscores.
    fn digits(p: *Parser, text: []const u8, base: u8) Error![]const u8 {
        if (text.len == 0) return p.fail("expected digits");
        if (text[0] == '_' or text[text.len - 1] == '_') return p.fail("underscores have to be between digits");
        var out: std.ArrayList(u8) = .empty;
        for (text, 0..) |c, i| {
            if (c == '_') {
                if (text[i - 1] == '_') return p.fail("underscores have to be between digits");
                continue;
            }
            const valid = switch (base) {
                16 => std.ascii.isHex(c),
                8 => c >= '0' and c <= '7',
                2 => c == '0' or c == '1',
                else => std.ascii.isDigit(c),
            };
            if (!valid) return p.fail("invalid number");
            try out.append(p.allocator, c);
        }
        return out.items;
    }
};

fn isControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

fn isDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseDigits(s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 10) catch unreachable;
}

fn daysIn(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn toValue(allocator: Allocator, node: Node) Allocator.Error!Value {
    switch (node) {
        .value => |v| return v,
        .array => |array| {
            var out: std.json.Array = .init(allocator);
            for (array.items.items) |item| try out.append(try toValue(allocator, item));
            return .{ .array = out };
        },
        .table => |table| {
            var out: std.json.ObjectMap = .empty;
            var it = table.entries.iterator();
            while (it.next()) |entry| try out.put(allocator, entry.key_ptr.*, try toValue(allocator, entry.value_ptr.*));
            return .{ .object = out };
        },
    }
}

/// Writes `value`, a struct, as a TOML document. Plain fields come first,
/// fields that are structs become tables after them, and null fields are left out.
pub fn stringify(allocator: Allocator, value: anytype) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    writeTable(&out.writer, value, "") catch return error.OutOfMemory;
    return out.written();
}

fn isTable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.layout != .@"packed" and !s.is_tuple,
        .optional => |o| isTable(o.child),
        else => false,
    };
}

fn writeTable(w: *std.Io.Writer, value: anytype, path: []const u8) std.Io.Writer.Error!void {
    const fields = @typeInfo(@TypeOf(value)).@"struct".fields;
    inline for (fields) |field| {
        if (comptime !isTable(field.type)) {
            const v = @field(value, field.name);
            const present = if (@typeInfo(field.type) == .optional) v != null else true;
            if (present) {
                try writeKey(w, field.name);
                try w.writeAll(" = ");
                try writeValue(w, v);
                try w.writeByte('\n');
            }
        }
    }
    inline for (fields) |field| {
        if (comptime isTable(field.type)) {
            if (@typeInfo(field.type) == .optional) {
                if (@field(value, field.name)) |table| try writeNamedTable(w, table, path, field.name);
            } else {
                try writeNamedTable(w, @field(value, field.name), path, field.name);
            }
        }
    }
}

fn writeNamedTable(w: *std.Io.Writer, table: anytype, path: []const u8, comptime field: []const u8) std.Io.Writer.Error!void {
    var buffer: [512]u8 = undefined;
    var name: std.Io.Writer = .fixed(&buffer);
    if (path.len > 0) {
        try name.writeAll(path);
        try name.writeByte('.');
    }
    try writeKey(&name, field);
    try w.print("\n[{s}]\n", .{name.buffered()});
    try writeTable(w, table, name.buffered());
}

fn writeKey(w: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    if (key.len == 0) return writeString(w, key);
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return writeString(w, key);
    }
    try w.writeAll(key);
}

fn writeValue(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => try writeFloat(w, value),
        .@"enum" => try writeString(w, @tagName(value)),
        .optional => if (value) |v| try writeValue(w, v),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return writeString(w, value);
            if (ptr.size == .one) return writeValue(w, value.*);
            try writeArray(w, value);
        },
        .array => |arr| if (arr.child == u8) try writeString(w, &value) else try writeArray(w, &value),
        .@"struct" => |st| if (st.is_tuple) try writeTuple(w, value) else try writeInlineTable(w, value),
        else => @compileError("can't write a " ++ @typeName(T) ++ " to TOML"),
    }
}

/// Writes a struct inside a value, such as an item of an array, as an inline table.
fn writeInlineTable(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    try w.writeByte('{');
    var first = true;
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        const v = @field(value, field.name);
        const present = if (@typeInfo(field.type) == .optional) v != null else true;
        if (present) {
            try w.writeAll(if (first) " " else ", ");
            first = false;
            try writeKey(w, field.name);
            try w.writeAll(" = ");
            try writeValue(w, v);
        }
    }
    try w.writeAll(if (first) "}" else " }");
}

fn writeTuple(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    try w.writeByte('[');
    inline for (0..value.len) |i| {
        if (i != 0) try w.writeAll(", ");
        try writeValue(w, value[i]);
    }
    try w.writeByte(']');
}

fn writeFloat(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const v: f64 = value;
    if (std.math.isNan(v)) return w.writeAll("nan");
    if (std.math.isInf(v)) return w.writeAll(if (v > 0) "inf" else "-inf");
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{v}) catch return w.print("{e}", .{v});
    try w.writeAll(text);
    // Without a fraction the value would read back as an integer.
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try w.writeAll(".0");
}

fn writeArray(w: *std.Io.Writer, items: anytype) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(", ");
        try writeValue(w, item);
    }
    try w.writeByte(']');
}

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .{};
    const tree = try parse(arena.allocator(),
        \\# A comment
        \\name = "Pumpkin \u00e9"
        \\path = 'C:\no\escapes'
        \\port = 25_565
        \\mask = 0xff
        \\ratio = -1.5e2
        \\enabled = true
        \\since = 1979-05-27 07:32:00Z
        \\owner.name = "Tom"
        \\point = { x = 1, y = 2 }
        \\tags = [
        \\  "a", # first
        \\  "b",
        \\]
        \\
        \\[limits.chat]
        \\max = 256
        \\
        \\[[worlds]]
        \\name = "overworld"
        \\[[worlds]]
        \\name = "nether"
    , &diagnostics);

    const root = tree.object;
    try std.testing.expectEqualStrings("Pumpkin é", root.get("name").?.string);
    try std.testing.expectEqualStrings("C:\\no\\escapes", root.get("path").?.string);
    try std.testing.expectEqual(25565, root.get("port").?.integer);
    try std.testing.expectEqual(255, root.get("mask").?.integer);
    try std.testing.expectEqual(-150.0, root.get("ratio").?.float);
    try std.testing.expect(root.get("enabled").?.bool);
    try std.testing.expectEqualStrings("1979-05-27T07:32:00Z", root.get("since").?.string);
    try std.testing.expectEqualStrings("Tom", root.get("owner").?.object.get("name").?.string);
    try std.testing.expectEqual(2, root.get("point").?.object.get("y").?.integer);
    try std.testing.expectEqual(2, root.get("tags").?.array.items.len);
    try std.testing.expectEqual(256, root.get("limits").?.object.get("chat").?.object.get("max").?.integer);
    try std.testing.expectEqualStrings("nether", root.get("worlds").?.array.items[1].object.get("name").?.string);
}

test "parse errors point at the problem" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "a = 1\nb = \"open\n", &diagnostics));
    try std.testing.expectEqual(2, diagnostics.line);
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "a = 1\na = 2\n", &diagnostics));
    try std.testing.expectEqualStrings("the key is defined twice", diagnostics.message);
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "[a]\n[a]\n", &diagnostics));
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "n = 012\n", &diagnostics));
}

test "stringify and parse again" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Config = struct {
        welcome: []const u8 = "Hi \"there\"",
        max_homes: u32 = 3,
        speed: f64 = 2,
        big: f64 = 3e20,
        small: f64 = 0.125,
        color: enum { gold, red } = .gold,
        worlds: []const []const u8 = &.{ "overworld", "nether" },
        nickname: ?[]const u8 = null,
        limits: struct { chat: u32 = 256 } = .{},
        warps: []const struct { name: []const u8, y: ?i32 = null } = &.{ .{ .name = "spawn", .y = 64 }, .{ .name = "end" } },
        enchants: []const struct { []const u8, u32 } = &.{.{ "sharpness", 5 }},
    };

    const text = try stringify(arena.allocator(), Config{});
    var diagnostics: Diagnostics = .{};
    const tree = try parse(arena.allocator(), text, &diagnostics);
    const back = try std.json.parseFromValueLeaky(Config, arena.allocator(), tree, .{});
    try std.testing.expectEqualDeep(Config{}, back);
}
