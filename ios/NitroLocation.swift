import CoreLocation
import NitroModules

// MARK: - Delegate Forwarder

@MainActor
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {

  weak var owner: NitroLocation?

  init(_ owner: NitroLocation) {
    self.owner = owner
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    owner?.handleLocations(
      locations,
      source: manager
    )
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
    owner?.handleAuthChange(
      manager.authorizationStatus
    )
  }

  func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    owner?.handleLocationError(error)
  }
}

@MainActor
final class NitroLocation: HybridNitroLocationSpec {

  // MARK: - Managers

  // Standard streaming + one-shot
  private let locationManager = CLLocationManager()

  // Dedicated significant-change manager
  private let significantLocationManager = CLLocationManager()

  // MARK: - Delegates

  private lazy var locationDelegate =
    LocationDelegate(self)

  // MARK: - Continuations

  private var permissionContinuation:
    CheckedContinuation<Bool, Never>?

  private var locationContinuation:
    CheckedContinuation<Variant_NullType_Location, Never>?

  // MARK: - Tasks

  private var locationTimeoutTask:
    Task<Void, Never>?

  // MARK: - State

  private var isOneShotUpdating = false

  private var isStreamingUpdates = false

  private var isMonitoringSignificant = false

  // Freshness threshold for active one-shot request
  private var currentOneShotMaxAgeMs:
    Double = 10_000

  // MARK: - Callback Properties

  var onLocationUpdate:
    Variant_NullType____locations___Location______Void =
      .first(.null)

  var onHeadingUpdate:
    Variant_NullType____heading__Heading_____Void =
      .first(.null)

  var onPermissionUpdate:
    Variant_NullType____status__LocationPermissionStatus_____Void =
      .first(.null)

  var onSignificantLocationUpdate:
    Variant_NullType____locations___Location______Void =
      .first(.null)

  // MARK: - Init

  public override init() {
    super.init()

    locationManager.delegate = locationDelegate

    significantLocationManager.delegate =
      locationDelegate
  }

  // IMPORTANT:
  // deinit is NOT actor-isolated even on @MainActor classes.
  // Never access actor-isolated state here.
  deinit { }

  // MARK: - Cleanup

  // MUST be called before releasing module.
  // Otherwise pending continuations remain unresolved.
  func invalidate() {

    locationManager.stopUpdatingLocation()
    locationManager.stopUpdatingHeading()

    significantLocationManager
      .stopMonitoringSignificantLocationChanges()

    locationTimeoutTask?.cancel()
    locationTimeoutTask = nil

    if let continuation = locationContinuation {

      locationContinuation = nil

      continuation.resume(
        returning: .first(.null)
      )
    }

    if let continuation = permissionContinuation {

      permissionContinuation = nil

      continuation.resume(
        returning: false
      )
    }

    isStreamingUpdates = false
    isMonitoringSignificant = false
    isOneShotUpdating = false
  }

  // MARK: - Configure

  func configure(
    options: ConfigureOptions
  ) throws -> Promise<Void> {

    return Promise.async {

      await MainActor.run {

        let managers = [
          self.locationManager,
          self.significantLocationManager
        ]

        for manager in managers {

          if let filter =
            options.distanceFilter {

            manager.distanceFilter = filter
          }

          if let bg =
            options.allowsBackgroundLocationUpdates {

            manager.allowsBackgroundLocationUpdates = bg
          }

          if let indicator =
            options.showsBackgroundLocationIndicator {

            manager.showsBackgroundLocationIndicator =
              indicator
          }

          if let activityType =
            options.activityType {

            manager.activityType =
              Self.mapActivityType(activityType)
          }

          if let accuracy =
            options.desiredAccuracy?.ios {

            manager.desiredAccuracy =
              Self.mapIosAccuracy(accuracy)
          }
        }
      }
    }
  }

  // MARK: - Permissions

  func requestPermission(
    options: RequestPermissionOptions
  ) throws -> Promise<Bool> {

    return Promise.async {

      return await MainActor.run {

        await withCheckedContinuation {
          continuation in

          guard self.permissionContinuation == nil else {

            continuation.resume(returning: false)

            return
          }

          self.permissionContinuation =
            continuation

          if options.ios == .always {

            self.locationManager
              .requestAlwaysAuthorization()

          } else {

            self.locationManager
              .requestWhenInUseAuthorization()
          }
        }
      }
    }
  }

  func getCurrentPermission()
    throws -> Promise<LocationPermissionStatus> {

    return Promise.async {

      await MainActor.run {

        Self.mapAuthStatus(
          self.locationManager.authorizationStatus
        )
      }
    }
  }

