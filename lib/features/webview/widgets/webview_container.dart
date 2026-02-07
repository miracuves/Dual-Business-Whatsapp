import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:dual_biz_wa/core/constants/app_constants.dart';
import 'package:dual_biz_wa/core/services/webview_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WebViewContainer extends StatefulWidget {
  final String sessionId;
  final Function(String title)? onTitleChanged;

  const WebViewContainer({
    super.key,
    required this.sessionId,
    this.onTitleChanged,
  });

  @override
  State<WebViewContainer> createState() => WebViewContainerState();
}

class WebViewContainerState extends State<WebViewContainer> with AutomaticKeepAliveClientMixin {
  InAppWebViewController? webViewController;
  final WebViewMonitor _monitor = WebViewMonitor();
  InAppWebViewKeepAlive? _keepAlive; // Keep WebView alive in background
  Timer? _refreshTimer; // Periodic refresh to ensure WebView stays active
  
  void reload() {
    webViewController?.reload();
  }
  
  void setSyncInterval(int seconds) {
    webViewController?.evaluateJavascript(source: "if(window.setSyncInterval) window.setSyncInterval($seconds);");
  }

  /// Query current title from WebView (for background monitoring)
  Future<String?> queryTitle() async {
    if (webViewController == null) return null;
    return await _monitor.queryTitle(webViewController);
  }

  @override
  void initState() {
    super.initState();
    // Initialize keep-alive to prevent WebView from being paused
    _keepAlive = InAppWebViewKeepAlive();
  }

  @override
  void dispose() {
    // Cancel refresh timer
    _refreshTimer?.cancel();
    _refreshTimer = null;
    
    // Keep-alive will be automatically released when WebView is disposed
    // No need to manually release it
    
    // Unregister WebView controller when disposed
    if (widget.sessionId == 'session1' || widget.sessionId == 'session_1') {
      _monitor.unregisterSession1();
    } else if (widget.sessionId == 'session2' || widget.sessionId == 'session_2') {
      _monitor.unregisterSession2();
    }
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true; // Important to keep the tab alive when switching

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    return Scaffold(
      body: InAppWebView(
        keepAlive: _keepAlive, // CRITICAL: Keep WebView alive in background
        initialUrlRequest: URLRequest(url: WebUri(AppConstants.waUrl)),
        initialSettings: InAppWebViewSettings(
          userAgent: AppConstants.desktopUserAgent,
          cacheEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          supportZoom: true,
          builtInZoomControls: true,
          displayZoomControls: false,
          allowFileAccess: true,
          iframeAllowFullscreen: true,
          // VITAL FOR BACKGROUND NOTIFICATIONS - Keep WebView active
          allowBackgroundAudioPlaying: true,
          iframeAllow: "camera; microphone",
          mediaPlaybackRequiresUserGesture: false,
          // Additional settings to prevent WebView from pausing
          javaScriptEnabled: true,
          javaScriptCanOpenWindowsAutomatically: true,
          // Keep network connections active
          clearCache: false,
          // Prevent WebView from being paused by Android
          useHybridComposition: true, // Better background support
        ),
        onWebViewCreated: (controller) {
          webViewController = controller;
          
          // Register WebView controller with WebViewMonitor for background polling
          if (widget.sessionId == 'session1' || widget.sessionId == 'session_1') {
            _monitor.registerSession1(controller);
          } else if (widget.sessionId == 'session2' || widget.sessionId == 'session_2') {
            _monitor.registerSession2(controller);
          }
          
          // Add the Javascript handler for title changes and message details
          // CRITICAL: This handler must be registered before script injection
          try {
            controller.addJavaScriptHandler(
              handlerName: 'onTitleChanged',
              callback: (args) {
                try {
                  if (args.isNotEmpty) {
                    final String data = args[0].toString();
                    widget.onTitleChanged?.call(data);
                  }
                } catch (e) {
                  debugPrint("WebView[${widget.sessionId}]: Error in notification handler callback: $e");
                }
              },
            );
            debugPrint("WebView[${widget.sessionId}]: JavaScript handler registered");
          } catch (e) {
            debugPrint("WebView[${widget.sessionId}]: Failed to register JavaScript handler: $e");
            // Retry handler registration
            Future.delayed(const Duration(seconds: 1), () {
              try {
                controller.addJavaScriptHandler(
                  handlerName: 'onTitleChanged',
                  callback: (args) {
                    if (args.isNotEmpty) {
                      final String data = args[0].toString();
                      widget.onTitleChanged?.call(data);
                    }
                  },
                );
                debugPrint("WebView[${widget.sessionId}]: JavaScript handler registered on retry");
              } catch (e2) {
                debugPrint("WebView[${widget.sessionId}]: Handler registration retry failed: $e2");
              }
            });
          }
        },
        onLoadStop: (controller, url) async {
            try {
                // Inject the title monitoring script ensuring it runs after load
                await controller.evaluateJavascript(source: AppConstants.notificationMonitorScript);
                
                // Load sync interval from preferences (parent will update if needed)
                // Default to 0 (continuous) if not set
                try {
                    final prefs = await SharedPreferences.getInstance();
                    final syncInterval = prefs.getInt('sync_interval') ?? 0;
                    controller.evaluateJavascript(source: "if(window.setSyncInterval) window.setSyncInterval($syncInterval);");
                    debugPrint("WebView[${widget.sessionId}]: Script injected with sync interval: $syncInterval");
                } catch (prefError) {
                    // Fallback to default if preferences fail
                    controller.evaluateJavascript(source: "if(window.setSyncInterval) window.setSyncInterval(0);");
                    debugPrint("WebView[${widget.sessionId}]: Script injected with default sync interval");
                }
                
                // Start periodic refresh to keep WebView active (every 5 minutes as fallback)
                // This ensures WebView stays connected even if Android tries to pause it
                _startPeriodicRefresh(controller);
                
            } catch (e) {
                debugPrint("WebView[${widget.sessionId}]: Error injecting script: $e");
                // Retry after delay
                Future.delayed(const Duration(seconds: 2), () async {
                    try {
                        await controller.evaluateJavascript(source: AppConstants.notificationMonitorScript);
                        // Try to apply sync interval on retry too
                        try {
                            final prefs = await SharedPreferences.getInstance();
                            final syncInterval = prefs.getInt('sync_interval') ?? 0;
                            controller.evaluateJavascript(source: "if(window.setSyncInterval) window.setSyncInterval($syncInterval);");
                        } catch (_) {
                            controller.evaluateJavascript(source: "if(window.setSyncInterval) window.setSyncInterval(0);");
                        }
                        debugPrint("WebView[${widget.sessionId}]: Script injected on retry");
                    } catch (e2) {
                        debugPrint("WebView[${widget.sessionId}]: Retry failed: $e2");
                    }
                });
            }
        },
        onConsoleMessage: (controller, consoleMessage) {
            debugPrint("WebView[${widget.sessionId}]: ${consoleMessage.message}");
        },
        onReceivedError: (controller, request, error) {
            debugPrint("WebView[${widget.sessionId}]: Error loading ${request.url}: ${error.description}");
            // Don't crash - just log the error
        },
        onReceivedHttpError: (controller, request, response) {
            debugPrint("WebView[${widget.sessionId}]: HTTP error ${response.statusCode} for ${request.url}");
        },
        // Monitor WebView state to ensure it stays active
        onProgressChanged: (controller, progress) {
            // Log progress to verify WebView is active
            if (progress == 100) {
                debugPrint("WebView[${widget.sessionId}]: Page fully loaded - WebView is active");
            }
        },
      ),
    );
  }
  
