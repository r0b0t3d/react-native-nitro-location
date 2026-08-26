package com.margelo.nitro.nitrolocation

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location as AndroidLocation
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Looper
import androidx.annotation.RequiresPermission
import androidx.core.content.ContextCompat
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.NullType
import com.margelo.nitro.core.Promise
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

@DoNotStrip
class NitroLocation : HybridNitroLocationSpec(), SensorEventListener {

    // Callback props
    override var onLocationUpdate: Variant__locations__Array_Location______Unit_NullType =
        Variant__locations__Array_Location______Unit_NullType.Second(NullType.NULL)
    override var onHeadingUpdate: Variant__heading__Heading_____Unit_NullType =
        Variant__heading__Heading_____Unit_NullType.Second(NullType.NULL)
    override var onPermissionUpdate: Variant__status__LocationPermissionStatus_____Unit_NullType =
        Variant__status__LocationPermissionStatus_____Unit_NullType.Second(NullType.NULL)
    override var onSignificantLocationUpdate: Variant__locations__Array_Location______Unit_NullType =
        Variant__locations__Array_Location______Unit_NullType.Second(NullType.NULL)
    override var onGeofenceTransition: Variant__event__GeofenceTransitionEvent_____Unit_NullType =
        Variant__event__GeofenceTransitionEvent_____Unit_NullType.Second(NullType.NULL)

    private val context: ReactApplicationContext
        get() = NitroModules.applicationContext ?: throw Error("No context - NitroModules.applicationContext was null!")

    private val fusedLocationClient: FusedLocationProviderClient
        get() = LocationServices.getFusedLocationProviderClient(context)

    private val locationManager: LocationManager
        get() = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private val geofencingClient: GeofencingClient
        get() = LocationServices.getGeofencingClient(context)

