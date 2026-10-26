package com.bilibeats.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.Settings
import android.webkit.CookieManager
import androidx.core.app.ActivityCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val pickRequest = 2001
    private var localChannel: MethodChannel? = null
    private var pendingPick: MethodChannel.Result? = null

    /// Audio files handed to the app (opened with or shared to BiliBeats)
    /// and not yet asked for by Dart.
    private val opened = mutableListOf<Uri>()
    private val copying = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        // From the recents list the launching intent comes again: its file
        // was already taken.
        if (savedInstanceState == null &&
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
        ) {
            takeAudio(intent)
        }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (takeAudio(intent)) localChannel?.invokeMethod("opened", null)
    }

    /// Notes the audio files [intent] carries; true when it carries any.
    private fun takeAudio(intent: Intent?): Boolean {
        if (intent == null) return false
        val uris = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(streamOf(intent))
            else -> emptyList()
        }
        opened.addAll(uris)
        return uris.isNotEmpty()
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }

    /// Copies [uris] off the main thread, then answers [result] with what
    /// each became (see LocalAudio.copy).
    private fun copyAll(uris: List<Uri>, result: MethodChannel.Result) {
        if (uris.isEmpty()) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        copying.execute {
            val copies = uris.map { LocalAudio.copy(applicationContext, it) }
            main.post { result.success(copies) }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val uris = mutableListOf<Uri>()
        if (resultCode == RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            } else {
                data.data?.let { uris.add(it) }
            }
        }
        copyAll(uris, result)
    }

    /// The system's document picker, for audio, several at a time.
    @Suppress("DEPRECATION")
    private fun pickAudio(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A pick is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("audio/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        try {
            pendingPick = result
            startActivityForResult(intent, pickRequest)
        } catch (_: ActivityNotFoundException) {
            pendingPick = null
            result.success(null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "bilibeats/local",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> pickAudio(result)
                    "takeOpened" -> {
                        val uris = opened.toList()
                        opened.clear()
                        copyAll(uris, result)
                    }
                    else -> result.notImplemented()
                }
            }
            // The engine outlives this activity (audio_service keeps it
            // for playback): when it is already running, Dart's start-up
            // does not come again to ask for the file that opened us.
            if (opened.isNotEmpty()) invokeMethod("opened", null)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "bilibeats/permissions",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotifications" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "releaseMediaService" -> {
                    releaseMediaService(leaveForeground = true)
                    result.success(null)
                }
                "releaseMediaWakeLock" -> {
                    releaseMediaService(leaveForeground = false)
                    result.success(null)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(requestIgnoreBatteryOptimizations())
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "bilibeats/files",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openAudioFolder" -> result.success(openAudioFolder())
                "notifyAudioFiles" -> {
                    AudioFilesProvider.notifyChanged(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // The in-app Bilibili login (a WebView): its session cookie is
        // HttpOnly, out of reach of the page's script, so it is read here.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "bilibeats/account",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "cookies" -> {
                    val url = call.argument<String>("url") ?: "https://www.bilibili.com"
                    result.success(CookieManager.getInstance().getCookie(url) ?: "")
                }
                "openInBilibili" -> {
                    result.success(openInBilibili(call.argument<String>("url") ?: ""))
                }
                "clearCookies" -> {
                    CookieManager.getInstance().removeAllCookies { _ ->
                        CookieManager.getInstance().flush()
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Opens the songs' folder (AudioFilesProvider) in the system Files app:
    /// its root, else the folder itself. False when no app takes either —
    /// the location is then still in the Files app's side menu.
    private fun openAudioFolder(): Boolean {
        val authority = AudioFilesProvider.authority(this)
        val attempts = listOf(
            Intent(Intent.ACTION_VIEW).setDataAndType(
                DocumentsContract.buildRootUri(authority, AudioFilesProvider.ROOT_ID),
                DocumentsContract.Root.MIME_TYPE_ITEM,
            ),
            Intent(Intent.ACTION_VIEW).setDataAndType(
                DocumentsContract.buildDocumentUri(authority, AudioFilesProvider.FOLDER_ID),
                DocumentsContract.Document.MIME_TYPE_DIR,
            ),
        )
        for (intent in attempts) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                return true
            } catch (_: ActivityNotFoundException) {
            } catch (_: SecurityException) {
            }
        }
        return false
    }

    /// Opens [url] in the Bilibili app's own browser, where the app's session
    /// is at hand (the login code's confirmation page). False when no
    /// Bilibili app is installed.
    private fun openInBilibili(url: String): Boolean {
        if (url.isEmpty()) return false
        val target = Uri.parse("bilibili://browser")
            .buildUpon()
            .appendQueryParameter("url", url)
            .build()
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, target))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    /// The handler has stopped playback for good (a long pause). While this
    /// activity exists the plugin's service stays bound, so stopSelf() does
    /// not destroy it, and destruction is the only place it gives up the
    /// foreground and its wake lock. Neither is exposed, hence reflection;
    /// if the plugin changes this simply does nothing.
    private fun releaseMediaService(leaveForeground: Boolean) {
        try {
            val cls = Class.forName("com.ryanheise.audioservice.AudioService")
            val field = cls.getDeclaredField("instance").apply { isAccessible = true }
            val service = field.get(null) as? android.app.Service ?: return
            if (leaveForeground) {
                @Suppress("DEPRECATION")
                service.stopForeground(true)
            }
            cls.getDeclaredMethod("releaseWakeLock")
                .apply { isAccessible = true }
                .invoke(service)
        } catch (_: Throwable) {
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /// Several OEM builds (MIUI, EMUI, ColorOS, …) kill background media apps
    /// that are under battery optimization even while they play. Asking to be
    /// exempted is the standard remedy; the user confirms in a system dialog.
    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName")),
            )
            false
        } catch (e: Exception) {
            // Some builds hide the direct dialog; fall back to the list.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
            false
        }
    }

    /// Android 13+ gates notifications behind a runtime grant. Stock Android
    /// exempts media-session notifications, but stricter OEM builds do not, so
    /// ask up front instead of discovering the missing permission on release.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                1001,
            )
        }
    }
}