#!/bin/bash
cd "$(dirname "$0")"
echo "Building APK with notification enhancements..."
echo "Using FVM Flutter SDK..."

# Try FVM first
if command -v fvm &> /dev/null; then
    echo "Using fvm command..."
    fvm flutter build apk --debug
elif [ -f ".fvm/flutter_sdk/bin/flutter" ]; then
    echo "Using .fvm/flutter_sdk directly..."
    .fvm/flutter_sdk/bin/flutter build apk --debug
elif [ -f "/Volumes/MXS/fvm/versions/3.24.0/bin/flutter" ]; then
    echo "Using /Volumes/MXS/fvm/versions/3.24.0/bin/flutter..."
    /Volumes/MXS/fvm/versions/3.24.0/bin/flutter build apk --debug
else
    echo "Flutter not found. Trying system flutter..."
    flutter build apk --debug
fi

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ APK built successfully!"
    echo "📦 Location: build/app/outputs/flutter-apk/app-debug.apk"
    echo ""
    echo "New features included:"
    echo "  • Notification actions (Reply, Mark as Read)"
    echo "  • Notification persistence setting"
    echo "  • Custom notification sound support"
else
    echo ""
    echo "❌ Build failed!"
    exit 1
fi

