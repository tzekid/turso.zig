const std = @import("std");
const raw = @import("raw.zig").c;
const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");
const value_mod = @import("value.zig");
const cstring = @import("cstring.zig");
const ffi = @import("ffi.zig");
const statement_mod = @import("statement.zig");
const functions_mod = @import("functions.zig");

pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const Value = value_mod.Value;
pub const Statement = statement_mod.Statement;
pub const Rows = statement_mod.Rows;
pub const StatementIoPolicy = statement_mod.IoPolicy;

const TransactionModeImpl = enum {
    deferred,
    immediate,
    exclusive,
    /// Requires Turso's MVCC journal mode. Commit can return BusySnapshot;
    /// callers decide whether to roll back and retry the whole transaction.
    concurrent,

    fn beginSql(self: TransactionModeImpl) []const u8 {
        return switch (self) {
            .deferred => "BEGIN DEFERRED",
            .immediate => "BEGIN IMMEDIATE",
            .exclusive => "BEGIN EXCLUSIVE",
            .concurrent => "BEGIN CONCURRENT",
        };
    }
};

pub const TransactionState = enum {
    active,
    committed,
    rolled_back,
    /// An implicit rollback failed or native autocommit changed unexpectedly.
    failed,
};

pub const ConnectionOptions = struct {
    busy_timeout_ms: ?u64 = null,
    diagnostics: ?*Diagnostics = null,
};

pub const OperationOptions = struct {
    diagnostics: ?*Diagnostics = null,
};

/// Heap-stable state shared by a Connection, its current Statement/Rows, and
/// its current Transaction. Moving the public Connection value does not move
/// this control block or invalidate child ownership pointers.
const Control = struct {
    allocator: std.mem.Allocator,
    handle: ?*raw.turso_connection_t,
    owner_connections: *std.atomic.Value(usize),
    statement_io_policy: StatementIoPolicy,
    aggregate_tracker: functions_mod.AggregateTracker = .{},
    operation: statement_mod.OperationControl = .{},
    transaction_active: bool = false,
    poisoned: bool = false,
    closed: bool = false,
};

