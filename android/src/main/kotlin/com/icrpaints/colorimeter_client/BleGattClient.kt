package com.icrpaints.colorimeter_client

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Notify/write characteristic pair to look for after service discovery. */
internal data class GattProfile(
    val notifyService: UUID,
    val notifyCharacteristic: UUID,
    val writeService: UUID,
    val writeCharacteristic: UUID,
)

/**
 * Thin BLE GATT bridge: scan, connect one device, enable notifications,
 * write bytes and forward notification chunks.
 *
 * LS170 framing, retries and timeouts live in Dart. All state is touched on
 * the main thread only; GATT callbacks are re-posted to it.
 */
@SuppressLint("MissingPermission")
internal class BleGattClient(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var scanCallback: ScanCallback? = null
    private var scanPrefixes: List<String> = emptyList()

    private var gatt: BluetoothGatt? = null
    private var deviceId: String? = null
    private var profiles: List<GattProfile> = emptyList()
    private var cccdUuid: UUID = DEFAULT_CCCD
    private var requestedMtu = 247
    private var negotiatedMtu: Int? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var servicesRequested = false
    private var ready = false
    private var pendingConnect: MethodChannel.Result? = null
    private var mtuFallback: Runnable? = null

    fun adapterStateName(): String {
        val bt = adapter ?: return "unavailable"
        if (!context.packageManager.hasSystemFeature("android.hardware.bluetooth_le")) {
            return "unavailable"
        }
        return adapterStateName(bt.state)
    }

    fun adapterStateName(state: Int): String = when (state) {
        BluetoothAdapter.STATE_ON -> "on"
        BluetoothAdapter.STATE_OFF -> "off"
        BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
        BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
        else -> "unknown"
    }

    /** Called when the adapter switches off: every link is gone. */
    fun onAdapterOff() {
        scanCallback = null
        val id = deviceId ?: return
        failConnect("bluetooth_off", "Bluetooth was switched off")
        closeGatt()
        emitConnection(id, connected = false, status = null)
    }

    // ---------------------------------------------------------------- scan

    fun startScan(prefixes: List<String>, result: MethodChannel.Result) {
        val bt = adapter ?: return result.error("bluetooth_unavailable", "No Bluetooth adapter", null)
        if (!bt.isEnabled) return result.error("bluetooth_off", "Bluetooth is off", null)
        val permission = BlePermissions.scanPermission(Build.VERSION.SDK_INT)
        if (!BlePermissions.isGranted(context, permission)) {
            return result.error("permission_denied", "Missing $permission", mapOf("missing" to listOf(permission)))
        }
        val scanner = bt.bluetoothLeScanner
            ?: return result.error("bluetooth_unavailable", "BLE scanner unavailable", null)
        stopScan()
        scanPrefixes = prefixes.map { it.uppercase() }
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) = handleScanResult(r)

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach(::handleScanResult)
            }

            override fun onScanFailed(errorCode: Int) {
                main.post {
                    if (scanCallback === this) scanCallback = null
                    emit(mapOf("event" to "scanFailed", "code" to errorCode))
                }
            }
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            scanner.startScan(null, settings, callback)
        } catch (e: SecurityException) {
            return result.error("permission_denied", e.message, mapOf("missing" to listOf(permission)))
        }
        scanCallback = callback
        result.success(null)
    }

    private fun handleScanResult(r: ScanResult) {
        val name = r.scanRecord?.deviceName ?: try {
            r.device.name
        } catch (_: SecurityException) {
            null
        }
        if (scanPrefixes.isNotEmpty()) {
            val upper = name?.trim()?.uppercase() ?: return
            if (scanPrefixes.none { upper.startsWith(it) }) return
        }
        val event = mapOf(
            "event" to "advertisement",
            "id" to r.device.address,
            "name" to name,
            "rssi" to r.rssi,
            "timestamp" to System.currentTimeMillis(),
        )
        main.post { if (scanCallback != null) emit(event) }
    }

    fun stopScan() {
        val callback = scanCallback ?: return
        scanCallback = null
        try {
            adapter?.bluetoothLeScanner?.stopScan(callback)
        } catch (_: Exception) {
            // Adapter off or permission revoked: the scan is gone anyway.
        }
    }

    // ---------------------------------------------------------- connection

    fun connect(
        id: String,
        mtu: Int,
        candidates: List<GattProfile>,
        cccd: UUID,
        result: MethodChannel.Result,
    ) {
        val bt = adapter ?: return result.error("bluetooth_unavailable", "No Bluetooth adapter", null)
        if (!bt.isEnabled) return result.error("bluetooth_off", "Bluetooth is off", null)
        BlePermissions.connectPermission(Build.VERSION.SDK_INT)?.let { p ->
            if (!BlePermissions.isGranted(context, p)) {
                return result.error("permission_denied", "Missing $p", mapOf("missing" to listOf(p)))
            }
        }
        if (!BluetoothAdapter.checkBluetoothAddress(id)) {
            return result.error("invalid_argument", "Invalid Bluetooth address $id", null)
        }
        stopScan()
        val previous = deviceId
        if (previous != null) {
            failConnect("cancelled", "Superseded by a new connection")
            closeGatt()
            if (previous != id) emitConnection(previous, connected = false, status = null)
        }

        val device: BluetoothDevice = bt.getRemoteDevice(id)
        deviceId = id
        profiles = candidates
        cccdUuid = cccd
        requestedMtu = mtu
        pendingConnect = result
        gatt = try {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: SecurityException) {
            failConnect("permission_denied", e.message)
            return
        }
        if (gatt == null) failConnect("connect_failed", "connectGatt returned null")
    }

    fun disconnect(id: String, result: MethodChannel.Result) {
        if (id == deviceId) {
            val wasOpen = gatt != null
            failConnect("cancelled", "Disconnect requested")
            closeGatt()
            if (wasOpen) emitConnection(id, connected = false, status = 0)
        }
        result.success(null)
    }

    fun write(id: String, value: ByteArray, result: MethodChannel.Result) {
        val g = gatt
        val w = writeChar
        if (!ready || id != deviceId || g == null || w == null) {
            return result.error("not_connected", "Device $id is not connected", null)
        }
        val noResponse = w.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        val writeType = if (noResponse) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        val ok = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(w, value, writeType) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                w.writeType = writeType
                @Suppress("DEPRECATION")
                w.value = value
                @Suppress("DEPRECATION")
                g.writeCharacteristic(w)
            }
        } catch (e: SecurityException) {
            return result.error("permission_denied", e.message, null)
        }
        if (ok) result.success(null) else result.error("write_failed", "writeCharacteristic returned false", null)
    }

    fun release() {
        stopScan()
        val id = deviceId
        failConnect("cancelled", "Plugin released")
        closeGatt()
        if (id != null) emitConnection(id, connected = false, status = null)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post { handleConnectionState(g, status, newState) }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                if (g !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) negotiatedMtu = mtu
                discoverServices(g)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post { handleServicesDiscovered(g, status) }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            main.post {
                if (g !== gatt || ready) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    onReady()
                } else {
                    failConnect("gatt_setup_failed", "Enabling notifications failed ($status)", status)
                }
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            val value = c.value?.copyOf() ?: return
            main.post { forwardNotification(g, value) }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            c: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val copy = value.copyOf()
            main.post { forwardNotification(g, copy) }
        }
    }

    private fun handleConnectionState(g: BluetoothGatt, status: Int, newState: Int) {
        if (g !== gatt) {
            // Late callback from a client that was already replaced.
            try { g.close() } catch (_: Exception) { }
            return
        }
        val id = deviceId ?: return
        if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
            val requested = try { g.requestMtu(requestedMtu) } catch (_: SecurityException) { false }
            if (requested) {
                // Some stacks never call onMtuChanged; continue anyway.
                val fallback = Runnable { if (g === gatt) discoverServices(g) }
                mtuFallback = fallback
                main.postDelayed(fallback, MTU_FALLBACK_MS)
            } else {
                discoverServices(g)
            }
            return
        }
        // Disconnected, or connect failed (e.g. status 133).
        failConnect("connect_failed", "GATT connection failed (status $status)", status)
        closeGatt()
        emitConnection(id, connected = false, status = status)
    }

    private fun discoverServices(g: BluetoothGatt) {
        mtuFallback?.let { main.removeCallbacks(it) }
        mtuFallback = null
        if (servicesRequested) return
        servicesRequested = true
        val ok = try { g.discoverServices() } catch (_: SecurityException) { false }
        if (!ok) failConnect("gatt_setup_failed", "Service discovery could not start")
    }

    private fun handleServicesDiscovered(g: BluetoothGatt, status: Int) {
        if (g !== gatt || ready) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            return failConnect("gatt_setup_failed", "Service discovery failed ($status)", status)
        }
        for (p in profiles) {
            val n = g.getService(p.notifyService)?.getCharacteristic(p.notifyCharacteristic)
            val w = g.getService(p.writeService)?.getCharacteristic(p.writeCharacteristic)
            if (n != null && w != null) {
                notifyChar = n
                writeChar = w
                return enableNotifications(g, n)
            }
        }
        val found = g.services.joinToString { it.uuid.toString() }
        failConnect("gatt_setup_failed", "Colorimeter characteristics not found. Services: $found")
    }

    private fun enableNotifications(g: BluetoothGatt, n: BluetoothGattCharacteristic) {
        try {
            if (!g.setCharacteristicNotification(n, true)) {
                return failConnect("gatt_setup_failed", "setCharacteristicNotification failed")
            }
            val cccd = n.getDescriptor(cccdUuid) ?: return onReady()
            val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            val written = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeDescriptor(cccd, value) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                cccd.value = value
                @Suppress("DEPRECATION")
                g.writeDescriptor(cccd)
            }
            if (!written) failConnect("gatt_setup_failed", "Could not write the CCCD")
        } catch (e: SecurityException) {
            failConnect("permission_denied", e.message)
        }
    }

    private fun onReady() {
        val id = deviceId ?: return
        ready = true
        val w = writeChar
        val r = pendingConnect
        pendingConnect = null
        r?.success(
            mapOf(
                "mtu" to negotiatedMtu,
                "notifyCharacteristic" to notifyChar?.uuid?.toString(),
                "writeCharacteristic" to w?.uuid?.toString(),
                "writeWithoutResponse" to
                    (w != null && w.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0),
            )
        )
        emitConnection(id, connected = true, status = 0)
    }

    private fun forwardNotification(g: BluetoothGatt, value: ByteArray) {
        if (g !== gatt || value.isEmpty()) return
        emit(mapOf("event" to "notification", "id" to deviceId, "value" to value))
    }

    /** Fails a pending connect; a GATT client that never became ready is closed. */
    private fun failConnect(code: String, message: String?, status: Int? = null) {
        val r = pendingConnect ?: return
        pendingConnect = null
        if (!ready) closeGatt()
        r.error(code, message, status?.let { mapOf("status" to it) })
    }

    private fun closeGatt() {
        mtuFallback?.let { main.removeCallbacks(it) }
        mtuFallback = null
        val g = gatt
        gatt = null
        deviceId = null
        notifyChar = null
        writeChar = null
        negotiatedMtu = null
        servicesRequested = false
        ready = false
        if (g != null) {
            try {
                g.disconnect()
                g.close()
            } catch (_: Exception) {
                // Already closed or permission revoked.
            }
        }
    }

    private fun emitConnection(id: String, connected: Boolean, status: Int?) {
        emit(mapOf("event" to "connection", "id" to id, "connected" to connected, "status" to status))
    }

    companion object {
        private const val MTU_FALLBACK_MS = 1500L
        private val DEFAULT_CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
