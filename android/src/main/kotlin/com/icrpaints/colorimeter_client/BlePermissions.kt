package com.icrpaints.colorimeter_client

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.provider.Settings

/** Runtime permissions needed for BLE scanning and connecting. */
internal object BlePermissions {
    /** Permissions to request on a device running [sdkInt]. */
    fun required(sdkInt: Int): List<String> =
        if (sdkInt >= Build.VERSION_CODES.S) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    /** Permission needed for GATT operations on [sdkInt] (null = none at runtime). */
    fun connectPermission(sdkInt: Int): String? =
        if (sdkInt >= Build.VERSION_CODES.S) Manifest.permission.BLUETOOTH_CONNECT else null

    /** Permission needed for scanning on [sdkInt]. */
    fun scanPermission(sdkInt: Int): String =
        if (sdkInt >= Build.VERSION_CODES.S) {
            Manifest.permission.BLUETOOTH_SCAN
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }

    /** Before Android 12, BLE scans return nothing while location services are off. */
    fun locationServicesRequired(sdkInt: Int): Boolean = sdkInt < Build.VERSION_CODES.S

    fun isGranted(context: Context, permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun missing(context: Context, sdkInt: Int = Build.VERSION.SDK_INT): List<String> =
        required(sdkInt).filterNot { isGranted(context, it) }

    fun locationServicesEnabled(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager?
            lm?.isLocationEnabled ?: false
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(
                context.contentResolver,
                Settings.Secure.LOCATION_MODE,
                Settings.Secure.LOCATION_MODE_OFF
            ) != Settings.Secure.LOCATION_MODE_OFF
        }
    }

    fun statusMap(context: Context, permanentlyDenied: List<String> = emptyList()): Map<String, Any> {
        val sdk = Build.VERSION.SDK_INT
        return mapOf(
            "missing" to missing(context, sdk),
            "permanentlyDenied" to permanentlyDenied,
            "locationServicesRequired" to locationServicesRequired(sdk),
            "locationServicesEnabled" to locationServicesEnabled(context),
        )
    }
}