/// Move-only exclusive native connection. Copying this value duplicates unique
/// ownership and is unsupported, but relocating it before or while a child is
/// alive is safe because all child state is heap-stable.
pub const Connection = struct {
    pub const Transaction = TransactionHandle;
    pub const TransactionMode = TransactionModeImpl;
    pub const CallbackError = functions_mod.CallbackError;
    pub const CollationOrder = functions_mod.CollationOrder;
    pub const ScalarFunctionOptions = functions_mod.ScalarFunctionOptions;
    pub const AggregateFunctionOptions = functions_mod.AggregateFunctionOptions;
    pub const CollationOptions = functions_mod.CollationOptions;

    control: ?*Control,

    pub fn prepare(self: *Connection, sql: []const u8, options: OperationOptions) status_mod.Error!Statement {
        const control = try self.requireControl(options.diagnostics);
        return prepareControl(control, sql, options, false, .enabled);
    }

    pub fn exec(
        self: *Connection,
        sql: []const u8,
        values: []const Value,
        options: OperationOptions,
    ) status_mod.Error!u64 {
        const control = try self.requireControl(options.diagnostics);
        return execControl(control, sql, values, options, false, .enabled);
    }

    /// Prepare one statement, bind a tuple or named struct through
    /// `Statement.bindParams`, and execute it without retrying.
    pub fn execParams(
        self: *Connection,
        sql: []const u8,
        params: anytype,
        options: OperationOptions,
    ) statement_mod.BindError!u64 {
        const control = try self.requireControl(options.diagnostics);
        return execParamsControl(control, sql, params, options, false, .enabled);
    }

    /// Execute every statement in `sql` in order without parameters and return
    /// the sum of their native rows-changed counts. Previous statements are not
    /// rolled back if a later one fails; use a Transaction when atomicity is
    /// required.
    pub fn execBatch(self: *Connection, sql: []const u8, options: OperationOptions) status_mod.Error!u64 {
        const control = try self.requireControl(options.diagnostics);
        return execBatchControl(control, sql, options, false, .enabled);
    }

    pub fn query(
        self: *Connection,
        sql: []const u8,
        values: []const Value,
        options: OperationOptions,
    ) status_mod.Error!Rows {
        const control = try self.requireControl(options.diagnostics);
        return queryControl(control, sql, values, options, false, .enabled);
    }

    /// Prepare one statement, bind a tuple or named struct through
    /// `Statement.bindParams`, and transfer its ownership to returned Rows.
    pub fn queryParams(
        self: *Connection,
        sql: []const u8,
        params: anytype,
        options: OperationOptions,
    ) statement_mod.BindError!Rows {
        const control = try self.requireControl(options.diagnostics);
        return queryParamsControl(control, sql, params, options, false, .enabled);
    }

    /// Register or replace a managed scalar function. `options` must be a
    /// `functions.ScalarFunctionOptions(Context)` value and is moved into the
    /// registration even when registration fails.
    pub fn registerScalarFunction(
        self: *Connection,
        name: []const u8,
        options: anytype,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        return functions_mod.registerScalarFunction(control.allocator, connection, name, options, diagnostics);
    }

    /// Register or replace a managed aggregate function. `options` must be an
    /// `functions.AggregateFunctionOptions(Context, State)` value and is moved
    /// into the registration even when registration fails.
    pub fn registerAggregateFunction(
        self: *Connection,
        name: []const u8,
        options: anytype,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        return functions_mod.registerAggregateFunction(
            control.allocator,
            connection,
            &control.aggregate_tracker,
            name,
            options,
            diagnostics,
        );
    }

    pub fn unregisterFunction(
        self: *Connection,
        name: []const u8,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        return functions_mod.unregisterFunction(control.allocator, connection, name, diagnostics);
    }

    /// Register or replace a managed collation. `options` must be a
    /// `functions.CollationOptions(Context)` value and is moved into the
    /// registration even when registration fails.
    pub fn registerCollation(
        self: *Connection,
        name: []const u8,
        options: anytype,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        return functions_mod.registerCollation(control.allocator, connection, name, options, diagnostics);
    }

    pub fn unregisterCollation(
        self: *Connection,
        name: []const u8,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        return functions_mod.unregisterCollation(control.allocator, connection, name, diagnostics);
    }

    /// Explicitly opt this connection's SQL `load_extension()` function in or
    /// out of native extension loading. The wrapper never enables it
    /// implicitly. Direct `loadExtension` calls are separately explicit and do
    /// not consult this flag, matching the pinned native implementation.
    pub fn enableLoadExtension(
        self: *Connection,
        enabled: bool,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_connection_enable_load_extension(connection, enabled, &native_error);
        try ffi.expect(
            native_status,
            native_error,
            .ok,
            diagnostics,
            "extension-loading configuration returned an unexpected control status",
        );
    }

    /// Directly load a trusted native extension through Turso's loader. This
    /// explicit API bypasses the SQL `load_extension()` opt-in flag, matching
    /// the pinned native implementation.
    pub fn loadExtension(
        self: *Connection,
        path: []const u8,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        const path_z = cstring.dupe(control.allocator, path) catch |err| {
            ffi.setWrapperError(diagnostics, "extension path must be valid UTF-8 without an interior NUL and must be copyable");
            return err;
        };
        defer control.allocator.free(path_z);
        if (path_z.len == 0) {
            ffi.setWrapperError(diagnostics, "extension path must not be empty");
            return error.InvalidState;
        }
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_connection_load_extension(connection, path_z.ptr, &native_error);
        try ffi.expect(
            native_status,
            native_error,
            .ok,
            diagnostics,
            "extension load returned an unexpected control status",
        );
    }

    /// Begin an exclusive wrapper-owned transaction. While it is active, all
    /// operations must go through the returned Transaction value.
    pub fn begin(
        self: *Connection,
        mode: TransactionModeImpl,
        options: OperationOptions,
    ) status_mod.Error!TransactionHandle {
        const control = try self.requireControl(options.diagnostics);
        const connection = try requireAvailable(control, options.diagnostics, false);
        if (!raw.turso_connection_get_autocommit(connection)) {
            ffi.setWrapperError(options.diagnostics, "nested transactions are not supported");
            return error.InvalidState;
        }

        _ = try execControl(control, mode.beginSql(), &.{}, options, false, .any);
        if (raw.turso_connection_get_autocommit(connection)) {
            ffi.setWrapperError(options.diagnostics, "BEGIN completed without entering a native transaction");
            return error.InvalidState;
        }
        control.transaction_active = true;
        return .{ .control = control };
    }

    /// Configure the native busy timeout. Zero disables waiting. BUSY and
    /// BUSY_SNAPSHOT remain distinct errors; this wrapper never retries a
    /// transaction automatically.
    pub fn setBusyTimeout(
        self: *Connection,
        timeout_ms: u64,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        const connection = try requireAvailable(control, diagnostics, false);
        if (timeout_ms > std.math.maxInt(i64)) {
            ffi.setWrapperError(diagnostics, "busy timeout does not fit the native signed millisecond range");
            return error.IntegerOverflow;
        }
        raw.turso_connection_set_busy_timeout_ms(connection, @intCast(timeout_ms));
        if (diagnostics) |detail| detail.clear();
    }

    pub fn close(self: *Connection, diagnostics: ?*Diagnostics) status_mod.Error!void {
        const control = try self.requireControl(diagnostics);
        if (control.operation.active or control.operation.statement_alive) {
            ffi.setWrapperError(diagnostics, "connection still owns an active statement or rows iterator");
            return error.InvalidState;
        }
        if (control.transaction_active) {
            ffi.setWrapperError(diagnostics, "connection still owns an active transaction");
            return error.InvalidState;
        }
        if (control.poisoned) {
            ffi.setWrapperError(diagnostics, "connection state is unknown after a failed implicit rollback");
            return error.InvalidState;
        }
        if (control.closed) {
            if (diagnostics) |detail| detail.clear();
            return;
        }
        const connection = control.handle orelse {
            ffi.setWrapperError(diagnostics, "connection is already deinited");
            return error.InvalidState;
        };
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_connection_close(connection, &native_error);
        try ffi.expect(
            native_status,
            native_error,
            .ok,
            diagnostics,
            "connection close returned an unexpected control status",
        );
        control.closed = true;
    }

    pub fn isAutocommit(self: *const Connection) status_mod.Error!bool {
        const control = self.control orelse return error.InvalidState;
        const connection = control.handle orelse return error.InvalidState;
        if (control.closed or
            control.poisoned or
            control.transaction_active or
            control.operation.active or
            control.operation.statement_alive)
        {
            return error.InvalidState;
        }
        return raw.turso_connection_get_autocommit(connection);
    }

    pub fn lastInsertRowId(self: *const Connection) status_mod.Error!i64 {
        const control = self.control orelse return error.InvalidState;
        const connection = control.handle orelse return error.InvalidState;
        if (control.closed or
            control.poisoned or
            control.transaction_active or
            control.operation.active or
            control.operation.statement_alive)
        {
            return error.InvalidState;
        }
        return raw.turso_connection_last_insert_rowid(connection);
    }

    pub fn deinit(self: *Connection) void {
        const control = self.control orelse return;
        if (control.operation.active or control.operation.statement_alive) {
            @panic("turso.Connection.deinit called before its statement or rows iterator was deinited");
        }
        if (control.transaction_active) {
            @panic("turso.Connection.deinit called before its transaction was finished or deinited");
        }
        // No native statement remains, so any tracked state is an upstream
        // survivor leak and can be destroyed while registration contexts are
        // still alive. Native connection teardown follows and drops contexts.
        control.aggregate_tracker.cleanup();
        if (control.handle) |connection| raw.turso_connection_deinit(connection);
        control.handle = null;
        control.closed = true;
        const previous = control.owner_connections.fetchSub(1, .release);
        std.debug.assert(previous != 0);
        const allocator = control.allocator;
        allocator.destroy(control);
        self.control = null;
    }

    fn requireControl(self: *const Connection, diagnostics: ?*Diagnostics) status_mod.Error!*Control {
        return self.control orelse {
            ffi.setWrapperError(diagnostics, "connection is already deinited");
            return error.InvalidState;
        };
    }
};

