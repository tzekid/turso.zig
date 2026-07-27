//! Mechanically translated Turso sync SDK Kit C ABI.
//!
//! The declarations come exclusively from the pinned
//! `include/turso_sync.h`, which includes the matching base ABI.

pub const c = @cImport({
    @cInclude("turso_sync.h");
});

test "pinned sync ABI translates" {
    _ = c.turso_sync_database_t;
    _ = c.turso_sync_operation_t;
    _ = c.turso_sync_io_item_t;
    _ = c.turso_sync_changes_t;
    _ = c.turso_sync_database_new;
    _ = c.turso_sync_operation_resume;
}
