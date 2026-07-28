const std = @import("std");
const invariant = @import("invariant");

pub const panic = std.debug.FullPanic(panicExit);

fn panicExit(message: []const u8, _: ?usize) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(86);
}

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();

    const scenario = arguments.next() orelse return error.MissingScenario;
    if (arguments.next() != null) return error.TooManyArguments;

    if (std.mem.eql(u8, scenario, "statement-registry-underflow")) {
        return invariant.requireRegisteredStatement(0);
    }
    if (std.mem.eql(u8, scenario, "active-statement-mismatch")) {
        var active_owner: u8 = 0;
        var different_statement: u8 = 0;
        return invariant.requireActiveStatement(&active_owner, &different_statement);
    }
    if (std.mem.eql(u8, scenario, "connection-owner-underflow")) {
        return invariant.requireConnectionOwner(0);
    }
    if (std.mem.eql(u8, scenario, "sync-io-underflow")) {
        return invariant.requireOutstandingSyncItem(0);
    }
    if (std.mem.eql(u8, scenario, "aggregate-head-mismatch")) {
        return invariant.requireAggregateHead(false);
    }
    return error.UnknownScenario;
}
