import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to monitor WebView titles and manage state for background notifications
/// This allows the background service to query WebView titles even when app is in background
class WebViewMonitor {
  static final WebViewMonitor _instance = WebViewMonitor._internal();
  factory WebViewMonitor() => _instance;
  WebViewMonitor._internal();

  // Store WebView controllers for both sessions
  InAppWebViewController? _session1Controller;
  InAppWebViewController? _session2Controller;

  // Store last known titles to prevent duplicate notifications
  String _lastTitle1 = '';
  String _lastTitle2 = '';
  DateTime _lastCheck1 = DateTime(1970);
  DateTime _lastCheck2 = DateTime(1970);

  // Register WebView controller for session 1 (main app)
  void registerSession1(InAppWebViewController controller) {
    _session1Controller = controller;
    debugPrint("WebViewMonitor: Session 1 controller registered");
  }

  // Register WebView controller for session 2 (secondary app)
  void registerSession2(InAppWebViewController controller) {
    _session2Controller = controller;
    debugPrint("WebViewMonitor: Session 2 controller registered");
  }

  // Unregister controllers when WebView is disposed
  void unregisterSession1() {
    _session1Controller = null;
    debugPrint("WebViewMonitor: Session 1 controller unregistered");
  }

  void unregisterSession2() {
    _session2Controller = null;
    debugPrint("WebViewMonitor: Session 2 controller unregistered");
  }

  /// Query current title from WebView via JavaScript
  /// Returns null if WebView is not available or query fails
  Future<String?> queryTitle(InAppWebViewController? controller) async {
    if (controller == null) {
      return null;
    }

    try {
      // Query document.title via JavaScript
      final result = await controller.evaluateJavascript(source: """
        (function() {
          try {
            // Get title
            var title = document.title || '';
            
            // Also try to get message details if available
            var messageData = null;
            try {
              var chatList = document.querySelector('[data-testid="chatlist"]') || 
                            document.querySelector('div[role="list"]');
              if (chatList) {
                var unreadChats = chatList.querySelectorAll('[data-testid="cell-frame-container"]:has([data-testid="icon-unread-count"])');
                if (unreadChats.length > 0) {
                  var latestChat = unreadChats[0];
                  var nameElement = latestChat.querySelector('[data-testid="cell-frame-title"]') ||
                                  latestChat.querySelector('span[title]');
                  var messageElement = latestChat.querySelector('[data-testid="cell-frame-secondary"]') ||
                                     latestChat.querySelector('span[title*=":"]');
                  var badgeElement = latestChat.querySelector('[data-testid="icon-unread-count"]');
                  
                  var senderName = nameElement ? (nameElement.getAttribute('title') || nameElement.textContent || '').trim() : '';
                  var messageText = messageElement ? (messageElement.getAttribute('title') || messageElement.textContent || '').trim() : '';
                  var unreadCount = 1;
                  if (badgeElement) {
                    var countText = badgeElement.textContent || badgeElement.innerText || badgeElement.getAttribute('aria-label') || '1';
                    var match = countText.match(/\\d+/);
                    if (match) unreadCount = parseInt(match[0]) || 1;
                  }
                  
                  messageData = {
                    senderName: senderName,
                    messageText: messageText,
                    unreadCount: unreadCount
                  };
                }
              }
            } catch (e) {
              console.log('Error extracting message: ' + e);
            }
            
            // Return JSON string with title and message data
            return JSON.stringify({
              title: title,
              messageData: messageData
            });
          } catch (e) {
            return JSON.stringify({title: '', error: e.toString()});
          }
        })();
      """);

      if (result != null && result is String) {
        // Parse the JSON result
        final data = result.replaceAll('\\"', '"').replaceAll('\\n', '');
        // Remove surrounding quotes if present
        final cleanData = data.startsWith('"') && data.endsWith('"')
            ? data.substring(1, data.length - 1)
            : data;
        
        // Try to parse as JSON
        try {
          final jsonData = jsonDecode(cleanData);
          return jsonData['title'] ?? '';
        } catch (e) {
          // If JSON parsing fails, return the raw result
          return result.toString();
        }
      }
      return null;
    } catch (e) {
      debugPrint("WebViewMonitor: Error querying title: $e");
      return null;
    }
  }