/// Move-only exclusive transaction borrowing heap-stable Connection state. A
/// live transaction prevents direct Connection use or deinit. Statement and
/// Rows values returned here must be deinited before another transaction method.
pub const TransactionHandle = struct {
    control: *Control,
    state: TransactionState = .active,

    pub fn prepare(self: *TransactionHandle, sql: []const u8, options: OperationOptions) status_mod.Error!Statement {
        try self.requireActive(options.diagnostics);
        return prepareControl(self.control, sql, options, true, .disabled);
    }

    pub fn exec(
        self: *TransactionHandle,
        sql: []const u8,
        values: []const Value,
        options: OperationOptions,
    ) status_mod.Error!u64 {
        try self.requireActive(options.diagnostics);
        return execControl(self.control, sql, values, options, true, .disabled);
    }

    /// Transaction-scoped counterpart to `Connection.execParams`.
    pub fn execParams(
        self: *TransactionHandle,
        sql: []const u8,
        params: anytype,
        options: OperationOptions,
    ) statement_mod.BindError!u64 {
        try self.requireActive(options.diagnostics);
        return execParamsControl(self.control, sql, params, options, true, .disabled);
    }

    pub fn execBatch(self: *TransactionHandle, sql: []const u8, options: OperationOptions) status_mod.Error!u64 {
        try self.requireActive(options.diagnostics);
        return execBatchControl(self.control, sql, options, true, .disabled);
    }

    pub fn query(
        self: *TransactionHandle,
        sql: []const u8,
        values: []const Value,
        options: OperationOptions,
    ) status_mod.Error!Rows {
        try self.requireActive(options.diagnostics);
        return queryControl(self.control, sql, values, options, true, .disabled);
    }

    /// Transaction-scoped counterpart to `Connection.queryParams`.
    pub fn queryParams(
        self: *TransactionHandle,
        sql: []const u8,
        params: anytype,
        options: OperationOptions,
    ) statement_mod.BindError!Rows {
        try self.requireActive(options.diagnostics);
        return queryParamsControl(self.control, sql, params, options, true, .disabled);
    }

    pub fn isAutocommit(self: *TransactionHandle) status_mod.Error!bool {
        try self.requireActive(null);
        return raw.turso_connection_get_autocommit(self.control.handle.?);
    }

    pub fn lastInsertRowId(self: *TransactionHandle) status_mod.Error!i64 {
        try self.requireActive(null);
        return raw.turso_connection_last_insert_rowid(self.control.handle.?);
    }

    pub fn commit(self: *TransactionHandle, diagnostics: ?*Diagnostics) status_mod.Error!void {
        try self.end("COMMIT", .committed, diagnostics);
    }

    pub fn rollback(self: *TransactionHandle, diagnostics: ?*Diagnostics) status_mod.Error!void {
        try self.end("ROLLBACK", .rolled_back, diagnostics);
    }

    /// Finish with the same rollback policy used by deinit, but report errors.
    pub fn finish(self: *TransactionHandle, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.state == .active) return self.rollback(diagnostics);
        if (diagnostics) |detail| detail.clear();
    }

    /// Roll back an active transaction best-effort. If rollback fails, poison
    /// the Connection so uncertain native state can only be released by deinit.
    pub fn deinit(self: *TransactionHandle) void {
        if (self.state != .active) return;
        if (self.control.operation.active or self.control.operation.statement_alive) {
            @panic("turso.Transaction.deinit called before its statement or rows iterator was deinited");
        }
        const connection = self.control.handle orelse {
            self.state = .failed;
            return;
        };
        if (raw.turso_connection_get_autocommit(connection)) {
            self.control.transaction_active = false;
            self.state = .failed;
            return;
        }
        self.rollback(null) catch {
            self.control.transaction_active = false;
            self.control.poisoned = true;
            self.state = .failed;
        };
    }

    fn end(
        self: *TransactionHandle,
        sql: []const u8,
        terminal: TransactionState,
        diagnostics: ?*Diagnostics,
    ) status_mod.Error!void {
        try self.requireActive(diagnostics);
        _ = execControl(self.control, sql, &.{}, .{ .diagnostics = diagnostics }, true, .any) catch |err| {
            // Preserve active ownership on failure so rollback can be retried.
            return err;
        };
        if (!raw.turso_connection_get_autocommit(self.control.handle.?)) {
            ffi.setWrapperError(diagnostics, "transaction terminator completed but native autocommit is still disabled");
            return error.InvalidState;
        }
        self.control.transaction_active = false;
        self.state = terminal;
    }

    fn requireActive(self: *TransactionHandle, diagnostics: ?*Diagnostics) status_mod.Error!void {
        if (self.state != .active) {
            ffi.setWrapperError(diagnostics, "transaction is no longer active");
            return error.InvalidState;
        }
        if (!self.control.transaction_active) {
            ffi.setWrapperError(diagnostics, "transaction ownership is no longer valid");
            return error.InvalidState;
        }
        _ = try requireAvailable(self.control, diagnostics, true);
    }
};

