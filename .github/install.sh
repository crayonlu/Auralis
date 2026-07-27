#!/usr/bin/env bash

# Auralis Installation Script
# This script installs Auralis from GitHub Actions artifacts

cd "$(dirname "$0")" || exit 1  # Change to the script's directory

set -e  # Exit on any error

APP_NAME="Auralis.app"
ENTITLEMENTS_FILE="Auralis.entitlements"
INSTALL_DIR="/Applications"

echo "🎵 Auralis Installation Script"
echo "================================"

# Check if running on macOS 14 or later
MACOS_VERSION=$(sw_vers -productVersion | cut -d '.' -f 1-2)
REQUIRED_VERSION="14.0"

if [[ "$(printf '%s\n' "$REQUIRED_VERSION" "$MACOS_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]]; then
    echo "❌ Error: macOS 14.0 or later is required. Current version: $MACOS_VERSION"
    exit 1
fi

# Check if Auralis.app exists in current directory
if [ ! -d "./$APP_NAME" ]; then
    echo "❌ Error: $APP_NAME not found in current directory"
    echo "Please make sure you have extracted the GitHub Actions artifact and are running this script from the same directory."
    exit 1
fi

# Check if entitlements file exists
if [ ! -f "./$ENTITLEMENTS_FILE" ]; then
    echo "❌ Error: $ENTITLEMENTS_FILE not found in current directory"
    echo "Please make sure the entitlements file is in the same directory as the app."
    exit 1
fi

echo "✅ Found $APP_NAME and $ENTITLEMENTS_FILE"

# Remove existing installation if it exists
if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
    echo "🗑️  Removing existing installation at $INSTALL_DIR/$APP_NAME"
    if [ -w "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR/$APP_NAME"
    else
        echo "⚠️  Need administrator privileges to remove existing installation"
        sudo rm -rf "$INSTALL_DIR/$APP_NAME"
    fi
fi

echo "🔓 Removing quarantine attribute..."
xattr -dr com.apple.quarantine "./$APP_NAME"

echo "✍️  Code signing the application..."
codesign -fs - -f --entitlements "./$ENTITLEMENTS_FILE" "./$APP_NAME"

echo "📦 Moving $APP_NAME to $INSTALL_DIR..."
if [ -w "$INSTALL_DIR" ]; then
    mv "./$APP_NAME" "$INSTALL_DIR/"
else
    echo "⚠️  Need administrator privileges to install to $INSTALL_DIR"
    sudo mv "./$APP_NAME" "$INSTALL_DIR/"
fi

echo "🎉 Installation completed successfully!"
echo "You can now find Auralis in your Applications folder."
echo ""
echo "To launch Auralis:"
echo "  - Open Finder -> Applications -> Auralis"
echo "  - Or use Spotlight: Press Cmd+Space and type 'Auralis'"
