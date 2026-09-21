const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const File = std.Io.File;

const util = @import("util.zig");
const lsp = @import("lsp.zig");
const rpc = @import("jsonrpc.zig");
const Response = rpc.Response;
const Request = rpc.Request;

const Workspace = @import("Workspace.zig");
const cli = @import("cli.zig");
const analysis = @import("analysis.zig");
const parse = @import("parse.zig");
const VaryingDef = @import("VaryingDef.zig").VaryingDef;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

var stdout_buffer: [1024]u8 = undefined;

fn enableDevelopmentMode(_: []const u8) !void {
    std.log.warn("development mode not available on {s}", .{@tagName(builtin.os.tag)});
    return error.UnsupportedPlatform;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.gpa;
    var static_arena = std.heap.ArenaAllocator.init(allocator);
    defer static_arena.deinit();

    var alloc_args = try init.minimal.args.iterateAllocator(allocator);
    defer alloc_args.deinit();

    const args = try cli.Arguments.parse(io, &alloc_args);

    if (args.dev_mode) |stderr_target| {
        if (enableDevelopmentMode(stderr_target)) {
            std.debug.print("\x1b[2J", .{}); // clear screen
            std.log.info("entered development mode '{s}'", .{stderr_target});
        } else |err| {
            std.log.warn("couldn't enable development mode: {s}", .{@errorName(err)});
        }
    }

    if (args.format_file) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 30)) catch |err| {
            std.log.err("could not open '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };
        defer allocator.free(source);

        var ignored = std.array_list.Managed(parse.Token).init(allocator);
        defer ignored.deinit();

        var diagnostics = std.array_list.Managed(parse.Diagnostic).init(allocator);
        defer diagnostics.deinit();

        var tree = try parse.parse(allocator, source, .{
            .ignored = &ignored,
            .diagnostics = &diagnostics,
        });
        defer tree.deinit(allocator);

        if (diagnostics.items.len != 0) {
            for (diagnostics.items) |diagnostic| {
                const position = diagnostic.position(source);
                var stderr_writer = std.Io.File.stderr().writer(io, &stdout_buffer);
                const stderr = &stderr_writer.interface;
                try stderr.print(
                    "{s}:{}:{}: {s}\n",
                    .{ path, position.line + 1, position.character + 1, diagnostic.message },
                );
            }
            return 1;
        }

        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        const stdout = &stdout_writer.interface;

        try @import("format.zig").format(tree, source, stdout, .{
            .ignored = ignored.items,
        });
        try stdout.flush();

        return 0;
    }

    if (args.parse_file) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 30)) catch |err| {
            std.log.err("could not open '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };
        defer allocator.free(source);

        var diagnostics = std.array_list.Managed(parse.Diagnostic).init(allocator);
        defer diagnostics.deinit();

        var tree = try parse.parse(allocator, source, .{ .diagnostics = &diagnostics });
        defer tree.deinit(allocator);

        if (args.print_ast) {
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            const stdout = &stdout_writer.interface;
            try stdout.print("{f}", .{tree.format(source)});
            try stdout.flush();
        }

        if (diagnostics.items.len != 0) {
            for (diagnostics.items) |diagnostic| {
                const position = diagnostic.position(source);
                var stderr_writer = std.Io.File.stderr().writer(io, &stdout_buffer);
                const stderr = &stderr_writer.interface;
                try stderr.print(
                    "{s}:{}:{}: {s}\n",
                    .{ path, position.line + 1, position.character + 1, diagnostic.message },
                );
                try stderr.flush();
            }
            return 1;
        }

        return 0;
    }

    var channel: Channel = switch (args.channel) {
        .stdio => .{ .stdio = .{
            .stdout = std.Io.File.stdout(),
            .stdin = std.Io.File.stdin(),
        } },
        .socket => |port| blk: {
            if (builtin.os.tag == .wasi) {
                return error.UnsupportedPlatform;
            }

            const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

            var server = try address.listen(io, .{});
            defer server.deinit(io);

            const connection = try server.accept(io);
            std.log.info("incoming connection from {f}", .{connection.socket.address});
            break :blk .{ .socket = connection };
        },
    };
    defer channel.close(io);

    var channel_buffer: [1024]u8 = undefined;
    var channel_writer = channel.writer(io, &channel_buffer);
    var state = State{
        .io = io,
        .allocator = allocator,
        .channel = channel_writer.interface(),
        .workspace = try Workspace.init(allocator),
    };
    defer state.deinit();

    var reader_buffer: [1024]u8 = undefined;
    var reader = channel.reader(io, &reader_buffer);

    var header_buffer: [1024]u8 = undefined;
    var header_stream = std.Io.Writer.fixed(&header_buffer);

    var content_buffer = std.array_list.Managed(u8).init(allocator);
    defer content_buffer.deinit();

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const max_content_length = 4 << 20; // 4MB

    outer: while (state.running) {
        defer _ = parse_arena.reset(.retain_capacity);

        // read headers
        const headers = blk: {
            header_stream.end = 0;
            while (!std.mem.endsWith(u8, header_buffer[0..header_stream.end], "\r\n\r\n")) {
                _ = reader.interface().streamDelimiter(&header_stream, '\n') catch |err| {
                    if (err == error.EndOfStream) break :outer;
                    return err;
                };

                reader.interface().toss(1);
                _ = try header_stream.write("\n");
            }
            break :blk try parseHeaders(header_buffer[0..header_stream.end]);
        };

        // read content
        const contents = blk: {
            if (headers.content_length > max_content_length) return error.MessageTooLong;
            try content_buffer.resize(headers.content_length);
            const actual_length = try reader.interface().readSliceShort(content_buffer.items);
            if (actual_length < headers.content_length) return error.UnexpectedEof;
            break :blk content_buffer.items;
        };

        // parse message(s)
        var message = blk: {
            var scanner = std.json.Scanner.initCompleteInput(parse_arena.allocator(), contents);
            defer scanner.deinit();

            var diagnostics = std.json.Diagnostics{};
            scanner.enableDiagnostics(&diagnostics);

            break :blk std.json.parseFromTokenSourceLeaky(
                rpc.Message(Request),
                parse_arena.allocator(),
                &scanner,
                .{ .allocate = .alloc_if_needed },
            ) catch |err| {
                logJsonError(@errorName(err), diagnostics, contents);
                state.fail(.null, .{ .code = .parse_error, .message = @errorName(err) }) catch {};
                continue;
            };
        };

        state.handleMessage(io, &message) catch |err| switch (err) {
            error.Failure => continue,
            else => return err,
        };
    }

    return 0;
}