  /// Check session 1 for title changes and return new title if changed
  Future<String?> checkSession1() async {
    final controller = _session1Controller;
    if (controller == null) {
      return null;
    }

    try {
      final currentTitle = await queryTitle(controller);
      if (currentTitle == null || currentTitle.isEmpty) {
        return null;
      }

      // Check if title changed
      if (currentTitle != _lastTitle1) {
        final oldTitle = _lastTitle1;
        _lastTitle1 = currentTitle;
        _lastCheck1 = DateTime.now();
        
        // Only notify if there are unread messages (title contains numbers in parentheses)
        if (RegExp(r'\(\d+\)').hasMatch(currentTitle)) {
          debugPrint("WebViewMonitor: Session 1 title changed: $oldTitle -> $currentTitle");
          return currentTitle;
        }
      }
      return null;
    } catch (e) {
      debugPrint("WebViewMonitor: Error checking session 1: $e");
      return null;
    }
  }

  /// Check session 2 for title changes and return new title if changed
  Future<String?> checkSession2() async {
    final controller = _session2Controller;
    if (controller == null) {
      return null;
    }

    try {
      final currentTitle = await queryTitle(controller);
      if (currentTitle == null || currentTitle.isEmpty) {
        return null;
      }

      // Check if title changed
      if (currentTitle != _lastTitle2) {
        final oldTitle = _lastTitle2;
        _lastTitle2 = currentTitle;
        _lastCheck2 = DateTime.now();
        
        // Only notify if there are unread messages (title contains numbers in parentheses)
        if (RegExp(r'\(\d+\)').hasMatch(currentTitle)) {
          debugPrint("WebViewMonitor: Session 2 title changed: $oldTitle -> $currentTitle");
          return currentTitle;
        }
      }
      return null;
    } catch (e) {
      debugPrint("WebViewMonitor: Error checking session 2: $e");
      return null;
    }
  }

  /// Get full message data from WebView (for rich notifications)
  /// If controller is null, uses session1 controller
  /// If sessionId is provided (1 or 2), uses that session's controller
  Future<Map<String, dynamic>?> getMessageData(InAppWebViewController? controller, {int? sessionId}) async {
    // Determine which controller to use
    InAppWebViewController? targetController;
    if (controller != null) {
      targetController = controller;
    } else if (sessionId == 2) {
      targetController = _session2Controller;
    } else {
      targetController = _session1Controller; // Default to session1
    }
    
    if (targetController == null) {
      return null;
    }

    try {
      final result = await targetController.evaluateJavascript(source: """
        (function() {
          try {
            var chatList = document.querySelector('[data-testid="chatlist"]') || 
                          document.querySelector('div[role="list"]');
            if (!chatList) return null;
            
            var unreadChats = chatList.querySelectorAll('[data-testid="cell-frame-container"]:has([data-testid="icon-unread-count"])');
            if (unreadChats.length === 0) {
              unreadChats = Array.from(chatList.querySelectorAll('div[role="row"]')).filter(function(chat) {
                var badge = chat.querySelector('[data-testid="icon-unread-count"]');
                return badge !== null;
              });
            }
            
            if (unreadChats.length === 0) return null;
            
            var latestChat = unreadChats[0];
            var nameElement = latestChat.querySelector('[data-testid="cell-frame-title"]') ||
                            latestChat.querySelector('span[title]') ||
                            latestChat.querySelector('div[title]');
            var messageElement = latestChat.querySelector('[data-testid="cell-frame-secondary"]') ||
                               latestChat.querySelector('span[title*=":"]') ||
                               latestChat.querySelector('div[title*=":"]');
            var badgeElement = latestChat.querySelector('[data-testid="icon-unread-count"]') ||
                             latestChat.querySelector('span[aria-label*="unread"]');
            
            var senderName = nameElement ? (nameElement.getAttribute('title') || nameElement.textContent || nameElement.innerText).trim() : 'Unknown';
            var messageText = messageElement ? (messageElement.getAttribute('title') || messageElement.textContent || messageElement.innerText).trim() : '';
            var unreadCount = 1;
            if (badgeElement) {
              var countText = badgeElement.textContent || badgeElement.innerText || badgeElement.getAttribute('aria-label') || '1';
              var match = countText.match(/\\d+/);
              if (match) unreadCount = parseInt(match[0]) || 1;
            }
            
            messageText = messageText.replace(/\\s+/g, ' ').trim();
            
            return JSON.stringify({
              senderName: senderName,
              messageText: messageText,
              unreadCount: unreadCount,
              title: document.title
            });
          } catch (e) {
            return null;
          }
        })();
      """);

      if (result != null && result is String) {
        final data = result.replaceAll('\\"', '"').replaceAll('\\n', '');
        final cleanData = data.startsWith('"') && data.endsWith('"')
            ? data.substring(1, data.length - 1)
            : data;
        
        try {
          final jsonData = jsonDecode(cleanData);
          return Map<String, dynamic>.from(jsonData);
        } catch (e) {
          return null;
        }
      }
      return null;
    } catch (e) {
      debugPrint("WebViewMonitor: Error getting message data: $e");
      return null;
    }
  }
}

