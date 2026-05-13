package com.margelo.nitro.nitrolocation

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location as AndroidLocation
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.NullType
import com.margelo.nitro.core.Promise
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

@DoNotStrip
class NitroLocation : HybridNitroLocationSpec(), LocationListener, SensorEventListener {

  // Callback props
  override var onLocationUpdate: Variant_NullType__locations__Array_Location______Unit =
    Variant_NullType__locations__Array_Location______Unit.First(NullType())
  override var onHeadingUpdate: Variant_NullType__heading__Heading_____Unit =
    Variant_NullType__heading__Heading_____Unit.First(NullType())
  override var onPermissionUpdate: Variant_NullType__status__LocationPermissionStatus_____Unit =
    Variant_NullType__status__LocationPermissionStatus_____Unit.First(NullType())
  override var onSignificantLocationUpdate: Variant_NullType__locations__Array_Location______Unit =
    Variant_NullType__locations__Array_Location______Unit.First(NullType())

  private val context: Context
    get() = NitroLocationPackage.reactAppContext?.applicationContext
      ?: throw IllegalStateException("ReactApplicationContext not available")

  private val locationManager: LocationManager
    get() = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

  private val sensorManager: SensorManager
    get() = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

  // Config state
  private var minDistanceMeters: Float = 0f
  private var minIntervalMs: Long = 1000L
  private var preferredProvider: String = LocationManager.GPS_PROVIDER

  // One-shot state
  @Volatile private var locationContinuation: ((Variant_NullType_Location) -> Unit)? = null
  private var locationTimeoutRunner: Runnable? = null

  // Heading state
  private val rotationMatrix = FloatArray(9)
  private val orientation = FloatArray(3)

  // MARK: - Configure
  override fun configure(options: ConfigureOptions): Promise<Unit> {
    return Promise.async {
      options.distanceFilter?.let { minDistanceMeters = it.toFloat() }
      options.interval?.let { minIntervalMs = it.toLong() }
      options.androidProvider?.let { provider ->
        preferredProvider = when (provider) {
          AndroidProvider.STANDARD -> LocationManager.NETWORK_PROVIDER
          AndroidProvider.PLAYSERVICES -> LocationManager.GPS_PROVIDER
          else -> LocationManager.GPS_PROVIDER
        }
      }
      options.desiredAccuracy?.android?.let { acc ->
        preferredProvider = when (acc) {
          AndroidDesiredAccuracy.HIGHACCURACY -> LocationManager.GPS_PROVIDER
          AndroidDesiredAccuracy.BALANCEDPOWERACCURACY -> LocationManager.NETWORK_PROVIDER
          AndroidDesiredAccuracy.LOWPOWER -> LocationManager.NETWORK_PROVIDER
          AndroidDesiredAccuracy.NOPOWER -> LocationManager.PASSIVE_PROVIDER
        }
      }
    }
  }

  // MARK: - Permissions
  override fun requestPermission(options: RequestPermissionOptions): Promise<Boolean> {
    return Promise.async {
      val reactContext = NitroLocationPackage.reactAppContext
        ?: return@async false

      val permission = when (options.android) {
        AndroidPermissionDetail.COARSE -> Manifest.permission.ACCESS_COARSE_LOCATION
        else -> Manifest.permission.ACCESS_FINE_LOCATION
      }

      if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
        return@async true
      }

      val activity = reactContext.currentActivity ?: return@async false

      return@async suspendCoroutine { continuation ->
        reactContext.addPermissionListener { requestCode, permissions, grantResults ->
          if (permissions.contains(permission)) {
            continuation.resume(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            true
          } else {
            false
          }
        }
        ActivityCompat.requestPermissions(activity, arrayOf(permission), LOCATION_PERMISSION_CODE)
      }
    }
  }

  override fun getCurrentPermission(): Promise<LocationPermissionStatus> {
    return Promise.async {
      val ctx = context
      val hasFine = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED
      val hasCoarse = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED
      when {
        hasFine -> LocationPermissionStatus.AUTHORIZEDFINE
        hasCoarse -> LocationPermissionStatus.AUTHORIZEDCOARSE
        else -> LocationPermissionStatus.DENIED
      }
    }
  }

