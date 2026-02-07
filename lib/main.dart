import 'dart:async';
import 'dart:convert'; // For JSON parsing
import 'dart:typed_data'; // Required for Int64List
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:dual_biz_wa/core/theme/app_theme.dart';
import 'package:dual_biz_wa/features/webview/widgets/webview_container.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:dual_biz_wa/core/services/background_service.dart';
import 'package:dual_biz_wa/core/services/webview_monitor.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:dual_biz_wa/secondary_main.dart'; // Import Secondary App

// Global notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

/// Top-level function to handle notification action button taps
void _handleNotificationAction(String actionId, int notificationId, String? payload) {
  debugPrint("Notification action tapped: $actionId for notification $notificationId");
  
  switch (actionId) {
    case 'action_reply':
      // Open app to reply (could be enhanced to show reply dialog)
      debugPrint("Reply action - opening app");
      // App will open when notification is tapped
      break;
    case 'action_mark_read':
      // Mark as read - dismiss notification
      flutterLocalNotificationsPlugin.cancel(notificationId);
      debugPrint("Mark as read - notification dismissed");
      break;
    default:
      debugPrint("Unknown action: $actionId");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notifications with proper error handling
  try {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/launcher_icon');
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Handle notification tap and actions
        debugPrint("Notification response: ID=${response.id}, Action=${response.actionId}, Payload=${response.payload}");
        
        // Handle notification actions
        if (response.actionId != null) {
          _handleNotificationAction(response.actionId!, response.id ?? 0, response.payload);
        } else {
          // Notification tapped - open app
          debugPrint("Notification tapped: ${response.id}");
        }
      },
    );
    debugPrint("Notifications initialized successfully");
  } catch (e) {
    debugPrint("Error initializing notifications: $e");
    // Continue anyway - app should still work
  }
  
  // Initialize Background Service
  await BackgroundServiceHelper.initializeService();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MCX WhatZ',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const MainDashboard(),
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final GlobalKey<WebViewContainerState> _key1 = GlobalKey();
  final GlobalKey<WebViewContainerState> _key2 = GlobalKey();
  
  String _label1 = 'Business 1';
  String _label2 = 'Business 2';

  bool _monitorSession1 = true;
  bool _monitorSession2 = true;
  bool _enableTab2 = true; // Enable/disable Business Tab 2 visibility
  bool _notificationPersist = false; // Keep notifications (don't auto-cancel)
  String _notificationSound = 'default'; // 'default' or custom sound name

  int _syncInterval = 0; // 0 = Continuous, 30, 60, 300

  /// Unread message counts for tab badges (session 2 count synced via SharedPreferences).
  int _unreadCount1 = 0;
  int _unreadCount2 = 0;
  
  final WebViewMonitor _webViewMonitor = WebViewMonitor();
  Timer? _backgroundPollTimer;
  AppLifecycleState? _lastLifecycleState;
  
  // Duplicate notification prevention
  String? _lastNotificationContent;
  DateTime? _lastNotificationTime;
  static const Duration _notificationCooldown = Duration(seconds: 5); // Prevent duplicates within 5 seconds

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _loadLabels();
    _loadSettings();
    _loadUnreadCount2(); // Session 2 unread is written by secondary process
    _setupMethodChannel(); // Setup method channel for background service communication
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundPollTimer?.cancel();
    _backgroundPollTimer = null;
    super.dispose();
  }
  
  /// Setup method channel for background service to request WebView checks
  void _setupMethodChannel() {
    try {
      const platform = MethodChannel('com.dualbiz.wa/webview_monitor');
      platform.setMethodCallHandler((call) async {
        try {
          if (call.method == 'checkWebViewTitles') {
            // Background service is requesting a WebView title check
            // Only check if widget is still mounted
            if (mounted) {
              await _checkWebViewTitlesForBackground();
            }
            return {'success': true};
          }
          return {'success': false, 'error': 'Unknown method'};
        } catch (e) {
          debugPrint("Error in method channel handler: $e");
          return {'success': false, 'error': e.toString()};
        }
      });
      debugPrint("Method channel 'com.dualbiz.wa/webview_monitor' setup complete");
    } catch (e) {
      debugPrint("Error setting up method channel: $e");
      // Don't crash - method channel is optional for background service
    }
  }

  /// Check WebView titles when requested by background service
  Future<void> _checkWebViewTitlesForBackground() async {
    try {
      // Only proceed if widget is still mounted
      if (!mounted) {
        return;
      }
      
      // Reload settings in case they changed
      final prefs = await SharedPreferences.getInstance();
      final bool monitor1 = prefs.getBool('monitor_session_1') ?? true;
      final bool monitor2 = prefs.getBool('monitor_session_2') ?? true;
      
      // Check session 1 (main app WebView)
      if (monitor1) {
        final newTitle = await _webViewMonitor.checkSession1();
        if (newTitle != null && mounted) {
          // Get full message data for rich notification
          // Specify sessionId: 1 to use session1 controller
          final messageData = await _webViewMonitor.getMessageData(null, sessionId: 1);
          if (mounted) {
            await _handleBackgroundTitleChange(newTitle, messageData, 0);
          }
        }
      }
      
      // Session 2 is in separate process, so we can't check it from here
      // The secondary app will handle its own background monitoring
    } catch (e) {
      debugPrint("Error checking WebView titles from background: $e");
      // Don't rethrow - this is called from background service
    }
  }
  
  /// Handle title change detected from background polling
  Future<void> _handleBackgroundTitleChange(String title, Map<String, dynamic>? messageData, int tabIndex) async {
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
      final String tabName = tabIndex == 0 ? _label1 : _label2;
      String notificationTitle;
      String notificationBody;
      
      if (senderName.isNotEmpty && messageText.isNotEmpty) {
        notificationTitle = '$tabName - $senderName';
        notificationBody = messageText;
        if (unreadCount > 1) {
          notificationBody = '[$unreadCount messages] $messageText';
        }
      } else {
        notificationTitle = tabName;
        notificationBody = unreadCount > 1 
            ? '$unreadCount new messages'
            : 'New message';
      }
      
      _showNotification(notificationTitle, notificationBody, tabIndex);
    } catch (e) {
      debugPrint("Error handling background title change: $e");
    }
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lastLifecycleState = state;
    
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // App went to background - background service will handle polling
      // But we also keep a local timer as backup
      debugPrint("App went to background - background service will poll WebView");
      _startBackgroundPolling();
    } else if (state == AppLifecycleState.resumed) {
      // App came to foreground - stop local polling, JavaScript MutationObserver will handle
      debugPrint("App resumed - stopping local polling, JavaScript monitoring active");
      _stopBackgroundPolling();
      _loadUnreadCount2(); // Refresh tab 2 badge (written by secondary process)
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
    debugPrint("Local background polling started (every 20 seconds) as backup");
  }
  
  /// Stop local polling when app comes to foreground
  void _stopBackgroundPolling() {
    _backgroundPollTimer?.cancel();
    _backgroundPollTimer = null;
    debugPrint("Local background polling stopped");
  }
  
  Future<void> _loadLabels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _label1 = prefs.getString('label_1') ?? 'Business 1';
          _label2 = prefs.getString('label_2') ?? 'Business 2';
        });
      }
    } catch (e) {
      debugPrint("Error loading labels: $e");
      // Use defaults if preferences fail
      if (mounted) {
        setState(() {
          _label1 = 'Business 1';
          _label2 = 'Business 2';
        });
      }
    }
  }

  static const String _unreadCount2Key = 'unread_count_2';

  Future<void> _loadUnreadCount2() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final count = prefs.getInt(_unreadCount2Key) ?? 0;
      if (mounted) setState(() => _unreadCount2 = count);
    } catch (e) {
      debugPrint("Error loading unread count 2: $e");
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bool enableTab2 = prefs.getBool('enable_tab_2') ?? true; // Default to enabled
      final bool monitor1 = prefs.getBool('monitor_session_1') ?? true;
      final bool monitor2 = prefs.getBool('monitor_session_2') ?? true;
      final bool notificationPersist = prefs.getBool('notification_persist') ?? false;
      final String notificationSound = prefs.getString('notification_sound') ?? 'default';
      final int syncInterval = prefs.getInt('sync_interval') ?? 0;
      final int unread2 = prefs.getInt(_unreadCount2Key) ?? 0;

      // If Tab 2 is being disabled and we're on Tab 2, switch to Tab 1 first
      int newIndex = _currentIndex;
      if (!enableTab2 && _currentIndex == 1) {
        newIndex = 0;
      }
      
      // Only update state if widget is still mounted
      if (mounted) {
        // Update all state in a single setState to avoid race conditions
        setState(() {
          _monitorSession1 = monitor1;
          _monitorSession2 = monitor2;
          _enableTab2 = enableTab2;
          _notificationPersist = notificationPersist;
          _notificationSound = notificationSound;
          _syncInterval = syncInterval;
          _unreadCount2 = unread2;
          _currentIndex = newIndex;
        });
      }
      
      // Apply initial state after a short delay to ensure WebView is ready
      // Retry multiple times in case WebView takes longer to load
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _applySyncSettings();
        }
      });
      // Additional retry after 5 seconds (for slow connections)
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          _applySyncSettings();
        }
      });
    } catch (e) {
      debugPrint("Error loading settings: $e");
      // Use defaults if preferences fail
      if (mounted) {
        setState(() {
          _monitorSession1 = true;
          _monitorSession2 = true;
          _enableTab2 = true;
          _notificationPersist = false;
          _notificationSound = 'default';
          _syncInterval = 0;
          // Ensure index is valid
          if (_currentIndex > 0) {
            _currentIndex = 0;
          }
        });
      }
    }
  }

  void _applySyncSettings() {
    try {
      // Apply sync interval to Tab 1 WebView
      // Tab 2 is in separate process, so it will apply its own settings
      _key1.currentState?.setSyncInterval(_syncInterval);
      debugPrint("Applied sync interval: $_syncInterval to session 1");
      // Note: Tab 2 (secondary process) applies settings independently via SharedPreferences
    } catch (e) {
      debugPrint("Error applying sync settings: $e");
      // Retry after delay
      Future.delayed(const Duration(seconds: 1), () {
        try {
          _key1.currentState?.setSyncInterval(_syncInterval);
        } catch (e2) {
          debugPrint("Retry failed: $e2");
        }
      });
    }
  }

  Future<void> _showRenameDialog() async {
    final TextEditingController c1 = TextEditingController(text: _label1);
    final TextEditingController c2 = TextEditingController(text: _label2);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Tabs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c1,
              decoration: const InputDecoration(labelText: 'Tab 1 Name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: c2,
              decoration: const InputDecoration(labelText: 'Tab 2 Name'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('label_1', c1.text);
              await prefs.setString('label_2', c2.text);
              
              setState(() {
                _label1 = c1.text;
                _label2 = c2.text;
              });
              
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    showDialog(
      context: context,
      builder: (context) {
        bool tempMonitor1 = _monitorSession1;
        bool tempMonitor2 = _monitorSession2;
        bool tempEnableTab2 = _enableTab2;
        int tempInterval = _syncInterval;

        bool tempNotificationPersist = _notificationPersist;
        String tempNotificationSound = _notificationSound;

        return StatefulBuilder(
            builder: (context, setDialogState) {
                return AlertDialog(
                    title: const Text('Settings'),
                    content: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Text('Tabs', style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            )),
                            SwitchListTile(
                                title: Text("Enable $_label2"),
                                subtitle: const Text("Show Business Tab 2 in navigation"),
                                value: tempEnableTab2,
                                onChanged: (val) => setDialogState(() => tempEnableTab2 = val),
                            ),
                            const Divider(),
                            Text('Notifications', style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            )),
                            SwitchListTile(
                                title: Text(_label1),
                                subtitle: const Text("Receive notifications for Business 1"),
                                value: tempMonitor1,
                                onChanged: (val) => setDialogState(() => tempMonitor1 = val),
                            ),
                            Opacity(
                              opacity: tempEnableTab2 ? 1.0 : 0.5,
                              child: SwitchListTile(
                                  title: Text(_label2),
                                  subtitle: const Text("Receive notifications for Business 2"),
                                  value: tempMonitor2,
                                  onChanged: tempEnableTab2 ? (val) => setDialogState(() => tempMonitor2 = val) : null,
                              ),
                            ),
                            if (!tempEnableTab2)
                              Padding(
                                padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                                child: Text(
                                  'Enable Tab 2 to configure notifications',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            const Divider(),
                            Text('Notification Options', style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            )),
                            SwitchListTile(
                                title: const Text("Keep Notifications"),
                                subtitle: const Text("Don't auto-dismiss notifications"),
                                value: tempNotificationPersist,
                                onChanged: (val) => setDialogState(() => tempNotificationPersist = val),
                            ),
                            const SizedBox(height: 8),
                            Text('Notification Sound', style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            )),
                            DropdownButton<String>(
                                value: tempNotificationSound,
                                isExpanded: true,
                                items: const [
                                    DropdownMenuItem(value: 'default', child: Text("System Default")),
                                    // Add more custom sounds here if you add sound files to android/app/src/main/res/raw/
                                    // DropdownMenuItem(value: 'custom_sound', child: Text("Custom Sound")),
                                ],
                                onChanged: (val) {
                                    if (val != null) setDialogState(() => tempNotificationSound = val);
                                },
                            ),
                            const Divider(),
                            Text('Sync & Battery', style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            )),
                            const SizedBox(height: 8),
                            Text('Refresh Frequency', style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            )),
                            DropdownButton<int>(
                                value: tempInterval,
                                isExpanded: true,
                                items: const [
                                    DropdownMenuItem(value: 0, child: Text("Continuous (Best Notifications, High Battery)")),
                                    DropdownMenuItem(value: 30, child: Text("Every 30 Seconds (Balanced)")),
                                    DropdownMenuItem(value: 60, child: Text("Every 1 Minute (Good Battery)")),
                                    DropdownMenuItem(value: 300, child: Text("Every 5 Minutes (Max Battery)")),
                                ],
                                onChanged: (val) {
                                    if (val != null) setDialogState(() => tempInterval = val);
                                },
                            ),
                        ],
                      ),
                    ),
                    actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                            onPressed: () async {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('monitor_session_1', tempMonitor1);
                                await prefs.setBool('monitor_session_2', tempMonitor2);
                                await prefs.setBool('enable_tab_2', tempEnableTab2);
                                await prefs.setBool('notification_persist', tempNotificationPersist);
                                await prefs.setString('notification_sound', tempNotificationSound);
                                await prefs.setInt('sync_interval', tempInterval);

                                // Calculate new index - if Tab 2 is being disabled and we're on Tab 2, switch to Tab 1
                                int newIndex = _currentIndex;
                                if (!tempEnableTab2 && _currentIndex == 1) {
                                  newIndex = 0;
                                }
                                
                                // Update all state in a single setState to avoid race conditions
                                setState(() {
                                    _monitorSession1 = tempMonitor1;
                                    _monitorSession2 = tempMonitor2;
                                    _enableTab2 = tempEnableTab2;
                                    _notificationPersist = tempNotificationPersist;
                                    _notificationSound = tempNotificationSound;
                                    _syncInterval = tempInterval;
                                    _currentIndex = newIndex;
                                });
                                
                                _applySyncSettings();
                                
                                if (mounted) Navigator.pop(context);
                            },
                            child: const Text('Save'),
                        ),
                    ],
                );
            }
        );
      },
    );
  }

  static const String _privacyPolicyUrl =
      'https://github.com/miracuves/Dual-Business-Whatsapp/blob/main/PRIVACY.md';

  void _showAboutDialog() {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MCX WhatZ', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Developed by Miracuves IT Solutions', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Version 1.0.0', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            InkWell(
              onTap: () async {
                final uri = Uri.parse(_privacyPolicyUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: Text(
                'Privacy Policy',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  
  // Unified notification channel ID - must match everywhere
  static const String _notificationChannelId = 'wa_messages_channel';
  static const String _notificationChannelName = 'WhatsApp Messages';
  static const String _notificationChannelDescription = 'Notifications for new WhatsApp messages';

  Future<void> _requestPermissions() async {
    // Aggressive Permission Request Sequence
    Map<Permission, PermissionStatus> statuses = await [
      Permission.notification,
      Permission.ignoreBatteryOptimizations,
      Permission.systemAlertWindow, // Background Pop-up
      Permission.scheduleExactAlarm,
      Permission.accessNotificationPolicy,
      
      // Storage & Media
      Permission.storage,
      Permission.manageExternalStorage, // For older androids or full access if allowed
      Permission.photos,
      Permission.videos,
      Permission.audio,
      Permission.camera,
      Permission.microphone,
    ].request();
    
    debugPrint("Permission Status: $statuses");

    // Create notification channel BEFORE any notifications are shown
    // This is critical for proper display on HarmonyOS 4.2 with MicroG
    // MicroG Note: Local notifications work perfectly with MicroG (no GCM/FCM needed)
    await _ensureNotificationChannel();
  }

  // Ensure notification channel exists - call this before showing any notification
  // CRITICAL: Creating channel multiple times is safe - it won't reset user preferences
  // HarmonyOS-friendly: Just create it, Android handles duplicates gracefully
  Future<void> _ensureNotificationChannel() async {
    final androidImplementation = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    
    if (androidImplementation == null) {
      debugPrint("Android notification implementation not available");
      return;
    }
    
    try {
      // Create channel - safe to call multiple times, won't reset user preferences
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        _notificationChannelId,
        _notificationChannelName,
        description: _notificationChannelDescription,
        importance: Importance.max, // MAX for heads-up notifications
        playSound: true,
        enableVibration: true,
        enableLights: true,
        showBadge: true, // Show badge on app icon
      );
      
      await androidImplementation.createNotificationChannel(channel);
      debugPrint("Notification channel ensured: $_notificationChannelId");
    } catch (e) {
      debugPrint("Error ensuring notification channel: $e");
      // Continue anyway - notification might still work
    }
  }


  // Notification display function - properly configured for HarmonyOS/MicroG
  Future<void> _showNotification(String title, String body, int id) async {
    // Duplicate notification prevention
    final String notificationKey = '$title|$body';
    final DateTime now = DateTime.now();
    
    if (_lastNotificationContent == notificationKey && 
        _lastNotificationTime != null &&
        now.difference(_lastNotificationTime!) < _notificationCooldown) {
      debugPrint("Duplicate notification prevented: $title");
      return; // Skip duplicate notification
    }
    
    // Update last notification tracking
    _lastNotificationContent = notificationKey;
    _lastNotificationTime = now;
    
    // Use unique notification ID per session (1000 + sessionId to avoid conflicts)
    // Session 1 (tabIndex 0) = ID 1000, Session 2 (tabIndex 1) = ID 1001
    final int uniqueNotificationId = 1000 + id;
    
    // Check notification permission first (critical for HarmonyOS)
    final notificationStatus = await Permission.notification.status;
    if (!notificationStatus.isGranted) {
      debugPrint("Notification permission not granted, requesting...");
      final result = await Permission.notification.request();
      if (!result.isGranted) {
        debugPrint("Notification permission denied, cannot show notification");
        return;
      }
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
          _notificationChannelId, // MUST match channel ID
          _notificationChannelName,
          channelDescription: _notificationChannelDescription,
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
    
    // Retry logic for HarmonyOS compatibility (sometimes first attempt fails)
    int retryCount = 0;
    const maxRetries = 2;
    
    while (retryCount <= maxRetries) {
      try {
        await flutterLocalNotificationsPlugin.show(
          uniqueNotificationId, // Use unique ID
          title, 
          body, 
          notificationDetails,
        );
        debugPrint("Notification shown successfully: $title (ID: $uniqueNotificationId, attempt ${retryCount + 1})");
        return; // Success, exit
      } catch (e) {
        retryCount++;
        debugPrint("Error showing notification (attempt $retryCount): $e");
        
        if (retryCount > maxRetries) {
          // Final fallback: try with minimal configuration
          try {
            final AndroidNotificationDetails fallbackDetails =
                AndroidNotificationDetails(
                  _notificationChannelId,
                  _notificationChannelName,
                  channelDescription: _notificationChannelDescription,
                  importance: Importance.max,
                  priority: Priority.max,
                  icon: '@mipmap/launcher_icon',
                  color: const Color(0xFFA70D2A),
                );
            await flutterLocalNotificationsPlugin.show(
              uniqueNotificationId, // Use unique ID
              title,
              body,
              NotificationDetails(android: fallbackDetails),
            );
            debugPrint("Notification shown with fallback configuration (ID: $uniqueNotificationId)");
          } catch (e2) {
            debugPrint("All notification attempts failed: $e2");
            // Log but don't crash - app should continue working
          }
        } else {
          // Wait a bit before retry (HarmonyOS sometimes needs a moment)
          await Future.delayed(Duration(milliseconds: 200 * retryCount));
        }
      }
    }
  }

  void _handleTitleChange(String data, int tabIndex) {
    try {
      // Try to parse as JSON (enhanced message data)
      Map<String, dynamic>? messageData;
      try {
        messageData = jsonDecode(data) as Map<String, dynamic>?;
      } catch (e) {
        // Not JSON, treat as plain title string
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

      // Update tab badge (session 1 only; session 2 is in secondary process)
      if (tabIndex == 0 && mounted) {
        setState(() => _unreadCount1 = unreadCount);
      }

      if (unreadCount <= 0) return;
      if (tabIndex == 0 && !_monitorSession1) return;
      if (tabIndex == 1 && !_monitorSession2) return;

      // Build notification title with tab name
      final String tabName = tabIndex == 0 ? _label1 : _label2;
      String notificationTitle;
      String notificationBody;
      
      if (senderName.isNotEmpty && messageText.isNotEmpty) {
        // Show sender name and message preview
        notificationTitle = '$tabName - $senderName';
        notificationBody = messageText;
        if (unreadCount > 1) {
          notificationBody = '[$unreadCount messages] $messageText';
        }
      } else {
        // Fallback: show tab name and unread count
        notificationTitle = '$tabName';
        notificationBody = unreadCount > 1 
            ? '$unreadCount new messages'
            : 'New message';
      }
      
      // SHOW NOTIFICATION with message details
      _showNotification(notificationTitle, notificationBody, tabIndex);
    } catch (e) {
      debugPrint("Error handling title change: $e");
      // Fallback to basic notification
      final RegExp unreadRegex = RegExp(r'\(\d+\)');
      if (unreadRegex.hasMatch(data)) {
        if (tabIndex == 0 && !_monitorSession1) return;
        if (tabIndex == 1 && !_monitorSession2) return;
        if (tabIndex == 0 && mounted) {
          final match = RegExp(r'\((\d+)\)').firstMatch(data);
          final n = match != null ? (int.tryParse(match.group(1) ?? '0') ?? 0) : 1;
          setState(() => _unreadCount1 = n);
        }
        _showNotification("New Message (${tabIndex == 0 ? _label1 : _label2})", data, tabIndex);
      }
    }
  }

  Future<void> _confirmStopService() async {
    final theme = Theme.of(context);
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop Background Service?'),
        content: const Text(
          'This will stop receiving notifications and save battery. You will not receive messages until you open the app again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Stop & Exit', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (shouldStop == true) {
        FlutterBackgroundService().invoke("stopService");
        SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCX WhatZ'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        actions: [
            Semantics(
              label: 'Reload current page',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload Page',
                onPressed: () {
                  if (_currentIndex == 0) {
                    _key1.currentState?.reload();
                  } else {
                    _key2.currentState?.reload();
                  }
                },
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Menu',
              onSelected: (value) {
                if (value == 'rename') {
                  _showRenameDialog();
                } else if (value == 'stop') {
                  _confirmStopService();
                } else if (value == 'about') {
                  _showAboutDialog();
                } else if (value == 'settings') {
                  _showSettingsDialog();
                }
              },
              itemBuilder: (BuildContext context) {
                return [
                  PopupMenuItem(
                    value: 'settings',
                    child: Row(
                      children: [
                        Icon(Icons.settings, color: colorScheme.primary),
                        const SizedBox(width: 12),
                        const Text('Notification Settings'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit, color: colorScheme.primary),
                        const SizedBox(width: 12),
                        const Text('Rename Tabs'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'stop',
                    child: Row(
                      children: [
                        Icon(Icons.power_settings_new, color: colorScheme.error),
                        const SizedBox(width: 12),
                        const Text('Stop Service & Exit'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'about',
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: colorScheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        const Text('About'),
                      ],
                    ),
                  ),
                ];
              },
            ),
        ],
      ),
      body: _enableTab2 
        ? IndexedStack(
            index: _currentIndex.clamp(0, 1),
            children: [
              // Tab 2 enabled - show both tabs
              WebViewContainer(
                  key: _key1,
                  sessionId: 'session_1', 
                  onTitleChanged: (t) => _handleTitleChange(t, 0)
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Tap below to open $_label2',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Semantics(
                        label: 'Open $_label2 in a separate session',
                        button: true,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            const platform = MethodChannel('com.dualbiz.wa/launcher');
                            platform.invokeMethod('launchSecondary');
                          },
                          icon: const Icon(Icons.open_in_new, size: 22),
                          label: Text('Open $_label2 Session'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 52),
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          )
        : WebViewContainer(
            // Tab 2 disabled - only show Tab 1
            key: _key1,
            sessionId: 'session_1', 
            onTitleChanged: (t) => _handleTitleChange(t, 0)
          ),
      bottomNavigationBar: _enableTab2
        ? NavigationBar(
            selectedIndex: _currentIndex.clamp(0, 1),
            onDestinationSelected: (int index) {
              setState(() {
                _currentIndex = index.clamp(0, 1);
              });
            },
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.business),
                label: _unreadCount1 > 0 ? '$_label1 ($_unreadCount1)' : _label1,
              ),
              NavigationDestination(
                icon: const Icon(Icons.store),
                label: _unreadCount2 > 0 ? '$_label2 ($_unreadCount2)' : _label2,
              ),
            ],
          )
        : null, // Hide navigation bar when Tab 2 is disabled
    );
  }
}

// -----------------------------------------------------------------------
// SECONDARY PROCESS ENTRY POINT
// -----------------------------------------------------------------------
@pragma('vm:entry-point')
void secondaryMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notifications for this process
  // CRITICAL: Use same icon as main app for consistency
  try {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/launcher_icon'); // Fixed: was ic_launcher
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Handle notification tap and actions
        debugPrint("Secondary notification response: ID=${response.id}, Action=${response.actionId}, Payload=${response.payload}");
        
        // Handle notification actions
        if (response.actionId != null) {
          debugPrint("Secondary: Notification action tapped: ${response.actionId} for notification ${response.id}");
          switch (response.actionId) {
            case 'action_reply':
              debugPrint("Secondary: Reply action - opening app");
              break;
            case 'action_mark_read':
              flutterLocalNotificationsPlugin.cancel(response.id ?? 0);
              debugPrint("Secondary: Mark as read - notification dismissed");
              break;
            default:
              debugPrint("Secondary: Unknown action: ${response.actionId}");
          }
        } else {
          // Notification tapped - open app
          debugPrint("Secondary notification tapped: ${response.id}");
        }
      },
    );
    debugPrint("Secondary notifications initialized successfully");
  } catch (e) {
    debugPrint("Error initializing secondary notifications: $e");
    // Continue anyway
  }
  
  runApp(const SecondaryApp());
}
