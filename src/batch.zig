const std = @import("std");
const cstring = @import("cstring.zig");
const diagnostics_mod = @import("diagnostics.zig");
const ffi = @import("ffi.zig");
const parameters = @import("parameters.zig");
const row_mod = @import("row.zig");
const statement_mod = @import("statement.zig");
const value_mod = @import("value.zig");

pub const Error = parameters.Error || error{MaterializationLimitExceeded};
pub const Diagnostics = diagnostics_mod.Diagnostics;
pub const NamedBinding = parameters.NamedBinding;
pub const Value = value_mod.Value;
pub const OwnedValue = value_mod.OwnedValue;
pub const ColumnInfo = row_mod.ColumnInfo;

/// Runtime bindings for one structured batch entry.
pub const BatchParameters = union(enum) {
    none,
    positional: []const Value,
    named: []const NamedBinding,
};

/// One SQL statement and its complete runtime binding set.
pub const BatchItem = struct {
    sql: []const u8,
    parameters: BatchParameters = .none,
};

/// Transaction policy for `Connection.executeBatch`.
///
/// `Transaction.executeBatch` already runs inside its caller-owned
/// transaction and therefore accepts only `.none`.
pub const BatchTransaction = enum {
    none,
    deferred,
    immediate,
    exclusive,
    concurrent,
};

/// Aggregate limits across all materialized entries in one report.
///
/// `max_items` counts column descriptors plus row values. `max_bytes` counts
/// owned SQL metadata, TEXT, and BLOB bytes; container allocation is bounded
/// by `max_rows`, `max_items`, and the caller-supplied batch length.
pub const MaterializeOptions = struct {
    max_rows: usize,
    max_items: usize,
    max_bytes: usize,
};

/// Query-row handling is explicit so a batch cannot allocate an unbounded
/// result accidentally.
pub const BatchRowPolicy = union(enum) {
    changes_only,
    materialize_rows: MaterializeOptions,
};

pub const BatchOptions = struct {
    diagnostics: ?*Diagnostics = null,
    transaction: BatchTransaction = .none,
    row_policy: BatchRowPolicy = .changes_only,
};

/// What happened to transaction ownership during a structured batch.
pub const BatchTransactionOutcome = enum {
    /// No wrapper-owned transaction was requested.
    not_requested,
    /// A requested Connection-owned transaction could not be started.
    begin_failed,
    /// The Connection-owned transaction committed.
    committed,
    /// The Connection-owned transaction rolled back after a failure.
    rolled_back,
    /// Rollback failed and the Connection was poisoned.
    rollback_failed,
    /// The caller-owned Transaction remains active.
    existing_transaction,
};

/// One allocator-owned materialized result row.
pub const BatchRow = struct {
    values: []OwnedValue = &.{},
    owned: bool = false,

    fn deinit(self: *BatchRow, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.values) |*value| value.deinit(allocator);
        allocator.free(self.values);
        self.values = &.{};
        self.owned = false;
    }
};

/// Result metadata for one successfully completed batch entry.
///
/// `columns` and `rows` are empty under `.changes_only`. Under
/// `.materialize_rows` they remain valid until the parent `BatchReport` is
/// deinited.
pub const BatchEntryResult = struct {
    rows_changed: u64 = 0,
    last_insert_row_id: i64 = 0,
    columns: []ColumnInfo = &.{},
    rows: []BatchRow = &.{},
    owned: bool = false,

    fn deinit(self: *BatchEntryResult, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.columns) |*column| column.deinit(allocator);
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.columns);
        allocator.free(self.rows);
        self.columns = &.{};
        self.rows = &.{};
        self.owned = false;
    }
};

/// Caller-visible progress for successful and failed structured batches.
///
/// Initialize with `.{};`, pass it to `executeBatch`, and call `deinit`.
/// `entries()` contains exactly `completed` successful entries. On an entry
/// failure, `failed_index` identifies the first uncompleted input. Deinit is
/// idempotent.
pub const BatchReport = struct {
    completed: usize = 0,
    failed_index: ?usize = null,
    transaction_outcome: BatchTransactionOutcome = .not_requested,

    allocator: ?std.mem.Allocator = null,
    storage: []BatchEntryResult = &.{},

    pub fn entries(self: *const BatchReport) []const BatchEntryResult {
        return self.storage[0..self.completed];
    }

    pub fn deinit(self: *BatchReport) void {
        const allocator = self.allocator orelse {
            self.* = .{};
            return;
        };
        for (self.storage[0..self.completed]) |*entry| entry.deinit(allocator);
        allocator.free(self.storage);
        self.* = .{};
    }

    /// Execution support shared by Connection and Transaction.
    pub fn prepareForExecution(
        self: *BatchReport,
        allocator: std.mem.Allocator,
        entry_count: usize,
    ) std.mem.Allocator.Error!void {
        self.deinit();
        const storage = try allocator.alloc(BatchEntryResult, entry_count);
        for (storage) |*entry| entry.* = .{};
        self.* = .{
            .allocator = allocator,
            .storage = storage,
        };
    }

    /// Move one completed result into the preallocated report.
    pub fn appendCompleted(self: *BatchReport, entry: *BatchEntryResult) void {
        std.debug.assert(self.completed < self.storage.len);
        self.storage[self.completed] = entry.*;
        self.completed += 1;
        entry.* = .{};
    }
};

