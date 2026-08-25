import CoreLocation
import NitroModules

// MARK: - Delegate Forwarder
// HybridNitroLocationSpec_base does not inherit NSObject,
// so we bridge CLLocationManagerDelegate separately.
// CLLocationManager calls delegates on the thread the manager was created on
// (always main thread when created via DispatchQueue.main.async or lazy init on main).

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {

  weak var owner: NitroLocation?

  init(_ owner: NitroLocation) {
    self.owner = owner
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    owner?.handleLocations(locations, source: manager)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateHeading newHeading: CLHeading
  ) {
    owner?.handleHeading(newHeading)
  }

  func locationManagerDidChangeAuthorization(
    _ manager: CLLocationManager
  ) {
    owner?.handleAuthChange(manager.authorizationStatus)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    owner?.handleLocationError(error)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didEnterRegion region: CLRegion
  ) {
    owner?.handleGeofenceTransition(region, type: .enter)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didExitRegion region: CLRegion
  ) {
    owner?.handleGeofenceTransition(region, type: .exit)
  }
}

final class NitroLocation: HybridNitroLocationSpec {

  // MARK: - Delegates

  private lazy var locationDelegate = LocationDelegate(self)

  // MARK: - Managers
  // Lazy so delegate assignment happens on first access.
  // Both managers must be first accessed on the main thread.

  // Standard streaming + one-shot
  private lazy var locationManager: CLLocationManager = {
    let m = CLLocationManager()
    m.delegate = locationDelegate
    return m
  }()

  // Dedicated significant-change manager — separate instance so
  // handleLocations can distinguish sources via identity check.
  private lazy var significantLocationManager: CLLocationManager = {
    let m = CLLocationManager()
    m.delegate = locationDelegate
    return m
  }()

  // MARK: - Continuations

  private var permissionContinuation: CheckedContinuation<Bool, Never>?
  private var locationContinuation: CheckedContinuation<Variant_NullType_Location, Never>?

  // MARK: - Tasks

  private var locationTimeoutTask: Task<Void, Never>?

  // MARK: - State

  private var isOneShotUpdating = false
  private var isStreamingUpdates = false
  private var isMonitoringSignificant = false
  private var currentOneShotMaxAgeMs: Double = 10_000

  // MARK: - Callback Properties

  var onLocationUpdate: Variant_NullType____locations___Location______Void = .first(.null)
  var onHeadingUpdate: Variant_NullType____heading__Heading_____Void = .first(.null)
  var onPermissionUpdate: Variant_NullType____status__LocationPermissionStatus_____Void = .first(.null)
  var onSignificantLocationUpdate: Variant_NullType____locations___Location______Void = .first(.null)
  var onGeofenceTransition: Variant_NullType____event__GeofenceTransitionEvent_____Void = .first(.null) {
    didSet {
      guard case .second(let callback) = onGeofenceTransition, !pendingGeofenceTransitions.isEmpty else { return }
      let buffered = pendingGeofenceTransitions
      pendingGeofenceTransitions.removeAll()
      buffered.forEach(callback)
    }
  }

  // MARK: - Init

  public override init() {
    super.init()
  }

  // MARK: - Lifecycle

