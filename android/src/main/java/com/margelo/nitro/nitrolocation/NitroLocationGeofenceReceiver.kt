package com.margelo.nitro.nitrolocation

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import com.facebook.react.HeadlessJsTaskService
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent

/**
 * Manifest-registered receiver for Play Services geofence transitions, so a transition is
 * still delivered after the app process has been killed. Play Services always targets this
 * PendingIntent (see NitroLocation.geofencePendingIntent), regardless of process state.
 *
 * The consuming app registers this receiver in its manifest and points it at its own
 * HeadlessJsTaskService via meta-data, so the library never depends on an app-specific class:
 *
 *   <receiver android:name="com.margelo.nitro.nitrolocation.NitroLocationGeofenceReceiver" android:exported="false">
 *     <meta-data android:name="com.margelo.nitro.nitrolocation.HEADLESS_TASK_SERVICE"
 *                android:value="com.example.app.GeofenceHeadlessTaskService"/>
 *   </receiver>
 */
class NitroLocationGeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) return
        // Forward exactly one triggering geofence's id and the transition type, nothing more.
        val geofence: Geofence = event.triggeringGeofences?.firstOrNull() ?: return
        val type = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
            else -> return
        }

        val serviceClassName = readHeadlessTaskServiceClassName(context) ?: return
        try {
            val serviceIntent = Intent().apply {
                component = ComponentName(context, serviceClassName)
                putExtra("identifier", geofence.requestId)
                putExtra("type", type)
            }
            context.startService(serviceIntent)
            HeadlessJsTaskService.acquireWakeLockNow(context)
        } catch (_: Exception) {}
    }

    private fun readHeadlessTaskServiceClassName(context: Context): String? {
        return try {
            val info = context.packageManager.getReceiverInfo(
                ComponentName(context, NitroLocationGeofenceReceiver::class.java),
                PackageManager.GET_META_DATA
            )
            info.metaData?.getString(META_DATA_HEADLESS_TASK_SERVICE)
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        const val META_DATA_HEADLESS_TASK_SERVICE = "com.margelo.nitro.nitrolocation.HEADLESS_TASK_SERVICE"
    }
}
