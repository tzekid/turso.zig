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

const Owner = enum {
    prepared,
    rows,
};

const StatementControl = struct {
    allocator: std.mem.Allocator,
    handle: *raw.turso_statement_t,
    operation_control: *OperationControl,
    autocommit_expectation: AutocommitExpectation,
    io_policy: IoPolicy,
    state: State = .ready,
    owner: Owner = .prepared,
    terminal_failure: bool = false,
};

/// Move-only owner of heap-stable prepared-statement state. Multiple
/// statements may remain idle on one connection; a Rows lease reserves its
/// statement as the connection's active execution.
pub const Statement = struct {
    pub const NamedBinding = parameters.NamedBinding;
    pub const ParameterInfo = parameters.ParameterInfo;
    pub const ColumnInfo = row_mod.ColumnInfo;

    control: ?*StatementControl,

    pub fn parameterCount(self: *const Statement) status_mod.Error!usize {
        const control = try self.requireUsable(null);
        const count = raw.turso_statement_parameters_count(control.handle);
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
        const control = try self.requireUsable(null);
        const count = try self.parameterCount();
        if (position == 0 or position > count) return error.ParameterNotFound;
        const native_name = raw.turso_statement_parameter_name(control.handle, @intCast(position));
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
        const control = try self.requireUsable(null);
        const count = raw.turso_statement_column_count(control.handle);
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
        const control = try self.requireUsable(null);
        if (index >= try self.columnCount()) return error.ColumnOutOfBounds;
        return row_mod.copyColumnInfo(allocator, control.handle, index);
    }

    /// Bind a one-based positional parameter.
    pub fn bind(self: *Statement, position: usize, value: Value, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const control = try self.requireReady(diagnostics);
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
            .null_value => raw.turso_statement_bind_positional_null(control.handle, position),
            .integer => |item| raw.turso_statement_bind_positional_int(control.handle, position, item),
            .real => |item| raw.turso_statement_bind_positional_double(control.handle, position, item),
            .text => |bytes| raw.turso_statement_bind_positional_text(control.handle, position, bytes.ptr, bytes.len),
            .blob => |bytes| raw.turso_statement_bind_positional_blob(control.handle, position, bytes.ptr, bytes.len),
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
        const control = try self.requireReady(diagnostics);
        const count = try self.parameterCount();
        if (bindings.len < count) {
            control.state = .failed;
            ffi.setWrapperError(diagnostics, "named binding set does not cover every SQL parameter slot");
            return error.MissingParameter;
        }
        if (bindings.len > count) {
            control.state = .failed;
            ffi.setWrapperError(diagnostics, "named binding set contains more entries than SQL parameter slots");
            return error.ParameterCountMismatch;
        }

        for (bindings, 0..) |binding, binding_index| {
            parameters.validateSqlName(binding.name) catch |err| {
                control.state = .failed;
                ffi.setWrapperError(diagnostics, switch (err) {
                    error.InteriorNul => "named parameter contains an interior NUL",
                    error.InvalidUtf8 => "named parameter is not valid UTF-8",
                    else => "named parameters require a : @ $ or numeric ? prefix",
                });
                return err;
            };
            const position = self.findExactParameter(binding.name) catch |err| {
                control.state = .failed;
                ffi.setWrapperError(diagnostics, "named parameter was not found in the prepared statement");
                return err;
            };
            for (bindings[0..binding_index]) |previous| {
                if (std.mem.eql(u8, previous.name, binding.name)) {
                    control.state = .failed;
                    ffi.setWrapperError(diagnostics, "named binding set contains a duplicate parameter");
                    return error.DuplicateParameter;
                }
                const previous_position = self.findExactParameter(previous.name) catch unreachable;
                if (previous_position == position) {
                    control.state = .failed;
                    ffi.setWrapperError(diagnostics, "multiple names resolve to the same SQL parameter slot");
                    return error.DuplicateParameter;
                }
            }
            self.bind(position, binding.value, diagnostics) catch |err| {
                control.state = .failed;
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
        const control = try self.requireReady(diagnostics);
        const count = try self.parameterCount();
        if (values.len != count) {
            ffi.setWrapperError(diagnostics, "bound value count does not match the statement parameter count");
            return error.ParameterCountMismatch;
        }
        for (values, 1..) |value, position| {
            self.bind(position, value, diagnostics) catch |err| {
                control.state = .failed;
                return err;
            };
        }
        if (diagnostics) |detail| detail.clear();
    }

    fn bindTuple(self: *Statement, input: anytype, diagnostics: ?*Diagnostics) BindError!void {
        const control = try self.requireReady(diagnostics);
        const fields = @typeInfo(@TypeOf(input)).@"struct".fields;
        if (fields.len != try self.parameterCount()) {
            control.state = .failed;
            ffi.setWrapperError(diagnostics, "tuple field count does not match SQL parameter count");
            return error.ParameterCountMismatch;
        }
        inline for (fields, 1..) |field, position| {
            const value = value_mod.Value.init(@field(input, field.name)) catch |err| {
                control.state = .failed;
                ffi.setWrapperError(diagnostics, "tuple parameter cannot be represented without truncation");
                return err;
            };
            self.bind(position, value, diagnostics) catch |err| {
                control.state = .failed;
                return err;
            };
        }
        if (diagnostics) |detail| detail.clear();
    }

    fn bindStruct(self: *Statement, input: anytype, diagnostics: ?*Diagnostics) BindError!void {
        const control = try self.requireReady(diagnostics);
        const fields = @typeInfo(@TypeOf(input)).@"struct".fields;
        const count = try self.parameterCount();
        if (fields.len < count) {
            control.state = .failed;
            ffi.setWrapperError(diagnostics, "struct omits one or more named SQL parameters");
            return error.MissingParameter;
        }
        if (fields.len > count) {
            control.state = .failed;
            ffi.setWrapperError(diagnostics, "struct contains fields unused by the named SQL parameters");
            return error.UnusedField;
        }

        var position: usize = 1;
        while (position <= count) : (position += 1) {
            const native_name = raw.turso_statement_parameter_name(control.handle, @intCast(position));
            if (native_name == null) {
                control.state = .failed;
                ffi.setWrapperError(diagnostics, "struct binding cannot target anonymous or sparse parameters");
                return error.MissingParameter;
            }
            defer raw.turso_str_deinit(native_name);
            const sql_name = std.mem.sliceTo(native_name, 0);
            const bare = parameters.bareName(sql_name) catch |err| {
                control.state = .failed;
                ffi.setWrapperError(diagnostics, "numbered parameters cannot be inferred from struct field names");
                return err;
            };

            var other: usize = 1;
            while (other < position) : (other += 1) {
                const other_native = raw.turso_statement_parameter_name(control.handle, @intCast(other));
                if (other_native == null) continue;
                defer raw.turso_str_deinit(other_native);
                const other_name = std.mem.sliceTo(other_native, 0);
                const other_bare = parameters.bareName(other_name) catch continue;
                if (std.mem.eql(u8, bare, other_bare)) {
                    control.state = .failed;
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
                        control.state = .failed;
                        ffi.setWrapperError(diagnostics, "struct parameter cannot be represented without truncation");
                        return err;
                    };
                    self.bind(position, value, diagnostics) catch |err| {
                        control.state = .failed;
                        return err;
                    };
                }
            }
            if (!matched) {
                control.state = .failed;
                ffi.setWrapperError(diagnostics, "named SQL parameter has no matching Zig struct field");
                return error.MissingParameter;
            }
        }
        if (diagnostics) |detail| detail.clear();
    }

    fn findExactParameter(self: *const Statement, name: []const u8) BindError!usize {
        const control = try self.requireUsable(null);
        const count = try self.parameterCount();
        var found: ?usize = null;
        var position: usize = 1;
        while (position <= count) : (position += 1) {
            const native_name = raw.turso_statement_parameter_name(control.handle, @intCast(position));
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
        const control = try self.requireReady(diagnostics);
        try acquireActive(control, diagnostics);
        defer releaseActive(control);
        invalidateRows(control);
        var rows_changed: u64 = 0;
        while (true) {
            var native_error: ffi.NativeError = null;
            const native_status = raw.turso_statement_execute(control.handle, &rows_changed, &native_error);
            const result = ffi.result(native_status, native_error, diagnostics) catch |err| {
                control.state = .failed;
                _ = verifyAutocommit(control, null) catch {};
                return err;
            };
            if (result == .done) break;
            if (result == .io and control.io_policy == .drive_io_inline) {
                runIoInline(
                    control,
                    diagnostics,
                    "statement run_io returned an unexpected control status while executing",
                ) catch |err| {
                    control.state = .failed;
                    _ = verifyAutocommit(control, null) catch {};
                    return err;
                };
                continue;
            }
            control.state = .failed;
            _ = verifyAutocommit(control, null) catch {};
            ffi.setWrapperError(diagnostics, "blocking statement execute returned an unexpected control status");
            return if (result == .io) error.Unsupported else error.InvalidState;
        }
        control.state = .done;
        verifyAutocommit(control, diagnostics) catch |err| {
            control.state = .failed;
            control.terminal_failure = true;
            return err;
        };
        return rows_changed;
    }

    /// Bind positional values and lease this prepared statement to Rows.
    pub fn query(
        self: *Statement,
        values: []const Value,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!Rows {
        try self.bindAll(values, diagnostics);
        return self.leaseRows(diagnostics);
    }

    /// Bind a tuple or named struct and lease this prepared statement to Rows.
    pub fn queryParams(
        self: *Statement,
        params: anytype,
        diagnostics: ?*Diagnostics,
    ) BindError!Rows {
        try self.bindParams(params, diagnostics);
        return self.leaseRows(diagnostics);
    }

    /// Consume this owner into Rows. Unlike `query`, the native statement is
    /// released when Rows ends.
    pub fn intoRows(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!Rows {
        const rows = try self.leaseRows(diagnostics);
        const control = rows.control.?;
        control.owner = .rows;
        self.control = null;
        return rows;
    }

    pub fn finalize(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const control = self.control orelse {
            ffi.setWrapperError(diagnostics, "statement is already deinited");
            return error.InvalidState;
        };
        if (control.owner != .prepared) {
            ffi.setWrapperError(diagnostics, "statement no longer owns its native handle");
            return error.InvalidState;
        }
        if (control.state == .finalized) {
            if (diagnostics) |detail| detail.clear();
            return;
        }
        if (control.operation_control.active_statement != null) {
            ffi.setWrapperError(diagnostics, "statement cannot finalize while a rows execution is active");
            return error.InvalidState;
        }
        try acquireActive(control, diagnostics);
        defer releaseActive(control);
        invalidateRows(control);
        while (true) {
            var native_error: ffi.NativeError = null;
            const native_status = raw.turso_statement_finalize(control.handle, &native_error);
            const result = ffi.result(native_status, native_error, diagnostics) catch |err| {
                control.state = .failed;
                control.terminal_failure = true;
                _ = verifyAutocommit(control, null) catch {};
                return err;
            };
            if (result == .done) break;
            if (result == .io and control.io_policy == .drive_io_inline) {
                runIoInline(
                    control,
                    diagnostics,
                    "statement run_io returned an unexpected control status while finalizing",
                ) catch |err| {
                    control.state = .failed;
                    control.terminal_failure = true;
                    _ = verifyAutocommit(control, null) catch {};
                    return err;
                };
                continue;
            }
            control.state = .failed;
            control.terminal_failure = true;
            _ = verifyAutocommit(control, null) catch {};
            ffi.setWrapperError(diagnostics, "blocking statement finalize returned an unexpected control status");
            return if (result == .io) error.Unsupported else error.InvalidState;
        }
        control.state = .finalized;
        control.operation_control.cleanupAggregates();
        try verifyAutocommit(control, diagnostics);
    }

    /// Fallible terminal completion. Unlike Rows.finish, this irreversibly
    /// finalizes the prepared statement.
    pub fn finish(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        return self.finalize(diagnostics);
    }

    pub fn reset(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const control = self.control orelse {
            ffi.setWrapperError(diagnostics, "statement is already deinited");
            return error.InvalidState;
        };
        if (control.owner != .prepared or
            (control.state != .done and control.state != .failed) or
            control.terminal_failure)
        {
            ffi.setWrapperError(diagnostics, "statement reset is valid only after recoverable completion or failure");
            return error.InvalidState;
        }
        try acquireActive(control, diagnostics);
        defer releaseActive(control);
        try resetControl(control, diagnostics, "statement reset returned an unexpected control status");
    }

    pub fn deinit(self: *Statement) void {
        const control = self.control orelse return;
        if (control.owner != .prepared) {
            self.control = null;
            return;
        }
        if (control.operation_control.isActive(control)) {
            @panic("turso.Statement.deinit called before its rows iterator was released");
        }
        destroyControl(control);
        self.control = null;
    }

    fn leaseRows(self: *Statement, diagnostics: ?*Diagnostics) status_mod.Error!Rows {
        const control = try self.requireReady(diagnostics);
        try acquireActive(control, diagnostics);
        invalidateRows(control);
        control.state = .rows_ready;
        return .{ .control = control };
    }

    fn requireUsable(
        self: *const Statement,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!*StatementControl {
        const control = self.control orelse {
            ffi.setWrapperError(diagnostics, "statement is already deinited");
            return error.InvalidState;
        };
        if (control.owner != .prepared or control.state == .finalized) {
            ffi.setWrapperError(diagnostics, "statement no longer owns a usable native handle");
            return error.InvalidState;
        }
        if (control.operation_control.active_statement != null) {
            ffi.setWrapperError(diagnostics, "connection already has an active statement execution");
            return error.InvalidState;
        }
        return control;
    }

    fn requireReady(
        self: *Statement,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!*StatementControl {
        const control = try self.requireUsable(diagnostics);
        if (control.state != .ready) {
            ffi.setWrapperError(diagnostics, "statement is not ready for binding or execution; reset it before reuse");
            return error.InvalidState;
        }
        if (!control.operation_control.autocommitInvariantHolds(control.autocommit_expectation)) {
            control.state = .failed;
            control.terminal_failure = true;
            ffi.setWrapperError(diagnostics, "connection is poisoned by an unexpected native transaction-state change");
            return error.InvalidState;
        }
        return control;
    }
};

/// Rows leases heap-stable statement state. Prepared-query Rows returns that
/// state to its Statement owner; one-shot and intoRows values own and destroy
/// it. A Row and its borrowed bytes expire at the next Rows operation.
pub const Rows = struct {
    pub const DecodeOptions = row_mod.DecodeOptions;
    pub const DecodeError = row_mod.DecodeError;

    control: ?*StatementControl,

    pub fn next(self: *Rows) status_mod.Error!?Row {
        const control = try self.requireControl(null);
        return stepForRows(control, null);
    }

    pub fn nextWithDiagnostics(self: *Rows, diagnostics: *Diagnostics) status_mod.Error!?Row {
        const control = try self.requireControl(diagnostics);
        return stepForRows(control, diagnostics);
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

    /// Return the native modification count after iteration reached DONE.
    /// Call this before `finish`, which releases the Rows lease.
    pub fn rowsChanged(self: *Rows) status_mod.Error!u64 {
        const control = try self.requireControl(null);
        if (control.state != .done) return error.InvalidState;
        const count = raw.turso_statement_n_change(control.handle);
        if (count < 0) return error.InvalidState;
        return std.math.cast(u64, count) orelse error.IntegerOverflow;
    }

    /// Drain to DONE, reset, and release this execution. Prepared statements
    /// become ready for another bind/query cycle.
    pub fn finish(self: *Rows, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const control = self.control orelse {
            if (diagnostics) |detail| detail.clear();
            return;
        };
        while (control.state == .rows_ready or control.state == .row) {
            _ = stepForRows(control, diagnostics) catch |err| {
                self.release(null) catch {};
                return err;
            };
        }
        try self.release(diagnostics);
    }

    /// Abort pending iteration with reset and release the Rows lease.
    pub fn cancel(self: *Rows, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.control == null) {
            if (diagnostics) |detail| detail.clear();
            return;
        }
        try self.release(diagnostics);
    }

    /// Best-effort cancellation. A prepared owner remains valid but terminal
    /// if native reset fails; an owning Rows always releases its allocation.
    pub fn deinit(self: *Rows) void {
        if (self.control == null) return;
        self.release(null) catch {};
    }

    fn requireControl(
        self: *Rows,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!*StatementControl {
        const control = self.control orelse {
            ffi.setWrapperError(diagnostics, "rows iterator is already released");
            return error.InvalidState;
        };
        if (!control.operation_control.isActive(control)) {
            ffi.setWrapperError(diagnostics, "rows iterator no longer owns the active statement execution");
            return error.InvalidState;
        }
        return control;
    }

    fn release(self: *Rows, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        invalidateRows(control);

        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_statement_reset(control.handle, &native_error);
        ffi.expect(
            native_status,
            native_error,
            .ok,
            diagnostics,
            "rows release failed while resetting the native statement",
        ) catch |err| {
            control.state = .failed;
            control.terminal_failure = true;
            self.detach(control);
            return err;
        };
        control.operation_control.cleanupAggregates();
        control.state = .ready;
        verifyAutocommit(control, diagnostics) catch |err| {
            control.state = .failed;
            control.terminal_failure = true;
            self.detach(control);
            return err;
        };
        self.detach(control);
    }

    fn detach(self: *Rows, control: *StatementControl) void {
        const owns_control = control.owner == .rows;
        releaseActive(control);
        self.control = null;
        if (owns_control) destroyControl(control);
    }
};

fn stepForRows(
    control: *StatementControl,
    diagnostics: ?*Diagnostics,
) status_mod.Error!?Row {
    if (!control.operation_control.isActive(control)) {
        ffi.setWrapperError(diagnostics, "rows wrapper is stale or no longer owns its native statement");
        return error.InvalidState;
    }
    if (control.state != .rows_ready and control.state != .row) {
        if (control.state == .done) {
            if (diagnostics) |detail| detail.clear();
            return null;
        }
        ffi.setWrapperError(diagnostics, "rows iterator is not in a step-capable state");
        return error.InvalidState;
    }

    invalidateRows(control);
    while (true) {
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_statement_step(control.handle, &native_error);
        const result = ffi.result(native_status, native_error, diagnostics) catch |err| {
            control.state = .failed;
            _ = verifyAutocommit(control, null) catch {};
            return err;
        };
        switch (result) {
            .row => {
                control.state = .row;
                verifyAutocommit(control, diagnostics) catch |err| {
                    control.state = .failed;
                    control.terminal_failure = true;
                    return err;
                };
                const count = raw.turso_statement_column_count(control.handle);
                if (count < 0) {
                    control.state = .failed;
                    ffi.setWrapperError(diagnostics, "native statement returned a negative column count");
                    return error.InvalidState;
                }
                const column_count = std.math.cast(usize, count) orelse {
                    control.state = .failed;
                    ffi.setWrapperError(diagnostics, "native column count does not fit usize");
                    return error.IntegerOverflow;
                };
                return row_mod.init(control.handle, column_count, control.operation_control);
            },
            .done => {
                control.state = .done;
                verifyAutocommit(control, diagnostics) catch |err| {
                    control.state = .failed;
                    control.terminal_failure = true;
                    return err;
                };
                return null;
            },
            .io => {
                if (control.io_policy == .drive_io_inline) {
                    runIoInline(
                        control,
                        diagnostics,
                        "statement run_io returned an unexpected control status while stepping rows",
                    ) catch |err| {
                        control.state = .failed;
                        _ = verifyAutocommit(control, null) catch {};
                        return err;
                    };
                    continue;
                }
                control.state = .failed;
                _ = verifyAutocommit(control, null) catch {};
                ffi.setWrapperError(diagnostics, "blocking rows iteration unexpectedly requested caller-driven IO");
                return error.Unsupported;
            },
            .ok => {
                control.state = .failed;
                _ = verifyAutocommit(control, null) catch {};
                ffi.setWrapperError(diagnostics, "statement step returned OK instead of ROW or DONE");
                return error.InvalidState;
            },
        }
    }
}

fn resetControl(
    control: *StatementControl,
    diagnostics: ?*Diagnostics,
    unexpected_detail: []const u8,
) status_mod.Error!void {
    invalidateRows(control);
    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_statement_reset(control.handle, &native_error);
    ffi.expect(native_status, native_error, .ok, diagnostics, unexpected_detail) catch |err| {
        control.state = .failed;
        control.terminal_failure = true;
        _ = verifyAutocommit(control, null) catch {};
        return err;
    };
    control.operation_control.cleanupAggregates();
    control.state = .ready;
    verifyAutocommit(control, diagnostics) catch |err| {
        control.state = .failed;
        control.terminal_failure = true;
        return err;
    };
}

fn runIoInline(
    control: *StatementControl,
    diagnostics: ?*Diagnostics,
    unexpected_detail: []const u8,
) status_mod.Error!void {
    std.debug.assert(control.io_policy == .drive_io_inline);
    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_statement_run_io(control.handle, &native_error);
    try ffi.expect(native_status, native_error, .ok, diagnostics, unexpected_detail);
}

fn acquireActive(control: *StatementControl, diagnostics: ?*Diagnostics) status_mod.Error!void {
    if (control.operation_control.acquire(control)) return;
    ffi.setWrapperError(diagnostics, "connection already has an active statement execution");
    return error.InvalidState;
}

fn releaseActive(control: *StatementControl) void {
    if (control.operation_control.isActive(control)) {
        control.operation_control.release(control);
    }
}

fn invalidateRows(control: *StatementControl) void {
    control.operation_control.invalidateRows();
}

fn verifyAutocommit(
    control: *StatementControl,
    diagnostics: ?*Diagnostics,
) status_mod.Error!void {
    if (control.operation_control.autocommitInvariantHolds(control.autocommit_expectation)) return;
    ffi.setWrapperError(
        diagnostics,
        "SQL changed native transaction state outside the wrapper-owned transaction API; connection is poisoned",
    );
    return error.InvalidState;
}

fn destroyControl(control: *StatementControl) void {
    const operation_control = control.operation_control;
    const already_active = operation_control.isActive(control);
    const acquired = if (already_active) false else operation_control.acquire(control);
    const can_run_terminal_work = already_active or acquired;

    invalidateRows(control);
    if (can_run_terminal_work) {
        if ((control.state == .rows_ready or
            control.state == .row or
            control.state == .failed) and
            !control.terminal_failure)
        {
            _ = raw.turso_statement_reset(control.handle, null);
        }
        if (control.state != .finalized) {
            _ = raw.turso_statement_finalize(control.handle, null);
        }
    }
    // If another statement owns the connection lease, reset/finalize would
    // violate wrapper exclusivity. Native deinit drops the boxed statement, so
    // teardown remains complete without terminal calls in that case.
    raw.turso_statement_deinit(control.handle);
    if (can_run_terminal_work) operation_control.cleanupAggregates();
    releaseActive(control);
    operation_control.unregister();
    const allocator = control.allocator;
    allocator.destroy(control);
}

pub fn init(
    allocator: std.mem.Allocator,
    handle: *raw.turso_statement_t,
    operation_control: *OperationControl,
    autocommit_expectation: AutocommitExpectation,
    io_policy: IoPolicy,
) status_mod.Error!Statement {
    const control = allocator.create(StatementControl) catch |err| {
        raw.turso_statement_deinit(handle);
        return err;
    };
    control.* = .{
        .allocator = allocator,
        .handle = handle,
        .operation_control = operation_control,
        .autocommit_expectation = autocommit_expectation,
        .io_policy = io_policy,
    };
    operation_control.register();
    return .{ .control = control };
}
