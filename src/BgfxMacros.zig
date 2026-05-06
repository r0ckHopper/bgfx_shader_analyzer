const std = @import("std");
const Spec = @import("Spec.zig");

pub const MacroInfo = struct {
    name: []const u8,
    kind: Kind,
    glsl_type: ?[]const u8 = null,

    pub const Kind = enum {
        sampler_declaration,
        image_declaration,
        buffer_declaration,
        thread_declaration,
        utility,
        flow_control,
    };
};

const MacroEntry = struct {
    name: []const u8,
    kind: MacroInfo.Kind,
    glsl_type: ?[]const u8,
};

const macro_entries = [_]MacroEntry{
    .{ .name = "SAMPLER2D", .kind = .sampler_declaration, .glsl_type = "sampler2D" },
    .{ .name = "SAMPLER2DMS", .kind = .sampler_declaration, .glsl_type = "sampler2DMS" },
    .{ .name = "SAMPLER2DARRAY", .kind = .sampler_declaration, .glsl_type = "sampler2DArray" },
    .{ .name = "SAMPLER2DSHADOW", .kind = .sampler_declaration, .glsl_type = "sampler2DShadow" },
    .{ .name = "SAMPLER2DARRAYSHADOW", .kind = .sampler_declaration, .glsl_type = "sampler2DArrayShadow" },
    .{ .name = "SAMPLER3D", .kind = .sampler_declaration, .glsl_type = "sampler3D" },
    .{ .name = "SAMPLERCUBE", .kind = .sampler_declaration, .glsl_type = "samplerCube" },
    .{ .name = "SAMPLERCUBESHADOW", .kind = .sampler_declaration, .glsl_type = "samplerCubeShadow" },
    .{ .name = "ISAMPLER2D", .kind = .sampler_declaration, .glsl_type = "isampler2D" },
    .{ .name = "USAMPLER2D", .kind = .sampler_declaration, .glsl_type = "usampler2D" },
    .{ .name = "ISAMPLER3D", .kind = .sampler_declaration, .glsl_type = "isampler3D" },
    .{ .name = "USAMPLER3D", .kind = .sampler_declaration, .glsl_type = "usampler3D" },

    .{ .name = "NUM_THREADS", .kind = .thread_declaration, .glsl_type = null },

    .{ .name = "IMAGE2D_RO", .kind = .image_declaration, .glsl_type = "readonly image2D" },
    .{ .name = "IMAGE2D_WO", .kind = .image_declaration, .glsl_type = "writeonly image2D" },
    .{ .name = "IMAGE2D_RW", .kind = .image_declaration, .glsl_type = "image2D" },
    .{ .name = "UIMAGE2D_RO", .kind = .image_declaration, .glsl_type = "readonly uimage2D" },
    .{ .name = "UIMAGE2D_WO", .kind = .image_declaration, .glsl_type = "writeonly uimage2D" },
    .{ .name = "UIMAGE2D_RW", .kind = .image_declaration, .glsl_type = "uimage2D" },
    .{ .name = "IMAGE2D_ARRAY_RO", .kind = .image_declaration, .glsl_type = "readonly image2DArray" },
    .{ .name = "IMAGE2D_ARRAY_WO", .kind = .image_declaration, .glsl_type = "writeonly image2DArray" },
    .{ .name = "IMAGE2D_ARRAY_RW", .kind = .image_declaration, .glsl_type = "image2DArray" },
    .{ .name = "IMAGE3D_RO", .kind = .image_declaration, .glsl_type = "readonly image3D" },
    .{ .name = "IMAGE3D_WO", .kind = .image_declaration, .glsl_type = "writeonly image3D" },
    .{ .name = "IMAGE3D_RW", .kind = .image_declaration, .glsl_type = "image3D" },

    .{ .name = "BUFFER_RO", .kind = .buffer_declaration, .glsl_type = null },
    .{ .name = "BUFFER_RW", .kind = .buffer_declaration, .glsl_type = null },
    .{ .name = "BUFFER_WO", .kind = .buffer_declaration, .glsl_type = null },

    .{ .name = "BRANCH", .kind = .flow_control, .glsl_type = null },
    .{ .name = "LOOP", .kind = .flow_control, .glsl_type = null },
    .{ .name = "UNROLL", .kind = .flow_control, .glsl_type = null },

    .{ .name = "CONST", .kind = .utility, .glsl_type = null },
    .{ .name = "SHARED", .kind = .utility, .glsl_type = null },
    .{ .name = "FORMAT", .kind = .utility, .glsl_type = null },
    .{ .name = "WRITEONLY", .kind = .utility, .glsl_type = null },
    .{ .name = "REGISTER", .kind = .utility, .glsl_type = null },
};