  // MARK: - Streaming

  func startLocationUpdates() throws {

    isStreamingUpdates = true

    locationManager.startUpdatingLocation()
  }

  func stopLocationUpdates() throws {

    isStreamingUpdates = false

    // Keep updates alive if one-shot still active
    if !isOneShotUpdating {

      locationManager.stopUpdatingLocation()
    }
  }

  // MARK: - Heading

  func startHeadingUpdates() throws {

    guard CLLocationManager.headingAvailable()
    else {
      return
    }

    locationManager.startUpdatingHeading()
  }

  func stopHeadingUpdates() throws {

    locationManager.stopUpdatingHeading()
  }

  // MARK: - Significant Updates

  func startSignificantLocationUpdates()
    throws {

    isMonitoringSignificant = true

    significantLocationManager
      .startMonitoringSignificantLocationChanges()
  }

  func stopSignificantLocationUpdates()
    throws {

    isMonitoringSignificant = false

    significantLocationManager
      .stopMonitoringSignificantLocationChanges()
  }

  // MARK: - One-shot Location

  func getLatestLocation(
    options: GetLatestLocationOptions
  ) throws -> Promise<Variant_NullType_Location> {

    return Promise.async {

      await MainActor.run {

        let maxAge =
          options.maximumAge ?? 10_000

        self.currentOneShotMaxAgeMs =
          maxAge

        // Fast cached path
        if let cached =
          self.locationManager.location {

          let ageMs =
            -cached.timestamp
              .timeIntervalSinceNow * 1_000

          if ageMs <= maxAge {

            return .second(
              Self.mapLocation(cached)
            )
          }
        }

        let timeout =
          options.timeout ?? 10_000

        return await withCheckedContinuation {
          continuation in

          // Prevent concurrent one-shot requests
          guard self.locationContinuation == nil
          else {

            continuation.resume(
              returning: .first(.null)
            )

            return
          }

          let status =
            self.locationManager
              .authorizationStatus

          guard status == .authorizedAlways ||
                status == .authorizedWhenInUse
          else {

            continuation.resume(
              returning: .first(.null)
            )

            return
          }

          self.locationContinuation =
            continuation

          self.isOneShotUpdating = true

          // More reliable than requestLocation()
          self.locationManager
            .startUpdatingLocation()

          self.locationTimeoutTask = Task {

            // Prevent UInt64 conversion crash
            let safeNs: UInt64

            if timeout.isFinite &&
                timeout >= 0 &&
                timeout < 1.8e16 {

              safeNs =
                UInt64(timeout) * 1_000_000

            } else {

              safeNs = UInt64.max
            }

            do {

              try await Task.sleep(
                nanoseconds: safeNs
              )

            } catch {

              // External cancellation:
              // resolve pending continuation safely

              guard let continuation =
                self.locationContinuation else {
                return
              }

              self.locationContinuation = nil
              self.locationTimeoutTask = nil

              self.stopOneShotUpdatesIfNeeded()

              continuation.resume(
                returning: .first(.null)
              )

              return
            }

            guard let continuation =
              self.locationContinuation else {
              return
            }

            self.locationContinuation = nil
            self.locationTimeoutTask = nil

            self.stopOneShotUpdatesIfNeeded()

            continuation.resume(
              returning: .first(.null)
            )
          }
        }
      }
    }
  }

  // MARK: - Delegate Handlers

  fileprivate func handleLocations(
    _ locations: [CLLocation],
    source manager: CLLocationManager
  ) {

    guard !locations.isEmpty else {
      return
    }

    let mapped =
      locations.map(Self.mapLocation)

    // Streaming callbacks ONLY during streaming mode
    if manager === locationManager,
       isStreamingUpdates {

      if case .second(let callback) =
        onLocationUpdate {

        callback(mapped)
      }
    }

    // Significant callbacks ONLY from dedicated manager
    if manager === significantLocationManager,
       isMonitoringSignificant {

      if case .second(let callback) =
        onSignificantLocationUpdate {

        callback(mapped)
      }
    }

    // One-shot resolution only from primary manager
    guard manager === locationManager else {
      return
    }

    guard let continuation =
      locationContinuation else {
      return
    }

    // Respect caller maximumAge
    let freshnessSeconds =
      min(
        currentOneShotMaxAgeMs / 1_000,
        15
      )

    guard let freshLocation =
      locations.first(where: {

        abs(
          $0.timestamp.timeIntervalSinceNow
        ) < freshnessSeconds

      }) else {
      return
    }

    locationTimeoutTask?.cancel()
    locationTimeoutTask = nil

    locationContinuation = nil

    stopOneShotUpdatesIfNeeded()

    continuation.resume(
      returning:
        .second(
          Self.mapLocation(freshLocation)
        )
    )
  }

