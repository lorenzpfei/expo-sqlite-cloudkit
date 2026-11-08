import Foundation

public typealias Row = [String: SyncValue]

public struct SQLiteFunctions {
  public typealias Destructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

  public var open: (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32
  public var close: (OpaquePointer?) -> Int32
  public var busyTimeout: (OpaquePointer?, Int32) -> Int32
  public var errmsg: (OpaquePointer?) -> UnsafePointer<CChar>?
  public var prepare: (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
  public var step: (OpaquePointer?) -> Int32
  public var finalize: (OpaquePointer?) -> Int32
  public var bindNull: (OpaquePointer?, Int32) -> Int32
  public var bindInt64: (OpaquePointer?, Int32, Int64) -> Int32
  public var bindDouble: (OpaquePointer?, Int32, Double) -> Int32
  public var bindText: (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, Destructor?) -> Int32
  public var bindBlob: (OpaquePointer?, Int32, UnsafeRawPointer?, Int32, Destructor?) -> Int32
  public var columnCount: (OpaquePointer?) -> Int32
  public var columnName: (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
  public var columnType: (OpaquePointer?, Int32) -> Int32
  public var columnInt64: (OpaquePointer?, Int32) -> Int64
  public var columnDouble: (OpaquePointer?, Int32) -> Double
  public var columnText: (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?
  public var columnBlob: (OpaquePointer?, Int32) -> UnsafeRawPointer?
  public var columnBytes: (OpaquePointer?, Int32) -> Int32

  public init(
    open: @escaping (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32,
    close: @escaping (OpaquePointer?) -> Int32,
    busyTimeout: @escaping (OpaquePointer?, Int32) -> Int32,
    errmsg: @escaping (OpaquePointer?) -> UnsafePointer<CChar>?,
    prepare: @escaping (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32,
    step: @escaping (OpaquePointer?) -> Int32,
    finalize: @escaping (OpaquePointer?) -> Int32,
    bindNull: @escaping (OpaquePointer?, Int32) -> Int32,
    bindInt64: @escaping (OpaquePointer?, Int32, Int64) -> Int32,
    bindDouble: @escaping (OpaquePointer?, Int32, Double) -> Int32,
    bindText: @escaping (OpaquePointer?, Int32, UnsafePointer<CChar>?, Int32, Destructor?) -> Int32,
    bindBlob: @escaping (OpaquePointer?, Int32, UnsafeRawPointer?, Int32, Destructor?) -> Int32,
    columnCount: @escaping (OpaquePointer?) -> Int32,
    columnName: @escaping (OpaquePointer?, Int32) -> UnsafePointer<CChar>?,
    columnType: @escaping (OpaquePointer?, Int32) -> Int32,
    columnInt64: @escaping (OpaquePointer?, Int32) -> Int64,
    columnDouble: @escaping (OpaquePointer?, Int32) -> Double,
    columnText: @escaping (OpaquePointer?, Int32) -> UnsafePointer<UInt8>?,
    columnBlob: @escaping (OpaquePointer?, Int32) -> UnsafeRawPointer?,
    columnBytes: @escaping (OpaquePointer?, Int32) -> Int32
  ) {
    self.open = open
    self.close = close
    self.busyTimeout = busyTimeout
    self.errmsg = errmsg
    self.prepare = prepare
    self.step = step
    self.finalize = finalize
    self.bindNull = bindNull
    self.bindInt64 = bindInt64
    self.bindDouble = bindDouble
    self.bindText = bindText
    self.bindBlob = bindBlob
    self.columnCount = columnCount
    self.columnName = columnName
    self.columnType = columnType
    self.columnInt64 = columnInt64
    self.columnDouble = columnDouble
    self.columnText = columnText
    self.columnBlob = columnBlob
    self.columnBytes = columnBytes
  }
}

public struct SQLiteError: Error, CustomStringConvertible {
  public let code: Int32
  public let message: String
  public var description: String { "SQLite error \(code): \(message)" }
}

public final class SQLiteConnection: @unchecked Sendable {
  private enum Code {
    static let ok: Int32 = 0
    static let row: Int32 = 100
    static let done: Int32 = 101
    static let integer: Int32 = 1
    static let float: Int32 = 2
    static let text: Int32 = 3
    static let blob: Int32 = 4
    static let openReadWrite: Int32 = 0x2
    static let openCreate: Int32 = 0x4
    static let openFullMutex: Int32 = 0x10000
  }

  private static let transient = unsafeBitCast(-1, to: SQLiteFunctions.Destructor.self)

  public let path: String
  private let api: SQLiteFunctions
  private let handle: OpaquePointer?
  private let lock = NSRecursiveLock()
  private var transactionDepth = 0

  public init(path: String, api: SQLiteFunctions, key: String? = nil) throws {
    var db: OpaquePointer?
    let code = api.open(path, &db, Code.openReadWrite | Code.openCreate | Code.openFullMutex, nil)
    if code != Code.ok {
      let message = db.flatMap { api.errmsg($0) }.map { String(cString: $0) } ?? "cannot open \(path)"
      _ = api.close(db)
      throw SQLiteError(code: code, message: message)
    }
    self.path = path
    self.api = api
    self.handle = db
    _ = api.busyTimeout(db, 5000)
    if let key {
      try execute("PRAGMA key = '\(key.replacingOccurrences(of: "'", with: "''"))'")
    }
    try execute("PRAGMA journal_mode = WAL")
  }

  deinit {
    _ = api.close(handle)
  }

  public func execute(_ sql: String, _ parameters: [SyncValue] = []) throws {
    _ = try run(sql, parameters, collect: false)
  }

  public func query(_ sql: String, _ parameters: [SyncValue] = []) throws -> [Row] {
    try run(sql, parameters, collect: true)
  }

  public func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    if transactionDepth > 0 {
      transactionDepth += 1
      defer { transactionDepth -= 1 }
      return try body()
    }
    try execute("BEGIN IMMEDIATE")
    transactionDepth = 1
    defer { transactionDepth = 0 }
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func run(_ sql: String, _ parameters: [SyncValue], collect: Bool) throws -> [Row] {
    lock.lock()
    defer { lock.unlock() }

    var statement: OpaquePointer?
    try check(api.prepare(handle, sql, -1, &statement, nil), sql)
    defer { _ = api.finalize(statement) }

    for (index, value) in parameters.enumerated() {
      try check(bind(value, at: Int32(index + 1), to: statement), sql)
    }

    var rows: [Row] = []
    while true {
      let code = api.step(statement)
      if code == Code.done { return rows }
      guard code == Code.row else { try check(code, sql); return rows }
      if collect { rows.append(readRow(statement)) }
    }
  }

  private func bind(_ value: SyncValue, at index: Int32, to statement: OpaquePointer?) -> Int32 {
    switch value {
    case .null:
      return api.bindNull(statement, index)
    case .integer(let number):
      return api.bindInt64(statement, index, number)
    case .real(let number):
      return api.bindDouble(statement, index, number)
    case .text(let text):
      return api.bindText(statement, index, text, -1, Self.transient)
    case .blob(let data):
      return data.withUnsafeBytes { bytes in
        api.bindBlob(statement, index, bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(bytes.count), Self.transient)
      }
    }
  }

  private func readRow(_ statement: OpaquePointer?) -> Row {
    var row: Row = [:]
    for index in 0..<api.columnCount(statement) {
      let name = api.columnName(statement, index).map { String(cString: $0) } ?? "\(index)"
      switch api.columnType(statement, index) {
      case Code.integer:
        row[name] = .integer(api.columnInt64(statement, index))
      case Code.float:
        row[name] = .real(api.columnDouble(statement, index))
      case Code.text:
        row[name] = .text(api.columnText(statement, index).map { String(cString: $0) } ?? "")
      case Code.blob:
        let count = Int(api.columnBytes(statement, index))
        row[name] = .blob(api.columnBlob(statement, index).map { Data(bytes: $0, count: count) } ?? Data())
      default:
        row[name] = .null
      }
    }
    return row
  }

  private func check(_ code: Int32, _ sql: String) throws {
    guard code != Code.ok else { return }
    let message = api.errmsg(handle).map { String(cString: $0) } ?? "unknown error"
    throw SQLiteError(code: code, message: "\(message) in \(sql)")
  }
}
