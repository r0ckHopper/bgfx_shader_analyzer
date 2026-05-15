const std = @import("std");

pub const VaryingDef = struct {
    entries: []const Entry,

    pub const Entry = struct {
        precision: ?[]const u8,
        interpolation: ?[]const u8,
        type: []const u8,
        name: []const u8,
        semantic: []const u8,
        default_value: ?[]const u8,
    };

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !VaryingDef {
        var entries = std.ArrayList(Entry).init(allocator);
        errdefer entries.deinit();

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "//")) continue;

            const entry = parseLine(trimmed) orelse continue;
            try entries.append(entry);
        }

        return .{ .entries = try entries.toOwnedSlice() };
    }

    pub fn deinit(self: VaryingDef, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub const LineContext = enum {
        start,
        type_name,
        after_type,
        after_colon,
        after_equals,
        comment_or_empty,
    };

    pub fn parseLineContext(line: []const u8, cursor_byte_offset: u32) LineContext {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.startsWith(u8, trimmed, "//")) {
            return .comment_or_empty;
        }
        if (trimmed.len == 0) {
            return .start;
        }

        var pos: usize = 0;
        var non_qualifier_count: usize = 0;
        var seen_colon = false;
        var seen_equals = false;

        while (pos < line.len) {
            while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
            if (pos >= line.len) break;

            const tok_start = pos;
            while (pos < line.len and !std.ascii.isWhitespace(line[pos]) and line[pos] != ':' and line[pos] != '=' and line[pos] != ';') pos += 1;
            const token = line[tok_start..pos];

            if (token.len == 0) {
                if (pos < line.len) {
                    if (line[pos] == ':') {
                        seen_colon = true;
                        pos += 1;
                        while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
                        if (cursor_byte_offset <= pos) return .after_colon;
                    } else if (line[pos] == '=') {
                        seen_equals = true;
                        pos += 1;
                    } else {
                        pos += 1;
                    }
                }
                continue;
            }

            if (isPrecision(token) or isInterpolation(token)) {
                if (cursor_byte_offset >= tok_start and cursor_byte_offset <= pos) return .start;
                while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
                continue;
            }

            non_qualifier_count += 1;

            if (!seen_colon and !seen_equals) {
                if (non_qualifier_count == 1 and cursor_byte_offset >= tok_start and cursor_byte_offset <= pos) {
                    return .type_name;
                }
                if (non_qualifier_count == 2 and cursor_byte_offset >= tok_start and cursor_byte_offset <= pos) {
                    return .after_type;
                }

                while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;

                if (pos < line.len and line[pos] == ':') {
                    seen_colon = true;
                    pos += 1;
                    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
                    if (cursor_byte_offset <= pos) return .after_colon;
                }
                continue;
            }
        }

        if (seen_equals) return .after_equals;
        if (seen_colon) return .after_colon;
        return .start;
    }

    pub fn buildLookup(allocator: std.mem.Allocator, entries: []const Entry) !std.StringHashMapUnmanaged(*const Entry) {
        var map = std.StringHashMapUnmanaged(*const Entry){};
        errdefer map.deinit(allocator);
        for (entries) |*entry| {
            const name = try allocator.dupe(u8, entry.name);
            try map.put(allocator, name, entry);
        }
        return map;
    }
};

const precision_keywords = [_][]const u8{ "lowp", "mediump", "highp" };
const interpolation_keywords = [_][]const u8{ "flat", "smooth", "noperspective", "centroid" };

fn isPrecision(token: []const u8) bool {
    inline for (precision_keywords) |kw| {
        if (std.mem.eql(u8, token, kw)) return true;
    }
    return false;
}

fn isInterpolation(token: []const u8) bool {
    inline for (interpolation_keywords) |kw| {
        if (std.mem.eql(u8, token, kw)) return true;
    }
    return false;
}

