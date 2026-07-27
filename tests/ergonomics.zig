const std = @import("std");
const turso = @import("turso");

test "tuple and struct binding support zero-allocation prepared reuse" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE people(id INTEGER, name TEXT)", &.{}, .{});
    var insert = try connection.prepare("INSERT INTO people VALUES (?1, ?2)", .{});
    try insert.bindParams(.{ @as(i64, 1), "Ada" }, null);
    try std.testing.expectEqual(@as(u64, 1), try insert.execute(null));
    try insert.reset(null);
    try insert.bindParams(.{ @as(i64, 2), "Grace" }, null);
    try std.testing.expectEqual(@as(u64, 1), try insert.execute(null));
    insert.deinit();

    var named = try connection.prepare("SELECT :id, @name", .{});
    try named.bindParams(.{ .id = @as(i64, 3), .name = "Linus" }, null);
    var rows = try named.intoRows(null);
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 3), try row.get(i64, 0));
    try std.testing.expectEqualStrings("Linus", try row.get([]const u8, 1));
}

test "connection typed one-shot helpers preserve diagnostics cleanup and rows ownership" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE one_shot(id INTEGER, name TEXT)", &.{}, .{});
    try std.testing.expectEqual(
        @as(u64, 1),
        try connection.execParams(
            "INSERT INTO one_shot VALUES (?1, ?2)",
            .{ @as(i64, 1), "Ada" },
            .{},
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        try connection.execParams(
            "INSERT INTO one_shot VALUES (:id, :name)",
            .{ .name = "Grace", .id = @as(i64, 2) },
            .{},
        ),
    );

    var diagnostics = turso.Diagnostics{};
    try std.testing.expectError(
        error.IntegerOverflow,
        connection.execParams(
            "INSERT INTO one_shot VALUES (?1, ?2)",
            .{ @as(u64, std.math.maxInt(u64)), "overflow" },
            .{ .diagnostics = &diagnostics },
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.text(), "without truncation") != null);

    // The failed helper released its prepared statement, so the connection is
    // reusable and success clears stale diagnostics.
    try std.testing.expectEqual(
        @as(u64, 1),
        try connection.execParams(
            "INSERT INTO one_shot VALUES (:id, :name)",
            .{ .id = @as(i64, 3), .name = "Linus" },
            .{ .diagnostics = &diagnostics },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text().len);

    var rows = try connection.queryParams(
        "SELECT name FROM one_shot WHERE id = ?5",
        .{ null, null, null, null, @as(i64, 2) },
        .{},
    );
    defer rows.deinit();
    try std.testing.expectError(
        error.InvalidState,
        connection.execParams("SELECT ?1", .{@as(i64, 1)}, .{}),
    );
    try std.testing.expectEqualStrings("Grace", try (try rows.next()).?.get([]const u8, 0));
    try rows.finish(null);
    rows.deinit();
    try std.testing.expectEqual(
        @as(u64, 0),
        try connection.execParams("SELECT ?1", .{@as(i64, 1)}, .{}),
    );
}

test "named rules and parameter metadata are explicit" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var statement = try connection.prepare("SELECT :value, @other", .{});
    defer statement.deinit();
    try std.testing.expectError(error.InvalidState, statement.reset(null));
    try std.testing.expectError(error.InvalidParameterName, statement.bindNamed("value", 1, null));
    try std.testing.expectError(error.InteriorNul, statement.bindNamed(":value\x00ignored", 1, null));
    try std.testing.expectError(error.ParameterNotFound, statement.bindNamed(":missing", 1, null));
    try statement.bindNamed(":value", @as(i64, 7), null);

    const NamedBinding = @TypeOf(statement).NamedBinding;
    const duplicates = [_]NamedBinding{
        .{ .name = ":value", .value = .{ .integer = 1 } },
        .{ .name = ":value", .value = .{ .integer = 2 } },
    };
    try std.testing.expectError(error.DuplicateParameter, statement.bindNamedAll(&duplicates, null));
    try statement.reset(null);

    var info = try statement.parameterInfo(std.testing.allocator, 1);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), info.position);
    try std.testing.expectEqualStrings(":value", info.name.?);

    statement.deinit();
    var ambiguous = try connection.prepare("SELECT :same, @same", .{});
    defer ambiguous.deinit();
    try std.testing.expectError(
        error.AmbiguousParameter,
        ambiguous.bindParams(.{ .same = @as(i64, 1), .other = @as(i64, 2) }, null),
    );
}

