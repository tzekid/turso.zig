//! Opt-in, ownership-safe bindings for the Turso Cloud sync SDK Kit.
//!
//! This low-level module exposes the caller-driven operation and I/O lifecycle.
//! HTTP/filesystem transports remain separate policy layers. Remote cipher
//! selection and unfinished native transform callbacks are not safe APIs.

pub const raw = @import("sync/raw.zig");
pub const version = @import("version.zig");
const config_mod = @import("sync/config.zig");
pub const database = @import("sync/database.zig");
const operation_mod = @import("sync/operation.zig");
const io_mod = @import("sync/io.zig");
pub const transport = @import("sync/transport.zig");
pub const std_transport = @import("sync/std_transport.zig");
const workflows_mod = @import("sync/workflows.zig");

/// Curated configuration façade. Native C configuration remains under `raw`.
pub const config = struct {
    pub const Diagnostics = config_mod.Diagnostics;
    pub const PartialBootstrap = config_mod.PartialBootstrap;
    pub const LocalConfig = config_mod.LocalConfig;
    pub const SyncConfig = config_mod.SyncConfig;
};

/// Curated operation façade. Operations are created by `SyncDatabase`.
pub const operation = struct {
    pub const Diagnostics = operation_mod.Diagnostics;
    pub const Error = operation_mod.Error;
    pub const Connection = operation_mod.Connection;
    pub const Poll = operation_mod.Poll;
    pub const Stats = operation_mod.Stats;
    pub const Changes = operation_mod.Changes;
    pub const Operation = operation_mod.Operation;
};

/// Curated I/O façade. Queue items are checked out by `SyncDatabase`.
pub const io = struct {
    pub const Diagnostics = io_mod.Diagnostics;
    pub const Error = io_mod.Error;
    pub const RequestKind = io_mod.RequestKind;
    pub const HttpRequest = io_mod.HttpRequest;
    pub const HttpHeader = io_mod.HttpHeader;
    pub const FullReadRequest = io_mod.FullReadRequest;
    pub const FullWriteRequest = io_mod.FullWriteRequest;
    pub const IoItem = io_mod.IoItem;
};

pub const Diagnostics = database.Diagnostics;
pub const LocalConfig = config.LocalConfig;
pub const SyncConfig = config.SyncConfig;
pub const PartialBootstrap = config.PartialBootstrap;
pub const SyncDatabase = database.SyncDatabase;
pub const Connection = operation.Connection;
pub const Changes = operation.Changes;
pub const Stats = operation.Stats;
pub const Operation = operation.Operation;
pub const Poll = operation.Poll;
pub const IoItem = io.IoItem;
pub const RequestKind = io.RequestKind;
pub const HttpRequest = io.HttpRequest;
pub const HttpHeader = io.HttpHeader;
pub const FullReadRequest = io.FullReadRequest;
pub const FullWriteRequest = io.FullWriteRequest;
pub const TransportHeader = transport.HttpHeader;
pub const TransportHttpRequest = transport.HttpRequest;
pub const AuthorizationProvider = transport.AuthorizationProvider;
pub const TransportOptions = transport.Options;
pub const BufferWriter = transport.BufferWriter;
pub const ResponseWriter = transport.ResponseWriter;
pub const run = transport.run;
pub const PullSummary = workflows_mod.PullSummary;
pub const SyncSummary = workflows_mod.SyncSummary;
pub const runVoid = workflows_mod.runVoid;
pub const runConnection = workflows_mod.runConnection;
pub const pull = workflows_mod.pull;
pub const sync = workflows_mod.sync;
pub const StandardTransport = std_transport.StandardTransport;

test {
    _ = raw;
    _ = version;
    _ = config;
    _ = database;
    _ = operation;
    _ = io;
    _ = transport;
    _ = std_transport;
    _ = workflows_mod;

    if (@hasDecl(config, "NativeConfig")) {
        @compileError("NativeConfig must not be part of the curated sync API");
    }
    if (@hasDecl(operation, "init")) {
        @compileError("operation.init must not be part of the curated sync API");
    }
    if (@hasDecl(io, "take")) {
        @compileError("io.take must not be part of the curated sync API");
    }
    if (@hasDecl(Changes, "takeForApply")) {
        @compileError("Changes.takeForApply must not be part of the curated sync API");
    }
    if (!@hasDecl(@This(), "run") or
        !@hasDecl(@This(), "runVoid") or
        !@hasDecl(@This(), "runConnection") or
        !@hasDecl(@This(), "pull") or
        !@hasDecl(@This(), "sync"))
    {
        @compileError("low- and high-level sync workflows must remain exposed");
    }
}