fn logJsonError(err: []const u8, diagnostics: std.json.Diagnostics, bytes: []const u8) void {
    std.log.err("{}:{}: {s}: '{f}'", .{
        diagnostics.getLine(),
        diagnostics.getColumn(),
        err,
        std.zig.fmtString(util.getJsonErrorContext(diagnostics, bytes)),
    });
}

const HeaderValues = struct {
    content_length: u32,
    mime_type: []const u8,
};

fn parseHeaders(bytes: []const u8) !HeaderValues {
    var content_length: ?u32 = null;
    var mime_type: []const u8 = "application/vscode-jsonrpc; charset=utf-8";

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidHeader;

        const name = trimmed[0..colon];
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], &std.ascii.whitespace);

        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = try std.fmt.parseInt(u32, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            mime_type = value;
        }
    }

    return HeaderValues{
        .content_length = content_length orelse return error.MissingContentLength,
        .mime_type = mime_type,
    };
}

pub const Channel = union(enum) {
    stdio: struct {
        stdin: std.Io.File,
        stdout: std.Io.File,
    },
    socket: std.Io.net.Stream,

    pub fn close(self: *Channel, io: std.Io) void {
        switch (self.*) {
            .stdio => {},
            .socket => |stream| stream.close(io),
        }
    }

    pub const ReadError = std.Io.File.ReadError || std.Io.net.Stream.ReadError || std.io.Reader.Error;
    pub const Reader = struct {
        channel: *Channel,

        stdin_reader: std.Io.File.Reader = undefined,
        socket_reader: std.Io.net.Stream.Reader = undefined,

        pub fn init(channel: *Channel, io: std.Io, buffer: []u8) Reader {
            var r: Reader = .{
                .channel = channel,
            };

            switch (r.channel.*) {
                .stdio => |stdio| r.stdin_reader = stdio.stdin.reader(io, buffer),
                .socket => |stream| r.socket_reader = stream.reader(io, buffer),
            }

            return r;
        }

        pub fn interface(r: *Reader) *std.Io.Reader {
            return switch (r.channel.*) {
                .stdio => &r.stdin_reader.interface,
                .socket => &r.socket_reader.interface,
            };
        }
    };

    pub fn reader(self: *Channel, io: std.Io, buffer: []u8) Reader {
        return .init(self, io, buffer);
    }

    pub const WriteError = std.Io.File.Writer.Error || std.Io.net.Stream.Writer.Error || std.json.Stringify.Error;
    pub const Writer = struct {
        channel: *Channel,

        stdout_writer: std.Io.File.Writer = undefined,
        socket_writer: std.Io.net.Stream.Writer = undefined,

        pub fn init(channel: *Channel, io: std.Io, buffer: []u8) Writer {
            var w: Writer = .{
                .channel = channel,
            };

            switch (w.channel.*) {
                .stdio => |stdio| w.stdout_writer = stdio.stdout.writer(io, buffer),
                .socket => |stream| w.socket_writer = stream.writer(io, buffer),
            }

            return w;
        }

        pub fn interface(w: *Writer) *std.Io.Writer {
            return switch (w.channel.*) {
                .stdio => &w.stdout_writer.interface,
                .socket => &w.socket_writer.interface,
            };
        }
    };

    pub fn writer(self: *Channel, io: std.Io, buffer: []u8) Writer {
        return .init(self, io, buffer);
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    channel: *std.Io.Writer,
    running: bool = true,
    initialized: bool = false,
    parent_pid: ?c_int = null,
    workspace: Workspace,
    varying_def_path: ?[]const u8 = null,

    pub fn deinit(self: *State) void {
        self.workspace.deinit();
    }

    fn handleMessage(self: *State, io: std.Io, message: *rpc.Message(Request)) !void {
        switch (message.*) {
            .single => |*request| try self.dispatchRequest(io, request),
            .batch => |batch| try self.dispatchBatch(io, batch),
        }
    }

    fn dispatchBatch(self: *State, io: std.Io, requests: []Request) !void {
        for (requests) |*request| try self.dispatchRequest(io, request);
    }

    fn dispatchRequest(self: *State, io: std.Io, request: *Request) !void {
        if (!std.mem.eql(u8, request.jsonrpc, "2.0"))
            return self.fail(request.id, .{
                .code = .invalid_request,
                .message = "invalid jsonrpc version",
            });

        std.log.debug("method: '{f}'", .{std.zig.fmtString(request.method)});

        if (!self.initialized and !std.mem.eql(u8, request.method, "initialize"))
            return self.fail(request.id, .{
                .code = .server_not_initialized,
                .message = "server has not been initialized",
            });

        inline for (Dispatch.methods) |method| {
            if (std.mem.eql(u8, request.method, method)) {
                try @field(Dispatch, method)(self, io, request);
                return;
            }
        }

        // ignore unknown notifications
        if (request.id == .null) {
            std.log.debug("ignoring unknown '{f}' notification", .{std.zig.fmtString(request.method)});
            return;
        }

        return self.fail(request.id, .{
            .code = .method_not_found,
            .message = request.method,
        });
    }

    const SendError = Channel.WriteError;

    fn sendResponse(self: *State, response: *const Response) SendError!void {
        const format_options = std.json.Stringify.Options{
            .emit_null_optional_fields = false,
        };

        // get the size of the encoded message
        var counting: std.Io.Writer.Discarding = .init(&.{});
        try std.json.Stringify.value(response, format_options, &counting.writer);
        const content_length = counting.count;

        // send the message to the client
        try self.channel.print("Content-Length: {}\r\n\r\n", .{content_length});
        try std.json.Stringify.value(response, format_options, self.channel);
        try self.channel.flush();
    }

    pub fn fail(
        self: *State,
        id: Request.Id,
        err: lsp.Error,
    ) (error{Failure} || SendError) {
        try self.sendResponse(&.{ .id = id, .result = .{ .failure = err } });
        return error.Failure;
    }

    pub fn success(self: *State, id: Request.Id, data: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, data, .{});
        defer self.allocator.free(bytes);
        try self.sendResponse(&Response{ .id = id, .result = .{ .success = .{ .raw = bytes } } });
    }
};