    private val geofencePendingIntent: PendingIntent
        get() = PendingIntent.getBroadcast(
            context,
            GEOFENCE_REQUEST_CODE,
            Intent(context, NitroLocationGeofenceReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    private val sensorManager: SensorManager
        get() = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    // Config state
    private var minDistanceMeters: Float = 0f
    private var minIntervalMs: Long = 1000L
    private var accuracyPriority: Int = Priority.PRIORITY_HIGH_ACCURACY

    // Heading state
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)

    // Active streaming callbacks — null when stopped
    private var locationCallback: LocationCallback? = null
    private var significantLocationCallback: LocationCallback? = null

    // MARK: - Configure
    override fun configure(options: ConfigureOptions): Promise<Unit> {
        return Promise.async {
            options.distanceFilter?.let { minDistanceMeters = it.toFloat() }
            options.interval?.let { minIntervalMs = it.toLong() }
            options.androidProvider?.let { provider ->
                accuracyPriority = when (provider) {
                    AndroidProvider.STANDARD -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
                    AndroidProvider.PLAYSERVICES -> Priority.PRIORITY_HIGH_ACCURACY
                    else -> Priority.PRIORITY_HIGH_ACCURACY
                }
            }
            options.desiredAccuracy?.android?.let { acc ->
                accuracyPriority = when (acc) {
                    AndroidDesiredAccuracy.HIGHACCURACY -> Priority.PRIORITY_HIGH_ACCURACY
                    AndroidDesiredAccuracy.BALANCEDPOWERACCURACY -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
                    AndroidDesiredAccuracy.LOWPOWER -> Priority.PRIORITY_LOW_POWER
                    AndroidDesiredAccuracy.NOPOWER -> Priority.PRIORITY_PASSIVE
                }
            }
        }
    }

    // MARK: - Permissions
    override fun requestPermission(options: RequestPermissionOptions): Promise<Boolean> {
        return Promise.async {
            val reactContext = NitroModules.applicationContext
                ?: return@async false

            val permission = when (options.android) {
                AndroidPermissionDetail.COARSE -> Manifest.permission.ACCESS_COARSE_LOCATION
                else -> Manifest.permission.ACCESS_FINE_LOCATION
            }

            if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
                return@async true
            }

            val activity = reactContext.currentActivity as? PermissionAwareActivity
                ?: return@async false

            return@async suspendCoroutine { continuation ->
                activity.requestPermissions(arrayOf(permission), LOCATION_PERMISSION_CODE,
                    PermissionListener { _, permissions, grantResults ->
                        if (permissions.contains(permission)) {
                            continuation.resume(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
                            true
                        } else {
                            false
                        }
                    }
                )
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
    @RequiresPermission(anyOf = [Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION])
    override fun startLocationUpdates() {
        if (!hasLocationPermission()) return

        locationCallback?.let {
            @Suppress("MissingPermission")
            fusedLocationClient.removeLocationUpdates(it)
        }

        if (!isPlayServicesAvailable()) {
            startLocationUpdatesLegacy()
            return
        }

        val request = LocationRequest.Builder(accuracyPriority, minIntervalMs)
            .setMinUpdateDistanceMeters(minDistanceMeters)
            .build()

        val callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val locs = result.locations.map { mapLocation(it) }.toTypedArray()
                if (locs.isNotEmpty()) {
                    onLocationUpdate.asFirstOrNull()?.invoke(locs)
                }
            }
        }
        locationCallback = callback

        try {
            @Suppress("MissingPermission")
            fusedLocationClient.requestLocationUpdates(request, callback, Looper.getMainLooper())
        } catch (_: SecurityException) {}
    }

    override fun stopLocationUpdates() {
        locationCallback?.let {
            try { fusedLocationClient.removeLocationUpdates(it) } catch (_: Exception) {}
        }
        locationCallback = null
        try { locationManager.removeUpdates(legacyLocationListener) } catch (_: Exception) {}
    }

    override fun startHeadingUpdates() {
        val sensor = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return
        sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
    }

    override fun stopHeadingUpdates() {
        sensorManager.unregisterListener(this)
    }

    @RequiresPermission(anyOf = [Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION])
    override fun startSignificantLocationUpdates() {
        if (!hasLocationPermission()) return

        significantLocationCallback?.let {
            @Suppress("MissingPermission")
            fusedLocationClient.removeLocationUpdates(it)
        }

        if (!isPlayServicesAvailable()) {
            startSignificantLocationUpdatesLegacy()
            return
        }

        val interval = minIntervalMs.coerceAtLeast(30_000L)
        val distance = minDistanceMeters.coerceAtLeast(500f)
        val request = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, interval)
            .setMinUpdateDistanceMeters(distance)
            .build()

        val callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val locs = result.locations.map { mapLocation(it) }.toTypedArray()
                if (locs.isNotEmpty()) {
                    onSignificantLocationUpdate.asFirstOrNull()?.invoke(locs)
                }
            }
        }
        significantLocationCallback = callback