fn prepareControl(
    control: *Control,
    sql: []const u8,
    options: OperationOptions,
    within_transaction: bool,
    autocommit_expectation: statement_mod.AutocommitExpectation,
) status_mod.Error!Statement {
    const connection = try requireAvailable(control, options.diagnostics, within_transaction);
    const sql_string = cstring.dupe(control.allocator, sql) catch |err| {
        ffi.setWrapperError(options.diagnostics, "SQL must be valid UTF-8 without an interior NUL and must be copyable");
        return err;
    };
    defer control.allocator.free(sql_string);

    var handle: ?*raw.turso_statement_t = null;
    var native_error: ffi.NativeError = null;
    const native_status = raw.turso_connection_prepare_single(connection, sql_string.ptr, &handle, &native_error);
    ffi.expect(native_status, native_error, .ok, options.diagnostics, "prepare returned an unexpected control status") catch |err| {
        if (handle) |value| raw.turso_statement_deinit(value);
        return err;
    };
    if (handle == null) {
        ffi.setWrapperError(options.diagnostics, "prepare returned a null statement handle");
        return error.InvalidState;
    }
    return statement_mod.init(
        handle.?,
        &control.operation,
        autocommit_expectation,
        control.statement_io_policy,
    );
}

fn execControl(
    control: *Control,
    sql: []const u8,
    values: []const Value,
    options: OperationOptions,
    within_transaction: bool,
    autocommit_expectation: statement_mod.AutocommitExpectation,
) status_mod.Error!u64 {
    var statement = try prepareControl(control, sql, options, within_transaction, autocommit_expectation);
    defer statement.deinit();
    try statement.bindAll(values, options.diagnostics);
    return statement.execute(options.diagnostics);
}

