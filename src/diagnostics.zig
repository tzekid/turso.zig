const status_mod = @import("status.zig");

pub const Status = status_mod.Status;

/// Allocation-free detail for the most recent operation.
///
/// The buffer is intentionally embedded so preserving the native error cannot
/// itself fail with `OutOfMemory`. A successful wrapper operation should call
/// `clear` before returning.
pub const Diagnostics = struct {
    pub const capacity = 1024;

    status: Status = .ok,
    message: [capacity]u8 = undefined,
    message_len: usize = 0,
    truncated: bool = false,

    pub fn clear(self: *Diagnostics) void {
        self.status = .ok;
        self.message_len = 0;
        self.truncated = false;
    }

    pub fn text(self: *const Diagnostics) []const u8 {
        return self.message[0..self.message_len];
    }

    /// Replace the current diagnostic. Oversize messages are truncated to the
    /// fixed capacity and remain valid byte slices; no terminator is stored.
    pub fn set(self: *Diagnostics, status: Status, detail: []const u8) void {
        const len = @min(detail.len, capacity);
        @memcpy(self.message[0..len], detail[0..len]);
        self.status = status;
        self.message_len = len;
        self.truncated = detail.len > capacity;
    }

    /// Record a wrapper-generated failure that has no native status/message
    /// out-parameter. `failure` is used because the richer identity lives in
    /// the Zig error union returned by the operation.
    pub fn setWrapperError(self: *Diagnostics, detail: []const u8) void {
        self.set(.failure, detail);
    }
};
