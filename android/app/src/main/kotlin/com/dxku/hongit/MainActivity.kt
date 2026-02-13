package com.dxku.hongit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import com.dxku.hongit.backend.MainService
import com.dxku.hongit.backend.youtube.YoutubeExtractorBridge
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val batteryChannel = "battery_optimization"
    private val youtubeBridge by lazy { YoutubeExtractorBridge(applicationContext) }

    companion object {
        private const val TAG = "MainActivity"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            batteryChannel
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "manufacturer" -> {
                    result.success(Build.MANUFACTURER)
                }

                "isIgnoring" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }

                "request" -> {
                    result.success(openBatteryOptimizationSettings())
                }

                else -> result.notImplemented()
            }
        }

        youtubeBridge.attach(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        youtubeBridge.initialize()
        MainService.start(this)
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        val packageUri = Uri.parse("package:$packageName")
        val manufacturer = Build.MANUFACTURER.lowercase()

        val intents = mutableListOf<Intent>()

        intents += Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            packageUri
        )
        intents += Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

        if (
            manufacturer.contains("xiaomi") ||
            manufacturer.contains("redmi") ||
            manufacturer.contains("poco")
        ) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                )
                putExtra("package_name", packageName)
                putExtra("package_label", applicationInfo.loadLabel(packageManager).toString())
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            }
        }

        if (
            manufacturer.contains("oppo") ||
            manufacturer.contains("realme") ||
            manufacturer.contains("oneplus")
        ) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.coloros.oppoguardelf",
                    "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"
                )
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.oplus.battery",
                    "com.oplus.powermanager.fuelgaue.PowerUsageModelActivity"
                )
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.privacypermissionsentry.PermissionTopActivity"
                )
            }
        }

        if (manufacturer.contains("vivo")) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.vivo.abe",
                    "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"
                )
            }
        }

        if (manufacturer.contains("huawei") || manufacturer.contains("honor")) {
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity"
                )
            }
            intents += Intent().apply {
                component = android.content.ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"
                )
            }
        }

        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)

        for (intent in intents) {
            if (tryLaunchSettingsIntent(intent)) {
                return true
            }
        }

        return false
    }

    private fun tryLaunchSettingsIntent(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val resolver = intent.resolveActivity(packageManager)
            if (resolver == null) {
                false
            } else {
                startActivity(intent)
                true
            }
        } catch (e: Exception) {
            Log.w(TAG, "Battery settings intent failed: ${e.message}")
            false
        }
    }
}