  // MARK: - Stream control
  override fun startLocationUpdates() {
    if (!hasLocationPermission()) return
    try {
      locationManager.requestLocationUpdates(preferredProvider, minIntervalMs, minDistanceMeters, this)
    } catch (_: Exception) {
      // Try fallback provider
      locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, minIntervalMs, minDistanceMeters, this)
    }
  }

  override fun stopLocationUpdates() {
    locationManager.removeUpdates(this)
  }

  override fun startHeadingUpdates() {
    val sensor = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return
    sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
  }

  override fun stopHeadingUpdates() {
    sensorManager.unregisterListener(this)
  }

  override fun startSignificantLocationUpdates() {
    if (!hasLocationPermission()) return
    // Use coarse location with larger distance filter for significant updates
    try {
      locationManager.requestLocationUpdates(
        LocationManager.NETWORK_PROVIDER,
        minIntervalMs.coerceAtLeast(30_000L),
        minDistanceMeters.coerceAtLeast(500f),
        this
      )
    } catch (_: Exception) {}
  }

  override fun stopSignificantLocationUpdates() {
    locationManager.removeUpdates(this)
  }

  // MARK: - One-shot
  override fun getLatestLocation(options: GetLatestLocationOptions): Promise<Variant_NullType_Location> {
    return Promise.async {
      val maxAgeMs = options.maximumAge ?: 10_000.0
      val timeoutMs = options.timeout ?: 10_000.0

      if (hasLocationPermission()) {
        val cached = getBestLastLocation()
        if (cached != null) {
          val ageMs = System.currentTimeMillis() - cached.time
          if (ageMs < maxAgeMs) {
            return@async Variant_NullType_Location.Second(mapLocation(cached))
          }
        }
      }

      if (!hasLocationPermission()) return@async Variant_NullType_Location.First(NullType())

      return@async suspendCoroutine { continuation ->
        locationContinuation = { result -> continuation.resume(result) }
        val timeoutRunnable = Runnable {
          val cont = locationContinuation
          locationContinuation = null
          cont?.invoke(Variant_NullType_Location.First(NullType()))
        }
        locationTimeoutRunner = timeoutRunnable

        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        handler.postDelayed(timeoutRunnable, timeoutMs.toLong())

        try {
          locationManager.requestSingleUpdate(preferredProvider, this@NitroLocation, android.os.Looper.getMainLooper())
        } catch (_: Exception) {
          handler.removeCallbacks(timeoutRunnable)
          locationContinuation = null
          continuation.resume(Variant_NullType_Location.First(NullType()))
        }
      }
    }
  }

  // MARK: - LocationListener
  override fun onLocationChanged(location: AndroidLocation) {
    val mapped = mapLocation(location)
    val locs = arrayOf(mapped)
    onLocationUpdate.asSecondOrNull()?.invoke(locs)
    onSignificantLocationUpdate.asSecondOrNull()?.invoke(locs)

    val cont = locationContinuation
    if (cont != null) {
      locationContinuation = null
      locationTimeoutRunner?.let {
        android.os.Handler(android.os.Looper.getMainLooper()).removeCallbacks(it)
      }
      locationTimeoutRunner = null
      cont.invoke(Variant_NullType_Location.Second(mapped))
    }
  }

  @Deprecated("Deprecated in Java")
  override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
  override fun onProviderEnabled(provider: String) {}
  override fun onProviderDisabled(provider: String) {}

  // MARK: - SensorEventListener (heading)
  override fun onSensorChanged(event: SensorEvent?) {
    if (event?.sensor?.type != Sensor.TYPE_ROTATION_VECTOR) return
    SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
    SensorManager.getOrientation(rotationMatrix, orientation)
    val azimuthDeg = Math.toDegrees(orientation[0].toDouble())
    val heading = if (azimuthDeg < 0) azimuthDeg + 360 else azimuthDeg
    onHeadingUpdate.asSecondOrNull()?.invoke(Heading(heading))
  }

  override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

  // MARK: - Helpers
  private fun hasLocationPermission(): Boolean {
    val ctx = context
    return ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
      PackageManager.PERMISSION_GRANTED ||
      ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) ==
      PackageManager.PERMISSION_GRANTED
  }

  private fun getBestLastLocation(): AndroidLocation? {
    val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
    return providers.mapNotNull { provider ->
      try { locationManager.getLastKnownLocation(provider) } catch (_: Exception) { null }
    }.maxByOrNull { it.time }
  }

  private fun mapLocation(loc: AndroidLocation): Location {
    return Location(
      timestamp = loc.time.toDouble(),
      latitude = loc.latitude,
      longitude = loc.longitude,
      accuracy = loc.accuracy.toDouble(),
      altitude = loc.altitude,
      altitudeAccuracy = if (loc.hasVerticalAccuracy()) loc.verticalAccuracyMeters.toDouble() else -1.0,
      course = if (loc.hasBearing()) loc.bearing.toDouble() else -1.0,
      courseAccuracy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && loc.hasBearingAccuracy())
        loc.bearingAccuracyDegrees.toDouble() else null,
      speed = if (loc.hasSpeed()) loc.speed.toDouble() else 0.0,
      speedAccuracy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && loc.hasSpeedAccuracy())
        loc.speedAccuracyMetersPerSecond.toDouble() else null,
      floor = null,
      fromMockProvider = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) loc.isMock else loc.isFromMockProvider
    )
  }

  companion object {
    private const val LOCATION_PERMISSION_CODE = 9372
  }
}
