class AppConstants {
  static const String waUrl = 'https://web.whatsapp.com';
  
  // Chrome on Windows User Agent (Key for WhatsApp Web to work)
  static const String desktopUserAgent = 
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
      
  static const String jsCheckLogin = """
    document.querySelector('canvas') != null || document.querySelector('div[data-ref]') != null
  """;
  
  // Enhanced script to monitor title changes AND extract message details
  // WhatsApp Web changes title to "(3) WhatsApp" when there are unread messages
  static const String notificationMonitorScript = """
    var lastTitle = document.title;
    var lastUnreadCount = 0;
    var vibrationTriggered = false;
    
    // Function to extract message details from WhatsApp Web DOM
    function getLatestMessage() {
        try {
            // Find the chat list panel
            var chatList = document.querySelector('[data-testid="chatlist"]') || 
                          document.querySelector('div[role="list"]') ||
                          document.querySelector('div[aria-label*="Chat list"]');
            
            if (!chatList) return null;
            
            // Find unread chats (they have a badge or unread indicator)
            var unreadChats = chatList.querySelectorAll('[data-testid="cell-frame-container"]:has([data-testid="icon-unread-count"])') ||
                            chatList.querySelectorAll('div[aria-label*="unread"]') ||
                            chatList.querySelectorAll('span[aria-label*="unread"]');
            
            // Alternative: Find chats with unread badge
            if (unreadChats.length === 0) {
                unreadChats = Array.from(chatList.querySelectorAll('div[role="row"]')).filter(function(chat) {
                    var badge = chat.querySelector('[data-testid="icon-unread-count"]') || 
                               chat.querySelector('span[aria-label*="unread"]') ||
                               chat.querySelector('.unread-count');
                    return badge !== null;
                });
            }
            
            if (unreadChats.length === 0) return null;
            
            // Get the first unread chat (most recent)
            var latestChat = unreadChats[0];
            
            // Extract sender/chat name
            var nameElement = latestChat.querySelector('[data-testid="cell-frame-title"]') ||
                            latestChat.querySelector('span[title]') ||
                            latestChat.querySelector('div[title]') ||
                            latestChat.querySelector('[aria-label*="chat"]');
            var senderName = nameElement ? (nameElement.getAttribute('title') || nameElement.textContent || nameElement.innerText).trim() : 'Unknown';
            
            // Extract message preview
            var messageElement = latestChat.querySelector('[data-testid="cell-frame-secondary"]') ||
                               latestChat.querySelector('span[title*=":"]') ||
                               latestChat.querySelector('div[title*=":"]') ||
                               latestChat.querySelector('.message-preview');
            var messageText = messageElement ? (messageElement.getAttribute('title') || messageElement.textContent || messageElement.innerText).trim() : '';
            
            // Extract unread count
            var badgeElement = latestChat.querySelector('[data-testid="icon-unread-count"]') ||
                             latestChat.querySelector('span[aria-label*="unread"]') ||
                             latestChat.querySelector('.unread-count');
            var unreadCount = 1;
            if (badgeElement) {
                var countText = badgeElement.textContent || badgeElement.innerText || badgeElement.getAttribute('aria-label') || '1';
                var match = countText.match(/\\d+/);
                if (match) unreadCount = parseInt(match[0]) || 1;
            }
            
            // Clean up message text (remove extra whitespace, newlines)
            messageText = messageText.replace(/\\s+/g, ' ').trim();
            
            return {
                senderName: senderName,
                messageText: messageText,
                unreadCount: unreadCount,
                title: document.title
            };
        } catch (e) {
            console.log('Error extracting message: ' + e);
            return null;
        }
    }
    
    // Monitor title changes and extract message details
    new MutationObserver(function(mutations) {
        if (document.title !== lastTitle) {
            lastTitle = document.title;
            
            // Extract unread count from title
            var titleMatch = document.title.match(/\\((\\d+)\\)/);
            var currentUnreadCount = titleMatch ? parseInt(titleMatch[1]) : 0;
            
            // Only trigger if there are unread messages
            if (currentUnreadCount > 0 && currentUnreadCount !== lastUnreadCount) {
                lastUnreadCount = currentUnreadCount;
                
                // Wait a bit for DOM to update, then extract message details
                setTimeout(function() {
                    var messageData = getLatestMessage();
                    if (messageData) {
                        // Send detailed message info
                        window.flutter_inappwebview.callHandler('onTitleChanged', JSON.stringify({
                            title: messageData.title,
                            senderName: messageData.senderName,
                            messageText: messageData.messageText,
                            unreadCount: messageData.unreadCount
                        }));
                    } else {
                        // Fallback to just title if extraction fails
                        window.flutter_inappwebview.callHandler('onTitleChanged', lastTitle);
                    }
                }, 500); // Small delay to ensure DOM is updated
            } else if (currentUnreadCount === 0 && lastUnreadCount !== 0) {
                lastUnreadCount = 0;
                window.flutter_inappwebview.callHandler('onTitleChanged', JSON.stringify({
                    title: document.title,
                    senderName: '',
                    messageText: '',
                    unreadCount: 0
                }));
            }
        }
    }).observe(
        document.querySelector('title'),
        { subtree: true, characterData: true, childList: true }
    );
    
    // Also monitor chat list changes for more reliable detection
    var chatListObserver = new MutationObserver(function(mutations) {
        var titleMatch = document.title.match(/\\((\\d+)\\)/);
        if (titleMatch) {
            var currentUnreadCount = parseInt(titleMatch[1]);
            if (currentUnreadCount > 0 && currentUnreadCount !== lastUnreadCount) {
                lastUnreadCount = currentUnreadCount;
                setTimeout(function() {
                    var messageData = getLatestMessage();
                    if (messageData) {
                        window.flutter_inappwebview.callHandler('onTitleChanged', JSON.stringify({
                            title: messageData.title,
                            senderName: messageData.senderName,
                            messageText: messageData.messageText,
                            unreadCount: messageData.unreadCount
                        }));
                    }
                }, 500);
            }
        }
    });
    
    // Observe chat list when available
    setTimeout(function() {
        var chatList = document.querySelector('[data-testid="chatlist"]') || 
                      document.querySelector('div[role="list"]');
        if (chatList) {
            chatListObserver.observe(chatList, { 
                childList: true, 
                subtree: true,
                attributes: true,
                attributeFilter: ['aria-label', 'title']
            });
        }
    }, 2000);

    // SYNC CONTROLLER - Optimized for battery life
    // Modes: 0 = Continuous (Best notifications, Higher battery), >0 = Pulse Interval (Better battery)
    window.syncMode = 0; 
    window.pulseActiveDuration = 5000; // OPTIMIZED: 5 seconds (was 10) - enough to keep WebView alive, better battery
    
    // Initialize Audio Keep-Alive (prevents WebView from sleeping)
    if (!window.keepAliveAudio) {
        try {
            window.keepAliveAudio = new Audio('data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAGZGF0YQQAAAAAAA=='); 
            window.keepAliveAudio.volume = 0.01; // Very quiet to avoid any sound
            window.keepAliveAudio.loop = true;
        } catch (e) {
            console.log("Failed to initialize keep-alive audio: " + e);
        }
    }

    window.setSyncInterval = function(intervalSeconds) {
        console.log("Setting Sync Interval: " + intervalSeconds + "s");
        
        // Clear existing configurations
        if (window.pulseTimer) {
            clearInterval(window.pulseTimer);
            window.pulseTimer = null;
        }
        
        if (intervalSeconds <= 0) {
            // CONTINUOUS MODE - Best for notifications, higher battery usage
            if (window.keepAliveAudio) {
                window.keepAliveAudio.loop = true;
                window.keepAliveAudio.play().catch(e => console.log("Audio play failed (continuous): " + e));
            }
        } else {
            // PULSE MODE - Better battery life
            // Stop continuous mode first
            if (window.keepAliveAudio) {
                window.keepAliveAudio.loop = false;
                window.keepAliveAudio.pause();
            }
            
            // Start Pulse Timer
            var intervalMs = intervalSeconds * 1000;
            
            window.pulseTimer = setInterval(function() {
                console.log("Pulse Wakeup (every " + intervalSeconds + "s)...");
                if (window.keepAliveAudio) {
                    window.keepAliveAudio.loop = true;
                    window.keepAliveAudio.play().catch(function(e) {
                        console.log("Pulse play failed: " + e);
                    });
                    
                    // Sleep again after active duration (optimized to 5 seconds)
                    setTimeout(function() {
                        console.log("Pulse Sleep...");
                        if (window.keepAliveAudio) {
                            window.keepAliveAudio.pause();
                        }
                    }, window.pulseActiveDuration);
                }
            }, intervalMs);
        }
    };
    
    // Cleanup function (called when page unloads)
    window.addEventListener('beforeunload', function() {
        if (window.pulseTimer) {
            clearInterval(window.pulseTimer);
            window.pulseTimer = null;
        }
        if (window.keepAliveAudio) {
            window.keepAliveAudio.pause();
            window.keepAliveAudio = null;
        }
    });
  """;
}
