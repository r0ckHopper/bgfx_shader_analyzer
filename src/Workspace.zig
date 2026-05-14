const std = @import("std");
const util = @import("util.zig");
const lsp = @import("lsp.zig");
const Spec = @import("Spec.zig");
const parse = @import("parse.zig");
pub const Document = @import("Document.zig");
const VaryingDef = @import("VaryingDef.zig").VaryingDef;

const Workspace = @This();

pub const BgfxVaryingInfo = struct {
    type: []const u8,
    semantic: []const u8,
    precision: ?[]const u8 = null,
    interpolation: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
};

allocator: std.mem.Allocator,
arena_state: std.heap.ArenaAllocator.State,
spec: Spec,
builtin_completions: []const lsp.CompletionItem,
varying_lookup: std.StringHashMapUnmanaged(*const VaryingDef.Entry) = .{},
varying_source: []const u8 = &.{},
varying_entries: []const VaryingDef.Entry = &.{},

/// Documents in the workspace, accessed by their path.
documents: std.StringHashMapUnmanaged(*Document) = .{},

pub fn init(allocator: std.mem.Allocator) !@This() {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const spec = try Spec.load(arena.allocator());
    const builtin_completions = try builtinCompletions(arena.allocator(), &spec);

    return .{
        .allocator = allocator,
        .arena_state = arena.state,
        .spec = spec,
        .builtin_completions = builtin_completions,
    };
}

pub fn loadVaryingDef(self: *@This(), path: []const u8) !void {
    {
        var it = self.varying_lookup.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.varying_lookup.deinit(self.allocator);
    }
    if (self.varying_entries.len > 0) self.allocator.free(self.varying_entries);
    if (self.varying_source.len > 0) self.allocator.free(self.varying_source);
    self.varying_lookup = .{};
    self.varying_source = &.{};
    self.varying_entries = &.{};

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const max_megabytes = 1;
    const contents = try file.reader().readAllAlloc(self.allocator, max_megabytes << 20);

    const varying_def = try VaryingDef.parse(self.allocator, contents);
    self.varying_lookup = try VaryingDef.buildLookup(self.allocator, varying_def.entries);
    self.varying_source = contents;
    self.varying_entries = varying_def.entries;
}

pub fn getVaryingInfo(self: *Workspace, name: []const u8) ?BgfxVaryingInfo {
    const entry = self.varying_lookup.get(name) orelse return null;
    return .{
        .type = entry.type,
        .semantic = entry.semantic,
        .precision = entry.precision,
        .interpolation = entry.interpolation,
        .default_value = entry.default_value,
    };
}

pub fn deinit(self: *Workspace) void {
    var entries = self.documents.iterator();
    while (entries.next()) |entry| {
        const document = entry.value_ptr.*;
        self.allocator.free(document.path);
        self.allocator.free(document.uri);
        document.deinit();
        self.allocator.destroy(document);
    }
    self.documents.deinit(self.allocator);
    {
        var it = self.varying_lookup.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.varying_lookup.deinit(self.allocator);
    }
    if (self.varying_entries.len > 0) self.allocator.free(self.varying_entries);
    if (self.varying_source.len > 0) self.allocator.free(self.varying_source);
    self.arena_state.promote(self.allocator).deinit();
}

pub fn getDocument(self: *Workspace, document: lsp.TextDocumentIdentifier) !?*Document {
    const path = try util.pathFromUri(self.allocator, document.uri);
    defer self.allocator.free(path);
    return self.documents.get(path);
}

pub fn getOrCreateDocument(
    self: *Workspace,
    document: lsp.VersionedTextDocumentIdentifier,
) !*Document {
    const path = try util.pathFromUri(self.allocator, document.uri);
    errdefer self.allocator.free(path);

    const entry = try self.documents.getOrPut(self.allocator, path);
    if (entry.found_existing) {
        self.allocator.free(path);
    } else {
        errdefer self.documents.removeByPtr(entry.key_ptr);

        const new_document = try self.allocator.create(Document);
        errdefer self.allocator.destroy(new_document);

        const uri_clone = try self.allocator.dupe(u8, document.uri);
        errdefer self.allocator.free(uri_clone);

        entry.key_ptr.* = path;
        new_document.* = .{
            .uri = uri_clone,
            .path = path,
            .workspace = self,
            .version = document.version,
        };
        entry.value_ptr.* = new_document;
    }
    return entry.value_ptr.*;
}

