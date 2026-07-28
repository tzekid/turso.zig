//! Internal invariants that must remain enforced in every optimization mode.

pub const messages = struct {
    pub const statement_registry_underflow =
        "turso internal invariant: statement registry underflow";
    pub const active_statement_mismatch =
        "turso internal invariant: released statement does not own the active lease";
    pub const connection_owner_underflow =
        "turso internal invariant: connection owner count underflow";
    pub const sync_io_underflow =
        "turso internal invariant: sync I/O item count underflow";
    pub const aggregate_head_mismatch =
        "turso internal invariant: aggregate tracker head mismatch";
};

pub inline fn requireRegisteredStatement(live_statements: usize) void {
    if (live_statements == 0) @panic(messages.statement_registry_underflow);
}

pub inline fn requireActiveStatement(
    active_statement: ?*const anyopaque,
    statement: *const anyopaque,
) void {
    if (active_statement != statement) @panic(messages.active_statement_mismatch);
}

pub inline fn requireConnectionOwner(previous_owners: usize) void {
    if (previous_owners == 0) @panic(messages.connection_owner_underflow);
}

pub inline fn requireOutstandingSyncItem(outstanding_items: usize) void {
    if (outstanding_items == 0) @panic(messages.sync_io_underflow);
}

pub inline fn requireAggregateHead(is_head: bool) void {
    if (!is_head) @panic(messages.aggregate_head_mismatch);
}