const MaterializationUsage = struct {
    rows: usize = 0,
    items: usize = 0,
    bytes: usize = 0,
};

/// Validate every descriptor before Connection or Transaction execution.
/// This is public only so the owner modules can share one implementation.
pub fn validateItems(
    items: []const BatchItem,
    diagnostics: ?*Diagnostics,
    report: *BatchReport,
) Error!void {
    for (items, 0..) |item, index| {
        cstring.validate(item.sql) catch |err| {
            report.failed_index = index;
            ffi.setWrapperError(
                diagnostics,
                "batch SQL must be valid UTF-8 without an interior NUL",
            );
            return err;
        };
        switch (item.parameters) {
            .none => {},
            .positional => |values| for (values) |value| {
                validateValue(value) catch |err| {
                    report.failed_index = index;
                    ffi.setWrapperError(diagnostics, "batch TEXT parameter is not valid UTF-8");
                    return err;
                };
            },
            .named => |bindings| for (bindings, 0..) |binding, binding_index| {
                parameters.validateSqlName(binding.name) catch |err| {
                    report.failed_index = index;
                    ffi.setWrapperError(
                        diagnostics,
                        "batch named parameter must be valid UTF-8, NUL-free, and explicitly prefixed",
                    );
                    return err;
                };
                validateValue(binding.value) catch |err| {
                    report.failed_index = index;
                    ffi.setWrapperError(diagnostics, "batch TEXT parameter is not valid UTF-8");
                    return err;
                };
                for (bindings[0..binding_index]) |previous| {
                    if (std.mem.eql(u8, previous.name, binding.name)) {
                        report.failed_index = index;
                        ffi.setWrapperError(
                            diagnostics,
                            "batch named parameter set contains a duplicate name",
                        );
                        return error.DuplicateParameter;
                    }
                }
            },
        }
    }
}

/// Execute through the public Statement lifecycle of a Connection or
/// Transaction owner. Transaction orchestration remains in connection.zig.
pub fn executeItems(
    owner: anytype,
    allocator: std.mem.Allocator,
    items: []const BatchItem,
    row_policy: BatchRowPolicy,
    diagnostics: ?*Diagnostics,
    report: *BatchReport,
) Error!void {
    var usage: MaterializationUsage = .{};
    for (items, 0..) |item, index| {
        var result = executeItem(
            owner,
            allocator,
            item,
            row_policy,
            diagnostics,
            &usage,
        ) catch |err| {
            report.failed_index = index;
            return err;
        };
        report.appendCompleted(&result);
    }
    if (diagnostics) |detail| detail.clear();
}

fn validateValue(value: Value) error{InvalidUtf8}!void {
    switch (value) {
        .text => |bytes| if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8,
        else => {},
    }
}

fn executeItem(
    owner: anytype,
    allocator: std.mem.Allocator,
    item: BatchItem,
    row_policy: BatchRowPolicy,
    diagnostics: ?*Diagnostics,
    usage: *MaterializationUsage,
) Error!BatchEntryResult {
    var statement = try owner.prepare(item.sql, .{ .diagnostics = diagnostics });
    defer statement.deinit();
    try bindParameters(&statement, item.parameters, diagnostics);

    return switch (row_policy) {
        .changes_only => .{
            .rows_changed = try statement.execute(diagnostics),
            .last_insert_row_id = try owner.lastInsertRowId(),
        },
        .materialize_rows => |limits| try materializeItem(
            owner,
            allocator,
            &statement,
            limits,
            diagnostics,
            usage,
        ),
    };
}

fn bindParameters(
    statement: *statement_mod.Statement,
    batch_parameters: BatchParameters,
    diagnostics: ?*Diagnostics,
) Error!void {
    return switch (batch_parameters) {
        .none => statement.bindAll(&.{}, diagnostics),
        .positional => |values| statement.bindAll(values, diagnostics),
        .named => |bindings| statement.bindNamedAll(bindings, diagnostics),
    };
}

