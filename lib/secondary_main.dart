import 'dart:async';
import 'dart:convert'; // For JSON parsing
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:dual_biz_wa/core/theme/app_theme.dart';
import 'package:dual_biz_wa/features/webview/widgets/webview_container.dart';
import 'package:dual_biz_wa/core/services/webview_monitor.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// Unified notification channel ID - must match main app
const String _secondaryNotificationChannelId = 'wa_messages_channel';
const String _secondaryNotificationChannelName = 'WhatsApp Messages';
const String _secondaryNotificationChannelDescription = 'Notifications for new WhatsApp messages';

/// Top-level function to handle notification action button taps for secondary app
void _handleSecondaryNotificationAction(String actionId, int notificationId, String? payload) {
  debugPrint("Secondary: Notification action tapped: $actionId for notification $notificationId");
  
  switch (actionId) {
    case 'action_reply':
      // Open app to reply
      debugPrint("Secondary: Reply action - opening app");
      break;
    case 'action_mark_read':
      // Mark as read - dismiss notification
      flutterLocalNotificationsPlugin.cancel(notificationId);
      debugPrint("Secondary: Mark as read - notification dismissed");
      break;
    default:
      debugPrint("Secondary: Unknown action: $actionId");
  }
}

class SecondaryApp extends StatelessWidget {
  const SecondaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MCX WhatZ - Business 2',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const SecondaryDashboard(),
    );
  }
}

class SecondaryDashboard extends StatefulWidget {
  const SecondaryDashboard({super.key});

  @override
  State<SecondaryDashboard> createState() => _SecondaryDashboardState();
}

class _SecondaryDashboardState extends State<SecondaryDashboard> with WidgetsBindingObserver {
  final GlobalKey<WebViewContainerState> _webKey = GlobalKey();
  String _label2 = 'Business 2'; // Load from preferences
  final WebViewMonitor _webViewMonitor = WebViewMonitor();
  Timer? _backgroundPollTimer;
  AppLifecycleState? _lastLifecycleState;
  
  // Duplicate notification prevention
  String? _lastNotificationContent;
  DateTime? _lastNotificationTime;
  static const Duration _notificationCooldown = Duration(seconds: 5); // Prevent duplicates within 5 seconds
  static const int _secondaryNotificationId = 1002; // Unique ID for session 2 (1000+2)
  