test "column metadata typed decode scan and owned fields" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var statement = try connection.prepare(
        "SELECT 42 AS id, 'Ada' AS name, x'0102' AS payload",
        .{},
    );
    var column = try statement.columnInfo(std.testing.allocator, 0);
    defer column.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("id", column.name);

    var rows = try statement.intoRows(null);
    defer rows.deinit();
    const row = (try rows.next()).?;

    const Positional = struct { i64, []const u8, turso.Blob };
    const positional = try row.decode(Positional, null, .{});
    try std.testing.expectEqual(@as(i64, 42), positional[0]);
    try std.testing.expectEqualStrings("Ada", positional[1]);

    const Named = struct { name: []const u8, id: i64, payload: turso.Blob };
    const named = try row.decode(Named, null, .{ .mode = .by_name });
    try std.testing.expectEqual(@as(i64, 42), named.id);
    try std.testing.expectEqualStrings("Ada", named.name);

    var id: i64 = 0;
    var name: []const u8 = undefined;
    var payload: turso.Blob = undefined;
    try row.scan(.{ &id, &name, &payload });
    try std.testing.expectEqual(@as(i64, 42), id);

    const Owned = struct { id: i64, name: []u8, payload: turso.OwnedValue };
    var owned = try row.decode(Owned, std.testing.allocator, .{});
    defer {
        std.testing.allocator.free(owned.name);
        owned.payload.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("Ada", owned.name);
}

test "custom type metadata preserves kind base type and array depth" {
    var database = try turso.Database.open(std.testing.allocator, .{
        .path = ":memory:",
        .features = .{ .custom_types = true },
    });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.execBatch(
        \\CREATE TYPE cents BASE integer ENCODE value * 100 DECODE value / 100;
        \\CREATE DOMAIN positive_int AS integer CHECK (VALUE > 0);
        \\CREATE TYPE point AS STRUCT(x INT, y INT);
        \\CREATE TYPE shape AS UNION(circle INT, square INT);
        \\CREATE TABLE rich(
        \\  amounts INTEGER[][],
        \\  price cents,
        \\  score positive_int,
        \\  position point,
        \\  geometry shape
        \\) STRICT;
    , .{});

    var statement = try connection.prepare(
        "SELECT amounts, price, score, position, geometry FROM rich",
        .{},
    );
    defer statement.deinit();
    const Expected = struct {
        kind: turso.ColumnKind,
        declared_name: []const u8,
        base_type: ?[]const u8,
        dimensions: u32,
    };
    const expected = [_]Expected{
        .{ .kind = .builtin, .declared_name = "INTEGER", .base_type = null, .dimensions = 2 },
        .{ .kind = .custom, .declared_name = "cents", .base_type = "INTEGER", .dimensions = 0 },
        .{ .kind = .domain, .declared_name = "positive_int", .base_type = "INTEGER", .dimensions = 0 },
        .{ .kind = .struct_type, .declared_name = "point", .base_type = "BLOB", .dimensions = 0 },
        .{ .kind = .union_type, .declared_name = "shape", .base_type = "BLOB", .dimensions = 0 },
    };
    for (expected, 0..) |want, index| {
        var info = try statement.columnInfo(std.testing.allocator, index);
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqual(want.kind, info.kind);
        try std.testing.expectEqualStrings(want.declared_name, info.declared_name.?);
        try std.testing.expectEqual(want.dimensions, info.array_dimensions);
        if (want.base_type) |base_type| {
            try std.testing.expectEqualStrings(base_type, info.base_type.?);
        } else {
            try std.testing.expect(info.base_type == null);
        }
    }
}

