package com.example.pconnect_mobile

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			"pconnect/connectivity"
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"getBluetoothInfo" -> {
					try {
						result.success(getBluetoothInfo())
					} catch (se: SecurityException) {
						result.error(
							"permission",
							"Bluetooth permission missing: ${se.message}",
							null
						)
					} catch (e: Exception) {
						result.error("error", e.message ?: e.toString(), null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun getBluetoothInfo(): HashMap<String, Any> {
		val map = HashMap<String, Any>()

		val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
		val adapter: BluetoothAdapter? = manager?.adapter

		map["enabled"] = adapter?.isEnabled == true

		val bonded = ArrayList<HashMap<String, String>>()
		val connected = ArrayList<HashMap<String, String>>()

		if (adapter != null) {
			// Paired (bonded) devices
			for (d in adapter.bondedDevices) {
				bonded.add(deviceToMap(d))
			}

			// Connected devices (best-effort; varies by device/profile)
			if (manager != null) {
				val seen = HashSet<String>()
				val profiles = intArrayOf(
					BluetoothProfile.HEADSET,
					BluetoothProfile.A2DP,
					BluetoothProfile.GATT
				)
				for (p in profiles) {
					val devs: List<BluetoothDevice> = try {
						manager.getConnectedDevices(p)
					} catch (_: Exception) {
						emptyList()
					}
					for (d in devs) {
						if (seen.add(d.address)) {
							connected.add(deviceToMap(d))
						}
					}
				}
			}
		}

		map["bonded"] = bonded
		map["connected"] = connected
		return map
	}

	private fun deviceToMap(d: BluetoothDevice): HashMap<String, String> {
		val m = HashMap<String, String>()
		m["name"] = d.name ?: ""
		m["address"] = d.address ?: ""
		return m
	}
}