pub fn getOrLoadDocument(
    self: *Workspace,
    document: lsp.TextDocumentIdentifier,
) !*Document {
    const path = try util.pathFromUri(self.allocator, document.uri);
    errdefer self.allocator.free(path);

    const entry = try self.documents.getOrPut(self.allocator, path);
    if (entry.found_existing) {
        self.allocator.free(path);
    } else {
        errdefer self.documents.removeByPtr(entry.key_ptr);

        const max_megabytes = 16;
        const contents = try std.fs.cwd().readFileAlloc(self.allocator, path, max_megabytes << 20);
        errdefer self.allocator.free(contents);

        const new_document = try self.allocator.create(Document);
        errdefer self.allocator.destroy(new_document);

        const uri_clone = try self.allocator.dupe(u8, document.uri);
        errdefer self.allocator.free(uri_clone);

        entry.key_ptr.* = path;
        new_document.* = .{
            .uri = uri_clone,
            .path = path,
            .workspace = self,
            .version = null,
            .contents = std.ArrayListUnmanaged(u8).fromOwnedSlice(contents),
        };
        entry.value_ptr.* = new_document;
    }
    return entry.value_ptr.*;
}

fn builtinCompletions(arena: std.mem.Allocator, spec: *const Spec) ![]lsp.CompletionItem {
    var completions = std.ArrayList(lsp.CompletionItem).init(arena);

    try completions.ensureUnusedCapacity(
        spec.types.len + spec.variables.len + spec.functions.len,
    );

    for (spec.types) |typ| {
        try completions.append(.{
            .label = typ.name,
            .kind = .class,
            .documentation = .{
                .kind = .markdown,
                .value = try std.mem.join(arena, "\n\n", typ.description),
            },
        });
    }

    keywords: for (spec.keywords) |keyword| {
        for (spec.types) |typ| {
            if (std.mem.eql(u8, keyword.name, typ.name)) {
                continue :keywords;
            }
        }

        try completions.append(.{
            .label = keyword.name,
            .kind = .keyword,
            .documentation = .{
                .kind = .markdown,
                .value = switch (keyword.kind) {
                    .glsl => "Available in standard GLSL.",
                    .vulkan => "Only available when targeting Vulkan.",
                    .reserved => "Reserved for future use.",
                    .bgfx => "bgfx shader language extension.",
                },
            },
        });
    }

    for (spec.variables) |variable| {
        var anonymous_signature = std.ArrayList(u8).init(arena);
        try writeVariableSignature(variable, anonymous_signature.writer(), .{ .names = false });

        var named_signature = std.ArrayList(u8).init(arena);
        try writeVariableSignature(variable, named_signature.writer(), .{ .names = true });

        try completions.append(.{
            .label = variable.name,
            .labelDetails = .{ .detail = anonymous_signature.items },
            .detail = named_signature.items,
            .kind = .variable,
            .documentation = try itemDocumentation(arena, variable),
        });
    }

    for (spec.functions) |function| {
        var anonymous_signature = std.ArrayList(u8).init(arena);
        try writeFunctionSignature(function, anonymous_signature.writer(), .{ .names = false });

        var named_signature = std.ArrayList(u8).init(arena);
        try writeFunctionSignature(function, named_signature.writer(), .{ .names = true });

        try completions.append(.{
            .label = function.name,
            .labelDetails = .{ .detail = anonymous_signature.items },
            .kind = .function,
            .detail = named_signature.items,
            .documentation = try itemDocumentation(arena, function),
        });
    }

    for (spec.builtins.uniforms) |uniform| {
        var sig = std.ArrayList(u8).init(arena);
        try sig.writer().print("uniform {s} {s}", .{ uniform.type, uniform.name });
        try completions.append(.{
            .label = uniform.name,
            .kind = .variable,
            .detail = sig.items,
            .documentation = if (uniform.description) |desc| lsp.MarkupContent{ .kind = .markdown, .value = desc } else null,
        });
    }

    for (spec.macros) |macro| {
        var detail = std.ArrayList(u8).init(arena);
        if (macro.params.len > 0) {
            var i: usize = 1;
            for (macro.params) |param| {
                if (i > 1) try detail.appendSlice(", ");
                try detail.writer().print("${{{d}:{s}}}", .{ i, param });
                i += 1;
            }
        }
        try completions.append(.{
            .label = macro.name,
            .kind = .function,
            .detail = detail.items,
            .documentation = if (macro.description) |desc| lsp.MarkupContent{ .kind = .markdown, .value = desc } else null,
        });
    }

    for (spec.bgfx_functions) |func| {
        var sig = std.ArrayList(u8).init(arena);
        try sig.writer().print("{s} {s}(", .{ func.return_type, func.name });
        for (func.parameters, 0..) |param, i| {
            if (i != 0) try sig.appendSlice(", ");
            try sig.writer().print("{s} {s}", .{ param.type, param.name });
        }
        try sig.appendSlice(")");
        try completions.append(.{
            .label = func.name,
            .kind = .function,
            .detail = sig.items,
            .documentation = if (func.description) |desc| lsp.MarkupContent{ .kind = .markdown, .value = desc } else null,
        });
    }

    for (spec.builtins.varying_semantics) |semantic| {
        var sig = std.ArrayList(u8).init(arena);
        if (semantic.type_hint) |hint| {
            try sig.writer().print("{s} : {s}", .{ hint, semantic.name });
        } else {
            try sig.appendSlice(semantic.name);
        }
        try completions.append(.{
            .label = semantic.name,
            .kind = .enum_member,
            .detail = sig.items,
            .documentation = if (semantic.description) |desc| lsp.MarkupContent{ .kind = .markdown, .value = desc } else null,
        });
    }

    return completions.toOwnedSlice();
}

