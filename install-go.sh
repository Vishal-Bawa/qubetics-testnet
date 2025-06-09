#!/bin/bash
set -e

# Get latest Go version
VERSION=$(curl -s https://go.dev/dl/ | grep -oP '(?<=go)[0-9.]+(?=.linux-amd64.tar.gz)' | head -n 1)

[ -z "$GOROOT" ] && GOROOT="$HOME/.go"
[ -z "$GOPATH" ] && GOPATH="$HOME/go"

OS="$(uname -s)"
ARCH="$(uname -m)"
shell=""
PLATFORM=""

case $OS in
    "Linux")
        case $ARCH in
            "x86_64") ARCH=amd64 ;;
            "aarch64") ARCH=arm64 ;;
            "armv6" | "armv7l") ARCH=armv6l ;;
            "armv8") ARCH=arm64 ;;
            *386*) ARCH=386 ;;
        esac
        PLATFORM="linux-$ARCH"
        ;;
    "Darwin")
        case $ARCH in
            "x86_64") ARCH=amd64 ;;
            "arm64") ARCH=arm64 ;;
        esac
        PLATFORM="darwin-$ARCH"
        ;;
esac

if [ -z "$PLATFORM" ]; then
    echo "Unsupported OS/ARCH combo: $OS/$ARCH"
    exit 1
fi

# Detect shell
if [ -n "$ZSH_VERSION" ]; then
    shell_profile="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ]; then
    shell_profile="$HOME/.bashrc"
elif [ -n "$FISH_VERSION" ]; then
    shell="fish"
    shell_profile="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
else
    shell_profile="$HOME/.bashrc"
fi

# Check if Go is already installed
if command -v go >/dev/null 2>&1; then
    CURRENT_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    if [ "$CURRENT_VERSION" == "$VERSION" ]; then
        echo "Go $VERSION is already installed."
        exit 0
    else
        echo "Different version of Go installed: $CURRENT_VERSION, replacing with $VERSION..."
        rm -rf "$GOROOT"
    fi
fi

PACKAGE_NAME="go$VERSION.$PLATFORM.tar.gz"
TEMP_DIR=$(mktemp -d)

echo "Downloading $PACKAGE_NAME ..."
if hash wget 2>/dev/null; then
    wget "https://go.dev/dl/$PACKAGE_NAME" -O "$TEMP_DIR/go.tar.gz"
else
    curl -Lo "$TEMP_DIR/go.tar.gz" "https://go.dev/dl/$PACKAGE_NAME"
fi

echo "Extracting Go..."
mkdir -p "$GOROOT"
tar -C "$GOROOT" --strip-components=1 -xzf "$TEMP_DIR/go.tar.gz"

echo "Configuring shell profile in $shell_profile ..."
touch "$shell_profile"
if [ "$shell" == "fish" ]; then
    {
        echo "# GoLang"
        echo "set -x GOROOT '$GOROOT'"
        echo "set -x GOPATH '$GOPATH'"
        echo "set -x PATH \$GOPATH/bin \$GOROOT/bin \$PATH"
    } >> "$shell_profile"
else
    {
        echo "# GoLang"
        echo "export GOROOT=$GOROOT"
        echo "export GOPATH=$GOPATH"
        echo 'export PATH=$GOROOT/bin:$GOPATH/bin:$PATH'
    } >> "$shell_profile"
fi

mkdir -p "$GOPATH"/{src,pkg,bin}
echo "Go $VERSION installed to $GOROOT"

# Apply immediately
source "$shell_profile" || echo "Please run 'source $shell_profile' or restart terminal to apply Go environment."

# Clean up
rm -rf "$TEMP_DIR"

