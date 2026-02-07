#!/bin/bash
cd "$(dirname "$0")"
echo "Building APK..."
fvm flutter build apk --debug
if [ $? -eq 0 ]; then
    echo "APK built successfully!"
    echo "Installing on emulator..."
    fvm flutter install -d emulator-5554
    if [ $? -eq 0 ]; then
        echo "App installed successfully!"
        echo "Launching app..."
        fvm flutter run -d emulator-5554 --debug
    else
        echo "Installation failed. Trying alternative method..."
        adb install -r build/app/outputs/flutter-apk/app-debug.apk
    fi
else
    echo "Build failed!"
    exit 1
fi

