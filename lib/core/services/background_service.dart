import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart'; // REQUIRED FOR METHOD CHANNEL
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackgroundServiceHelper {
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    // Notification Channel setup
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'wa_service_channel', // id
      'Background Service', // title
      description: 'Keeps the Dual WA App running', // description
      importance: Importance.low, // low importance to not annoy user
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        // This will be executed in the separate isolate
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: 'wa_service_channel', // must match above
        initialNotificationTitle: 'Dual WA Service',
        initialNotificationContent: 'Monitoring for new messages...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
      ),
    );
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    // Only available for flutter 3.0.0 and later
    DartPluginRegistrant.ensureInitialized();
    
    // Check if we are in foreground mode
    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });
      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    // NATIVE WAKELOCK: Acquire for HarmonyOS compatibility
    // CRITICAL: Must release on service stop to prevent battery drain
    // Wait a moment for native method channels to be ready
    await Future.delayed(const Duration(seconds: 2));
    try {
        const platform = MethodChannel('com.dualbiz.wa/launcher');
        await platform.invokeMethod('acquireWakeLock');
        print("BgService: Native WakeLock acquired");
    } catch (e) {
        // WakeLock might not be available immediately - will retry if needed
        if (e.toString().contains('MissingPluginException')) {
          print("BgService: WakeLock method channel not ready yet (will retry)");
        } else {
          print("BgService: Failed to acquire Native WakeLock: $e");
        }
    }

    // CRITICAL: Poll WebView titles from background service
    // This runs in a separate isolate that HarmonyOS won't pause
    Timer? webViewPollTimer;
    Timer? updateTimer;

    // Wait a bit for method channels to be set up in main app
    // Method channels are registered in initState, so give it time
    await Future.delayed(const Duration(seconds: 5));

    // Poll WebView titles every 10 seconds when app is in background
    // Use method channel to request main app to check WebView titles
    webViewPollTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      try {
        // Check session 1 (main app)
        try {
          const platform1 = MethodChannel('com.dualbiz.wa/webview_monitor');
          await platform1.invokeMethod('checkWebViewTitles');
          print("BgService: Requested session 1 WebView title check");
        } catch (e) {
          // Silently handle - method channel might not be ready yet
          // This is expected during app startup
          if (e.toString().contains('MissingPluginException')) {
            // Method channel not ready yet - will retry on next poll
            print("BgService: Method channel not ready yet for session 1 (will retry)");
          } else {
            print("BgService: Error checking session 1: $e");
          }
        }
        
        // Check session 2 (secondary app) - separate process
        try {
          const platform2 = MethodChannel('com.dualbiz.wa/webview_monitor_secondary');
          await platform2.invokeMethod('checkWebViewTitles');
          print("BgService: Requested session 2 WebView title check");
        } catch (e) {
          // Silently handle - method channel might not be ready yet
          if (e.toString().contains('MissingPluginException')) {
            print("BgService: Method channel not ready yet for session 2 (will retry)");
          } else {
            print("BgService: Error checking session 2: $e");
          }
        }
      } catch (e) {
        print("BgService: Error in WebView polling: $e");
      }
    });

    // Update service every 30 seconds to keep it alive
    updateTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          try {
            // Update service to keep it alive
            service.invoke(
              'update',
              {
                "current_date": DateTime.now().toIso8601String(),
                "status": "monitoring",
              },
            );
          } catch (e) {
            print("BgService: Error updating service: $e");
          }
        }
      }
    });

    // SINGLE stopService listener - handles WakeLock release and all timer cleanup
    service.on('stopService').listen((event) async {
      // Cancel all timers
      webViewPollTimer?.cancel();
      webViewPollTimer = null;
      updateTimer?.cancel();
      updateTimer = null;
      
      // Release WakeLock
      try {
        const platform = MethodChannel('com.dualbiz.wa/launcher');
        await platform.invokeMethod('releaseWakeLock');
        print("BgService: Native WakeLock released");
      } catch (e) {
        print("BgService: Error releasing WakeLock: $e");
      }
      
      // Stop the service
      service.stopSelf();
    });
  }
}
