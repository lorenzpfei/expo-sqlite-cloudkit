import SyncCore

#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension SQLiteFunctions {
  public static let system = SQLiteFunctions(
    open: sqlite3_open_v2,
    close: sqlite3_close_v2,
    busyTimeout: sqlite3_busy_timeout,
    errmsg: sqlite3_errmsg,
    prepare: sqlite3_prepare_v2,
    step: sqlite3_step,
    finalize: sqlite3_finalize,
    bindNull: sqlite3_bind_null,
    bindInt64: sqlite3_bind_int64,
    bindDouble: sqlite3_bind_double,
    bindText: sqlite3_bind_text,
    bindBlob: sqlite3_bind_blob,
    columnCount: sqlite3_column_count,
    columnName: sqlite3_column_name,
    columnType: sqlite3_column_type,
    columnInt64: sqlite3_column_int64,
    columnDouble: sqlite3_column_double,
    columnText: sqlite3_column_text,
    columnBlob: sqlite3_column_blob,
    columnBytes: sqlite3_column_bytes
  )
}