const macro_map = std.StaticStringMap(MacroEntry).initComptime(init: {
    var entries: [macro_entries.len]struct { []const u8, MacroEntry } = undefined;
    for (&entries, macro_entries) |*out, entry| {
        out.* = .{ entry.name, entry };
    }
    break :init entries;
});

const all_names = init: {
    var names: [macro_entries.len][]const u8 = undefined;
    for (&names, macro_entries) |*out, entry| {
        out.* = entry.name;
    }
    break :init names;
};

pub fn resolveMacro(name: []const u8) ?MacroInfo {
    const entry = macro_map.get(name) orelse return null;
    return .{
        .name = entry.name,
        .kind = entry.kind,
        .glsl_type = entry.glsl_type,
    };
}

pub fn macroResultType(macro: MacroInfo) ?[]const u8 {
    return macro.glsl_type;
}

pub fn isBgfxMacro(name: []const u8) bool {
    return macro_map.get(name) != null;
}

pub fn allMacroNames() []const []const u8 {
    return &all_names;
}

test "resolveMacro SAMPLER2D" {
    const m = resolveMacro("SAMPLER2D").?;
    try std.testing.expect(m.kind == .sampler_declaration);
    try std.testing.expectEqualStrings("sampler2D", m.glsl_type.?);
    try std.testing.expectEqualStrings("SAMPLER2D", m.name);
}

test "resolveMacro NUM_THREADS" {
    const m = resolveMacro("NUM_THREADS").?;
    try std.testing.expect(m.kind == .thread_declaration);
    try std.testing.expect(m.glsl_type == null);
}

test "resolveMacro IMAGE2D_RO" {
    const m = resolveMacro("IMAGE2D_RO").?;
    try std.testing.expect(m.kind == .image_declaration);
    try std.testing.expectEqualStrings("readonly image2D", m.glsl_type.?);
}

test "resolveMacro BUFFER_RO" {
    const m = resolveMacro("BUFFER_RO").?;
    try std.testing.expect(m.kind == .buffer_declaration);
    try std.testing.expect(m.glsl_type == null);
}

test "resolveMacro BRANCH" {
    const m = resolveMacro("BRANCH").?;
    try std.testing.expect(m.kind == .flow_control);
    try std.testing.expect(m.glsl_type == null);
}

test "resolveMacro unknown returns null" {
    try std.testing.expect(resolveMacro("notAMacro") == null);
    try std.testing.expect(resolveMacro("") == null);
    try std.testing.expect(resolveMacro("sampler2D") == null);
}

test "isBgfxMacro" {
    try std.testing.expect(isBgfxMacro("SAMPLER2D"));
    try std.testing.expect(isBgfxMacro("IMAGE2D_RW"));
    try std.testing.expect(isBgfxMacro("BRANCH"));
    try std.testing.expect(isBgfxMacro("BUFFER_RO"));
    try std.testing.expect(isBgfxMacro("NUM_THREADS"));
    try std.testing.expect(isBgfxMacro("CONST"));
    try std.testing.expect(!isBgfxMacro("notAMacro"));
    try std.testing.expect(!isBgfxMacro("main"));
}

test "allMacroNames" {
    const names = allMacroNames();
    try std.testing.expect(names.len == macro_entries.len);
    try std.testing.expectEqualStrings("SAMPLER2D", names[0]);
}

test "macroResultType" {
    const m = resolveMacro("SAMPLER3D").?;
    try std.testing.expectEqualStrings("sampler3D", macroResultType(m).?);
    const n = resolveMacro("LOOP").?;
    try std.testing.expect(macroResultType(n) == null);
}

test "all sampler macros" {
    inline for (&.{
        "SAMPLER2D",            "SAMPLER2DMS", "SAMPLER2DARRAY", "SAMPLER2DSHADOW",
        "SAMPLER2DARRAYSHADOW", "SAMPLER3D",   "SAMPLERCUBE",    "SAMPLERCUBESHADOW",
        "ISAMPLER2D",           "USAMPLER2D",  "ISAMPLER3D",     "USAMPLER3D",
    }) |name| {
        const m = resolveMacro(name).?;
        try std.testing.expect(m.kind == .sampler_declaration);
        try std.testing.expect(m.glsl_type != null);
    }
}

test "all image macros" {
    inline for (&.{
        "IMAGE2D_RO",       "IMAGE2D_WO",       "IMAGE2D_RW",
        "UIMAGE2D_RO",      "UIMAGE2D_WO",      "UIMAGE2D_RW",
        "IMAGE2D_ARRAY_RO", "IMAGE2D_ARRAY_WO", "IMAGE2D_ARRAY_RW",
        "IMAGE3D_RO",       "IMAGE3D_WO",       "IMAGE3D_RW",
    }) |name| {
        const m = resolveMacro(name).?;
        try std.testing.expect(m.kind == .image_declaration);
        try std.testing.expect(m.glsl_type != null);
    }
}