const LineStart = struct {
    /// The utf-8 byte offset.
    utf8: u32,
    /// The utf-16 byte offset.
    utf16: u32,
};

const Diagnostic = struct {
    message: ?[]const u8 = null,
    /// If the message has been allocated, this is `false`, otherwise `true`.
    static: bool = true,
};

fn findVaryingDef(io: std.Io, allocator: std.mem.Allocator, root_path: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true}) catch return null;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "varying.def.sc")) {
            return std.fs.path.join(allocator, &.{ root_path, entry.path }) catch null;
        }
    }
    return null;
}

pub const Dispatch = struct {
    pub const methods = [_][]const u8{
        "initialize",
        "initialized",
        "shutdown",
        "textDocument/didOpen",
        "textDocument/didClose",
        "textDocument/didSave",
        "textDocument/didChange",
        "textDocument/completion",
        "textDocument/hover",
        "textDocument/formatting",
        "textDocument/definition",
    };

    fn parseParams(comptime T: type, state: *State, request: *Request) !std.json.Parsed(T) {
        return std.json.parseFromValue(T, state.allocator, request.params, .{
            .ignore_unknown_fields = true,
        });
    }

    fn isVaryingDef(uri: []const u8) bool {
        return std.mem.endsWith(u8, uri, "varying.def.sc");
    }

    fn getDocumentOrFail(
        state: *State,
        request: *Request,
        id: lsp.TextDocumentIdentifier,
    ) !*Workspace.Document {
        return try state.workspace.getDocument(id) orelse state.fail(request.id, .{
            .code = .invalid_params,
            .message = "document not found",
        });
    }

    pub const InitializeParams = struct {
        processId: ?c_int = null,
        rootUri: ?[]const u8 = null,
        clientInfo: ?struct {
            name: []const u8,
            version: ?[]const u8 = null,
        } = null,
        capabilities: lsp.ClientCapabilities,
    };

    pub fn initialize(state: *State, io: std.Io, request: *Request) !void {
        if (state.initialized) {
            return state.fail(request.id, .{
                .code = .invalid_request,
                .message = "server already initialized",
            });
        }

        const params = try parseParams(InitializeParams, state, request);
        defer params.deinit();

        // TODO: Parse initializationOptions for bgfx configuration:
        //   - includePaths: []const []const u8 — extra bgfx include directories
        //   - targetPlatform: enum { glsl, hlsl, metal, spirv } — target shader platform
        //   - varyingDefPath: ?[]const u8 — path to varying.def.sc for $input/$output type resolution
        //   - glslVersion: u32 — GLSL version target (default: 430)
        // These would be read from request.params["initializationOptions"]["bgfx"]
        // and stored on the State struct for use by analysis/formatting.

        try state.success(request.id, .{
            .capabilities = .{
                .completionProvider = .{
                    .triggerCharacters = &.{ ".", ":" },
                },
                .textDocumentSync = .{
                    .openClose = true,
                    .change = @intFromEnum(lsp.TextDocumentSyncKind.incremental),
                    .willSave = false,
                    .willSaveWaitUntil = false,
                    .save = .{ .includeText = false },
                },
                .hoverProvider = true,
                .documentFormattingProvider = true,
                .definitionProvider = true,
            },
            .serverInfo = .{ .name = "bgfx_shader_analyzer" },
        });

        state.initialized = true;
        state.parent_pid = state.parent_pid orelse params.value.processId;

        if (params.value.rootUri) |root_uri| {
            const root_path = util.pathFromUri(state.allocator, root_uri) catch null;
            if (root_path) |rp| {
                defer state.allocator.free(rp);
                if (findVaryingDef(io, state.allocator, rp)) |found_path| {
                    const load_result = state.workspace.loadVaryingDef(io, found_path);
                    if (load_result) {
                        state.varying_def_path = found_path;
                        std.log.info("loaded varying.def.sc from: {s}", .{found_path});
                    } else |_| {
                        state.allocator.free(found_path);
                    }
                }
            }
        }
    }

    pub fn shutdown(state: *State, _: std.Io, request: *Request) !void {
        state.running = false;
        try state.success(request.id, null);
    }

    pub fn initialized(state: *State, _: std.Io, request: *Request) !void {
        _ = request;
        _ = state;
        return;
    }

    pub const DidOpenParams = struct {
        textDocument: lsp.TextDocumentItem,
    };

    pub fn @"textDocument/didOpen"(state: *State, _: std.Io, request: *Request) !void {
        const params = try parseParams(DidOpenParams, state, request);
        defer params.deinit();

        const document = &params.value.textDocument;
        std.log.debug("opened: {s} : {s} : {} : {}", .{
            document.uri,
            document.languageId,
            document.version,
            document.text.len,
        });

        const file = try state.workspace.getOrCreateDocument(document.versioned());
        try file.replaceAll(document.text);

        return;
    }

    pub const DidCloseParams = struct {
        textDocument: lsp.TextDocumentIdentifier,
    };

    pub fn @"textDocument/didClose"(state: *State, _: std.Io, request: *Request) !void {
        const params = try parseParams(DidCloseParams, state, request);
        defer params.deinit();
        std.log.debug("closed: {s}", .{params.value.textDocument.uri});
        return;
    }

    pub const DidSaveParams = struct {
        textDocument: lsp.TextDocumentIdentifier,
        text: ?[]const u8 = null,
    };

    pub fn @"textDocument/didSave"(state: *State, io: std.Io, request: *Request) !void {
        const params = try parseParams(DidSaveParams, state, request);
        defer params.deinit();

        std.log.debug("saved: {s} : {?}", .{
            params.value.textDocument.uri,
            if (params.value.text) |text| text.len else null,
        });

        if (state.varying_def_path) |stored_path| {
            const saved_path = util.pathFromUri(state.allocator, params.value.textDocument.uri) catch null;
            if (saved_path) |sp| {
                defer state.allocator.free(sp);
                if (std.mem.eql(u8, sp, stored_path)) {
                    std.log.info("varying.def.sc saved, reloading", .{});
                    state.workspace.loadVaryingDef(io, stored_path) catch |err| {
                        std.log.err("failed to reload varying.def.sc: {s}", .{@errorName(err)});
                    };
                }
            }
        }

        return;
    }

    pub const DidChangeParams = struct {
        textDocument: lsp.VersionedTextDocumentIdentifier,
        contentChanges: []const lsp.TextDocumentContentChangeEvent,
    };

    pub fn @"textDocument/didChange"(state: *State, _: std.Io, request: *Request) !void {
        const params = try parseParams(DidChangeParams, state, request);
        defer params.deinit();

        std.log.debug("didChange: {s}", .{params.value.textDocument.uri});
        const file = try state.workspace.getOrCreateDocument(params.value.textDocument);

        for (params.value.contentChanges) |change| {
            if (change.range) |range| {
                try file.replace(range, change.text);
            } else {
                try file.replaceAll(change.text);
            }
        }

        file.version = params.value.textDocument.version;
    }

    pub const CompletionParams = struct {
        textDocument: lsp.TextDocumentIdentifier,
        position: lsp.Position,
    };

    pub fn @"textDocument/completion"(state: *State, io: std.Io, request: *Request) !void {
        const params = try parseParams(CompletionParams, state, request);
        defer params.deinit();

        std.log.debug("complete: {f} {s}", .{ params.value.position, params.value.textDocument.uri });

        const document = try getDocumentOrFail(state, request, params.value.textDocument);

        var symbol_arena = std.heap.ArenaAllocator.init(state.allocator);
        defer symbol_arena.deinit();

        if (isVaryingDef(params.value.textDocument.uri)) {
            const source = document.source();
            const line_start = blk: {
                var pos: usize = 0;
                var remaining = params.value.position.line;
                while (remaining > 0 and pos < source.len) : (pos += 1) {
                    if (source[pos] == '\n') remaining -= 1;
                }
                break :blk pos;
            };
            const line_end = if (std.mem.indexOfScalarPos(u8, source, line_start, '\n')) |e| e else source.len;
            const line = source[line_start..line_end];

            const cursor_byte = document.utf8FromPosition(params.value.position);
            const cursor_in_line: u32 = if (cursor_byte >= line_start and cursor_byte <= line_end)
                @intCast(cursor_byte - line_start)
            else
                @intCast(line.len);

            const context = VaryingDef.parseLineContext(line, cursor_in_line);

            const prefix_start = blk2: {
                var p = cursor_in_line;
                while (p > 0 and (std.ascii.isAlphanumeric(line[p - 1]) or line[p - 1] == '_')) {
                    p -= 1;
                }
                break :blk2 p;
            };
            const prefix = line[prefix_start..cursor_in_line];

            const items = try state.workspace.varyingDefCompletions(
                symbol_arena.allocator(),
                context,
                prefix,
            );
            try state.success(request.id, items);
            return;
        }

        var completions = std.array_list.Managed(lsp.CompletionItem).init(state.allocator);
        defer completions.deinit();

        const token = try document.tokenBeforeCursor(params.value.position);

        const parsed = try document.parseTree();
        if (token != null and parsed.tree.tag(token.?) == .comment) {
            // don't give completions in comments
            return state.success(request.id, null);
        }

        try completionsAtToken(
            state,
            io,
            document,
            token,
            &completions,
            symbol_arena.allocator(),
            .{ .ignore_current = true },
        );

        try state.success(request.id, completions.items);
    }

    fn completionsAtToken(
        state: *State,
        io: std.Io,
        document: *Workspace.Document,
        start_token: ?u32,
        completions: *std.array_list.Managed(lsp.CompletionItem),
        arena: std.mem.Allocator,
        options: struct { ignore_current: bool },
    ) !void {
        var has_fields = false;

        var symbols = std.array_list.Managed(analysis.Reference).init(arena);

        if (start_token) |token| {
            try analysis.visibleFields(io, arena, document, token, &symbols);
            has_fields = symbols.items.len != 0;

            if (!has_fields) try analysis.visibleSymbols(io, arena, document, token, &symbols);

            try completions.ensureUnusedCapacity(symbols.items.len);

            for (symbols.items) |symbol| {
                if (options.ignore_current and symbol.document == document and symbol.node == token) {
                    continue;
                }

                const parsed: *const Workspace.Document.CompleteParseTree = try symbol.document.parseTree();

                const symbol_type = try analysis.typeOf(symbol);

                const type_signature = if (symbol_type) |typ|
                    try std.fmt.allocPrint(arena, "{f}", .{
                        typ.format(parsed.tree, symbol.document.source()),
                    })
                else if (parsed.tree.tag(symbol.node) == .preprocessor) blk: {
                    const span = symbol.span();
                    break :blk symbol.document.source()[span.start..span.end];
                } else null;

                var completion: lsp.CompletionItem = .{
                    .label = symbol.name(),
                    .labelDetails = .{
                        .detail = type_signature,
                    },
                    .detail = type_signature,
                    .kind = switch (parsed.tree.tag(symbol.parent_declaration)) {
                        .struct_specifier => .class,
                        .function_declaration => .function,
                        .preprocessor => .constant,
                        else => blk: {
                            if (parsed.tree.parent(symbol.parent_declaration)) |grandparent| {
                                if (parsed.tree.tag(grandparent) == .field_declaration_list) {
                                    break :blk .field;
                                }
                            }
                            break :blk .variable;
                        },
                    },
                };

                if (type_signature == null and
                    (parsed.tree.tag(symbol.parent_declaration) == .bgfx_input or
                        parsed.tree.tag(symbol.parent_declaration) == .bgfx_output))
                {
                    const sym_name = symbol.name();
                    if (state.workspace.getVaryingInfo(sym_name)) |vary_info| {
                        const sig = try std.fmt.allocPrint(arena, "{s} {s} : {s}", .{
                            vary_info.type,
                            sym_name,
                            vary_info.semantic,
                        });
                        completion.detail = sig;
                        completion.labelDetails = .{ .detail = sig };
                        if (vary_info.default_value) |dv| {
                            completion.documentation = lsp.MarkupContent{
                                .kind = .markdown,
                                .value = try std.fmt.allocPrint(arena, "Default: `{s}`", .{dv}),
                            };
                        }
                    }
                }
                try completions.append(completion);
            }
        }

        if (!has_fields) {
            try completions.appendSlice(state.workspace.builtin_completions);
        }
    }

    pub const HoverParams = struct {
        textDocument: lsp.TextDocumentIdentifier,
        position: lsp.Position,
    };

    pub fn @"textDocument/hover"(state: *State, io: std.Io, request: *Request) !void {
        const params = try parseParams(HoverParams, state, request);
        defer params.deinit();

        std.log.debug("hover: {f} {s}", .{ params.value.position, params.value.textDocument.uri });

        const document = try getDocumentOrFail(state, request, params.value.textDocument);
        const parsed = try document.parseTree();

        const token = try document.identifierUnderCursor(params.value.position) orelse {
            return state.success(request.id, null);
        };

        if (parsed.tree.tag(token) != .identifier) {
            return state.success(request.id, null);
        }

        const token_span = parsed.tree.token(token);
        const token_text = document.source()[token_span.start..token_span.end];

        var completions = std.array_list.Managed(lsp.CompletionItem).init(state.allocator);
        defer completions.deinit();

        var symbol_arena = std.heap.ArenaAllocator.init(state.allocator);
        defer symbol_arena.deinit();

        try completionsAtToken(
            state,
            io,
            document,
            token,
            &completions,
            symbol_arena.allocator(),
            .{ .ignore_current = false },
        );

        // group completions by their documentation.
        var groups: std.array_hash_map.String(std.ArrayListUnmanaged(*const lsp.CompletionItem)) = .empty;
        defer groups.deinit(symbol_arena.allocator());

        for (completions.items) |*completion| {
            if (!std.mem.eql(u8, completion.label, token_text)) continue;

            const documentation_string = if (completion.documentation) |markup| markup.value else "";

            const result = try groups.getOrPut(symbol_arena.allocator(), documentation_string);
            if (!result.found_existing) result.value_ptr.* = .empty;
            try result.value_ptr.append(symbol_arena.allocator(), completion);
        }

        var text: std.Io.Writer.Allocating = .init(symbol_arena.allocator());
        defer text.deinit();

        for (groups.keys(), groups.values()) |description, group| {
            if (text.written().len != 0) {
                try text.writer.writeAll("\n\n---\n\n");
            }

            if (group.items.len != 0) {
                try text.writer.writeAll("```glsl\n");
                for (group.items) |completion| {
                    if (completion.detail) |detail| {
                        try text.writer.print("{s}\n", .{detail});
                    }
                }
                try text.writer.writeAll("```\n");
            }

            if (description.len != 0) {
                if (group.items.len != 0) try text.writer.writeAll("\n");
                try text.writer.writeAll(description);
            }
        }

        if (text.written().len == 0) {
            return state.success(request.id, null);
        }

        try state.success(request.id, .{
            .contents = lsp.MarkupContent{
                .kind = .markdown,
                .value = text.written(),
            },
        });
    }

    const FormattingParams = struct {
        textDocument: lsp.TextDocumentIdentifier,
        options: struct {
            tabSize: u32 = 4,
            insertSpaces: bool = true,
        },
    };

    pub fn @"textDocument/formatting"(state: *State, io: std.Io, request: *Request) !void {
        const params = try parseParams(FormattingParams, state, request);
        defer params.deinit();
        std.log.debug("format: {s} tabSize: {}", .{ params.value.textDocument.uri, params.value.options.tabSize });

        const document = try state.workspace.getOrLoadDocument(io, params.value.textDocument);
        const parsed = try document.parseTree();

        var buffer: std.Io.Writer.Allocating = .init(state.allocator);
        defer buffer.deinit();

        try @import("format.zig").format(
            parsed.tree,
            document.contents.items,
            &buffer.writer,
            .{
                .ignored = parsed.ignored,
                .tab_size = params.value.options.tabSize,
            },
        );

        try state.success(request.id, .{
            .{
                .range = document.wholeRange(),
                .newText = buffer.written(),
            },
        });
    }

    const DefinitionParams = struct {
        textDocument: lsp.TextDocumentIdentifier,
        position: lsp.Position,
    };

    pub fn @"textDocument/definition"(state: *State, io: std.Io, request: *Request) !void {
        const params = try parseParams(DefinitionParams, state, request);
        defer params.deinit();
        std.log.debug("goto definition: {f} {s}", .{
            params.value.position,
            params.value.textDocument.uri,
        });

        const document = try state.workspace.getOrLoadDocument(io, params.value.textDocument);
        const source_node = try document.identifierUnderCursor(params.value.position) orelse {
            std.log.debug("no node under cursor", .{});
            return state.success(request.id, null);
        };

        var references = std.array_list.Managed(analysis.Reference).init(state.allocator);
        defer references.deinit();

        var arena = std.heap.ArenaAllocator.init(state.allocator);
        defer arena.deinit();
        try analysis.findDefinition(io, arena.allocator(), document, source_node, &references);

        if (references.items.len == 0) {
            std.log.debug("could not find definition", .{});
            return state.success(request.id, null);
        }

        const locations = try state.allocator.alloc(lsp.Location, references.items.len);
        defer state.allocator.free(locations);

        for (references.items, locations) |reference, *location| {
            location.* = .{
                .uri = reference.document.uri,
                .range = try reference.document.nodeRange(reference.node),
            };
        }

        try state.success(request.id, locations);
    }
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("Workspace.zig"));
    std.testing.refAllDecls(@import("Document.zig"));
    std.testing.refAllDecls(@import("parse.zig"));
    std.testing.refAllDecls(@import("format.zig"));
    std.testing.refAllDecls(@import("analysis.zig"));
    std.testing.refAllDecls(@import("syntax.zig"));
    std.testing.refAllDecls(@import("VaryingDef.zig"));
    std.testing.refAllDecls(@import("BgfxMacros.zig"));
}