        try {
            @Suppress("MissingPermission")
            fusedLocationClient.requestLocationUpdates(request, callback, Looper.getMainLooper())
        } catch (_: SecurityException) {}
    }

    override fun stopSignificantLocationUpdates() {
        significantLocationCallback?.let {
            try { fusedLocationClient.removeLocationUpdates(it) } catch (_: Exception) {}
        }
        significantLocationCallback = null
        try { locationManager.removeUpdates(legacySignificantLocationListener) } catch (_: Exception) {}
    }

    // MARK: - Geofencing
    override fun startMonitoringGeofences(regions: Array<GeofenceRegion>): Promise<StartMonitoringGeofencesResult> {
        val promise = Promise<StartMonitoringGeofencesResult>()

        val geofenceList = regions.map { region ->
            Geofence.Builder()
                .setRequestId(region.identifier)
                .setCircularRegion(region.latitude, region.longitude, region.radiusMeters.toFloat())
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                .build()
        }

        try {
            // Full replace: remove any previously monitored regions before adding the new set.
            val removeTask = geofencingClient.removeGeofences(geofencePendingIntent)

            if (geofenceList.isEmpty()) {
                // GeofencingRequest.Builder().build() throws IllegalArgumentException when no
                // geofence was added. An empty regions array is itself a valid "unregister
                // everything" request under full-replace semantics, so resolve immediately
                // without ever constructing the request.
                promise.resolve(StartMonitoringGeofencesResult(0.0))
                return promise
            }

            val request = GeofencingRequest.Builder()
                .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
                .addGeofences(geofenceList)
                .build()

            // removeGeofences and addGeofences are independent async Play Services Tasks with
            // no ordering guarantee between them. Chain addGeofences via continueWithTask so it
            // only runs once removeGeofences has settled (success OR failure — a "nothing to
            // remove" failure here is not fatal), instead of firing both unawaited.
            removeTask.continueWithTask {
                @Suppress("MissingPermission")
                geofencingClient.addGeofences(request, geofencePendingIntent)
            }
                .addOnSuccessListener {
                    promise.resolve(StartMonitoringGeofencesResult(regions.size.toDouble()))
                }
                .addOnFailureListener { error ->
                    promise.reject(error)
                }
        } catch (e: SecurityException) {
            promise.reject(e)
        }

        return promise
    }

    override fun stopMonitoringGeofences() {
        geofencingClient.removeGeofences(geofencePendingIntent)
    }

    override fun getPendingGeofenceTransition(): Variant_NullType_GeofenceTransitionEvent {
        // Android has no relaunch-race buffering need (spec is iOS-only): the manifest
        // BroadcastReceiver (NitroLocationGeofenceReceiver) covers reboot/process-death instead.
        // Permanent no-op.
        return Variant_NullType_GeofenceTransitionEvent.First(NullType.NULL)
    }

    // MARK: - One-shot
    override fun getLatestLocation(options: GetLatestLocationOptions): Promise<Variant_NullType_Location> {
        return Promise.async {
            val maxAgeMs = options.maximumAge ?: 10_000.0
            val timeoutMs = options.timeout ?: 10_000.0

            if (!hasLocationPermission()) {
                return@async Variant_NullType_Location.First(NullType.NULL)
            }

            if (!isPlayServicesAvailable()) {
                return@async getLatestLocationLegacy(maxAgeMs, timeoutMs)
            }

            // Step 1: try fresh cached fused location
            val cached = getFusedLastLocation()
            if (cached != null) {
                val ageMs = System.currentTimeMillis() - cached.time
                if (ageMs < maxAgeMs) {
                    return@async Variant_NullType_Location.Second(mapLocation(cached))
                }
            }

            // Step 2: request fresh high-accuracy location
            val cts = CancellationTokenSource()
            val handler = android.os.Handler(Looper.getMainLooper())
            val timeoutRunnable = Runnable { cts.cancel() }
            handler.postDelayed(timeoutRunnable, timeoutMs.toLong())

            return@async suspendCoroutine { continuation ->
                try {
                    @Suppress("MissingPermission")
                    fusedLocationClient.getCurrentLocation(accuracyPriority, cts.token)
                        .addOnCompleteListener { task ->
                            handler.removeCallbacks(timeoutRunnable)
                            val location = if (task.isSuccessful) task.result else null
                            if (location != null) {
                                continuation.resume(Variant_NullType_Location.Second(mapLocation(location)))
                            } else {
                                // Step 3: fallback to last known fused location
                                @Suppress("MissingPermission")
                                fusedLocationClient.lastLocation
                                    .addOnCompleteListener { lastTask ->
                                        val last = if (lastTask.isSuccessful) lastTask.result else null
                                        // Step 4: return NULL if still nothing
                                        continuation.resume(
                                            if (last != null) Variant_NullType_Location.Second(mapLocation(last))
                                            else Variant_NullType_Location.First(NullType.NULL)
                                        )
                                    }
                            }
                        }
                } catch (_: SecurityException) {
                    handler.removeCallbacks(timeoutRunnable)
                    cts.cancel()
                    continuation.resume(Variant_NullType_Location.First(NullType.NULL))
                } catch (_: Exception) {
                    handler.removeCallbacks(timeoutRunnable)
                    cts.cancel()
                    continuation.resume(Variant_NullType_Location.First(NullType.NULL))
                }
            }
        }
    }

    // MARK: - SensorEventListener (heading)
    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_ROTATION_VECTOR) return
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
        SensorManager.getOrientation(rotationMatrix, orientation)
        val azimuthDeg = Math.toDegrees(orientation[0].toDouble())
        val heading = if (azimuthDeg < 0) azimuthDeg + 360 else azimuthDeg
        onHeadingUpdate.asFirstOrNull()?.invoke(Heading(heading))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // MARK: - Play Services
    private fun isPlayServicesAvailable(): Boolean {
        return try {
            GoogleApiAvailability.getInstance()
                .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("MissingPermission")
    private suspend fun getFusedLastLocation(): AndroidLocation? {
        return suspendCoroutine { continuation ->
            try {
                fusedLocationClient.lastLocation
                    .addOnCompleteListener { task ->
                        continuation.resume(if (task.isSuccessful) task.result else null)
                    }
            } catch (_: Exception) {
                continuation.resume(null)
            }
        }
    }

    // MARK: - Legacy fallbacks (no Play Services)
    private val legacyLocationListener = LocationListener { location ->
        onLocationUpdate.asFirstOrNull()?.invoke(arrayOf(mapLocation(location)))
    }

    private val legacySignificantLocationListener = LocationListener { location ->
        onSignificantLocationUpdate.asFirstOrNull()?.invoke(arrayOf(mapLocation(location)))
    }

    private fun startLocationUpdatesLegacy() {
        try {
            @Suppress("MissingPermission")
            locationManager.requestLocationUpdates(
                LocationManager.NETWORK_PROVIDER, minIntervalMs, minDistanceMeters, legacyLocationListener
            )
        } catch (_: Exception) {}
    }

    private fun startSignificantLocationUpdatesLegacy() {
        try {
            @Suppress("MissingPermission")
            locationManager.requestLocationUpdates(
                LocationManager.NETWORK_PROVIDER,
                minIntervalMs.coerceAtLeast(30_000L),
                minDistanceMeters.coerceAtLeast(500f),
                legacySignificantLocationListener
            )
        } catch (_: Exception) {}
    }

    private suspend fun getLatestLocationLegacy(maxAgeMs: Double, timeoutMs: Double): Variant_NullType_Location {
        val cached = getLegacyLastLocation()
        if (cached != null && System.currentTimeMillis() - cached.time < maxAgeMs) {
            return Variant_NullType_Location.Second(mapLocation(cached))
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return if (cached != null) Variant_NullType_Location.Second(mapLocation(cached))
            else Variant_NullType_Location.First(NullType.NULL)
        }

        val provider = when {
            locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> return if (cached != null) Variant_NullType_Location.Second(mapLocation(cached))
                    else Variant_NullType_Location.First(NullType.NULL)
        }

        return suspendCoroutine { continuation ->
            val handler = android.os.Handler(Looper.getMainLooper())
            val cancellationSignal = android.os.CancellationSignal()
            val timeoutRunnable = Runnable { cancellationSignal.cancel() }
            handler.postDelayed(timeoutRunnable, timeoutMs.toLong())

            try {
                @Suppress("MissingPermission")
                locationManager.getCurrentLocation(provider, cancellationSignal, context.mainExecutor) { location ->
                    handler.removeCallbacks(timeoutRunnable)
                    if (location != null) {
                        continuation.resume(Variant_NullType_Location.Second(mapLocation(location)))
                    } else {
                        val last = getLegacyLastLocation()
                        continuation.resume(
                            if (last != null) Variant_NullType_Location.Second(mapLocation(last))
                            else Variant_NullType_Location.First(NullType.NULL)
                        )
                    }
                }
            } catch (_: SecurityException) {
                handler.removeCallbacks(timeoutRunnable)
                continuation.resume(Variant_NullType_Location.First(NullType.NULL))
            } catch (_: Exception) {
                handler.removeCallbacks(timeoutRunnable)
                continuation.resume(Variant_NullType_Location.First(NullType.NULL))
            }
        }
    }

    @Suppress("MissingPermission")
    private fun getLegacyLastLocation(): AndroidLocation? {
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        return providers.mapNotNull { provider ->
            try { locationManager.getLastKnownLocation(provider) } catch (_: Exception) { null }
        }.maxByOrNull { it.time }
    }

    // MARK: - Map location
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
        private const val GEOFENCE_REQUEST_CODE = 9373
    }

    private fun hasLocationPermission(): Boolean {
        val ctx = context
        return ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
    }
}