  /// Start periodic refresh to keep WebView active (fallback mechanism)
  /// This ensures the WebView maintains connection even if Android tries to pause it
  void _startPeriodicRefresh(InAppWebViewController controller) {
    _refreshTimer?.cancel();
    
    // CRITICAL: More frequent "keep-alive" touches to prevent WebView from pausing
    // Every 30 seconds, execute JavaScript to keep the WebView active
    // This is essential for HarmonyOS which aggressively pauses background WebViews
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      try {
        // Execute a lightweight JavaScript to keep WebView active
        // This prevents HarmonyOS from pausing JavaScript execution
        await controller.evaluateJavascript(source: """
          // Keep WebView active by touching the DOM
          if (document.readyState === 'complete') {
            // Force a title check to ensure MutationObserver is still working
            var titleMatch = document.title.match(/\\((\\d+)\\)/);
            if (titleMatch) {
              // If there are unread messages, trigger notification check
              // This is a fallback if MutationObserver stopped working
              try {
                var messageData = null;
                if (typeof getLatestMessage === 'function') {
                  messageData = getLatestMessage();
                }
                if (messageData) {
                  window.flutter_inappwebview.callHandler('onTitleChanged', JSON.stringify({
                    title: messageData.title,
                    senderName: messageData.senderName,
                    messageText: messageData.messageText,
                    unreadCount: messageData.unreadCount
                  }));
                } else {
                  window.flutter_inappwebview.callHandler('onTitleChanged', document.title);
                }
              } catch (e) {
                console.log('Keep-alive notification check error: ' + e);
              }
            }
            // Touch audio keep-alive to prevent WebView sleep
            if (window.keepAliveAudio && window.keepAliveAudio.paused) {
              try {
                window.keepAliveAudio.play().catch(function(e) {
                  console.log('Keep-alive audio play error: ' + e);
                });
              } catch (e) {
                console.log('Keep-alive audio error: ' + e);
              }
            }
          }
        """);
        debugPrint("WebView[${widget.sessionId}]: Keep-alive touch executed");
      } catch (e) {
        debugPrint("WebView[${widget.sessionId}]: Error in keep-alive touch: $e");
        // If JavaScript execution fails, WebView might be paused
        // Try to reload to wake it up
        try {
          final currentUrl = await controller.getUrl();
          if (currentUrl != null && currentUrl.toString().contains('web.whatsapp.com')) {
            // WebView URL is still valid, just reload to wake it up
            await controller.reload();
            debugPrint("WebView[${widget.sessionId}]: Reloaded to wake up WebView");
          }
        } catch (reloadError) {
          debugPrint("WebView[${widget.sessionId}]: Failed to reload: $reloadError");
        }
      }
    });
    debugPrint("WebView[${widget.sessionId}]: Periodic keep-alive started (every 30 seconds)");
  }
}
