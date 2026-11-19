package fr.applitransport.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Position du téléphone par la localisation standard d'Android (LocationManager : GPS, et réseau si le
 * téléphone en fournit un), sans les services Google. Canal « fr.applitransport/location » (permission,
 * service, dernière position, position actuelle) et flux « fr.applitransport/location/updates ».
 */
class MainActivity : FlutterActivity() {
    private val requestCode = 4210
    private var pendingPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private var updater: UpdateInstaller? = null

    private val lm: LocationManager
        get() = getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    private val fine get() = granted(Manifest.permission.ACCESS_FINE_LOCATION)
    private val coarse get() = granted(Manifest.permission.ACCESS_COARSE_LOCATION)

    /** Fournisseurs utilisables : GPS d'abord, réseau s'il existe et est actif. */
    private fun providers(): List<String> {
        val all = lm.getProviders(true)
        return listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter { it in all }
    }

    private fun toMap(l: Location): Map<String, Any> = mapOf(
        "lat" to l.latitude,
        "lon" to l.longitude,
        "accuracy" to (if (l.hasAccuracy()) l.accuracy.toDouble() else 0.0),
        "speed" to (if (l.hasSpeed()) l.speed.toDouble() else 0.0),
        "heading" to (if (l.hasBearing()) l.bearing.toDouble() else -1.0),
        "time" to l.time,
    )

    /** « denied », « deniedForever », « whileInUse » (la position en arrière-plan n'est jamais demandée). */
    private fun permissionState(): String {
        if (fine || coarse) return "whileInUse"
        val asked = getPreferences(Context.MODE_PRIVATE).getBoolean("location_asked", false)
        return if (asked && !shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)) {
            "deniedForever"
        } else {
            "denied"
        }
    }

    @Suppress("MissingPermission")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        updater = UpdateInstaller(this, messenger)

        // types de processeur du téléphone, du préféré au moins bon (choix de l'APK des mises à jour)
        MethodChannel(messenger, "fr.applitransport/device").setMethodCallHandler { call, result ->
            if (call.method == "abis") result.success(Build.SUPPORTED_ABIS.toList()) else result.notImplemented()
        }

        MethodChannel(messenger, "fr.applitransport/location").setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermission" -> result.success(permissionState())
                "requestPermission" -> {
                    if (fine || coarse) {
                        result.success("whileInUse")
                    } else {
                        pendingPermission = result
                        getPreferences(Context.MODE_PRIVATE).edit().putBoolean("location_asked", true).apply()
                        requestPermissions(
                            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                            requestCode,
                        )
                    }
                }
                "isServiceEnabled" -> result.success(
                    if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else providers().isNotEmpty()
                )
                "accuracyStatus" -> result.success(if (fine) "precise" else "reduced")
                "lastKnown" -> {
                    if (!fine && !coarse) return@setMethodCallHandler result.success(null)
                    val best = (providers() + LocationManager.PASSIVE_PROVIDER)
                        .mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
                        .maxByOrNull { it.time }
                    result.success(best?.let { toMap(it) })
                }
                "current" -> {
                    if (!fine && !coarse) return@setMethodCallHandler result.error("permission", "permission refusée", null)
                    val ps = providers()
                    if (ps.isEmpty()) return@setMethodCallHandler result.error("disabled", "localisation désactivée", null)
                    currentLocation(ps, result)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "fr.applitransport/location/updates").setStreamHandler(object : EventChannel.StreamHandler {
            private var listener: LocationListener? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                if (!fine && !coarse) return events.error("permission", "permission refusée", null)
                val args = arguments as? Map<*, *>
                val minDistance = (args?.get("distance") as? Number)?.toFloat() ?: 0f
                val interval = (args?.get("interval") as? Number)?.toLong() ?: 1000L
                listener?.let { lm.removeUpdates(it) } // un seul flux à la fois
                val l = LocationListener { loc -> events.success(toMap(loc)) }
                listener = l
                val ps = providers()
                if (ps.isEmpty()) return events.error("disabled", "localisation désactivée", null)
                for (p in ps) lm.requestLocationUpdates(p, interval, minDistance, l, Looper.getMainLooper())
            }

            override fun onCancel(arguments: Any?) {
                listener?.let { lm.removeUpdates(it) }
                listener = null
            }
        })
    }

    /** Première position fraîche venue de l'un des fournisseurs (le délai est géré côté Dart). */
    @Suppress("MissingPermission", "DEPRECATION")
    private fun currentLocation(ps: List<String>, result: MethodChannel.Result) {
        var done = false
        val cancels = mutableListOf<CancellationSignal>()
        val listeners = mutableListOf<LocationListener>()
        fun deliver(loc: Location?) {
            if (done || loc == null) return
            done = true
            cancels.forEach { it.cancel() }
            listeners.forEach { lm.removeUpdates(it) }
            result.success(toMap(loc))
        }
        for (p in ps) {
            if (Build.VERSION.SDK_INT >= 30) {
                val c = CancellationSignal()
                cancels += c
                lm.getCurrentLocation(p, c, mainExecutor) { deliver(it) }
            } else {
                val l = object : LocationListener {
                    override fun onLocationChanged(loc: Location) = deliver(loc)
                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                }
                listeners += l
                lm.requestSingleUpdate(p, l, Looper.getMainLooper())
            }
        }
        // sans réponse au bout de 60 s : on rend la main (le côté Dart a son propre délai, plus court)
        main.postDelayed({
            if (!done) {
                done = true
                cancels.forEach { it.cancel() }
                listeners.forEach { lm.removeUpdates(it) }
                result.error("timeout", "pas de position", null)
            }
        }, 60_000)
    }

    override fun onDestroy() {
        updater?.dispose()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code != requestCode) return
        pendingPermission?.success(permissionState())
        pendingPermission = null
    }
}