fn parseLine(line: []const u8) ?VaryingDef.Entry {
    var pos: usize = 0;

    var precision: ?[]const u8 = null;
    var interpolation: ?[]const u8 = null;

    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;

    while (pos < line.len) {
        const token_start = pos;
        while (pos < line.len and !std.ascii.isWhitespace(line[pos]) and line[pos] != ':' and line[pos] != '=' and line[pos] != ';') pos += 1;
        const token = line[token_start..pos];

        if (token.len == 0) {
            pos += 1;
            continue;
        }

        if (precision == null and isPrecision(token)) {
            precision = token;
        } else if (interpolation == null and isInterpolation(token)) {
            interpolation = token;
        } else {
            const type_name = token;

            while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
            const name_start = pos;
            while (pos < line.len and !std.ascii.isWhitespace(line[pos]) and line[pos] != ':' and line[pos] != '=' and line[pos] != ';') pos += 1;
            const name = line[name_start..pos];

            while (pos < line.len and (std.ascii.isWhitespace(line[pos]) or line[pos] == ':')) pos += 1;

            const semantic_start = pos;
            while (pos < line.len and !std.ascii.isWhitespace(line[pos]) and line[pos] != '=' and line[pos] != ';') pos += 1;
            const semantic = line[semantic_start..pos];

            var default_value: ?[]const u8 = null;

            while (pos < line.len) {
                if (line[pos] == '=') {
                    pos += 1;
                    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
                    const dv_start = pos;
                    while (pos < line.len and line[pos] != ';') pos += 1;
                    default_value = std.mem.trim(u8, line[dv_start..pos], &std.ascii.whitespace);
                    break;
                } else if (line[pos] == ';') {
                    break;
                }
                pos += 1;
            }

            return .{
                .precision = precision,
                .interpolation = interpolation,
                .type = type_name,
                .name = name,
                .semantic = semantic,
                .default_value = default_value,
            };
        }

        while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
    }

    return null;
}

test "parse basic attribute" {
    const source = "vec3 a_position : POSITION;";
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    const e = result.entries[0];
    try std.testing.expect(e.precision == null);
    try std.testing.expect(e.interpolation == null);
    try std.testing.expectEqualStrings("vec3", e.type);
    try std.testing.expectEqualStrings("a_position", e.name);
    try std.testing.expectEqualStrings("POSITION", e.semantic);
    try std.testing.expect(e.default_value == null);
}

test "parse with precision" {
    const source = "highp vec2 v_uv : TEXCOORD0;";
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    const e = result.entries[0];
    try std.testing.expect(e.precision != null);
    try std.testing.expectEqualStrings("highp", e.precision.?);
    try std.testing.expectEqualStrings("vec2", e.type);
    try std.testing.expectEqualStrings("v_uv", e.name);
    try std.testing.expectEqualStrings("TEXCOORD0", e.semantic);
}

test "parse with interpolation" {
    const source = "flat vec4 v_color : COLOR0;";
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    const e = result.entries[0];
    try std.testing.expect(e.interpolation != null);
    try std.testing.expectEqualStrings("flat", e.interpolation.?);
    try std.testing.expectEqualStrings("vec4", e.type);
    try std.testing.expectEqualStrings("v_color", e.name);
    try std.testing.expectEqualStrings("COLOR0", e.semantic);
}

test "parse with default value" {
    const source = "vec4 v_color0 : COLOR0 = vec4(1.0, 1.0, 1.0, 1.0);";
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    const e = result.entries[0];
    try std.testing.expect(e.default_value != null);
    try std.testing.expectEqualStrings("vec4(1.0, 1.0, 1.0, 1.0)", e.default_value.?);
}

test "parse full example with precision and interpolation" {
    const source = "highp flat vec3 v_normal : NORMAL = vec3(0.0, 0.0, 1.0);";
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    const e = result.entries[0];
    try std.testing.expectEqualStrings("highp", e.precision.?);
    try std.testing.expectEqualStrings("flat", e.interpolation.?);
    try std.testing.expectEqualStrings("vec3", e.type);
    try std.testing.expectEqualStrings("v_normal", e.name);
    try std.testing.expectEqualStrings("NORMAL", e.semantic);
    try std.testing.expectEqualStrings("vec3(0.0, 0.0, 1.0)", e.default_value.?);
}

