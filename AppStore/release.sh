#!/bin/bash
# Archives vinnyfin for each platform and uploads each archive to App Store Connect: iOS, which
# iPhone and iPad share, macOS, tvOS and visionOS. One target with one bundle ID builds them all,
# so every upload goes to the same app, to its platform's version there. Each platform's version
# is still submitted for review in App Store Connect, which takes a submission per platform. The
# archives and the upload logs stay out of the repo, in AppStore/Output.
#
# App Store Connect takes a build number once per version and platform, so CURRENT_PROJECT_VERSION
# goes up before every upload after the first of a version.
#
# Usage: AppStore/release.sh [ios] [mac] [tv] [vision]   (default: all)
# Needs Xcode signed in to an account in the team, whose distribution certificate and profiles it
# makes and signs with.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
project="$root/Vinnyfin.xcodeproj"
output="$here/Output"
usage="Usage: AppStore/release.sh [ios] [mac] [tv] [vision]"
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(ios mac tv vision)

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# xcodebuild's name for each platform asked for, all checked before anything is built.
platforms=()
for name in "${names[@]}"; do
  case $name in
    ios) platforms+=(iOS) ;;
    mac) platforms+=(macOS) ;;
    tv) platforms+=(tvOS) ;;
    vision) platforms+=(visionOS) ;;
    *) fail "There's no platform called $name. $usage" ;;
  esac
done

command -v xcodebuild >/dev/null || fail "xcodebuild isn't installed."

settings=$(xcodebuild -showBuildSettings -project "$project" -target Vinnyfin 2>/dev/null)
setting() { awk -v name="$1" '$1 == name { print $3; exit }' <<<"$settings"; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
team=$(setting DEVELOPMENT_TEAM)

# Uploads rather than exports, signed for the App Store by Xcode, with the build number the
# project has: one App Store Connect already has fails the upload instead of being replaced.
options="$output/ExportOptions.plist"
mkdir -p "$output"
cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

uploaded=()
# Stops at the first platform that fails, saying which went up before it.
stop() { # what failed
  fail "$1${uploaded[*]:+ Uploaded before it: ${uploaded[*]}.}"
}
for platform in "${platforms[@]}"; do
  archive="$output/Archives/$platform.xcarchive"
  log="$output/Uploads/$platform"
  say "Archiving vinnyfin $version ($build) for $platform"
  rm -rf "$archive"
  xcodebuild archive -project "$project" -scheme Vinnyfin -configuration Release -destination "generic/platform=$platform" \
    -archivePath "$archive" -allowProvisioningUpdates -quiet ||
    stop "Archiving for $platform failed."
  say "Uploading $platform"
  rm -rf "$log"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$log" \
    -allowProvisioningUpdates -quiet ||
    stop "Uploading $platform failed; what Xcode did is in $log."
  uploaded+=("$platform")
done

say "Uploaded vinnyfin $version ($build) for ${platforms[*]}"
echo "Each is in App Store Connect once it's processed, to submit for review there."