fn execParamsControl(
    control: *Control,
    sql: []const u8,
    params: anytype,
    options: OperationOptions,
    within_transaction: bool,
    autocommit_expectation: statement_mod.AutocommitExpectation,
) statement_mod.BindError!u64 {
    var statement = try prepareControl(control, sql, options, within_transaction, autocommit_expectation);
    defer statement.deinit();
    try statement.bindParams(params, options.diagnostics);
    return statement.execute(options.diagnostics);
}

fn queryControl(
    control: *Control,
    sql: []const u8,
    values: []const Value,
    options: OperationOptions,
    within_transaction: bool,
    autocommit_expectation: statement_mod.AutocommitExpectation,
) status_mod.Error!Rows {
    var statement = try prepareControl(control, sql, options, within_transaction, autocommit_expectation);
    errdefer statement.deinit();
    try statement.bindAll(values, options.diagnostics);
    return statement.intoRows(options.diagnostics);
}

fn queryParamsControl(
    control: *Control,
    sql: []const u8,
    params: anytype,
    options: OperationOptions,
    within_transaction: bool,
    autocommit_expectation: statement_mod.AutocommitExpectation,
) statement_mod.BindError!Rows {
    var statement = try prepareControl(control, sql, options, within_transaction, autocommit_expectation);
    errdefer statement.deinit();
    try statement.bindParams(params, options.diagnostics);
    return statement.intoRows(options.diagnostics);
}

