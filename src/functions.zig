//! Safe managed-function and collation trampolines for the Turso C ABI.
//!
//! Callback arguments are borrowed only for the duration of a callback. Text
//! and blob results are copied into wrapper-owned result boxes before returning
//! to C; Turso copies them and calls `valueDestructor` exactly once.
//!
//! Zig panics cannot be caught at a C boundary. User callbacks and optional
//! deinitializers supplied here MUST NOT panic, use `unreachable`, unwind, or
//! retain callback argument slices. Report ordinary callback failures through
//! `CallbackError`. The wrapper catches that closed error set and returns a
//! native Turso extension error value; no Zig error union crosses C.

const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");
const value_mod = @import("value.zig");
const cstring = @import("cstring.zig");
const ffi = @import("ffi.zig");
const invariant = @import("invariant.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Value = value_mod.Value;

/// Failures that a managed callback can safely return across its Zig API.
/// Each maps to the corresponding Turso extension result code.
pub const CallbackError = error{
    OutOfMemory,
    InvalidArguments,
    Corrupt,
    NotFound,
    AlreadyExists,
    PermissionDenied,
    Aborted,
    OutOfRange,
    Unimplemented,
    Internal,
    Unavailable,
    Custom,
    EndOfFile,
    ReadOnly,
    Interrupt,
    Busy,
    ConstraintViolation,
};

pub const CollationOrder = enum {
    less,
    equal,
    greater,
};

const AggregateStateHeader = struct {
    tracker: *AggregateTracker,
    previous: ?*AggregateStateHeader = null,
    next: ?*AggregateStateHeader = null,
    destroy: *const fn (*AggregateStateHeader) void,
};

/// Internal connection-scoped ownership fallback for an upstream error path
/// that discards sibling external aggregate pointers without invoking their
/// destructor. Normal native destructors detach states before freeing them.
pub const AggregateTracker = struct {
    head: ?*AggregateStateHeader = null,

    fn attach(self: *AggregateTracker, state: *AggregateStateHeader) void {
        state.previous = null;
        state.next = self.head;
        if (self.head) |head| head.previous = state;
        self.head = state;
    }

    fn detach(self: *AggregateTracker, state: *AggregateStateHeader) void {
        if (state.previous) |previous| {
            previous.next = state.next;
        } else {
            invariant.requireAggregateHead(self.head == state);
            self.head = state.next;
        }
        if (state.next) |next| next.previous = state.previous;
        state.previous = null;
        state.next = null;
    }

    /// Call only after native reset/finalize/deinit has discarded every
    /// aggregate pointer for this connection's exclusive statement.
    pub fn cleanup(self: *AggregateTracker) void {
        while (self.head) |state| state.destroy(state);
    }

    pub fn isEmpty(self: *const AggregateTracker) bool {
        return self.head == null;
    }
};

/// Configuration moved into a scalar registration. `context_deinit` runs
/// exactly once: on registration failure, replacement, unregister, or final
/// connection teardown. The callback must not retain `args` or panic.
pub fn ScalarFunctionOptions(comptime Context: type) type {
    return struct {
        context: Context,
        callback: *const fn (context: *Context, args: []const Value) CallbackError!Value,
        context_deinit: ?*const fn (context: *Context) void = null,
        argc: i32 = -1,
        deterministic: bool = false,
    };
}

/// Configuration moved into an aggregate registration. A distinct `State` is
/// created for every aggregate group, including the zero-row aggregate path.
/// `state_deinit` owns only that state; it must not free registration context.
/// All callbacks and deinitializers must not panic or retain argument slices.
pub fn AggregateFunctionOptions(comptime Context: type, comptime State: type) type {
    return struct {
        context: Context,
        init: *const fn (context: *Context) CallbackError!State,
        step: *const fn (context: *Context, state: *State, args: []const Value) CallbackError!void,
        final: *const fn (context: *Context, state: *State) CallbackError!Value,
        context_deinit: ?*const fn (context: *Context) void = null,
        state_deinit: ?*const fn (state: *State) void = null,
        argc: i32 = -1,
    };
}

/// Configuration moved into a collation registration. Both byte slices are
/// valid UTF-8 borrowed only for the callback. The callback must not retain
/// them or panic.
pub fn CollationOptions(comptime Context: type) type {
    return struct {
        context: Context,
        compare: *const fn (context: *Context, left: []const u8, right: []const u8) CollationOrder,
        context_deinit: ?*const fn (context: *Context) void = null,
    };
}

pub fn registerScalarFunction(
    allocator: std.mem.Allocator,
    connection: *raw.turso_connection_t,
    name: []const u8,
    options: anytype,
    diagnostics: ?*Diagnostics,
) status_mod.Error!void {
    const Options = @TypeOf(options);
    const Context = @TypeOf(options.context);
    comptime requireScalarOptions(Options, Context);

    const Box = ScalarBox(Context);
    const box = allocator.create(Box) catch {
        if (options.context_deinit) |deinit| deinit(@constCast(&options.context));
        ffi.setWrapperError(diagnostics, "scalar registration context could not be allocated");
        return error.OutOfMemory;
    };
    box.* = .{
        .allocator = allocator,
        .context = options.context,
        .callback = options.callback,
        .context_deinit = options.context_deinit,
    };
    var owned = true;
    defer if (owned) Box.destroy(@intFromPtr(box));

    if (options.argc < -1) {
        ffi.setWrapperError(diagnostics, "function argument count must be -1 or non-negative");
        return error.InvalidState;
    }
    const name_z = cstring.dupe(allocator, name) catch |err| {
        ffi.setWrapperError(diagnostics, "function name must be valid UTF-8 without an interior NUL and must be copyable");
        return err;
    };
    defer allocator.free(name_z);
    if (name_z.len == 0) {
        ffi.setWrapperError(diagnostics, "function name must not be empty");
        return error.InvalidState;
    }

    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_connection_register_scalar_function(
        connection,
        name_z.ptr,
        options.argc,
        options.deterministic,
        @intFromPtr(box),
        Box.call,
        Box.destroy,
        valueDestructor,
        &native_error,
    );
    try ffi.expect(native_status, native_error, .ok, diagnostics, "scalar registration returned an unexpected control status");
    owned = false;
}

pub fn registerAggregateFunction(
    allocator: std.mem.Allocator,
    connection: *raw.turso_connection_t,
    tracker: *AggregateTracker,
    name: []const u8,
    options: anytype,
    diagnostics: ?*Diagnostics,
) status_mod.Error!void {
    const Options = @TypeOf(options);
    const Context = @TypeOf(options.context);
    const State = aggregateStateType(Options);
    comptime requireAggregateOptions(Options, Context, State);

    const Box = AggregateBox(Context, State);
    const box = allocator.create(Box) catch {
        if (options.context_deinit) |deinit| deinit(@constCast(&options.context));
        ffi.setWrapperError(diagnostics, "aggregate registration context could not be allocated");
        return error.OutOfMemory;
    };
    box.* = .{
        .allocator = allocator,
        .context = options.context,
        .init_callback = options.init,
        .step_callback = options.step,
        .final_callback = options.final,
        .context_deinit = options.context_deinit,
        .state_deinit = options.state_deinit,
        .tracker = tracker,
    };
    var owned = true;
    defer if (owned) Box.destroy(@intFromPtr(box));

    if (options.argc < -1) {
        ffi.setWrapperError(diagnostics, "function argument count must be -1 or non-negative");
        return error.InvalidState;
    }
    const name_z = cstring.dupe(allocator, name) catch |err| {
        ffi.setWrapperError(diagnostics, "function name must be valid UTF-8 without an interior NUL and must be copyable");
        return err;
    };
    defer allocator.free(name_z);
    if (name_z.len == 0) {
        ffi.setWrapperError(diagnostics, "function name must not be empty");
        return error.InvalidState;
    }

    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_connection_register_aggregate_function(
        connection,
        name_z.ptr,
        options.argc,
        @intFromPtr(box),
        Box.init,
        Box.step,
        Box.final,
        Box.destroy,
        Box.destroyState,
        valueDestructor,
        &native_error,
    );
    try ffi.expect(native_status, native_error, .ok, diagnostics, "aggregate registration returned an unexpected control status");
    owned = false;
}

pub fn registerCollation(
    allocator: std.mem.Allocator,
    connection: *raw.turso_connection_t,
    name: []const u8,
    options: anytype,
    diagnostics: ?*Diagnostics,
) status_mod.Error!void {
    const Options = @TypeOf(options);
    const Context = @TypeOf(options.context);
    comptime requireCollationOptions(Options, Context);

    const Box = CollationBox(Context);
    const box = allocator.create(Box) catch {
        if (options.context_deinit) |deinit| deinit(@constCast(&options.context));
        ffi.setWrapperError(diagnostics, "collation registration context could not be allocated");
        return error.OutOfMemory;
    };
    box.* = .{
        .allocator = allocator,
        .context = options.context,
        .compare = options.compare,
        .context_deinit = options.context_deinit,
    };
    var owned = true;
    defer if (owned) Box.destroy(@intFromPtr(box));

    const name_z = cstring.dupe(allocator, name) catch |err| {
        ffi.setWrapperError(diagnostics, "collation name must be valid UTF-8 without an interior NUL and must be copyable");
        return err;
    };
    defer allocator.free(name_z);
    if (name_z.len == 0) {
        ffi.setWrapperError(diagnostics, "collation name must not be empty");
        return error.InvalidState;
    }

    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_connection_register_collation(
        connection,
        name_z.ptr,
        @intFromPtr(box),
        Box.call,
        Box.destroy,
        &native_error,
    );
    try ffi.expect(native_status, native_error, .ok, diagnostics, "collation registration returned an unexpected control status");
    owned = false;
}

pub fn unregisterFunction(
    allocator: std.mem.Allocator,
    connection: *raw.turso_connection_t,
    name: []const u8,
    diagnostics: ?*Diagnostics,
) status_mod.Error!void {
    const name_z = try checkedName(allocator, name, diagnostics, "function");
    defer allocator.free(name_z);
    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_connection_unregister_function(connection, name_z.ptr, &native_error);
    try ffi.expect(
        native_status,
        native_error,
        .ok,
        diagnostics,
        "function unregister returned an unexpected control status",
    );
}

pub fn unregisterCollation(
    allocator: std.mem.Allocator,
    connection: *raw.turso_connection_t,
    name: []const u8,
    diagnostics: ?*Diagnostics,
) status_mod.Error!void {
    const name_z = try checkedName(allocator, name, diagnostics, "collation");
    defer allocator.free(name_z);
    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_connection_unregister_collation(connection, name_z.ptr, &native_error);
    try ffi.expect(
        native_status,
        native_error,
        .ok,
        diagnostics,
        "collation unregister returned an unexpected control status",
    );
}

fn checkedName(
    allocator: std.mem.Allocator,
    name: []const u8,
    diagnostics: ?*Diagnostics,
    comptime category: []const u8,
) status_mod.Error![:0]u8 {
    const name_z = cstring.dupe(allocator, name) catch |err| {
        ffi.setWrapperError(diagnostics, category ++ " name must be valid UTF-8 without an interior NUL and must be copyable");
        return err;
    };
    if (name_z.len == 0) {
        allocator.free(name_z);
        ffi.setWrapperError(diagnostics, category ++ " name must not be empty");
        return error.InvalidState;
    }
    return name_z;
}

fn ScalarBox(comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        context: Context,
        callback: *const fn (*Context, []const Value) CallbackError!Value,
        context_deinit: ?*const fn (*Context) void,

        fn call(
            context: usize,
            argc: i32,
            argv: [*c]const raw.turso_value_t,
            _: raw.turso_context_destructor_t,
            _: raw.turso_value_destructor_t,
        ) callconv(.c) raw.turso_value_t {
            if (context == 0) return staticOutOfMemory();
            const self: *Self = @ptrFromInt(context);
            const args = decodeArgs(self.allocator, argc, argv) catch |err| return makeError(self.allocator, err);
            defer self.allocator.free(args);
            const result = self.callback(&self.context, args) catch |err| return makeError(self.allocator, err);
            return makeValue(self.allocator, result);
        }

        fn destroy(context: usize) callconv(.c) void {
            if (context == 0) return;
            const self: *Self = @ptrFromInt(context);
            if (self.context_deinit) |deinit| deinit(&self.context);
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}

fn AggregateBox(comptime Context: type, comptime State: type) type {
    return struct {
        const Self = @This();
        const StateStorage = union(enum) {
            ready: State,
            failed: CallbackError,
        };
        const StateBox = struct {
            header: AggregateStateHeader,
            native: raw.turso_agg_ctx_t,
            allocator: std.mem.Allocator,
            state_deinit: ?*const fn (*State) void,
            storage: StateStorage,
        };

        allocator: std.mem.Allocator,
        context: Context,
        init_callback: *const fn (*Context) CallbackError!State,
        step_callback: *const fn (*Context, *State, []const Value) CallbackError!void,
        final_callback: *const fn (*Context, *State) CallbackError!Value,
        context_deinit: ?*const fn (*Context) void,
        state_deinit: ?*const fn (*State) void,
        tracker: *AggregateTracker,

        fn init(context: usize) callconv(.c) ?*raw.turso_agg_ctx_t {
            if (context == 0) return null;
            const self: *Self = @ptrFromInt(context);
            const state_box = self.allocator.create(StateBox) catch return null;
            state_box.* = .{
                .header = .{
                    .tracker = self.tracker,
                    .destroy = destroyTrackedState,
                },
                .native = .{ .state = null },
                .allocator = self.allocator,
                .state_deinit = self.state_deinit,
                .storage = undefined,
            };
            self.tracker.attach(&state_box.header);
            state_box.storage = if (self.init_callback(&self.context)) |state|
                .{ .ready = state }
            else |err|
                .{ .failed = err };
            return &state_box.native;
        }

        fn step(
            context: usize,
            aggregate_context: ?*raw.turso_agg_ctx_t,
            argc: i32,
            argv: [*c]const raw.turso_value_t,
        ) callconv(.c) raw.turso_value_t {
            if (context == 0 or aggregate_context == null) return staticOutOfMemory();
            const self: *Self = @ptrFromInt(context);
            const state_box: *StateBox = @fieldParentPtr("native", aggregate_context.?);
            switch (state_box.storage) {
                .failed => |err| return makeError(self.allocator, err),
                .ready => |*state| {
                    const args = decodeArgs(self.allocator, argc, argv) catch |err| return makeError(self.allocator, err);
                    defer self.allocator.free(args);
                    self.step_callback(&self.context, state, args) catch |err| return makeError(self.allocator, err);
                    return nullValue();
                },
            }
        }

        fn final(context: usize, aggregate_context: ?*raw.turso_agg_ctx_t) callconv(.c) raw.turso_value_t {
            if (context == 0 or aggregate_context == null) return staticOutOfMemory();
            const self: *Self = @ptrFromInt(context);
            const state_box: *StateBox = @fieldParentPtr("native", aggregate_context.?);
            switch (state_box.storage) {
                .failed => |err| return makeError(self.allocator, err),
                .ready => |*state| {
                    const result = self.final_callback(&self.context, state) catch |err| return makeError(self.allocator, err);
                    return makeValue(self.allocator, result);
                },
            }
        }

        fn destroy(context: usize) callconv(.c) void {
            if (context == 0) return;
            const self: *Self = @ptrFromInt(context);
            if (self.context_deinit) |deinit| deinit(&self.context);
            const allocator = self.allocator;
            allocator.destroy(self);
        }

        fn destroyState(context: usize) callconv(.c) void {
            if (context == 0) return;
            const native: *raw.turso_agg_ctx_t = @ptrFromInt(context);
            const state_box: *StateBox = @fieldParentPtr("native", native);
            destroyStateBox(state_box);
        }

        fn destroyTrackedState(header: *AggregateStateHeader) void {
            const state_box: *StateBox = @fieldParentPtr("header", header);
            destroyStateBox(state_box);
        }

        fn destroyStateBox(state_box: *StateBox) void {
            state_box.header.tracker.detach(&state_box.header);
            switch (state_box.storage) {
                .ready => |*state| if (state_box.state_deinit) |deinit| deinit(state),
                .failed => {},
            }
            const allocator = state_box.allocator;
            allocator.destroy(state_box);
        }
    };
}

fn CollationBox(comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        context: Context,
        compare: *const fn (*Context, []const u8, []const u8) CollationOrder,
        context_deinit: ?*const fn (*Context) void,

        fn call(
            context: usize,
            left_ptr: [*c]const u8,
            left_len: usize,
            right_ptr: [*c]const u8,
            right_len: usize,
        ) callconv(.c) i32 {
            if (context == 0) return 0;
            const self: *Self = @ptrFromInt(context);
            const left = borrowedBytes(left_ptr, left_len) orelse return 0;
            const right = borrowedBytes(right_ptr, right_len) orelse return 0;
            return switch (self.compare(&self.context, left, right)) {
                .less => -1,
                .equal => 0,
                .greater => 1,
            };
        }

        fn destroy(context: usize) callconv(.c) void {
            if (context == 0) return;
            const self: *Self = @ptrFromInt(context);
            if (self.context_deinit) |deinit| deinit(&self.context);
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}

fn decodeArgs(
    allocator: std.mem.Allocator,
    argc: i32,
    argv: [*c]const raw.turso_value_t,
) CallbackError![]Value {
    if (argc < 0) return error.InvalidArguments;
    const count: usize = @intCast(argc);
    if (count != 0 and argv == null) return error.InvalidArguments;
    const values = allocator.alloc(Value, count) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    for (values, 0..) |*destination, index| {
        destination.* = try decodeValue(argv[index]);
    }
    return values;
}

fn decodeValue(native: raw.turso_value_t) CallbackError!Value {
    return switch (native.value_type) {
        raw.TURSO_EXTENSION_VALUE_NULL => .null_value,
        raw.TURSO_EXTENSION_VALUE_INTEGER => .{ .integer = native.value.int_value },
        raw.TURSO_EXTENSION_VALUE_FLOAT => .{ .real = native.value.float_value },
        raw.TURSO_EXTENSION_VALUE_TEXT => blk: {
            const text = native.value.text;
            if (text == null) return error.InvalidArguments;
            const bytes = borrowedBytes(text.*.text, text.*.len) orelse return error.InvalidArguments;
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArguments;
            break :blk .{ .text = bytes };
        },
        raw.TURSO_EXTENSION_VALUE_BLOB => blk: {
            const blob = native.value.blob;
            if (blob == null) return error.InvalidArguments;
            const len = std.math.cast(usize, blob.*.size) orelse return error.OutOfRange;
            const bytes = borrowedBytes(blob.*.data, len) orelse return error.InvalidArguments;
            break :blk .{ .blob = bytes };
        },
        else => error.InvalidArguments,
    };
}

fn borrowedBytes(pointer: [*c]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    if (pointer == null) return null;
    return pointer[0..len];
}

const TextBox = struct {
    allocator: std.mem.Allocator,
    native: raw.turso_extension_text_t,
    bytes: []u8,
};

const BlobBox = struct {
    allocator: std.mem.Allocator,
    native: raw.turso_extension_blob_t,
    bytes: []u8,
};

const ErrorBox = struct {
    allocator: std.mem.Allocator,
    native_error: raw.turso_extension_error_t,
    native_message: raw.turso_extension_text_t,
    bytes: []u8,
};

const oom_error = raw.turso_extension_error_t{
    .code = raw.TURSO_EXTENSION_RESULT_OOM,
    .message = null,
};

fn makeValue(allocator: std.mem.Allocator, value: Value) raw.turso_value_t {
    return switch (value) {
        .null_value => nullValue(),
        .integer => |number| .{
            .value_type = raw.TURSO_EXTENSION_VALUE_INTEGER,
            .value = .{ .int_value = number },
        },
        .real => |number| .{
            .value_type = raw.TURSO_EXTENSION_VALUE_FLOAT,
            .value = .{ .float_value = number },
        },
        .text => |bytes| makeText(allocator, bytes),
        .blob => |bytes| makeBlob(allocator, bytes),
    };
}

fn makeText(allocator: std.mem.Allocator, bytes: []const u8) raw.turso_value_t {
    if (!std.unicode.utf8ValidateSlice(bytes)) return makeError(allocator, error.InvalidArguments);
    const len = std.math.cast(u32, bytes.len) orelse return makeError(allocator, error.OutOfRange);
    const box = allocator.create(TextBox) catch return staticOutOfMemory();
    box.* = .{
        .allocator = allocator,
        .native = .{ .subtype = raw.TURSO_EXTENSION_TEXT_TEXT, .text = null, .len = len },
        .bytes = allocator.dupe(u8, bytes) catch {
            allocator.destroy(box);
            return staticOutOfMemory();
        },
    };
    box.native.text = box.bytes.ptr;
    return .{
        .value_type = raw.TURSO_EXTENSION_VALUE_TEXT,
        .value = .{ .text = &box.native },
    };
}

fn makeBlob(allocator: std.mem.Allocator, bytes: []const u8) raw.turso_value_t {
    const box = allocator.create(BlobBox) catch return staticOutOfMemory();
    box.* = .{
        .allocator = allocator,
        .native = .{ .data = null, .size = bytes.len },
        .bytes = allocator.dupe(u8, bytes) catch {
            allocator.destroy(box);
            return staticOutOfMemory();
        },
    };
    box.native.data = box.bytes.ptr;
    return .{
        .value_type = raw.TURSO_EXTENSION_VALUE_BLOB,
        .value = .{ .blob = &box.native },
    };
}

fn makeError(allocator: std.mem.Allocator, err: CallbackError) raw.turso_value_t {
    const message = @errorName(err);
    const len = std.math.cast(u32, message.len) orelse return staticOutOfMemory();
    const box = allocator.create(ErrorBox) catch return staticOutOfMemory();
    box.* = .{
        .allocator = allocator,
        .native_error = .{ .code = resultCode(err), .message = null },
        .native_message = .{ .subtype = raw.TURSO_EXTENSION_TEXT_TEXT, .text = null, .len = len },
        .bytes = allocator.dupe(u8, message) catch {
            allocator.destroy(box);
            return staticOutOfMemory();
        },
    };
    box.native_message.text = box.bytes.ptr;
    box.native_error.message = &box.native_message;
    return .{
        .value_type = raw.TURSO_EXTENSION_VALUE_ERROR,
        .value = .{ .@"error" = &box.native_error },
    };
}

fn staticOutOfMemory() raw.turso_value_t {
    return .{
        .value_type = raw.TURSO_EXTENSION_VALUE_ERROR,
        .value = .{ .@"error" = &oom_error },
    };
}

fn nullValue() raw.turso_value_t {
    return .{
        .value_type = raw.TURSO_EXTENSION_VALUE_NULL,
        .value = .{ .int_value = 0 },
    };
}

fn valueDestructor(result: ?*raw.turso_value_t) callconv(.c) void {
    const value = result orelse return;
    switch (value.value_type) {
        raw.TURSO_EXTENSION_VALUE_TEXT => {
            const native = value.value.text;
            value.* = nullValue();
            if (native == null) return;
            const native_ptr: *raw.turso_extension_text_t = @ptrCast(@constCast(native));
            const box: *TextBox = @fieldParentPtr("native", native_ptr);
            const allocator = box.allocator;
            allocator.free(box.bytes);
            allocator.destroy(box);
        },
        raw.TURSO_EXTENSION_VALUE_BLOB => {
            const native = value.value.blob;
            value.* = nullValue();
            if (native == null) return;
            const native_ptr: *raw.turso_extension_blob_t = @ptrCast(@constCast(native));
            const box: *BlobBox = @fieldParentPtr("native", native_ptr);
            const allocator = box.allocator;
            allocator.free(box.bytes);
            allocator.destroy(box);
        },
        raw.TURSO_EXTENSION_VALUE_ERROR => {
            const native = value.value.@"error";
            value.* = nullValue();
            if (native == null or native.*.message == null) return;
            const native_ptr: *raw.turso_extension_error_t = @ptrCast(@constCast(native));
            const box: *ErrorBox = @fieldParentPtr("native_error", native_ptr);
            const allocator = box.allocator;
            allocator.free(box.bytes);
            allocator.destroy(box);
        },
        else => value.* = nullValue(),
    }
}

fn resultCode(err: CallbackError) raw.turso_extension_result_code_t {
    return switch (err) {
        error.OutOfMemory => raw.TURSO_EXTENSION_RESULT_OOM,
        error.InvalidArguments => raw.TURSO_EXTENSION_RESULT_INVALID_ARGS,
        error.Corrupt => raw.TURSO_EXTENSION_RESULT_CORRUPT,
        error.NotFound => raw.TURSO_EXTENSION_RESULT_NOT_FOUND,
        error.AlreadyExists => raw.TURSO_EXTENSION_RESULT_ALREADY_EXISTS,
        error.PermissionDenied => raw.TURSO_EXTENSION_RESULT_PERMISSION_DENIED,
        error.Aborted => raw.TURSO_EXTENSION_RESULT_ABORTED,
        error.OutOfRange => raw.TURSO_EXTENSION_RESULT_OUT_OF_RANGE,
        error.Unimplemented => raw.TURSO_EXTENSION_RESULT_UNIMPLEMENTED,
        error.Internal => raw.TURSO_EXTENSION_RESULT_INTERNAL,
        error.Unavailable => raw.TURSO_EXTENSION_RESULT_UNAVAILABLE,
        error.Custom => raw.TURSO_EXTENSION_RESULT_CUSTOM_ERROR,
        error.EndOfFile => raw.TURSO_EXTENSION_RESULT_EOF,
        error.ReadOnly => raw.TURSO_EXTENSION_RESULT_READ_ONLY,
        error.Interrupt => raw.TURSO_EXTENSION_RESULT_INTERRUPT,
        error.Busy => raw.TURSO_EXTENSION_RESULT_BUSY,
        error.ConstraintViolation => raw.TURSO_EXTENSION_RESULT_CONSTRAINT_VIOLATION,
    };
}

fn aggregateStateType(comptime Options: type) type {
    const init_type = @typeInfo(@TypeOf(@as(Options, undefined).init)).pointer.child;
    const return_type = @typeInfo(init_type).@"fn".return_type.?;
    return @typeInfo(return_type).error_union.payload;
}

fn requireScalarOptions(comptime Options: type, comptime Context: type) void {
    const Expected = ScalarFunctionOptions(Context);
    if (Options != Expected) @compileError("registerScalarFunction options must be ScalarFunctionOptions(Context)");
}

fn requireAggregateOptions(comptime Options: type, comptime Context: type, comptime State: type) void {
    const Expected = AggregateFunctionOptions(Context, State);
    if (Options != Expected) @compileError("registerAggregateFunction options must be AggregateFunctionOptions(Context, State)");
}

fn requireCollationOptions(comptime Options: type, comptime Context: type) void {
    const Expected = CollationOptions(Context);
    if (Options != Expected) @compileError("registerCollation options must be CollationOptions(Context)");
}