  fileprivate func handleHeading(
    _ newHeading: CLHeading
  ) {

    let heading =
      newHeading.trueHeading >= 0
      ? newHeading.trueHeading
      : newHeading.magneticHeading

    if case .second(let callback) =
      onHeadingUpdate {

      callback(
        Heading(heading: heading)
      )
    }
  }

  fileprivate func handleAuthChange(
    _ status: CLAuthorizationStatus
  ) {

    let mapped =
      Self.mapAuthStatus(status)

    if case .second(let callback) =
      onPermissionUpdate {

      callback(mapped)
    }

    guard let continuation =
      permissionContinuation else {
      return
    }

    switch status {

    case .authorizedAlways,
         .authorizedWhenInUse:

      permissionContinuation = nil

      continuation.resume(
        returning: true
      )

    case .denied,
         .restricted:

      permissionContinuation = nil

      continuation.resume(
        returning: false
      )

    case .notDetermined:
      break

    @unknown default:

      permissionContinuation = nil

      continuation.resume(
        returning: false
      )
    }
  }

  fileprivate func handleLocationError(
    _ error: Error
  ) {

    // Temporary GPS warmup issue
    if let clError = error as? CLError,
       clError.code == .locationUnknown {

      return
    }

    guard let continuation =
      locationContinuation else {
      return
    }

    locationContinuation = nil

    locationTimeoutTask?.cancel()
    locationTimeoutTask = nil

    stopOneShotUpdatesIfNeeded()

    continuation.resume(
      returning: .first(.null)
    )
  }

  // MARK: - Helpers

  private func stopOneShotUpdatesIfNeeded() {

    guard isOneShotUpdating else {
      return
    }

    isOneShotUpdating = false

    if !isStreamingUpdates {

      locationManager.stopUpdatingLocation()
    }
  }

  // MARK: - Mapping

  private static func mapLocation(
    _ location: CLLocation
  ) -> Location {

    return Location(

      timestamp:
        location.timestamp
          .timeIntervalSince1970 * 1_000,

      latitude:
        location.coordinate.latitude,

      longitude:
        location.coordinate.longitude,

      accuracy:
        location.horizontalAccuracy,

      altitude:
        location.altitude,

      altitudeAccuracy:
        location.verticalAccuracy,

      course:
        location.course,

      courseAccuracy:
        location.courseAccuracy >= 0
        ? location.courseAccuracy
        : nil,

      speed:
        location.speed,

      speedAccuracy:
        location.speedAccuracy >= 0
        ? location.speedAccuracy
        : nil,

      floor:
        location.floor.map {
          Double($0.level)
        },

      fromMockProvider: nil
    )
  }

  private static func mapAuthStatus(
    _ status: CLAuthorizationStatus
  ) -> LocationPermissionStatus {

    switch status {

    case .authorizedAlways:
      return .authorizedalways

    case .authorizedWhenInUse:
      return .authorizedwheninuse

    case .denied:
      return .denied

    case .restricted:
      return .restricted

    case .notDetermined:
      return .notdetermined

    @unknown default:
      return .notdetermined
    }
  }

  private static func mapIosAccuracy(
    _ accuracy: IosDesiredAccuracy
  ) -> CLLocationAccuracy {

    switch accuracy {

    case .bestfornavigation:
      return kCLLocationAccuracyBestForNavigation

    case .best:
      return kCLLocationAccuracyBest

    case .nearesttenmeters:
      return kCLLocationAccuracyNearestTenMeters

    case .hundredmeters:
      return kCLLocationAccuracyHundredMeters

    case .threekilometers:
      return kCLLocationAccuracyThreeKilometers

    @unknown default:
      return kCLLocationAccuracyBest
    }
  }

  private static func mapActivityType(
    _ type: ActivityType
  ) -> CLActivityType {

    switch type {

    case .other:
      return .other

    case .automotivenavigation:
      return .automotiveNavigation

    case .fitness:
      return .fitness

    case .othernavigation:
      return .otherNavigation

    case .airborne:

      if #available(iOS 12.0, *) {
        return .airborne
      } else {
        return .other
      }

    @unknown default:
      return .other
    }
  }
}