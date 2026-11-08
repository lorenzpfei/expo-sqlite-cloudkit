import Foundation

public enum SyncValue: Hashable, Sendable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)

  var timestamp: Double? {
    switch self {
    case .integer(let value): return Double(value)
    case .real(let value): return value
    case .text(let value): return Double(value)
    case .null, .blob: return nil
    }
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}
