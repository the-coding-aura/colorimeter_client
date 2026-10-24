package com.icrpaints.colorimeter_client

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.UUID

/** Flutter entry point: routes method calls to [BleGattClient] and streams its events. */
class ColorimeterClientPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var ble: BleGattClient? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            val client = ble ?: return
            if (state == BluetoothAdapter.STATE_OFF || state == BluetoothAdapter.STATE_TURNING_OFF) {
                client.onAdapterOff()
            }
            emit(mapOf("event" to "adapterState", "state" to client.adapterStateName(state)))
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        ble = BleGattClient(context, ::emit)
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(adapterReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(adapterReceiver, filter)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ble?.release()
        ble = null
        try {
            context.unregisterReceiver(adapterReceiver)
        } catch (_: IllegalArgumentException) {
            // Not registered.
        }
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
    }

    // ------------------------------------------------------------ activity

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    // -------------------------------------------------------------- events

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            main.post { eventSink?.success(event) }
        }
    }

    // ------------------------------------------------------------- methods

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val client = ble ?: return result.error("bluetooth_unavailable", "Plugin detached", null)
        when (call.method) {
            "getAdapterState" -> result.success(client.adapterStateName())
            "checkPermissions" -> result.success(BlePermissions.statusMap(context))
            "requestPermissions" -> requestPermissions(result)
            "startScan" -> {
                val prefixes = call.argument<List<String>>("namePrefixes") ?: emptyList()
                client.startScan(prefixes, result)
            }
            "stopScan" -> {
                client.stopScan()
                result.success(null)
            }
            "connect" -> {
                val id = call.argument<String>("id")
                    ?: return result.error("invalid_argument", "Missing id", null)
                val mtu = call.argument<Int>("mtu") ?: 247
                val cccd = call.argument<String>("cccd")?.let(UUID::fromString)
                    ?: UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
                val profiles = try {
                    parseProfiles(call.argument<List<Map<String, String>>>("candidates"))
                } catch (e: IllegalArgumentException) {
                    return result.error("invalid_argument", e.message, null)
                }
                client.connect(id, mtu, profiles, cccd, result)
            }
            "disconnect" -> {
                val id = call.argument<String>("id")
                    ?: return result.error("invalid_argument", "Missing id", null)
                client.disconnect(id, result)
            }
            "write" -> {
                val id = call.argument<String>("id")
                    ?: return result.error("invalid_argument", "Missing id", null)
                val value = call.argument<ByteArray>("value")
                    ?: return result.error("invalid_argument", "Missing value", null)
                client.write(id, value, result)
            }
            "release" -> {
                client.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun parseProfiles(raw: List<Map<String, String>>?): List<GattProfile> =
        raw.orEmpty().map {
            GattProfile(
                notifyService = UUID.fromString(it.getValue("notifyService")),
                notifyCharacteristic = UUID.fromString(it.getValue("notifyCharacteristic")),
                writeService = UUID.fromString(it.getValue("writeService")),
                writeCharacteristic = UUID.fromString(it.getValue("writeCharacteristic")),
            )
        }

    // --------------------------------------------------------- permissions

    private fun requestPermissions(result: MethodChannel.Result) {
        val missing = BlePermissions.missing(context)
        if (missing.isEmpty()) return result.success(BlePermissions.statusMap(context))
        val activity: Activity = activityBinding?.activity
            ?: return result.error("no_activity", "Permissions can only be requested from an Activity", null)
        if (pendingPermissionResult != null) {
            return result.error("busy", "A permission request is already running", null)
        }
        pendingPermissionResult = result
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        val activity = activityBinding?.activity
        val permanentlyDenied = permissions.filterIndexed { i, p ->
            grantResults.getOrNull(i) != PackageManager.PERMISSION_GRANTED &&
                activity != null && !activity.shouldShowRequestPermissionRationale(p)
        }
        result.success(BlePermissions.statusMap(context, permanentlyDenied))
        return true
    }

    private companion object {
        const val METHOD_CHANNEL = "com.icrpaints.colorimeter_client/methods"
        const val EVENT_CHANNEL = "com.icrpaints.colorimeter_client/events"
        const val PERMISSION_REQUEST_CODE = 0x1700
    }
}
