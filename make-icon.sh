#!/bin/zsh
set -euo pipefail
script_directory="${0:A:h}"
source_png="$script_directory/assets/LidRun.png"
output_icns="$script_directory/assets/LidRun.icns"

[[ -f "$source_png" ]] || {
    print -u2 "Missing icon source: $source_png. Supply a transparent square PNG before generating the app icon."
    exit 1
}
metadata="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$source_png")"
image_format="$(print -r -- "$metadata" | /usr/bin/awk '/^[[:space:]]+format:/{print $2}')"
image_width="$(print -r -- "$metadata" | /usr/bin/awk '/^[[:space:]]+pixelWidth:/{print $2}')"
image_height="$(print -r -- "$metadata" | /usr/bin/awk '/^[[:space:]]+pixelHeight:/{print $2}')"
if [[ "$image_format" != "png" || "$image_width" != "$image_height" ]] ||
   (( image_width < 1024 || image_width > 4096 )); then
    print -u2 "Icon source must be a square PNG between 1024 and 4096 pixels: $source_png"
    exit 1
fi

temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lidrun-icon.XXXXXX")"
trap '/bin/rm -rf -- "$temporary_directory"' EXIT
iconset_directory="$temporary_directory/LidRun.iconset"
/bin/mkdir "$iconset_directory"
icon_sizes=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)
for icon_size in "${icon_sizes[@]}"; do
    filename="${icon_size%:*}"
    pixels="${icon_size##*:}"
    /usr/bin/sips -z "$pixels" "$pixels" "$source_png" --out "$iconset_directory/$filename" >/dev/null
done
/usr/bin/iconutil -c icns -o "$temporary_directory/LidRun.icns" "$iconset_directory"
/bin/mv -f "$temporary_directory/LidRun.icns" "$output_icns"
print "$output_icns"
