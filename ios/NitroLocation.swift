import CoreLocation
import NitroModules

// Separate NSObject delegate forwarder — HybridNitroLocationSpec_base doesn't extend NSObject
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
  weak var owner: NitroLocation?
  init(_ owner: NitroLocation) { self.owner = owner }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    owner?.handleLocations(locations)
  }
  func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    owner?.handleHeading(newHeading)
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    owner?.handleAuthChange(manager.authorizationStatus)
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    owner?.handleLocationError()
  }
}

class NitroLocation: HybridNitroLocationSpec {
  private let manager = CLLocationManager()
  private lazy var locationDelegate = LocationDelegate(self)
  private var permissionContinuation: CheckedContinuation<Bool, Never>?
  private var locationContinuation: CheckedContinuation<Variant_NullType_Location, Never>?
  private var locationTimeoutTask: Task<Void, Never>?

  // MARK: - Callback properties
  var onLocationUpdate: Variant_NullType____locations___Location______Void = .first(.null)
  var onHeadingUpdate: Variant_NullType____heading__Heading_____Void = .first(.null)
  var onPermissionUpdate: Variant_NullType____status__LocationPermissionStatus_____Void = .first(.null)
  var onSignificantLocationUpdate: Variant_NullType____locations___Location______Void = .first(.null)

  public override init() {
    super.init()
    manager.delegate = locationDelegate
  }

  // MARK: - Configure
  func configure(options: ConfigureOptions) throws -> Promise<Void> {
    return Promise.async {
      await MainActor.run {
        if let filter = options.distanceFilter { self.manager.distanceFilter = filter }
        if let bg = options.allowsBackgroundLocationUpdates { self.manager.allowsBackgroundLocationUpdates = bg }
        if let indicator = options.showsBackgroundLocationIndicator { self.manager.showsBackgroundLocationIndicator = indicator }
        if let activityType = options.activityType { self.manager.activityType = Self.mapActivityType(activityType) }
        if let accuracy = options.desiredAccuracy?.ios { self.manager.desiredAccuracy = Self.mapIosAccuracy(accuracy) }
      }
    }
  }

