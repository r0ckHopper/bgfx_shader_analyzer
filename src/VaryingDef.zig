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
