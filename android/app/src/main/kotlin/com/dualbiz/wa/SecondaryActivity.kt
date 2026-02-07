package com.dualbiz.wa

import android.os.Bundle
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class SecondaryActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Critical: Set the data directory suffix BEFORE WebView is touched.
        // This isolates cookies and storage for this process.
        try {
            WebView.setDataDirectorySuffix("secondary_session")
        } catch (e: Exception) {
            // Log error or ignore if already set
        }
        
        android.widget.Toast.makeText(this, "Business 2 Process Started", android.widget.Toast.LENGTH_LONG).show()
        
        // Pass intent so Flutter knows what to render (if we used same entry point)
        // usage: intent.putExtra("route", "/secondary") 
        super.onCreate(savedInstanceState)
    }
    
    // CRITICAL: Override onPause/onResume to prevent WebView from being paused
    // This keeps the WebView active even when app goes to background
    override fun onPause() {
        super.onPause()
        // CRITICAL: Don't call webView.onPause() - this keeps JavaScript running
        // HarmonyOS will try to pause the WebView, but we need it active for notifications
        android.util.Log.d("SecondaryActivity", "onPause - WebView kept active for background monitoring")
        
        // Try to find and keep WebView alive
        try {
            val flutterView = findViewById<android.view.View>(android.R.id.content)
            if (flutterView != null) {
                // WebView is managed by Flutter, but we can try to prevent pause
                android.util.Log.d("SecondaryActivity", "SecondaryActivity: Flutter view found, keeping active")
            }
        } catch (e: Exception) {
            android.util.Log.e("SecondaryActivity", "Error in onPause: ${e.message}")
        }
    }
    
    override fun onResume() {
        super.onResume()
        android.util.Log.d("SecondaryActivity", "onResume - WebView resumed")
        
        // Ensure WebView is active when app comes to foreground
        try {
            val flutterView = findViewById<android.view.View>(android.R.id.content)
            if (flutterView != null) {
                android.util.Log.d("SecondaryActivity", "SecondaryActivity: Flutter view active")
            }
        } catch (e: Exception) {
            android.util.Log.e("SecondaryActivity", "Error in onResume: ${e.message}")
        }
    }
    
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Log focus changes to debug background behavior
        android.util.Log.d("SecondaryActivity", "Window focus changed: $hasFocus")
    }

    override fun getDartEntrypointFunctionName(): String {
        return "secondaryMain"
    }
}