  // MARK: - Permissions
  func requestPermission(options: RequestPermissionOptions) throws -> Promise<Bool> {
    return Promise.async {
      return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.main.async {
          self.permissionContinuation = continuation
          if options.ios == .always {
            self.manager.requestAlwaysAuthorization()
          } else {
            self.manager.requestWhenInUseAuthorization()
          }
        }
      }
    }
  }

  func getCurrentPermission() throws -> Promise<LocationPermissionStatus> {
    return Promise.async {
      return await MainActor.run { Self.mapAuthStatus(self.manager.authorizationStatus) }
    }
  }

  // MARK: - Stream control
  func startLocationUpdates() throws { DispatchQueue.main.async { self.manager.startUpdatingLocation() } }
  func stopLocationUpdates() throws { DispatchQueue.main.async { self.manager.stopUpdatingLocation() } }
  func startHeadingUpdates() throws { DispatchQueue.main.async { self.manager.startUpdatingHeading() } }
  func stopHeadingUpdates() throws { DispatchQueue.main.async { self.manager.stopUpdatingHeading() } }
  func startSignificantLocationUpdates() throws { DispatchQueue.main.async { self.manager.startMonitoringSignificantLocationChanges() } }
  func stopSignificantLocationUpdates() throws { DispatchQueue.main.async { self.manager.stopMonitoringSignificantLocationChanges() } }

  // MARK: - One-shot
  func getLatestLocation(options: GetLatestLocationOptions) throws -> Promise<Variant_NullType_Location> {
    return Promise.async {
      let maxAge = options.maximumAge ?? 10_000
      if let loc = await MainActor.run(body: { self.manager.location }) {
        let ageMs = -loc.timestamp.timeIntervalSinceNow * 1_000
        if ageMs < maxAge { return .second(Self.mapLocation(loc)) }
      }
      let timeout = options.timeout ?? 10_000
      return await withCheckedContinuation { (continuation: CheckedContinuation<Variant_NullType_Location, Never>) in
        DispatchQueue.main.async {
          self.locationContinuation = continuation
          self.manager.requestLocation()
          self.locationTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
            DispatchQueue.main.async {
              guard let cont = self.locationContinuation else { return }
              self.locationContinuation = nil
              self.locationTimeoutTask = nil
              cont.resume(returning: .first(.null))
            }
          }
        }
      }
    }
  }

  // MARK: - Delegate callbacks (called by LocationDelegate)
  fileprivate func handleLocations(_ locations: [CLLocation]) {
    let mapped = locations.map { Self.mapLocation($0) }
    if case .second(let cb) = onLocationUpdate { cb(mapped) }
    if case .second(let cb) = onSignificantLocationUpdate { cb(mapped) }
    if let cont = locationContinuation {
      locationTimeoutTask?.cancel()
      locationTimeoutTask = nil
      locationContinuation = nil
      cont.resume(returning: mapped.first.map { .second($0) } ?? .first(.null))
    }
  }

  fileprivate func handleHeading(_ newHeading: CLHeading) {
    let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    if case .second(let cb) = onHeadingUpdate { cb(Heading(heading: h)) }
  }

  fileprivate func handleAuthChange(_ status: CLAuthorizationStatus) {
    let mapped = Self.mapAuthStatus(status)
    if case .second(let cb) = onPermissionUpdate { cb(mapped) }
    guard let cont = permissionContinuation else { return }
    if status == .authorizedAlways || status == .authorizedWhenInUse {
      permissionContinuation = nil
      cont.resume(returning: true)
    } else if status != .notDetermined {
      permissionContinuation = nil
      cont.resume(returning: false)
    }
  }

  fileprivate func handleLocationError() {
    if let cont = locationContinuation {
      locationContinuation = nil
      locationTimeoutTask?.cancel()
      locationTimeoutTask = nil
      cont.resume(returning: .first(.null))
    }
  }

  // MARK: - Mapping helpers
  private static func mapLocation(_ loc: CLLocation) -> Location {
    return Location(
      timestamp: loc.timestamp.timeIntervalSince1970 * 1_000,
      latitude: loc.coordinate.latitude,
      longitude: loc.coordinate.longitude,
      accuracy: loc.horizontalAccuracy,
      altitude: loc.altitude,
      altitudeAccuracy: loc.verticalAccuracy,
      course: loc.course,
      courseAccuracy: loc.courseAccuracy >= 0 ? loc.courseAccuracy : nil,
      speed: loc.speed,
      speedAccuracy: loc.speedAccuracy >= 0 ? loc.speedAccuracy : nil,
      floor: loc.floor.map { Double($0.level) },
      fromMockProvider: nil
    )
  }

  private static func mapAuthStatus(_ status: CLAuthorizationStatus) -> LocationPermissionStatus {
    switch status {
    case .authorizedAlways: return .authorizedalways
    case .authorizedWhenInUse: return .authorizedwheninuse
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notdetermined
    @unknown default: return .notdetermined
    }
  }

  private static func mapIosAccuracy(_ acc: IosDesiredAccuracy) -> CLLocationAccuracy {
    switch acc {
    case .bestfornavigation: return kCLLocationAccuracyBestForNavigation
    case .best: return kCLLocationAccuracyBest
    case .nearesttenmeters: return kCLLocationAccuracyNearestTenMeters
    case .hundredmeters: return kCLLocationAccuracyHundredMeters
    case .threekilometers: return kCLLocationAccuracyThreeKilometers
    @unknown default: return kCLLocationAccuracyBest
    }
  }

  private static func mapActivityType(_ type: ActivityType) -> CLActivityType {
    switch type {
    case .other: return .other
    case .automotivenavigation: return .automotiveNavigation
    case .fitness: return .fitness
    case .othernavigation: return .otherNavigation
    case .airborne:
      if #available(iOS 12.0, *) { return .airborne } else { return .other }
    @unknown default: return .other
    }
  }
}
