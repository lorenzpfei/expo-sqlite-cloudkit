import ExpoModulesCore

public class ExpoSqliteCloudkitModule: Module {
  private var controller: AnyObject?

  public func definition() -> ModuleDefinition {
    Name("ExpoSqliteCloudkit")

    Events("onChange", "onStatus")

    AsyncFunction("configure") { (databasePath: String, containerIdentifier: String, schemaJson: String, encryptionKey: String?) async throws in
      guard #available(iOS 17.0, *) else { throw UnsupportedOSException() }
      let schema = try JSONDecoder().decode(SyncSchema.self, from: Data(schemaJson.utf8))
      (self.controller as? SyncController)?.stop()
      let path = databasePath.hasPrefix("file://") ? URL(string: databasePath)?.path ?? databasePath : databasePath
      let controller = try SyncController(
        databasePath: path, containerIdentifier: containerIdentifier, schema: schema, encryptionKey: encryptionKey)
      controller.onChange = { [weak self] tables in self?.sendEvent("onChange", ["tables": tables]) }
      controller.onStatus = { [weak self] status in self?.sendEvent("onStatus", status) }
      self.controller = controller
      _ = await controller.refreshAccountStatus()
    }

    AsyncFunction("syncNow") { () async throws in
      guard #available(iOS 17.0, *) else { throw UnsupportedOSException() }
      try await self.configured().syncNow()
    }

    AsyncFunction("getStatus") { () -> [String: Any] in
      guard #available(iOS 17.0, *), let controller = self.controller as? SyncController else {
        return [
          "configured": false, "account": "unknown", "syncing": false, "pendingChanges": 0,
          "lastSyncAt": NSNull(), "lastError": NSNull(),
        ]
      }
      return controller.status()
    }

    AsyncFunction("accountStatus") { () async throws -> String in
      guard #available(iOS 17.0, *) else { return "unsupported" }
      return try await self.configured().refreshAccountStatus()
    }

    AsyncFunction("resetLocalSyncState") {
      guard #available(iOS 17.0, *) else { throw UnsupportedOSException() }
      try self.configured().reset()
    }
  }

  @available(iOS 17.0, *)
  private func configured() throws -> SyncController {
    guard let controller = controller as? SyncController else { throw NotConfiguredException() }
    return controller
  }
}

final class NotConfiguredException: Exception {
  override var reason: String {
    "configureSync() has not been called yet"
  }
}

final class UnsupportedOSException: Exception {
  override var reason: String {
    "expo-sqlite-cloudkit needs iOS 17 or newer"
  }
}
