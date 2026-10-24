package com.icrpaints.colorimeter_client

import android.Manifest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class BlePermissionsTest {
    @Test
    fun android12AndLaterNeedScanAndConnect() {
        assertEquals(
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT),
            BlePermissions.required(31),
        )
        assertEquals(Manifest.permission.BLUETOOTH_CONNECT, BlePermissions.connectPermission(34))
        assertFalse(BlePermissions.locationServicesRequired(31))
    }

    @Test
    fun android11AndEarlierNeedFineLocation() {
        assertEquals(listOf(Manifest.permission.ACCESS_FINE_LOCATION), BlePermissions.required(30))
        assertEquals(Manifest.permission.ACCESS_FINE_LOCATION, BlePermissions.scanPermission(24))
        assertNull(BlePermissions.connectPermission(30))
        assertTrue(BlePermissions.locationServicesRequired(29))
    }
}
