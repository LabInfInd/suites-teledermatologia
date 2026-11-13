#!/bin/sh
# Rigenera le icone Android e iOS dai file in branding/.
# Richiede macOS (usa sips). Uso: tool/genera_icone.sh
set -eu
cd "$(dirname "$0")/.."

icon=branding/app_icon.png                   # 1024×1024, fondo bianco, senza trasparenza
foreground=branding/app_icon_foreground.png  # 1024×1024, trasparente, simbolo nel cerchio sicuro
res=android/app/src/main/res
ios=ios/Runner/Assets.xcassets/AppIcon.appiconset

resize() {
  sips -s format png -z "$2" "$2" "$1" --out "$3" >/dev/null
}

# Android: icona tradizionale (48 dp) e primo piano dell'icona adattiva (108 dp).
for spec in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  density=${spec%%:*}
  sizes=${spec#*:}
  mkdir -p "$res/drawable-$density"
  resize "$icon" "${sizes%%:*}" "$res/mipmap-$density/ic_launcher.png"
  resize "$foreground" "${sizes#*:}" "$res/drawable-$density/ic_launcher_foreground.png"
done

# iOS: i nomi corrispondono a quelli elencati in Contents.json.
for spec in 20x20@1x:20 20x20@2x:40 20x20@3x:60 29x29@1x:29 29x29@2x:58 29x29@3x:87 \
  40x40@1x:40 40x40@2x:80 40x40@3x:120 60x60@2x:120 60x60@3x:180 76x76@1x:76 \
  76x76@2x:152 83.5x83.5@2x:167 1024x1024@1x:1024; do
  resize "$icon" "${spec#*:}" "$ios/Icon-App-${spec%%:*}.png"
done

echo "Icone rigenerate."
