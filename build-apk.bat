@echo off
setlocal enabledelayedexpansion

echo.
echo ========================================
echo Church Cam Flutter - Build APK
echo ========================================
echo.

REM Set Flutter path
set FLUTTER_PATH=C:\Users\PC\Downloads\flutter_windows_3.41.9-stable\flutter

REM Check if Flutter exists
if not exist "!FLUTTER_PATH!" (
    echo ERROR: Flutter not found at !FLUTTER_PATH!
    pause
    exit /b 1
)

REM Set PATH to include Flutter
set PATH=!FLUTTER_PATH!\bin;!PATH!

REM Get dependencies
echo Getting dependencies...
call flutter pub get
if errorlevel 1 (
    echo ERROR: Failed to get dependencies
    pause
    exit /b 1
)

REM Build APK
echo.
echo Building APK (this may take 2-5 minutes)...
call flutter build apk --release
if errorlevel 1 (
    echo ERROR: Build failed
    pause
    exit /b 1
)

REM Show result
echo.
echo ========================================
echo SUCCESS! APK built successfully
echo ========================================
echo.
echo APK location:
echo D:\MyProjects\LiveStream\ChurchCamFlutter\build\app\outputs\apk\release\app-release.apk
echo.
echo Next steps:
echo 1. Connect your Android phone via USB
echo 2. Run: adb install build\app\outputs\apk\release\app-release.apk
echo 3. Or copy the APK file and install manually
echo.
pause
