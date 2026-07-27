//! Mechanically translated Turso SDK Kit C ABI.
//!
//! The declarations come exclusively from the pinned `include/turso.h` through
//! `@cImport`; there is no second, hand-maintained set of extern declarations.

pub const c = @cImport({
    @cInclude("turso.h");
});

test "pinned ABI translates" {
    _ = c.turso_database_t;
    _ = c.turso_connection_t;
    _ = c.turso_statement_t;
    _ = c.turso_database_new;
    _ = c.turso_statement_step;
}