  // Notification settings
  bool _notificationPersist = false;
  String _notificationSound = 'default';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Load label and settings from preferences (must match main app)
    _loadSettings();
    // Ensure notification channel is created on init
    _ensureNotificationChannel();
    _setupMethodChannel(); // Setup method channel for background service communication
  }
  
  /// Setup method channel for background service to request WebView checks
  void _setupMethodChannel() {
    const platform = MethodChannel('com.dualbiz.wa/webview_monitor_secondary');
    platform.setMethodCallHandler((call) async {
      if (call.method == 'checkWebViewTitles') {
        // Background service is requesting a WebView title check
        await _checkWebViewTitlesForBackground();
        return {'success': true};
      }
      return {'success': false, 'error': 'Unknown method'};
    });
    debugPrint("Secondary: Method channel 'com.dualbiz.wa/webview_monitor_secondary' setup complete");
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundPollTimer?.cancel();
    _backgroundPollTimer = null;
    super.dispose();
  }
  
  /// Check WebView titles when requested by background service
  Future<void> _checkWebViewTitlesForBackground() async {
    try {
      // Reload settings in case they changed
      final prefs = await SharedPreferences.getInstance();
      final bool monitor2 = prefs.getBool('monitor_session_2') ?? true;
      
      // Check session 2 (secondary app WebView)
      if (monitor2) {
        final newTitle = await _webViewMonitor.checkSession2();
        if (newTitle != null) {
          // Get full message data for rich notification
          // Specify sessionId: 2 to use session2 controller
          final messageData = await _webViewMonitor.getMessageData(null, sessionId: 2);
          await _handleBackgroundTitleChange(newTitle, messageData);
        }
      }
    } catch (e) {
      debugPrint("Secondary: Error checking WebView titles from background: $e");
    }
  }
  
  /// Handle title change detected from background polling
  Future<void> _handleBackgroundTitleChange(String title, Map<String, dynamic>? messageData) async {
    try {
      String senderName = '';
      String messageText = '';
      int unreadCount = 1;
      
      if (messageData != null) {
        senderName = messageData['senderName']?.toString() ?? '';
        messageText = messageData['messageText']?.toString() ?? '';
        unreadCount = messageData['unreadCount'] as int? ?? 1;
      } else {
        // Parse from title
        final RegExp unreadRegex = RegExp(r'\((\d+)\)');
        final match = unreadRegex.firstMatch(title);
        if (match != null) {
          unreadCount = int.tryParse(match.group(1) ?? '1') ?? 1;
        }
      }
      
      // Build notification
      String notificationTitle;
      String notificationBody;
      
      if (senderName.isNotEmpty && messageText.isNotEmpty) {
        notificationTitle = '$_label2 - $senderName';
        notificationBody = messageText;
        if (unreadCount > 1) {
          notificationBody = '[$unreadCount messages] $messageText';
        }
      } else {
        notificationTitle = _label2;
        notificationBody = unreadCount > 1 
            ? '$unreadCount new messages'
            : 'New message';
      }
      
      _showNotification(notificationTitle, notificationBody);
    } catch (e) {
      debugPrint("Secondary: Error handling background title change: $e");
    }
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lastLifecycleState = state;
    
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // App went to background - background service will handle polling
      // But we also keep a local timer as backup
      debugPrint("Secondary: App went to background - background service will poll WebView");
      _startBackgroundPolling();
    } else if (state == AppLifecycleState.resumed) {
      // App came to foreground - stop local polling, JavaScript MutationObserver will handle
      debugPrint("Secondary: App resumed - stopping local polling, JavaScript monitoring active");
      _stopBackgroundPolling();
    }
  }
  
  /// Start local polling WebView titles when app is in background (backup mechanism)
  /// Primary polling is done by background service via method channel
  void _startBackgroundPolling() {
    _stopBackgroundPolling(); // Cancel any existing timer
    
    // Local polling as backup (every 20 seconds)
    // Primary polling is done by background service every 10 seconds
    _backgroundPollTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      await _checkWebViewTitlesForBackground();
    });
    debugPrint("Secondary: Local background polling started (every 20 seconds) as backup");
  }
  
  /// Stop local polling when app comes to foreground
  void _stopBackgroundPolling() {
    _backgroundPollTimer?.cancel();
    _backgroundPollTimer = null;
    debugPrint("Secondary: Local background polling stopped");
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _label2 = prefs.getString('label_2') ?? 'Business 2';
        _notificationPersist = prefs.getBool('notification_persist') ?? false;
        _notificationSound = prefs.getString('notification_sound') ?? 'default';
      });
    }
    
    // Apply sync interval to WebView after it loads
    // Delay to ensure WebView is ready
    Future.delayed(const Duration(seconds: 3), () {
      final syncInterval = prefs.getInt('sync_interval') ?? 0;
      _webKey.currentState?.setSyncInterval(syncInterval);
      debugPrint("Secondary: Applied sync interval: $syncInterval");
    });
  }
  
  /// Handle notification action button taps
  void _handleNotificationAction(String actionId, int notificationId, String? payload) {
    debugPrint("Secondary: Notification action tapped: $actionId for notification $notificationId");
    
    switch (actionId) {
      case 'action_reply':
        // Open app to reply
        debugPrint("Secondary: Reply action - opening app");
        break;
      case 'action_mark_read':
        // Mark as read - dismiss notification
        flutterLocalNotificationsPlugin.cancel(notificationId);
        debugPrint("Secondary: Mark as read - notification dismissed");
        break;
      default:
        debugPrint("Secondary: Unknown action: $actionId");
    }
  }

  // Ensure notification channel exists - call this before showing any notification
  // CRITICAL: Creating channel multiple times is safe - it won't reset user preferences
  // HarmonyOS-friendly: Just create it, Android handles duplicates gracefully
  Future<void> _ensureNotificationChannel() async {
    final androidImplementation = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidImplementation == null) {
      debugPrint("Secondary: Android notification implementation not available");
      return;
    }
    
    try {
      // Create channel - safe to call multiple times, won't reset user preferences
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        _secondaryNotificationChannelId,
        _secondaryNotificationChannelName,
        description: _secondaryNotificationChannelDescription,
        importance: Importance.max, // MAX for heads-up notifications
        playSound: true,
        enableVibration: true,
        enableLights: true,
        showBadge: true, // Show badge on app icon
      );
      
      await androidImplementation.createNotificationChannel(channel);
      debugPrint("Secondary notification channel ensured: $_secondaryNotificationChannelId");
    } catch (e) {
      debugPrint("Error ensuring secondary notification channel: $e");
    }
  }

  // Notification display function - properly configured for HarmonyOS/MicroG
  Future<void> _showNotification(String title, String body) async {
    // Duplicate notification prevention
    final String notificationKey = '$title|$body';
    final DateTime now = DateTime.now();
    
    if (_lastNotificationContent == notificationKey && 
        _lastNotificationTime != null &&
        now.difference(_lastNotificationTime!) < _notificationCooldown) {
      debugPrint("Secondary: Duplicate notification prevented: $title");
      return; // Skip duplicate notification
    }
    
    // Update last notification tracking
    _lastNotificationContent = notificationKey;
    _lastNotificationTime = now;
    
    // Check notification permission first (critical for HarmonyOS)
    final notificationStatus = await Permission.notification.status;
    if (!notificationStatus.isGranted) {
      debugPrint("Secondary: Notification permission not granted");
      return;
    }
    
    // Ensure channel exists before showing notification
    await _ensureNotificationChannel();

    // Create BigText style for expandable notifications
    final BigTextStyleInformation bigTextStyleInformation =
        BigTextStyleInformation(
          body, 
          htmlFormatBigText: false, // Disable HTML for better compatibility
          contentTitle: title, 
          htmlFormatContentTitle: false,
          summaryText: 'New WhatsApp Message',
        );

    // Configure notification sound
    dynamic soundConfig;
    if (_notificationSound == 'default' || _notificationSound.isEmpty) {
      soundConfig = true; // Use system default
    } else {
      // Use custom sound (must be in android/app/src/main/res/raw/)
      soundConfig = RawResourceAndroidNotificationSound(_notificationSound);
    }

    // Create notification actions
    final List<AndroidNotificationAction> actions = [
      AndroidNotificationAction(
        'action_reply',
        'Reply',
        titleColor: const Color(0xFFA70D2A),
        showsUserInterface: true, // Opens app for reply
      ),
      AndroidNotificationAction(
        'action_mark_read',
        'Mark as Read',
        titleColor: const Color(0xFFA70D2A),
        cancelNotification: true, // Dismisses notification
      ),
    ];

    // Create notification details with proper configuration for HarmonyOS/MicroG
    // Configured for POP-UP BANNERS (heads-up notifications)
    final AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          _secondaryNotificationChannelId, // MUST match channel ID
          _secondaryNotificationChannelName,
          channelDescription: _secondaryNotificationChannelDescription,
          importance: Importance.max, // MAX = Heads-up pop-up banner (required!)
          priority: Priority.max, // MAX priority = Immediate pop-up display (required!)
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public, // Show on lock screen
          ticker: 'New WhatsApp Message',
          icon: '@mipmap/launcher_icon', // Use launcher icon (always exists)
          styleInformation: bigTextStyleInformation, // Expandable notification with message content
          color: const Color(0xFFA70D2A), // Brand Red
          ledColor: const Color(0xFFA70D2A),
          ledOnMs: 1000,
          ledOffMs: 500,
          enableLights: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 250, 200, 250]), // Short vibration pattern
          playSound: soundConfig, // Custom or default sound
          showWhen: true, // Show timestamp
          when: DateTime.now().millisecondsSinceEpoch,
          autoCancel: !_notificationPersist, // Auto-dismiss based on setting
          ongoing: false, // Not ongoing notification
          onlyAlertOnce: false, // Alert every time (important for multiple messages)
          channelShowBadge: true, // Show badge on channel
          fullScreenIntent: false, // Don't use full screen (banner is better)
          // Additional properties for HarmonyOS compatibility
          timeoutAfter: null, // Don't auto-dismiss (user can dismiss manually)
          groupKey: 'wa_messages_group', // Group related notifications
          setAsGroupSummary: false,
          actions: actions, // Add action buttons
        );

    final NotificationDetails notificationDetails =
        NotificationDetails(android: androidNotificationDetails);
    
    // Retry logic for HarmonyOS compatibility
    int retryCount = 0;
    const maxRetries = 2;
    
    while (retryCount <= maxRetries) {
      try {
        await flutterLocalNotificationsPlugin.show(
          _secondaryNotificationId, // Use unique ID (1002)
          title, 
          body, 
          notificationDetails,
        );
        debugPrint("Secondary notification shown successfully: $title (ID: $_secondaryNotificationId, attempt ${retryCount + 1})");
        return; // Success
      } catch (e) {
        retryCount++;
        debugPrint("Error showing secondary notification (attempt $retryCount): $e");
        
        if (retryCount > maxRetries) {
          // Final fallback
          try {
            final AndroidNotificationDetails fallbackDetails =
                AndroidNotificationDetails(
                  _secondaryNotificationChannelId,
                  _secondaryNotificationChannelName,
                  channelDescription: _secondaryNotificationChannelDescription,
                  importance: Importance.max,
                  priority: Priority.max,
                  icon: '@mipmap/launcher_icon',
                  color: const Color(0xFFA70D2A),
                );
            await flutterLocalNotificationsPlugin.show(
              _secondaryNotificationId, // Use unique ID (1002)
              title,
              body,
              NotificationDetails(android: fallbackDetails),
            );
            debugPrint("Secondary notification shown with fallback (ID: $_secondaryNotificationId)");
          } catch (e2) {
            debugPrint("All secondary notification attempts failed: $e2");
          }
        } else {
          await Future.delayed(Duration(milliseconds: 200 * retryCount));
        }
      }
    }
  }

  static const String _unreadCount2Key = 'unread_count_2';

  void _handleTitleChange(String data) async {
    try {
      Map<String, dynamic>? messageData;
      try {
        messageData = jsonDecode(data) as Map<String, dynamic>?;
      } catch (e) {
        messageData = null;
      }

      String title = data;
      String senderName = '';
      String messageText = '';
      int unreadCount = 0;

      if (messageData != null) {
        title = messageData['title']?.toString() ?? data;
        senderName = messageData['senderName']?.toString() ?? '';
        messageText = messageData['messageText']?.toString() ?? '';
        unreadCount = messageData['unreadCount'] as int? ?? 0;
      } else {
        final RegExp unreadRegex = RegExp(r'\((\d+)\)');
        final match = unreadRegex.firstMatch(title);
        if (match != null) {
          unreadCount = int.tryParse(match.group(1) ?? '0') ?? 0;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      await prefs.setInt(_unreadCount2Key, unreadCount); // For main app tab badge

      final bool monitor = prefs.getBool('monitor_session_2') ?? true;
      if (unreadCount <= 0 || !monitor) return;

      // Build notification with message details
      String notificationTitle;
      String notificationBody;
      
      // Reload label in case it was changed in main app
      await _loadSettings();
      
      if (senderName.isNotEmpty && messageText.isNotEmpty) {
        // Show sender name and message preview with actual label
        notificationTitle = '$_label2 - $senderName';
        notificationBody = messageText;
        if (unreadCount > 1) {
          notificationBody = '[$unreadCount messages] $messageText';
        }
      } else {
        // Fallback: show business name and unread count
        notificationTitle = _label2;
        notificationBody = unreadCount > 1 
            ? '$unreadCount new messages'
            : 'New message';
      }
      
      _showNotification(notificationTitle, notificationBody);
    } catch (e) {
      debugPrint("Error handling title change in secondary: $e");
      final RegExp unreadRegex = RegExp(r'\((\d+)\)');
      final match = unreadRegex.firstMatch(data);
      if (match != null) {
        final int n = int.tryParse(match.group(1) ?? '0') ?? 0;
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        await prefs.setInt(_unreadCount2Key, n);
        final bool monitor = prefs.getBool('monitor_session_2') ?? true;
        if (monitor) {
          await _loadSettings();
          _showNotification("$_label2 Message", data);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
        appBar: AppBar(
          title: Text('MCX WhatZ - $_label2'),
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          leading: Semantics(
            label: 'Back to main app',
            button: true,
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => SystemNavigator.pop(),
            ),
          ),
          actions: [
            Semantics(
              label: 'Reload page',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _webKey.currentState?.reload(),
              ),
            ),
          ],
        ),
        body: WebViewContainer(
           key: _webKey,
           sessionId: 'session_2',
           onTitleChanged: _handleTitleChange, 
        )
     );
  }
}
