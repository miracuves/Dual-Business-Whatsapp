# Dual-Business-Whatsapp

**MCX WhatZ** — An Android app that runs two independent WhatsApp Web (Business) sessions in one place and delivers local notifications for new messages on both, including when the app is in the background.

**Developed by:** [Miracuves IT Solutions](https://github.com/miracuves)

---

## The idea

Many businesses and users need to use **two WhatsApp (or WhatsApp Business) accounts** on a single phone—for example, one for personal and one for business, or two business lines. The official WhatsApp app only supports one account per device without workarounds.

This project provides a single Android app that:

- Opens **WhatsApp Web** in an in-app browser for a first account (Business 1).
- Opens a **second, separate session** in another screen/process (Business 2), so you can log in with a different phone number.
- Keeps **both sessions active** and shows **local notifications** for new messages on either account, even when the app is in the background.

No official WhatsApp API or server is used—only WhatsApp Web in WebViews, with local logic to detect new messages and show notifications.

---

## What it was done for

- **Dual accounts on one device:** Use two WhatsApp/WhatsApp Business numbers without switching apps or devices.
- **Reliable notifications:** Get notified for new messages on both accounts when the app is backgrounded, via a foreground service and WebView monitoring.
- **Battery vs. responsiveness:** Configurable refresh/sync intervals so you can trade off between faster notifications and lower battery use.
- **Compatibility:** Built with Flutter for Android; tested to work on standard Android and environments like HarmonyOS / MicroG (no Google Play Services required for notifications).

---

## What we have done (features)

### Dual sessions

- **Session 1 (Business 1):** WhatsApp Web runs inside the main app in a WebView. You log in with your first number (QR scan).
- **Session 2 (Business 2):** Launched via a separate Android activity/process so it can use a different WhatsApp account. Accessible from the main screen (“Open Business 2 Session”).
- **Custom tab names:** Rename “Business 1” and “Business 2” (e.g. “Personal”, “Shop”) in app settings.

### Notifications

- **Local notifications** when new messages arrive on either account, with:
  - Sender/chat name and message preview.
  - Unread count when there are multiple messages.
- **Background behavior:** A foreground service keeps the app eligible to run; it periodically asks the app to check the WebView (e.g. page title / unread state) and triggers the same notification logic.
- **Notification actions:** “Reply” (opens app) and “Mark as Read” (dismisses notification).
- **Per-account toggles:** Enable or disable notifications for Business 1 and/or Business 2 in settings.
- **Options:** Keep notifications until dismissed, choose notification sound (default or custom when provided).

### Sync and battery

- **Refresh frequency:** Choose how often the app checks for new messages when in background:
  - Continuous (best for notifications, higher battery use).
  - Every 30 seconds, 1 minute, or 5 minutes (better battery).
- **WebView keep-alive:** Injected JavaScript (e.g. MutationObserver on title/DOM, optional silent audio keep-alive) and periodic touches so the WebView stays active and notifications remain reliable where the OS allows.

### Technical implementation

- **WebView monitoring:** JavaScript injected into WhatsApp Web watches the page title (e.g. `(3) WhatsApp`) and the chat list to detect unread messages and, when possible, extract sender name and message preview. Results are sent to Flutter via a JavaScript handler.
- **Background service:** Uses `flutter_background_service` as a foreground service. It periodically invokes method channels so the Flutter side can query the WebView (e.g. title) and show notifications. Optional WakeLock for compatibility on some devices (e.g. HarmonyOS).
- **Two processes:** Session 1 lives in the main process; Session 2 runs in a secondary process (`SecondaryActivity` / `secondaryMain`), so two independent WhatsApp Web sessions can be maintained.
- **Settings persistence:** Labels, notification toggles, sync interval, and notification options are stored with `shared_preferences` and shared where needed across the app.

---

## Tech stack

- **Flutter** (Dart), Android only in this repo.
- **Packages:**  
  `flutter_inappwebview` (WhatsApp Web), `flutter_background_service`, `flutter_local_notifications`, `permission_handler`, `shared_preferences`, `url_launcher`.
- **Min SDK:** Android 21+ (see `pubspec.yaml` / Android config).

---

## Project structure (high level)

```
lib/
├── main.dart                 # Main app, dashboard, Session 1 WebView, notifications, settings
├── secondary_main.dart       # Entry point for Session 2 (separate process)
├── core/
│   ├── constants/
│   │   └── app_constants.dart # WhatsApp Web URL, user agent, notification JS script
│   └── services/
│       ├── background_service.dart  # Foreground service and WebView polling
│       └── webview_monitor.dart     # Register/query WebView controllers for notifications
└── features/
    └── webview/
        └── widgets/
            └── webview_container.dart  # InAppWebView, JS injection, keep-alive
android/
└── app/src/main/kotlin/.../   # MainActivity, SecondaryActivity, method channels (launcher, WebView monitor)
```

---

## Getting started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (e.g. 3.5+).
- Android SDK (Android 5.0 / API 21+).
- Optional: [FVM](https://fvm.app/) if you use `.fvmrc` for Flutter version.

### Clone and run

```bash
git clone https://github.com/miracuves/Dual-Business-Whatsapp.git
cd Dual-Business-Whatsapp
flutter pub get
flutter run
```

### Build APK

```bash
flutter build apk
# Or use the project scripts if present:
# ./build_apk.sh
# ./build_and_install.sh
```

### First use

1. Install and open the app.
2. Grant notifications and any requested permissions (e.g. battery optimization, overlay if needed).
3. **Business 1:** On the first tab, WhatsApp Web will load; scan the QR code with your first WhatsApp/WhatsApp Business account.
4. **Business 2:** Tap “Open Business 2 Session”, then scan the QR code with your second account.
5. Rename tabs and adjust notification/sync settings from the app menu (e.g. Settings, Rename Tabs).

---

## Known limitations

- **Notifications depend on WhatsApp Web’s layout.** Unread detection uses the page title (e.g. `(3) WhatsApp`) and, when possible, the chat list DOM. If WhatsApp Web changes its structure or class names, notification or badge behavior may break until the app’s injected script is updated. Last verified with WhatsApp Web as of the date of the release; if something stops working after a WhatsApp Web update, check for an app update.
- **Battery and background.** The app uses a foreground service and periodic checks to deliver notifications when in the background. On some devices or OEM power-saving modes, the OS may still restrict background activity. If notifications stop when the app is closed, allow the app to run in the background / disable battery optimization for it (see in-app permission prompts or system settings).
- **Tested environments.** The app is built and tested on standard Android (API 21+) and has been used on HarmonyOS / devices with MicroG (no Google Play Services required for notifications). Behavior on other forks or heavily customized Android builds may differ.
- **No official WhatsApp API.** This app is not endorsed by or affiliated with WhatsApp/Meta. It only loads WhatsApp Web in a WebView and does not use any official business or cloud API.

---

## License and credits

- **Product name:** MCX WhatZ  
- **Repository:** [miracuves/Dual-Business-Whatsapp](https://github.com/miracuves/Dual-Business-Whatsapp)  
- **Developed by:** Miracuves IT Solutions  

This project is not affiliated with WhatsApp or Meta. It uses WhatsApp Web in a WebView and local notification logic only.
