package fr.applitransport.app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Mise à jour de l'appli par elle-même, sans services Google : télécharge l'APK de la Release, vérifie son
 * SHA-256, puis l'installe avec le module d'installation d'Android (PackageInstaller), qui demande une
 * confirmation (pas de mise à jour sans écran : sa permission fait bloquer l'APK par Play Protect, cf.
 * AndroidManifest.xml). Canal « fr.applitransport/update » :
 *  - Dart → Android : « install » {url, sha256} → « started », « permission » (réglage ouvert) ;
 *  - Android → Dart : « progress » (0..1), « done » (null si réussi, sinon le message d'erreur).
 */
class UpdateInstaller(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "fr.applitransport/update")
    private val main = Handler(Looper.getMainLooper())
    private val action = "${activity.packageName}.MISE_A_JOUR"
    private var busy = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                // confirmation demandée par Android : son écran « Mettre à jour cette application ? »
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    @Suppress("DEPRECATION")
                    val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    if (confirm != null) activity.startActivity(confirm)
                }
                // réussi : Android arrête l'appli pour la remplacer, ce message n'arrive en général pas
                PackageInstaller.STATUS_SUCCESS -> finish(null)
                else -> finish(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "installation refusée")
            }
        }
    }

    init {
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(receiver, filter)
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> {
                    if (busy) return@setMethodCallHandler result.success("started")
                    // première fois : autoriser AppliTransport à installer des applications
                    if (!activity.packageManager.canRequestPackageInstalls()) {
                        activity.startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
                        )
                        return@setMethodCallHandler result.success("permission")
                    }
                    val url = call.argument<String>("url")!!
                    val sha = call.argument<String>("sha256")
                    busy = true
                    result.success("started")
                    Thread { run(url, sha) }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() = runCatching { activity.unregisterReceiver(receiver) }

    private fun finish(error: String?) = main.post {
        busy = false
        channel.invokeMethod("done", error)
    }

    private fun progress(f: Double) = main.post { channel.invokeMethod("progress", f) }

    /** Téléchargement, contrôle de l'empreinte, puis installation (fil d'exécution à part). */
    private fun run(url: String, sha256: String?) {
        val file = File(activity.cacheDir, "mise-a-jour.apk")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            val c = URL(url).openConnection() as HttpURLConnection
            c.instanceFollowRedirects = true
            c.connectTimeout = 15_000
            c.readTimeout = 30_000
            if (c.responseCode != 200) throw Exception("téléchargement : HTTP ${c.responseCode}")
            val total = c.contentLengthLong
            var done = 0L
            var last = -1
            c.inputStream.use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        digest.update(buf, 0, n)
                        done += n
                        if (total > 0) {
                            val pct = (done * 100 / total).toInt()
                            if (pct != last) { last = pct; progress(pct / 100.0) }
                        }
                    }
                }
            }
            val got = digest.digest().joinToString("") { "%02x".format(it) }
            if (sha256 != null && !got.equals(sha256, ignoreCase = true)) {
                throw Exception("fichier altéré (empreinte SHA-256 différente de celle de la Release)")
            }
            install(file)
        } catch (e: Exception) {
            file.delete()
            finish(e.message ?: e.toString())
        }
    }

    private fun install(apk: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(activity.packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("applitransport.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            apk.delete()
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val pi = PendingIntent.getBroadcast(
                activity, id, Intent(action).setPackage(activity.packageName), flags
            )
            session.commit(pi.intentSender)
        }
    }
}
