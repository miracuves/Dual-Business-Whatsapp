#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "========================================="
echo "Building and Running Flutter App"
echo "========================================="

FLUTTER_PATH="/Volumes/MXS/fvm/versions/3.24.0/bin/flutter"

echo "Step 1: Checking devices..."
$FLUTTER_PATH devices

echo ""
echo "Step 2: Building APK..."
$FLUTTER_PATH build apk --debug

if [ $? -eq 0 ]; then
    echo ""
    echo "Step 3: Installing on emulator..."
    $FLUTTER_PATH install -d emulator-5554
    
    echo ""
    echo "Step 4: Running app..."
    $FLUTTER_PATH run -d emulator-5554 --debug
else
    echo "Build failed!"
    exit 1
fi