test "skip comments and blank lines" {
    const source =
        \\// this is a comment
        \\
        \\vec3 a_position : POSITION;
        \\
        \\// another comment
    ;
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("a_position", result.entries[0].name);
}

test "parse multiple lines" {
    const source =
        \\vec3 a_position : POSITION;
        \\vec4 a_color0 : COLOR0;
        \\vec2 a_texcoord0 : TEXCOORD0;
        \\vec3 v_normal : NORMAL = vec3(0.0, 0.0, 1.0);
        \\flat vec4 v_color : COLOR0;
        \\highp vec2 v_uv : TEXCOORD0;
    ;
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), result.entries.len);

    try std.testing.expectEqualStrings("a_position", result.entries[0].name);
    try std.testing.expectEqualStrings("a_color0", result.entries[1].name);
    try std.testing.expectEqualStrings("a_texcoord0", result.entries[2].name);
    try std.testing.expectEqualStrings("v_normal", result.entries[3].name);
    try std.testing.expect(result.entries[3].default_value != null);

    try std.testing.expectEqualStrings("flat", result.entries[4].interpolation.?);
    try std.testing.expectEqualStrings("highp", result.entries[5].precision.?);
}

test "buildLookup from entries" {
    const source =
        \\vec3 a_position : POSITION;
        \\vec4 v_color0 : COLOR0;
        \\vec2 v_texcoord0 : TEXCOORD0;
    ;
    const result = try VaryingDef.parse(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    var lookup = try VaryingDef.buildLookup(std.testing.allocator, result.entries);
    defer {
        var it = lookup.keyIterator();
        while (it.next()) |key| std.testing.allocator.free(key.*);
        lookup.deinit(std.testing.allocator);
    }

    const pos_entry = lookup.get("a_position").?;
    try std.testing.expectEqualStrings("vec3", pos_entry.type);
    try std.testing.expectEqualStrings("POSITION", pos_entry.semantic);

    const color_entry = lookup.get("v_color0").?;
    try std.testing.expectEqualStrings("vec4", color_entry.type);
    try std.testing.expectEqualStrings("COLOR0", color_entry.semantic);

    const tc_entry = lookup.get("v_texcoord0").?;
    try std.testing.expectEqualStrings("vec2", tc_entry.type);
    try std.testing.expectEqualStrings("TEXCOORD0", tc_entry.semantic);

    try std.testing.expect(lookup.get("nonexistent") == null);
}

test "parseLineContext: start position" {
    const line = "vec3 a_position : POSITION;";
    try std.testing.expect(VaryingDef.parseLineContext(line, 0) == .type_name);
}

test "parseLineContext: type_name position" {
    const line = "vec3 a_position : POSITION;";
    try std.testing.expect(VaryingDef.parseLineContext(line, 2) == .type_name);
    try std.testing.expect(VaryingDef.parseLineContext(line, 4) == .type_name);
}

test "parseLineContext: after_colon position" {
    const line = "vec3 a_position : POSITION;";
    try std.testing.expect(VaryingDef.parseLineContext(line, 19) == .after_colon);
    try std.testing.expect(VaryingDef.parseLineContext(line, 22) == .after_colon);
}

test "parseLineContext: with qualifiers" {
    const line = "highp flat vec3 v_normal : NORMAL;";
    try std.testing.expect(VaryingDef.parseLineContext(line, 0) == .start);
    try std.testing.expect(VaryingDef.parseLineContext(line, 6) == .start);
    try std.testing.expect(VaryingDef.parseLineContext(line, 13) == .type_name);
    try std.testing.expect(VaryingDef.parseLineContext(line, 30) == .after_colon);
}

test "parseLineContext: empty and comment" {
    try std.testing.expect(VaryingDef.parseLineContext("", 0) == .start);
    try std.testing.expect(VaryingDef.parseLineContext("  ", 0) == .start);
    try std.testing.expect(VaryingDef.parseLineContext("// comment", 0) == .comment_or_empty);
}