fn materializeItem(
    owner: anytype,
    allocator: std.mem.Allocator,
    statement: *statement_mod.Statement,
    limits: MaterializeOptions,
    diagnostics: ?*Diagnostics,
    usage: *MaterializationUsage,
) Error!BatchEntryResult {
    const column_count = try statement.columnCount();
    try reserveMaterialized(
        &usage.items,
        column_count,
        limits.max_items,
        diagnostics,
        "batch materialization exceeded max_items while copying column metadata",
    );

    const columns = allocator.alloc(ColumnInfo, column_count) catch |err| {
        ffi.setWrapperError(diagnostics, "batch column metadata allocation failed");
        return err;
    };
    var initialized_columns: usize = 0;
    errdefer {
        for (columns[0..initialized_columns]) |*column| column.deinit(allocator);
        allocator.free(columns);
    }
    while (initialized_columns < column_count) : (initialized_columns += 1) {
        columns[initialized_columns] = statement.columnInfo(
            allocator,
            initialized_columns,
        ) catch |err| {
            ffi.setWrapperError(diagnostics, "batch column metadata could not be copied");
            return err;
        };
        reserveColumnBytes(
            usage,
            &columns[initialized_columns],
            limits.max_bytes,
            diagnostics,
        ) catch |err| {
            columns[initialized_columns].deinit(allocator);
            return err;
        };
    }

    var materialized_rows: std.ArrayList(BatchRow) = .empty;
    errdefer {
        for (materialized_rows.items) |*row| deinitMaterializedRow(row, allocator);
        materialized_rows.deinit(allocator);
    }

    var rows = try statement.intoRows(diagnostics);
    defer rows.deinit();
    while (try nextRow(&rows, diagnostics)) |row| {
        try reserveMaterialized(
            &usage.rows,
            1,
            limits.max_rows,
            diagnostics,
            "batch materialization exceeded max_rows",
        );
        try reserveMaterialized(
            &usage.items,
            column_count,
            limits.max_items,
            diagnostics,
            "batch materialization exceeded max_items while copying row values",
        );

        const values = allocator.alloc(OwnedValue, column_count) catch |err| {
            ffi.setWrapperError(diagnostics, "batch row allocation failed");
            return err;
        };
        var initialized_values: usize = 0;
        errdefer {
            for (values[0..initialized_values]) |*value| value.deinit(allocator);
            allocator.free(values);
        }
        while (initialized_values < column_count) : (initialized_values += 1) {
            const value = try row.value(initialized_values);
            const owned_bytes = switch (value) {
                .text => |bytes| bytes.len,
                .blob => |bytes| bytes.len,
                else => 0,
            };
            try reserveMaterialized(
                &usage.bytes,
                owned_bytes,
                limits.max_bytes,
                diagnostics,
                "batch materialization exceeded max_bytes while copying row values",
            );
            values[initialized_values] = value.toOwned(allocator) catch |err| {
                ffi.setWrapperError(diagnostics, "batch row value allocation failed");
                return err;
            };
        }

        const owned_row: BatchRow = .{
            .values = values,
            .owned = true,
        };
        materialized_rows.append(allocator, owned_row) catch |err| {
            ffi.setWrapperError(diagnostics, "batch row-list allocation failed");
            return err;
        };
    }
    const rows_changed = try rows.rowsChanged();
    try rows.finish(diagnostics);

    const owned_rows = materialized_rows.toOwnedSlice(allocator) catch |err| {
        ffi.setWrapperError(diagnostics, "batch result finalization allocation failed");
        return err;
    };
    return .{
        .rows_changed = rows_changed,
        .last_insert_row_id = try owner.lastInsertRowId(),
        .columns = columns,
        .rows = owned_rows,
        .owned = true,
    };
}

fn nextRow(
    rows: *statement_mod.Rows,
    diagnostics: ?*Diagnostics,
) Error!?statement_mod.Row {
    return if (diagnostics) |detail|
        rows.nextWithDiagnostics(detail)
    else
        rows.next();
}

fn reserveColumnBytes(
    usage: *MaterializationUsage,
    column: *const ColumnInfo,
    limit: usize,
    diagnostics: ?*Diagnostics,
) Error!void {
    try reserveMaterialized(
        &usage.bytes,
        column.name.len,
        limit,
        diagnostics,
        "batch materialization exceeded max_bytes while copying column metadata",
    );
    if (column.declared_type) |value| try reserveMaterialized(
        &usage.bytes,
        value.len,
        limit,
        diagnostics,
        "batch materialization exceeded max_bytes while copying column metadata",
    );
    if (column.declared_name) |value| try reserveMaterialized(
        &usage.bytes,
        value.len,
        limit,
        diagnostics,
        "batch materialization exceeded max_bytes while copying column metadata",
    );
    if (column.base_type) |value| try reserveMaterialized(
        &usage.bytes,
        value.len,
        limit,
        diagnostics,
        "batch materialization exceeded max_bytes while copying column metadata",
    );
}

fn reserveMaterialized(
    current: *usize,
    additional: usize,
    limit: usize,
    diagnostics: ?*Diagnostics,
    detail: []const u8,
) Error!void {
    const next = std.math.add(usize, current.*, additional) catch {
        ffi.setWrapperError(diagnostics, detail);
        return error.MaterializationLimitExceeded;
    };
    if (next > limit) {
        ffi.setWrapperError(diagnostics, detail);
        return error.MaterializationLimitExceeded;
    }
    current.* = next;
}

fn deinitMaterializedRow(row: *BatchRow, allocator: std.mem.Allocator) void {
    if (!row.owned) return;
    for (row.values) |*value| value.deinit(allocator);
    allocator.free(row.values);
    row.* = .{};
}
