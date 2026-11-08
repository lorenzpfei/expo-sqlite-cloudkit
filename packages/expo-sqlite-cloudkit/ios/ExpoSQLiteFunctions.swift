import ExpoSQLite

extension SQLiteFunctions {
  static let expoSQLite = SQLiteFunctions(
    open: exsqlite3_open_v2,
    close: exsqlite3_close_v2,
    busyTimeout: exsqlite3_busy_timeout,
    errmsg: exsqlite3_errmsg,
    prepare: exsqlite3_prepare_v2,
    step: exsqlite3_step,
    finalize: exsqlite3_finalize,
    bindNull: exsqlite3_bind_null,
    bindInt64: exsqlite3_bind_int64,
    bindDouble: exsqlite3_bind_double,
    bindText: exsqlite3_bind_text,
    bindBlob: exsqlite3_bind_blob,
    columnCount: exsqlite3_column_count,
    columnName: exsqlite3_column_name,
    columnType: exsqlite3_column_type,
    columnInt64: exsqlite3_column_int64,
    columnDouble: exsqlite3_column_double,
    columnText: exsqlite3_column_text,
    columnBlob: exsqlite3_column_blob,
    columnBytes: exsqlite3_column_bytes
  )
}