  func invalidate() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.locationManager.stopUpdatingLocation()
      self.locationManager.stopUpdatingHeading()
      self.significantLocationManager.stopMonitoringSignificantLocationChanges()
      self.locationTimeoutTask?.cancel()
      self.locationTimeoutTask = nil
      if let continuation = self.locationContinuation {
        self.locationContinuation = nil
        continuation.resume(returning: .first(.null))
      }
      if let continuation = self.permissionContinuation {
        self.permissionContinuation = nil
        continuation.resume(returning: false)
      }
      self.isStreamingUpdates = false
      self.isMonitoringSignificant = false
      self.isOneShotUpdating = false
    }
  }

  // MARK: - Configure

  func configure(options: ConfigureOptions) throws -> Promise<Void> {
    return Promise.async {
      DispatchQueue.main.async {
        let managers = [
          self.locationManager,
          self.significantLocationManager
        ]
        for manager in managers {
          if let filter = options.distanceFilter { manager.distanceFilter = filter }
          if let bg = options.allowsBackgroundLocationUpdates { manager.allowsBackgroundLocationUpdates = bg }
          if let indicator = options.showsBackgroundLocationIndicator { manager.showsBackgroundLocationIndicator = indicator }
          if let activityType = options.activityType { manager.activityType = Self.mapActivityType(activityType) }
          if let accuracy = options.desiredAccuracy?.ios { manager.desiredAccuracy = Self.mapIosAccuracy(accuracy) }
          // CoreLocation defaults this to true, which auto-pauses delivery when the device
          // looks stationary (e.g. locked, sitting on a desk) — exactly the case we need
          // updates during. Not exposed in ConfigureOptions.
          manager.pausesLocationUpdatesAutomatically = false
        }
      }
    }
  }

  // MARK: - Permissions

  func requestPermission(options: RequestPermissionOptions) throws -> Promise<Bool> {
    return Promise.async {
      return await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          guard self.permissionContinuation == nil else {
            continuation.resume(returning: false)
            return
          }
          self.permissionContinuation = continuation
          if options.ios == .always {
            self.locationManager.requestAlwaysAuthorization()
          } else {
            self.locationManager.requestWhenInUseAuthorization()
          }
        }
      }
    }
  }

  func getCurrentPermission() throws -> Promise<LocationPermissionStatus> {
    return Promise.async {
      return await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          continuation.resume(
            returning: Self.mapAuthStatus(
              self.locationManager.authorizationStatus
            )
          )
        }
      }
    }
  }

  // MARK: - Streaming

  func startLocationUpdates() throws {
    DispatchQueue.main.async {
      self.isStreamingUpdates = true
      self.locationManager.startUpdatingLocation()
    }
  }

  func stopLocationUpdates() throws {
    DispatchQueue.main.async {
      self.isStreamingUpdates = false
      if !self.isOneShotUpdating {
        self.locationManager.stopUpdatingLocation()
      }
    }
  }

  func startHeadingUpdates() throws {
    DispatchQueue.main.async {
      guard CLLocationManager.headingAvailable() else { return }
      self.locationManager.startUpdatingHeading()
    }
  }

  func stopHeadingUpdates() throws {
    DispatchQueue.main.async {
      self.locationManager.stopUpdatingHeading()
    }
  }

  func startSignificantLocationUpdates() throws {
    DispatchQueue.main.async {
      self.isMonitoringSignificant = true
      self.significantLocationManager.startMonitoringSignificantLocationChanges()
    }
  }

  func stopSignificantLocationUpdates() throws {
    DispatchQueue.main.async {
      self.isMonitoringSignificant = false
      self.significantLocationManager.stopMonitoringSignificantLocationChanges()
    }
  }

  // MARK: - One-shot Location
  // Requires NSLocationWhenInUseUsageDescription in Info.plist.
  // Uses startUpdatingLocation() instead of requestLocation() for reliability
  // on real devices: cold GPS start, indoors, reduced accuracy, low power mode.

  func getLatestLocation(options: GetLatestLocationOptions) throws -> Promise<Variant_NullType_Location> {
    return Promise.async {
      let maxAge = options.maximumAge ?? 10_000
      let timeout = options.timeout ?? 10_000

      return await withCheckedContinuation { continuation in
        DispatchQueue.main.async {

          // Fast path: reuse cached location if fresh enough.
          // When streaming is active, skip the age check — the stream keeps the cache current.
          if let cached = self.locationManager.location {
            let ageMs = -cached.timestamp.timeIntervalSinceNow * 1_000
            if ageMs <= maxAge || self.isStreamingUpdates {
              continuation.resume(returning: .second(Self.mapLocation(cached)))
              return
            }
          }

          // Prevent concurrent one-shot requests
          guard self.locationContinuation == nil else {
            continuation.resume(returning: .first(.null))
            return
          }

          let status = self.locationManager.authorizationStatus
          guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            continuation.resume(returning: .first(.null))
            return
          }

          self.currentOneShotMaxAgeMs = maxAge
          self.locationContinuation = continuation
          self.isOneShotUpdating = true
          self.locationManager.startUpdatingLocation()

          self.locationTimeoutTask = Task {
            let safeNs: UInt64 = timeout.isFinite && timeout >= 0 && timeout < 1.8e16
              ? UInt64(timeout) * 1_000_000
              : UInt64.max

            do {
              try await Task.sleep(nanoseconds: safeNs)
            } catch {
              // Cancelled — continuation already resolved by handleLocations/invalidate
              return
            }

            DispatchQueue.main.async {
              guard let cont = self.locationContinuation else { return }
              self.locationContinuation = nil
              self.locationTimeoutTask = nil
              self.stopOneShotUpdatesIfNeeded()
              cont.resume(returning: .first(.null))
            }
          }
        }
      }
    }
  }

  // MARK: - Geofencing

  private var pendingGeofenceTransitions: [GeofenceTransitionEvent] = []

  func startMonitoringGeofences(regions: [GeofenceRegion]) throws -> Promise<StartMonitoringGeofencesResult> {
    return Promise.async {
      return await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          let authStatus = self.locationManager.authorizationStatus
          let accuracyAuthorization = CLLocationManager().accuracyAuthorization
          guard authStatus == .authorizedAlways, accuracyAuthorization == .fullAccuracy else {
            continuation.resume(returning: StartMonitoringGeofencesResult(monitoredCount: 0))
            return
          }

          for region in self.locationManager.monitoredRegions {
            self.locationManager.stopMonitoring(for: region)
          }

          for region in regions {
            let circularRegion = CLCircularRegion(
              center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
              radius: region.radiusMeters,
              identifier: region.identifier
            )
            circularRegion.notifyOnEntry = true
            circularRegion.notifyOnExit = true
            self.locationManager.startMonitoring(for: circularRegion)
          }

          continuation.resume(
            returning: StartMonitoringGeofencesResult(
              monitoredCount: Double(self.locationManager.monitoredRegions.count)
            )
          )
        }
      }
    }
  }

  func stopMonitoringGeofences() throws {
    DispatchQueue.main.async {
      for region in self.locationManager.monitoredRegions {
        self.locationManager.stopMonitoring(for: region)
      }
    }
  }

  func getPendingGeofenceTransition() throws -> Variant_NullType_GeofenceTransitionEvent {
    guard !pendingGeofenceTransitions.isEmpty else {
      return .first(.null)
    }
    return .second(pendingGeofenceTransitions.removeFirst())
  }

  private func bufferGeofenceTransition(_ event: GeofenceTransitionEvent) {
    pendingGeofenceTransitions.append(event)
    if pendingGeofenceTransitions.count > 5 {
      pendingGeofenceTransitions.removeFirst()
    }
  }

  // MARK: - Delegate Handlers
  // Called on main thread by CLLocationManager.

  fileprivate func handleLocations(
    _ locations: [CLLocation],
    source manager: CLLocationManager
  ) {
    guard !locations.isEmpty else { return }

    let mapped = locations.map(Self.mapLocation)

    if manager === locationManager, isStreamingUpdates {
      if case .second(let callback) = onLocationUpdate { callback(mapped) }
    }

    if manager === significantLocationManager, isMonitoringSignificant {
      if case .second(let callback) = onSignificantLocationUpdate { callback(mapped) }
    }

    guard manager === locationManager else { return }
    guard let continuation = locationContinuation else { return }

    // Filter stale cached fixes during one-shot — threshold respects maximumAge
    let thresholdSec = min(currentOneShotMaxAgeMs / 1_000, 15)
    guard let freshLocation = locations.first(where: {
      abs($0.timestamp.timeIntervalSinceNow) < thresholdSec
    }) else { return }

    locationTimeoutTask?.cancel()
    locationTimeoutTask = nil
    locationContinuation = nil
    stopOneShotUpdatesIfNeeded()
    continuation.resume(returning: .second(Self.mapLocation(freshLocation)))
  }

  fileprivate func handleHeading(_ newHeading: CLHeading) {
    let heading = newHeading.trueHeading >= 0
      ? newHeading.trueHeading
      : newHeading.magneticHeading
    if case .second(let callback) = onHeadingUpdate {
      callback(Heading(heading: heading))
    }
  }

  fileprivate func handleAuthChange(_ status: CLAuthorizationStatus) {
    let mapped = Self.mapAuthStatus(status)
    if case .second(let callback) = onPermissionUpdate { callback(mapped) }

    guard let continuation = permissionContinuation else { return }

    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      permissionContinuation = nil
      continuation.resume(returning: true)
    case .denied, .restricted:
      permissionContinuation = nil
      continuation.resume(returning: false)
    case .notDetermined:
      break
    @unknown default:
      permissionContinuation = nil
      continuation.resume(returning: false)
    }
  }

  fileprivate func handleLocationError(_ error: Error) {
    // locationUnknown is a transient GPS warmup error — keep waiting
    if let clError = error as? CLError, clError.code == .locationUnknown { return }

    guard let continuation = locationContinuation else { return }
    locationContinuation = nil
    locationTimeoutTask?.cancel()
    locationTimeoutTask = nil
    stopOneShotUpdatesIfNeeded()
    continuation.resume(returning: .first(.null))
  }

  fileprivate func handleGeofenceTransition(_ region: CLRegion, type: GeofenceTransitionType) {
    let event = GeofenceTransitionEvent(identifier: region.identifier, type: type)
    if case .second(let callback) = onGeofenceTransition {
      callback(event)
    } else {
      bufferGeofenceTransition(event)
    }
  }

  // MARK: - Helpers

  private func stopOneShotUpdatesIfNeeded() {
    guard isOneShotUpdating else { return }
    isOneShotUpdating = false
    if !isStreamingUpdates {
      locationManager.stopUpdatingLocation()
    }
  }

  // MARK: - Mapping

  private static func mapLocation(_ location: CLLocation) -> Location {
    return Location(
      timestamp: location.timestamp.timeIntervalSince1970 * 1_000,
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      accuracy: location.horizontalAccuracy,
      altitude: location.altitude,
      altitudeAccuracy: location.verticalAccuracy,
      course: location.course,
      courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
      speed: location.speed,
      speedAccuracy: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
      floor: location.floor.map { Double($0.level) },
      fromMockProvider: nil
    )
  }

  private static func mapAuthStatus(
    _ status: CLAuthorizationStatus
  ) -> LocationPermissionStatus {
    switch status {
    case .authorizedAlways: return .authorizedalways
    case .authorizedWhenInUse: return .authorizedwheninuse
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notdetermined
    @unknown default: return .notdetermined
    }
  }

  private static func mapIosAccuracy(
    _ accuracy: IosDesiredAccuracy
  ) -> CLLocationAccuracy {
    switch accuracy {
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
