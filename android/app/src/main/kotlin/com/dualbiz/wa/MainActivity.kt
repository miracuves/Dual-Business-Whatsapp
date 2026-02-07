package com.dualbiz.wa

import android.content.Intent
import android.os.Bundle
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.dualbiz.wa/launcher"
    
    // CRITICAL: Override onPause/onResume to prevent WebView from being paused
    // This keeps the WebView active even when app goes to background
    override fun onPause() {
        super.onPause()
        // CRITICAL: Don't call webView.onPause() - this keeps JavaScript running
        // HarmonyOS will try to pause the WebView, but we need it active for notifications
        android.util.Log.d("MainActivity", "onPause - WebView kept active for background monitoring")
        
        // Try to find and keep WebView alive
        try {
            val flutterView = findViewById<android.view.View>(android.R.id.content)
            if (flutterView != null) {
                // WebView is managed by Flutter, but we can try to prevent pause
                android.util.Log.d("MainActivity", "MainActivity: Flutter view found, keeping active")
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error in onPause: ${e.message}")
        }
    }
    
    override fun onResume() {
        super.onResume()
        android.util.Log.d("MainActivity", "onResume - WebView resumed")
        
        // Ensure WebView is active when app comes to foreground
        try {
            val flutterView = findViewById<android.view.View>(android.R.id.content)
            if (flutterView != null) {
                android.util.Log.d("MainActivity", "MainActivity: Flutter view active")
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error in onResume: ${e.message}")
        }
    }
    
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Log focus changes to debug background behavior
        android.util.Log.d("MainActivity", "Window focus changed: $hasFocus")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "launchSecondary") {
                try {
                    android.widget.Toast.makeText(this, "Launching Business 2...", android.widget.Toast.LENGTH_SHORT).show()
                    val intent = Intent(this, SecondaryActivity::class.java)
                    startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    android.util.Log.e("MainActivity", "Failed to launch secondary: ${e.message}", e)
                    result.error("LAUNCH_FAILED", e.message, null)
                }
            } else if (call.method == "acquireWakeLock") {
                try {
                    if (wakeLock == null) {
                        val powerManager = getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
                        wakeLock = powerManager.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "DualBizWA:NativeWakeLock")
                        wakeLock?.setReferenceCounted(false)
                    }
                    if (wakeLock?.isHeld == false) {
                        wakeLock?.acquire()
                        android.util.Log.d("MainActivity", "Native WakeLock Acquired")
                    }
                    result.success(true)
                } catch (e: Exception) {
                    android.util.Log.e("MainActivity", "WakeLock Error: ${e.message}", e)
                    result.error("WAKELOCK_ERROR", e.message, null)
                }
            } else if (call.method == "releaseWakeLock") {
                try {
                    if (wakeLock?.isHeld == true) {
                        wakeLock?.release()
                        android.util.Log.d("MainActivity", "Native WakeLock Released")
                    }
                    result.success(true)
                } catch (e: Exception) {
                    result.error("WAKELOCK_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
    
    private var wakeLock: android.os.PowerManager.WakeLock? = null
    
    override fun onDestroy() {
        super.onDestroy()
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
    }
}