fn itemDocumentation(arena: std.mem.Allocator, item: anytype) !lsp.MarkupContent {
    var documentation = std.ArrayList(u8).init(arena);

    for (item.description orelse &.{}) |paragraph| {
        try documentation.appendSlice(paragraph);
        try documentation.appendSlice("\n\n");
    }

    if (item.extensions) |extensions| {
        try documentation.appendSlice("```glsl\n");
        for (extensions) |extension| {
            try documentation.writer().print("#extension {s} : enable\n", .{extension});
        }
        try documentation.appendSlice("```\n");
    }

    return .{ .kind = .markdown, .value = try documentation.toOwnedSlice() };
}

fn writeVariableSignature(
    variable: Spec.Variable,
    writer: anytype,
    options: struct { names: bool },
) !void {
    if (!std.meta.eql(variable.modifiers, .{ .in = true })) {
        try writer.print("{}", .{variable.modifiers});
        try writer.writeAll(" ");
    }

    try writer.writeAll(variable.type);

    if (options.names) {
        try writer.writeAll(" ");
        try writer.writeAll(variable.name);

        if (variable.default_value) |value| {
            try writer.writeAll(" = ");
            try writer.writeAll(value);
        }

        try writer.writeAll(";");
    }
}

fn writeFunctionSignature(
    function: Spec.Function,
    writer: anytype,
    options: struct { names: bool },
) !void {
    try writer.writeAll(function.return_type);
    try writer.writeAll(" ");
    if (options.names) try writer.writeAll(function.name);
    try writer.writeAll("(");
    for (function.parameters, 0..) |param, i| {
        if (i != 0) try writer.writeAll(", ");
        if (param.optional) try writer.writeAll("[");
        if (param.modifiers) |modifiers| {
            try writer.print("{}", .{modifiers});
            try writer.writeAll(" ");
        }
        if (options.names) {
            const array_start = std.mem.indexOfScalar(u8, param.type, '[') orelse param.type.len;
            try writer.writeAll(param.type[0..array_start]);
            try writer.writeAll(" ");
            try writer.writeAll(param.name);
            try writer.writeAll(param.type[array_start..]);
        } else {
            try writer.writeAll(param.type);
        }
        if (param.optional) try writer.writeAll("]");
    }
    try writer.writeAll(")");
}
