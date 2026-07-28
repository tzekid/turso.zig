//! Zig-friendly native bindings for the Turso database engine.
//!
//! The safe API is built in layers. Advanced callers can access the exact
//! pinned SDK Kit C ABI through the raw namespace.

pub const raw = @import("raw.zig");
pub const version = @import("version.zig");

const status_mod = @import("status.zig");
const diagnostics_mod = @import("diagnostics.zig");
const value_mod = @import("value.zig");
const config_mod = @import("config.zig");
const database_mod = @import("database.zig");
const connection_mod = @import("connection.zig");
const statement_mod = @import("statement.zig");
const row_mod = @import("row.zig");
const runtime_mod = @import("runtime.zig");
const functions_mod = @import("functions.zig");
const batch_mod = @import("batch.zig");

pub const Error = status_mod.Error;
pub const Status = status_mod.Status;
pub const Control = status_mod.Control;
pub const Diagnostics = diagnostics_mod.Diagnostics;

pub const Text = value_mod.Text;
pub const Blob = value_mod.Blob;
pub const Value = value_mod.Value;
pub const ValueRef = value_mod.ValueRef;
pub const OwnedValue = value_mod.OwnedValue;

pub const Vfs = config_mod.Vfs;
pub const FeatureSet = config_mod.FeatureSet;
pub const EncryptionCipher = config_mod.EncryptionCipher;
pub const EncryptionOptions = config_mod.EncryptionOptions;

pub const Database = database_mod.Database;
pub const DatabaseOptions = database_mod.DatabaseOptions;
pub const OpenError = database_mod.OpenError;
pub const Connection = connection_mod.Connection;
pub const ConnectionOptions = connection_mod.ConnectionOptions;
pub const OperationOptions = connection_mod.OperationOptions;
pub const Statement = statement_mod.Statement;
pub const StatementState = statement_mod.State;
pub const Rows = statement_mod.Rows;
pub const Row = row_mod.Row;
pub const NamedBinding = statement_mod.NamedBinding;
pub const ParameterInfo = statement_mod.ParameterInfo;
pub const BindError = statement_mod.BindError;
pub const ColumnInfo = row_mod.ColumnInfo;
pub const ColumnKind = row_mod.ColumnKind;
pub const DecodeError = row_mod.DecodeError;
pub const DecodeMode = row_mod.DecodeMode;
pub const DecodeOptions = row_mod.DecodeOptions;
pub const Transaction = connection_mod.Connection.Transaction;
pub const TransactionMode = connection_mod.Connection.TransactionMode;
pub const TransactionState = connection_mod.TransactionState;

pub const BatchError = batch_mod.Error;
pub const BatchParameters = batch_mod.BatchParameters;
pub const BatchItem = batch_mod.BatchItem;
pub const BatchTransaction = batch_mod.BatchTransaction;
pub const MaterializeOptions = batch_mod.MaterializeOptions;
pub const BatchRowPolicy = batch_mod.BatchRowPolicy;
pub const BatchOptions = batch_mod.BatchOptions;
pub const BatchTransactionOutcome = batch_mod.BatchTransactionOutcome;
pub const BatchRow = batch_mod.BatchRow;
pub const BatchEntryResult = batch_mod.BatchEntryResult;
pub const BatchReport = batch_mod.BatchReport;

pub const CallbackError = functions_mod.CallbackError;
pub const CollationOrder = functions_mod.CollationOrder;
pub const ScalarFunctionOptions = functions_mod.ScalarFunctionOptions;
pub const AggregateFunctionOptions = functions_mod.AggregateFunctionOptions;
pub const CollationOptions = functions_mod.CollationOptions;

pub const LogLevel = runtime_mod.LogLevel;
pub const TracingLevel = runtime_mod.TracingLevel;
pub const Log = runtime_mod.Log;
pub const Logger = runtime_mod.Logger;
pub const SetupOptions = runtime_mod.SetupOptions;
pub const setup = runtime_mod.setup;
pub const runtimeVersion = runtime_mod.runtimeVersion;
pub const expectedRuntimeVersion = runtime_mod.expectedRuntimeVersion;
pub const verifyRuntimeVersion = runtime_mod.verifyRuntimeVersion;