fn execBatchControl(
    control: *Control,
    sql: []const u8,
    options: OperationOptions,
    within_transaction: bool,
    autocommit_expectation: statement_mod.AutocommitExpectation,
) status_mod.Error!u64 {
    _ = try requireAvailable(control, options.diagnostics, within_transaction);
    // Validate and copy the complete batch before executing its first
    // statement. This prevents an interior NUL from truncating a partially
    // executed batch.
    const sql_string = cstring.dupe(control.allocator, sql) catch |err| {
        ffi.setWrapperError(options.diagnostics, "SQL batch must be valid UTF-8 without an interior NUL and must be copyable");
        return err;
    };
    defer control.allocator.free(sql_string);

    var offset: usize = 0;
    var total_changes: u64 = 0;
    while (offset < sql.len) {
        const connection = try requireAvailable(control, options.diagnostics, within_transaction);
        const remaining_len = sql.len - offset;
        var handle: ?*raw.turso_statement_t = null;
        var tail_idx: usize = 0;
        var native_error: ffi.NativeError = null;
        const native_status = raw.turso_connection_prepare_first(
            connection,
            sql_string.ptr + offset,
            &handle,
            &tail_idx,
            &native_error,
        );
        ffi.expect(native_status, native_error, .ok, options.diagnostics, "batch prepare returned an unexpected control status") catch |err| {
            if (handle) |value| raw.turso_statement_deinit(value);
            return err;
        };

        // No statement means the remaining input contains only SQL trivia.
        if (handle == null) {
            if (options.diagnostics) |detail| detail.clear();
            return total_changes;
        }
        if (tail_idx == 0 or tail_idx > remaining_len) {
            raw.turso_statement_deinit(handle.?);
            ffi.setWrapperError(options.diagnostics, "batch parser returned a non-progressing or out-of-range tail offset");
            return error.InvalidState;
        }

        var statement = statement_mod.init(
            handle.?,
            &control.operation,
            autocommit_expectation,
            control.statement_io_policy,
        );
        defer statement.deinit();
        const changed = try statement.execute(options.diagnostics);
        total_changes = std.math.add(u64, total_changes, changed) catch {
            ffi.setWrapperError(options.diagnostics, "batch rows-changed total overflowed u64");
            return error.IntegerOverflow;
        };
        statement.deinit();
        offset += tail_idx;
    }
    if (options.diagnostics) |detail| detail.clear();
    return total_changes;
}

fn requireAvailable(
    control: *Control,
    diagnostics: ?*Diagnostics,
    within_transaction: bool,
) status_mod.Error!*raw.turso_connection_t {
    if (control.closed or control.handle == null) {
        ffi.setWrapperError(diagnostics, "connection is closed or deinited");
        return error.InvalidState;
    }
    if (control.poisoned) {
        ffi.setWrapperError(diagnostics, "connection state is unknown after a failed implicit rollback");
        return error.InvalidState;
    }
    if (control.transaction_active != within_transaction) {
        ffi.setWrapperError(diagnostics, if (control.transaction_active)
            "connection is exclusively borrowed by a transaction"
        else
            "transaction is no longer active");
        return error.InvalidState;
    }
    if (control.operation.active or control.operation.statement_alive) {
        ffi.setWrapperError(diagnostics, "connection already owns an active statement or rows iterator");
        return error.InvalidState;
    }
    return control.handle.?;
}

pub fn init(
    allocator: std.mem.Allocator,
    handle: *raw.turso_connection_t,
    owner_connections: *std.atomic.Value(usize),
) status_mod.Error!Connection {
    return initWithStatementIoPolicy(
        allocator,
        handle,
        owner_connections,
        .reject_io,
    );
}

/// Adopt an already-owned native connection into the safe Connection wrapper.
/// The caller retains ownership when allocation fails. On success, `deinit`
/// releases the native handle and decrements `owner_connections` exactly once.
///
/// Local databases use `init`, whose statement policy remains `reject_io`.
/// Sync connections explicitly select `drive_io_inline` because their native
/// statements can expose caller-driven I/O even through this synchronous API.
pub fn initWithStatementIoPolicy(
    allocator: std.mem.Allocator,
    handle: *raw.turso_connection_t,
    owner_connections: *std.atomic.Value(usize),
    statement_io_policy: StatementIoPolicy,
) status_mod.Error!Connection {
    const control = try allocator.create(Control);
    control.* = .{
        .allocator = allocator,
        .handle = handle,
        .owner_connections = owner_connections,
        .statement_io_policy = statement_io_policy,
    };
    control.operation.aggregate_cleanup_context = &control.aggregate_tracker;
    control.operation.aggregate_cleanup = cleanupAggregateTracker;
    control.operation.autocommit_context = control;
    control.operation.autocommit_check = checkAutocommitInvariant;
    return .{ .control = control };
}

fn cleanupAggregateTracker(context: *anyopaque) void {
    const tracker: *functions_mod.AggregateTracker = @ptrCast(@alignCast(context));
    tracker.cleanup();
}

fn checkAutocommitInvariant(
    context: *anyopaque,
    expectation: statement_mod.AutocommitExpectation,
) bool {
    const control: *Control = @ptrCast(@alignCast(context));
    if (control.poisoned) return false;
    const connection = control.handle orelse {
        control.poisoned = true;
        return false;
    };
    const expected = switch (expectation) {
        .enabled => true,
        .disabled => false,
        .any => return true,
    };
    if (raw.turso_connection_get_autocommit(connection) == expected) return true;
    control.poisoned = true;
    return false;
}
