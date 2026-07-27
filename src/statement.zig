const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");
const value_mod = @import("value.zig");
const ffi = @import("ffi.zig");
const row_mod = @import("row.zig");
const parameters = @import("parameters.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Value = value_mod.Value;
pub const Row = row_mod.Row;
pub const NamedBinding = parameters.NamedBinding;
pub const ParameterInfo = parameters.ParameterInfo;
pub const BindError = parameters.Error;
pub const ColumnInfo = row_mod.ColumnInfo;
pub const OperationControl = row_mod.OperationControl;
pub const AutocommitExpectation = row_mod.AutocommitExpectation;

pub const State = enum {
    ready,
    rows_ready,
    row,
    done,
    failed,
    finalized,
};

/// Policy selected when a native connection is adopted. Local blocking
/// connections reject caller-driven statement I/O; sync-owned connections
/// drive each I/O turn inline without adding an async public facade.
pub const IoPolicy = enum {
    reject_io,
    drive_io_inline,
};

/// Move-only prepared statement holding its connection's exclusive-operation
/// slot until deinit.
pub const Statement = struct {
    pub const NamedBinding = parameters.NamedBinding;
    pub const ParameterInfo = parameters.ParameterInfo;
    pub const ColumnInfo = row_mod.ColumnInfo;

    handle: ?*raw.turso_statement_t,
    operation_control: *OperationControl,
    generation: u64,
    io_policy: IoPolicy,
    state: State = .ready,

    pub fn parameterCount(self: *const Statement) status_mod.Error!usize {
        try self.ensureCurrent();
        const statement = self.handle orelse return error.InvalidState;
        if (self.state == .finalized) return error.InvalidState;
        const count = raw.turso_statement_parameters_count(statement);
        if (count < 0) return error.InvalidState;
        return std.math.cast(usize, count) orelse error.IntegerOverflow;
    }

    /// Copy one parameter's native SQL name. Positions are one-based. The
    /// pinned engine canonicalizes anonymous `?` slots to `?NNN`; a null result
    /// is reserved for a native slot without a name. The caller owns the bytes.
    pub fn parameterName(
        self: *const Statement,
        allocator: std.mem.Allocator,
        position: usize,
    ) status_mod.Error!?[]u8 {
        const statement = self.handle orelse return error.InvalidState;
        if (self.state == .finalized) return error.InvalidState;
        const count = try self.parameterCount();
        if (position == 0 or position > count) return error.ParameterNotFound;
        const native_name = raw.turso_statement_parameter_name(statement, @intCast(position));
        if (native_name == null) return null;
        defer raw.turso_str_deinit(native_name);
        return try allocator.dupe(u8, std.mem.sliceTo(native_name, 0));
    }

    pub fn parameterInfo(
        self: *const Statement,
        allocator: std.mem.Allocator,
        position: usize,
    ) status_mod.Error!parameters.ParameterInfo {
        return .{
            .position = position,
            .name = try self.parameterName(allocator, position),
        };
    }

    pub fn columnCount(self: *const Statement) status_mod.Error!usize {
        try self.ensureCurrent();
        const statement = self.handle orelse return error.InvalidState;
        if (self.state == .finalized) return error.InvalidState;
        const count = raw.turso_statement_column_count(statement);
        if (count < 0) return error.InvalidState;
        return std.math.cast(usize, count) orelse error.IntegerOverflow;
    }

    /// Copy complete column metadata. Every native string is freed immediately;
    /// the returned `ColumnInfo` owns only Zig allocations.
    pub fn columnInfo(
        self: *const Statement,
        allocator: std.mem.Allocator,
        index: usize,
    ) status_mod.Error!row_mod.ColumnInfo {
        const statement = self.handle orelse return error.InvalidState;
        if (index >= try self.columnCount()) return error.ColumnOutOfBounds;
        return row_mod.copyColumnInfo(allocator, statement, index);
    }

    /// Bind a one-based positional parameter.
    pub fn bind(self: *Statement, position: usize, value: Value, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const statement = try self.requireReady(diagnostics);
        const count = try self.parameterCount();
        if (position == 0 or position > count) {
            ffi.setWrapperError(diagnostics, "parameter position is outside the one-based statement parameter range");
            return error.ParameterNotFound;
        }
        switch (value) {
            .text => |bytes| if (!std.unicode.utf8ValidateSlice(bytes)) {
                ffi.setWrapperError(diagnostics, "SQL TEXT binding is not valid UTF-8");
                return error.InvalidUtf8;
            },
            else => {},
        }

        const native_status = switch (value) {
            .null_value => raw.turso_statement_bind_positional_null(statement, position),
            .integer => |item| raw.turso_statement_bind_positional_int(statement, position, item),
            .real => |item| raw.turso_statement_bind_positional_double(statement, position, item),
            .text => |bytes| raw.turso_statement_bind_positional_text(statement, position, bytes.ptr, bytes.len),
            .blob => |bytes| raw.turso_statement_bind_positional_blob(statement, position, bytes.ptr, bytes.len),
        };
        try ffi.expectWithoutMessage(native_status, .ok, diagnostics, "native positional parameter binding failed");
    }

    /// Bind one explicitly prefixed SQL parameter name.
    pub fn bindNamed(
        self: *Statement,
        name: []const u8,
        input: anytype,
        diagnostics: ?*Diagnostics,
    ) BindError!void {
        parameters.validateSqlName(name) catch |err| {
            ffi.setWrapperError(diagnostics, switch (err) {
                error.InteriorNul => "named parameter contains an interior NUL",
                error.InvalidUtf8 => "named parameter is not valid UTF-8",
                else => "named parameters require a : @ $ or numeric ? prefix",
            });
            return err;
        };
        const position = self.findExactParameter(name) catch |err| {
            ffi.setWrapperError(diagnostics, "named parameter was not found in the prepared statement");
            return err;
        };
        const value = value_mod.Value.init(input) catch |err| {
            ffi.setWrapperError(diagnostics, "named parameter value cannot be represented without truncation");
            return err;
        };
        return self.bind(position, value, diagnostics);
    }

    /// Bind a complete explicitly named set. Duplicate input names/slots,
    /// missing SQL parameters, and anonymous parameters are rejected.
    pub fn bindNamedAll(
        self: *Statement,
        bindings: []const parameters.NamedBinding,
        diagnostics: ?*Diagnostics,
    ) BindError!void {
        _ = try self.requireReady(diagnostics);
        const count = try self.parameterCount();
        if (bindings.len < count) {
            self.state = .failed;
            ffi.setWrapperError(diagnostics, "named binding set does not cover every SQL parameter slot");
            return error.MissingParameter;
        }
        if (bindings.len > count) {
            self.state = .failed;
            ffi.setWrapperError(diagnostics, "named binding set contains more entries than SQL parameter slots");
            return error.ParameterCountMismatch;
        }

        for (bindings, 0..) |binding, binding_index| {
            parameters.validateSqlName(binding.name) catch |err| {
                self.state = .failed;
                ffi.setWrapperError(diagnostics, switch (err) {
                    error.InteriorNul => "named parameter contains an interior NUL",
                    error.InvalidUtf8 => "named parameter is not valid UTF-8",
                    else => "named parameters require a : @ $ or numeric ? prefix",
                });
                return err;
            };
            const position = self.findExactParameter(binding.name) catch |err| {
                self.state = .failed;
                ffi.setWrapperError(diagnostics, "named parameter was not found in the prepared statement");
                return err;
            };
            for (bindings[0..binding_index]) |previous| {
                if (std.mem.eql(u8, previous.name, binding.name)) {
                    self.state = .failed;
                    ffi.setWrapperError(diagnostics, "named binding set contains a duplicate parameter");
                    return error.DuplicateParameter;
                }
                const previous_position = self.findExactParameter(previous.name) catch unreachable;
                if (previous_position == position) {
                    self.state = .failed;
                    ffi.setWrapperError(diagnostics, "multiple names resolve to the same SQL parameter slot");
                    return error.DuplicateParameter;
                }
            }
            self.bind(position, binding.value, diagnostics) catch |err| {
                self.state = .failed;
                return err;
            };
        }
        if (diagnostics) |detail| detail.clear();
    }

    /// Bind a tuple by one-based SQL position or a struct by bare named fields.
    pub fn bindParams(self: *Statement, input: anytype, diagnostics: ?*Diagnostics) BindError!void {
        const T = @TypeOf(input);
        const info = @typeInfo(T);
        if (info != .@"struct") return error.TypeMismatch;
        if (info.@"struct".is_tuple) return self.bindTuple(input, diagnostics);
        return self.bindStruct(input, diagnostics);
    }

    pub fn bindAll(self: *Statement, values: []const Value, diagnostics: ?*Diagnostics) status_mod.Error!void {
        _ = try self.requireReady(diagnostics);
        const count = try self.parameterCount();
        if (values.len != count) {
            ffi.setWrapperError(diagnostics, "bound value count does not match the statement parameter count");
            return error.ParameterCountMismatch;
        }
        for (values, 1..) |value, position| {
            self.bind(position, value, diagnostics) catch |err| {
                self.state = .failed;
                return err;
            };
        }
        if (diagnostics) |detail| detail.clear();
    }

    fn bindTuple(self: *Statement, input: anytype, diagnostics: ?*Diagnostics) BindError!void {
        _ = try self.requireReady(diagnostics);
        const fields = @typeInfo(@TypeOf(input)).@"struct".fields;
        if (fields.len != try self.parameterCount()) {
            self.state = .failed;
            ffi.setWrapperError(diagnostics, "tuple field count does not match SQL parameter count");
            return error.ParameterCountMismatch;
        }
        inline for (fields, 1..) |field, position| {
            const value = value_mod.Value.init(@field(input, field.name)) catch |err| {
                self.state = .failed;
                ffi.setWrapperError(diagnostics, "tuple parameter cannot be represented without truncation");
                return err;
            };
            self.bind(position, value, diagnostics) catch |err| {
                self.state = .failed;
                return err;
            };
        }
        if (diagnostics) |detail| detail.clear();
    }

    fn bindStruct(self: *Statement, input: anytype, diagnostics: ?*Diagnostics) BindError!void {
        _ = try self.requireReady(diagnostics);
        const fields = @typeInfo(@TypeOf(input)).@"struct".fields;
        const count = try self.parameterCount();
        if (fields.len < count) {
            self.state = .failed;
            ffi.setWrapperError(diagnostics, "struct omits one or more named SQL parameters");
            return error.MissingParameter;
        }
        if (fields.len > count) {
            self.state = .failed;
            ffi.setWrapperError(diagnostics, "struct contains fields unused by the named SQL parameters");
            return error.UnusedField;
        }

        var position: usize = 1;
        while (position <= count) : (position += 1) {
            const native_name = raw.turso_statement_parameter_name(self.handle.?, @intCast(position));
            if (native_name == null) {
                self.state = .failed;
                ffi.setWrapperError(diagnostics, "struct binding cannot target anonymous or sparse parameters");
                return error.MissingParameter;
            }
            defer raw.turso_str_deinit(native_name);
            const sql_name = std.mem.sliceTo(native_name, 0);
            const bare = parameters.bareName(sql_name) catch |err| {
                self.state = .failed;
                ffi.setWrapperError(diagnostics, "numbered parameters cannot be inferred from struct field names");
                return err;
            };

            var other: usize = 1;
            while (other < position) : (other += 1) {
                const other_native = raw.turso_statement_parameter_name(self.handle.?, @intCast(other));
                if (other_native == null) continue;
                defer raw.turso_str_deinit(other_native);
                const other_name = std.mem.sliceTo(other_native, 0);
                const other_bare = parameters.bareName(other_name) catch continue;
                if (std.mem.eql(u8, bare, other_bare)) {
                    self.state = .failed;
                    ffi.setWrapperError(diagnostics, "multiple SQL parameters reduce to the same Zig field name");
                    return error.AmbiguousParameter;
                }
            }

            var matched = false;
            inline for (fields) |field| {
                if (std.mem.eql(u8, bare, field.name)) {
                    if (matched) return error.AmbiguousParameter;
                    matched = true;
                    const value = value_mod.Value.init(@field(input, field.name)) catch |err| {
                        self.state = .failed;
                        ffi.setWrapperError(diagnostics, "struct parameter cannot be represented without truncation");
                        return err;
                    };
                    self.bind(position, value, diagnostics) catch |err| {
                        self.state = .failed;
                        return err;
                    };
                }
            }
            if (!matched) {
                self.state = .failed;
                ffi.setWrapperError(diagnostics, "named SQL parameter has no matching Zig struct field");
                return error.MissingParameter;
            }
        }
        if (diagnostics) |detail| detail.clear();
    }

    fn findExactParameter(self: *const Statement, name: []const u8) BindError!usize {
        const statement = self.handle orelse return error.InvalidState;
        const count = try self.parameterCount();
        var found: ?usize = null;
        var position: usize = 1;
        while (position <= count) : (position += 1) {
            const native_name = raw.turso_statement_parameter_name(statement, @intCast(position));
            if (native_name == null) continue;
            defer raw.turso_str_deinit(native_name);
            if (std.mem.eql(u8, name, std.mem.sliceTo(native_name, 0))) {
                if (found != null) return error.AmbiguousParameter;
                found = position;
            }
        }
        return found orelse error.ParameterNotFound;
    }

    pub fn execute(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!u64 {
        const statement = try self.requireReady(diagnostics);
        self.invalidateRows();
        var rows_changed: u64 = 0;
        while (true) {
            var native_error: ffi.NativeError = null;
            const native_status = raw.turso_statement_execute(statement, &rows_changed, &native_error);
            const control = ffi.result(native_status, native_error, diagnostics) catch |err| {
                self.state = .failed;
                _ = self.verifyAutocommit(null) catch {};
                return err;
            };
            if (control == .done) break;
            if (control == .io and self.io_policy == .drive_io_inline) {
                self.runIoInline(
                    statement,
                    diagnostics,
                    "statement run_io returned an unexpected control status while executing",
                ) catch |err| {
                    self.state = .failed;
                    _ = self.verifyAutocommit(null) catch {};
                    return err;
                };
                continue;
            }
            self.state = .failed;
            _ = self.verifyAutocommit(null) catch {};
            ffi.setWrapperError(diagnostics, "blocking statement execute returned an unexpected control status");
            return if (control == .io) error.Unsupported else error.InvalidState;
        }
        self.state = .done;
        try self.verifyAutocommit(diagnostics);
        return rows_changed;
    }

    pub fn intoRows(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!Rows {
        _ = try self.requireReady(diagnostics);
        self.state = .rows_ready;
        const moved = self.*;
        self.handle = null;
        return .{ .statement = moved };
    }

    pub fn finalize(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.state == .finalized) {
            if (diagnostics) |detail| detail.clear();
            return;
        }
        self.ensureCurrent() catch {
            ffi.setWrapperError(diagnostics, "statement wrapper is stale or no longer owns its native handle");
            return error.InvalidState;
        };
        const statement = self.handle orelse {
            ffi.setWrapperError(diagnostics, "statement is already deinited");
            return error.InvalidState;
        };
        self.invalidateRows();
        while (true) {
            var native_error: ffi.NativeError = null;
            const native_status = raw.turso_statement_finalize(statement, &native_error);
            const control = ffi.result(native_status, native_error, diagnostics) catch |err| {
                self.state = .failed;
                _ = self.verifyAutocommit(null) catch {};
                return err;
            };
            if (control == .done) break;
            if (control == .io and self.io_policy == .drive_io_inline) {
                self.runIoInline(
                    statement,
                    diagnostics,
                    "statement run_io returned an unexpected control status while finalizing",
                ) catch |err| {
                    self.state = .failed;
                    _ = self.verifyAutocommit(null) catch {};
                    return err;
                };
                continue;
            }
            self.state = .failed;
            _ = self.verifyAutocommit(null) catch {};
            ffi.setWrapperError(diagnostics, "blocking statement finalize returned an unexpected control status");
            return if (control == .io) error.Unsupported else error.InvalidState;
        }
        self.state = .finalized;
        self.operation_control.cleanupAggregates();
        try self.verifyAutocommit(diagnostics);
    }

    /// Fallible terminal completion. This may drain a running native statement;
    /// unlike `deinit`, every native error is preserved for the caller.
    pub fn finish(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        return self.finalize(diagnostics);
    }

    pub fn reset(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.state != .done and self.state != .failed) {
            ffi.setWrapperError(diagnostics, "statement reset is valid only after completion or a recorded failure");
            return error.InvalidState;
        }
        self.ensureCurrent() catch {
            ffi.setWrapperError(diagnostics, "statement wrapper is stale or no longer owns its native handle");
            return error.InvalidState;
        };
        const statement = self.handle orelse {
            ffi.setWrapperError(diagnostics, "statement is already deinited");
            return error.InvalidState;
        };
        self.invalidateRows();
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_statement_reset(statement, &native_error);
        ffi.expect(
            native_status,
            native_error,
            .ok,
            diagnostics,
            "statement reset returned an unexpected control status",
        ) catch |err| {
            _ = self.verifyAutocommit(null) catch {};
            return err;
        };
        self.operation_control.cleanupAggregates();
        self.state = .ready;
        try self.verifyAutocommit(diagnostics);
    }

    pub fn deinit(self: *Statement) void {
        if (self.handle == null) return;
        if (!self.operation_control.statement_alive or
            self.generation != self.operation_control.generation)
        {
            self.handle = null;
            self.state = .finalized;
            return;
        }
        self.invalidateRows();
        if (self.state == .rows_ready or self.state == .row or self.state == .failed) {
            // Best-effort cancellation prevents early iterator destruction or
            // failed execution cleanup from draining a still-running statement
            // during finalization. No message is requested because deinit cannot
            // report it.
            _ = raw.turso_statement_reset(self.handle.?, null);
        }
        if (self.state != .finalized) {
            _ = raw.turso_statement_finalize(self.handle.?, null);
        }
        _ = self.operation_control.autocommitInvariantHolds();
        raw.turso_statement_deinit(self.handle.?);
        self.operation_control.cleanupAggregates();
        self.handle = null;
        self.state = .finalized;
        self.operation_control.statement_alive = false;
        self.operation_control.active = false;
    }

    fn stepForRows(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!?Row {
        self.ensureCurrent() catch {
            ffi.setWrapperError(diagnostics, "rows wrapper is stale or no longer owns its native statement");
            return error.InvalidState;
        };
        if (self.state != .rows_ready and self.state != .row) {
            if (self.state == .done) {
                if (diagnostics) |detail| detail.clear();
                return null;
            }
            ffi.setWrapperError(diagnostics, "rows iterator is not in a step-capable state");
            return error.InvalidState;
        }
        const statement = self.handle orelse return error.InvalidState;
        self.invalidateRows();
        while (true) {
            var native_error: ffi.NativeError = null;
            const native_status = raw.turso_statement_step(statement, &native_error);
            const control = ffi.result(native_status, native_error, diagnostics) catch |err| {
                self.state = .failed;
                _ = self.verifyAutocommit(null) catch {};
                return err;
            };
            switch (control) {
                .row => {
                    self.state = .row;
                    try self.verifyAutocommit(diagnostics);
                    const count = raw.turso_statement_column_count(statement);
                    if (count < 0) {
                        ffi.setWrapperError(diagnostics, "native statement returned a negative column count");
                        return error.InvalidState;
                    }
                    const column_count = std.math.cast(usize, count) orelse {
                        self.state = .failed;
                        ffi.setWrapperError(diagnostics, "native column count does not fit usize");
                        return error.IntegerOverflow;
                    };
                    return row_mod.init(statement, column_count, self.operation_control);
                },
                .done => {
                    self.state = .done;
                    try self.verifyAutocommit(diagnostics);
                    return null;
                },
                .io => {
                    if (self.io_policy == .drive_io_inline) {
                        self.runIoInline(
                            statement,
                            diagnostics,
                            "statement run_io returned an unexpected control status while stepping rows",
                        ) catch |err| {
                            self.state = .failed;
                            _ = self.verifyAutocommit(null) catch {};
                            return err;
                        };
                        continue;
                    }
                    self.state = .failed;
                    _ = self.verifyAutocommit(null) catch {};
                    ffi.setWrapperError(diagnostics, "blocking rows iteration unexpectedly requested caller-driven IO");
                    return error.Unsupported;
                },
                .ok => {
                    self.state = .failed;
                    _ = self.verifyAutocommit(null) catch {};
                    ffi.setWrapperError(diagnostics, "statement step returned OK instead of ROW or DONE");
                    return error.InvalidState;
                },
            }
        }
    }

    fn runIoInline(
        self: *Statement,
        statement: *raw.turso_statement_t,
        diagnostics: ?*Diagnostics,
        unexpected_detail: []const u8,
    ) status_mod.Error!void {
        std.debug.assert(self.io_policy == .drive_io_inline);
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_statement_run_io(statement, &native_error);
        try ffi.expect(native_status, native_error, .ok, diagnostics, unexpected_detail);
    }

    fn requireReady(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!*raw.turso_statement_t {
        self.ensureCurrent() catch {
            ffi.setWrapperError(diagnostics, "statement wrapper is stale or no longer owns its native handle");
            return error.InvalidState;
        };
        if (self.handle == null or self.state != .ready) {
            ffi.setWrapperError(diagnostics, "statement is not ready for binding or execution; reset it before reuse");
            return error.InvalidState;
        }
        if (!self.operation_control.autocommitInvariantHolds()) {
            ffi.setWrapperError(diagnostics, "connection is poisoned by an unexpected native transaction-state change");
            return error.InvalidState;
        }
        return self.handle.?;
    }

    fn ensureCurrent(self: *const Statement) status_mod.Error!void {
        if (!self.operation_control.active or
            !self.operation_control.statement_alive or
            self.generation != self.operation_control.generation)
        {
            return error.InvalidState;
        }
    }

    fn invalidateRows(self: *Statement) void {
        self.operation_control.invalidate();
        self.generation = self.operation_control.generation;
    }

    fn verifyAutocommit(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.operation_control.autocommitInvariantHolds()) return;
        ffi.setWrapperError(
            diagnostics,
            "SQL changed native transaction state outside the wrapper-owned transaction API; connection is poisoned",
        );
        return error.InvalidState;
    }
};

/// Owns a statement in row-stepping mode. A Row and all of its byte slices are
/// invalidated by the next call to `next` or by `deinit`.
pub const Rows = struct {
    pub const DecodeOptions = row_mod.DecodeOptions;
    pub const DecodeError = row_mod.DecodeError;

    statement: Statement,

    pub fn next(self: *Rows) status_mod.Error!?Row {
        return self.statement.stepForRows(null);
    }

    pub fn nextWithDiagnostics(self: *Rows, diagnostics: *Diagnostics) status_mod.Error!?Row {
        return self.statement.stepForRows(diagnostics);
    }

    pub fn nextAs(
        self: *Rows,
        comptime T: type,
        allocator: ?std.mem.Allocator,
        options: row_mod.DecodeOptions,
    ) row_mod.DecodeError!?T {
        const row = (try self.next()) orelse return null;
        return try row.decode(T, allocator, options);
    }

    /// Drain and finalize the remaining execution, reporting native errors.
    pub fn finish(self: *Rows, diagnostics: ?*Diagnostics) status_mod.Error!void {
        try self.statement.finish(diagnostics);
        self.statement.deinit();
    }

    /// Explicitly abort pending iteration, then finalize and release the handle.
    pub fn cancel(self: *Rows, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.statement.state == .rows_ready or self.statement.state == .row) {
            self.statement.ensureCurrent() catch {
                ffi.setWrapperError(diagnostics, "rows wrapper is stale or no longer owns its native statement");
                return error.InvalidState;
            };
            const statement = self.statement.handle orelse return error.InvalidState;
            var native_error: ffi.NativeError = null;
            const native_status = raw.turso_statement_reset(statement, &native_error);
            self.statement.invalidateRows();
            ffi.expect(
                native_status,
                native_error,
                .ok,
                diagnostics,
                "rows cancellation failed while resetting the native statement",
            ) catch |err| {
                _ = self.statement.verifyAutocommit(null) catch {};
                return err;
            };
            self.statement.operation_control.cleanupAggregates();
            self.statement.state = .done;
            try self.statement.verifyAutocommit(diagnostics);
        }
        try self.finish(diagnostics);
    }

    /// Best-effort cancellation and release. Use `finish` or `cancel` when the
    /// cleanup outcome matters.
    pub fn deinit(self: *Rows) void {
        self.statement.deinit();
    }
};

pub fn init(
    handle: *raw.turso_statement_t,
    operation_control: *OperationControl,
    autocommit_expectation: AutocommitExpectation,
    io_policy: IoPolicy,
) Statement {
    std.debug.assert(!operation_control.active);
    std.debug.assert(!operation_control.statement_alive);
    operation_control.invalidate();
    operation_control.active = true;
    operation_control.statement_alive = true;
    operation_control.autocommit_expectation = autocommit_expectation;
    return .{
        .handle = handle,
        .operation_control = operation_control,
        .generation = operation_control.generation,
        .io_policy = io_policy,
    };
}