test "duplicate and missing column names are rejected" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var rows = try connection.query("SELECT 1 AS x, 2 AS x", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectError(error.AmbiguousColumn, row.getByName(i64, "x"));
    try std.testing.expectError(error.MissingColumn, row.getByName(i64, "missing"));
}

test "nextAs cleans partially allocated rows on decode failure" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var rows = try connection.query("SELECT 'owned', 'not an integer'", &.{}, .{});
    defer rows.deinit();
    const Invalid = struct { first: []u8, second: i64 };
    try std.testing.expectError(
        error.TypeMismatch,
        rows.nextAs(Invalid, std.testing.allocator, .{}),
    );
}

test "row generation rejects stale access and explicit cancel releases connection" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    var rows = try connection.query("SELECT 1 UNION ALL SELECT 2", &.{}, .{});
    defer rows.deinit();
    const first = (try rows.next()).?;
    const second = (try rows.next()).?;
    try std.testing.expectError(error.InvalidState, first.value(0));
    try std.testing.expectEqual(@as(i64, 2), try second.get(i64, 0));
    try rows.cancel(null);

    _ = try connection.exec("SELECT 1", &.{}, .{});
}

test "owned row copies survive step finish and native statement teardown" {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    var rows = try connection.query(
        "SELECT 'retained', X'00FF' UNION ALL SELECT 'later', X'AA'",
        &.{},
        .{},
    );
    const first = (try rows.next()).?;
    var text = try first.toOwned(std.testing.allocator, 0);
    defer text.deinit(std.testing.allocator);
    var blob = try first.toOwned(std.testing.allocator, 1);
    defer blob.deinit(std.testing.allocator);
    _ = (try rows.next()).?;
    try rows.finish(null);
    rows.deinit();

    try std.testing.expectEqualStrings("retained", try text.get([]const u8));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xff }, (try blob.get(turso.Blob)).bytes);
}

test "positional prepared steady state performs no Zig allocation" {
    var allocator_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = allocator_probe.allocator();
    var database = try turso.Database.open(allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();

    _ = try connection.exec("CREATE TABLE allocation_probe(value INTEGER)", &.{}, .{});
    var statement = try connection.prepare("INSERT INTO allocation_probe VALUES (?1)", .{});
    defer statement.deinit();

    const allocations_before = allocator_probe.allocations;
    allocator_probe.fail_index = allocator_probe.alloc_index;
    for (1..4) |value| {
        try statement.bindParams(.{@as(i64, @intCast(value))}, null);
        try std.testing.expectEqual(@as(u64, 1), try statement.execute(null));
        if (value != 3) try statement.reset(null);
    }
    try std.testing.expectEqual(allocations_before, allocator_probe.allocations);
    try std.testing.expect(!allocator_probe.has_induced_failure);
}

test "owned metadata and typed rows clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyMetadataWithAllocator, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeOwnedRowWithAllocator, .{});
}

fn copyMetadataWithAllocator(allocator: std.mem.Allocator) !void {
    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    _ = try connection.exec("CREATE TABLE metadata_oom(id INTEGER, name TEXT)", &.{}, .{});
    var statement = try connection.prepare(
        "SELECT id AS identifier, name FROM metadata_oom WHERE id = :id",
        .{},
    );
    defer statement.deinit();

    var parameter = try statement.parameterInfo(allocator, 1);
    defer parameter.deinit(allocator);
    var first = try statement.columnInfo(allocator, 0);
    defer first.deinit(allocator);
    var second = try statement.columnInfo(allocator, 1);
    defer second.deinit(allocator);
}

fn decodeOwnedRowWithAllocator(allocator: std.mem.Allocator) !void {
    const Result = struct {
        name: []u8,
        payload: turso.OwnedValue,
    };

    var database = try turso.Database.open(std.testing.allocator, .{ .path = ":memory:" });
    defer database.deinit();
    var connection = try database.connect(.{});
    defer connection.deinit();
    var rows = try connection.query("SELECT 'Ada', X'00FF'", &.{}, .{});
    defer rows.deinit();
    var decoded = (try rows.nextAs(Result, allocator, .{})).?;
    defer allocator.free(decoded.name);
    defer decoded.payload.deinit(allocator);
}
