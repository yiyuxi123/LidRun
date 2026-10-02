#!/bin/zsh
set -euo pipefail
script_directory="${0:A:h}"
destination="${1:-$HOME/Applications/LidRun.app}"
destination="${destination:A}"
cd "$script_directory"

assert_destination_idle() {
    local target_executable="$destination/Contents/MacOS/LidRun"
    local running_pid running_executable
    while read -r running_pid running_executable; do
        if [[ "$running_executable" == "$target_executable" ]]; then
            print -u2 "LidRun is running from $destination (PID $running_pid). Quit it before rebuilding this app."
            exit 1
        fi
    done < <(/bin/ps -axo pid=,comm=)
}

[[ "$destination" == *.app ]] || { print -u2 "Build destination must end in .app: $destination"; exit 1; }
assert_destination_idle
[[ -f "$script_directory/assets/LidRun.png" ]] || {
    print -u2 "Missing icon source: $script_directory/assets/LidRun.png. Supply the square PNG before building LidRun."
    exit 1
}
/bin/zsh "$script_directory/make-icon.sh" >/dev/null
assert_destination_idle
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -O -parse-as-library App.swift Dashboard.swift Metrics.swift Telemetry.swift PhysicalNetwork.swift History.swift Diagnostics.swift -o "$destination/Contents/MacOS/LidRun" -framework AppKit -framework SwiftUI -framework IOKit -framework Charts
/usr/bin/swiftc -swift-version 5 -O Guard.swift -o "$destination/Contents/Resources/LidRunGuard" -framework IOKit
/bin/cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.lidrun.app</string>
<key>CFBundleName</key><string>LidRun</string>
<key>CFBundleDisplayName</key><string>合盖继续运行</string>
<key>CFBundleExecutable</key><string>LidRun</string>
<key>CFBundleIconFile</key><string>LidRun.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.1.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/bin/cp "$script_directory/assets/LidRun.icns" "$destination/Contents/Resources/LidRun.icns"
/usr/bin/codesign --force --sign - "$destination/Contents/Resources/LidRunGuard"
/usr/bin/codesign --force --sign - "$destination"
/usr/bin/codesign --verify --deep --strict "$destination"
print "$destination"
