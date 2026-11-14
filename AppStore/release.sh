#!/bin/bash
# Archives vinnyfin for each platform and uploads each archive to App Store Connect: iOS, which
# iPhone and iPad share, macOS, tvOS and visionOS. One target with one bundle ID builds them all,
# so every upload goes to the same app, to its platform's version there. Each platform's version
# is still submitted for review in App Store Connect, which takes a submission per platform. The
# archives stay out of the repo, in AppStore/Output.
#
# The platforms go at once, each archiving and then uploading on its own, so one that fails
# leaves the others to finish. Each has its own DerivedData, as two builds can't share one's
# build database, and its own log in AppStore/Output/Logs. The packages are fetched once, before
# any build, into a folder they all read.
#
# App Store Connect takes a build number once per version and platform, so CURRENT_PROJECT_VERSION
# goes up before every upload after the first of a version.
#
# Usage: AppStore/release.sh [ios] [mac] [tv] [vision]   (default: all)
# Needs Xcode signed in to an account in the team, whose distribution certificate and profiles it
# makes and signs with.
set -euo pipefail
# Each platform's job leads a process group of its own, for stopping it with what it runs.
set -m

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
logs="$output/Logs"
packages="$output/Packages"
mkdir -p "$output" "$logs"
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

say "Fetching packages"
xcodebuild -resolvePackageDependencies -project "$project" -scheme Vinnyfin -clonedSourcePackagesDirPath "$packages" \
  >"$logs/Packages.log" 2>&1 || fail "Fetching the packages failed; see $logs/Packages.log."

# What a platform's job exits with when its archive fails, and when its upload does.
archive_failed=3
upload_failed=4

# Archives a platform and uploads the archive, saying on the terminal as each step is done. The
# packages are the ones fetched above, as Package.resolved pins them, so no build fetches or
# updates them under another.
release() { # platform
  local platform=$1 archive="$output/Archives/$1.xcarchive" started=$SECONDS
  rm -rf "$archive"
  xcodebuild archive -project "$project" -scheme Vinnyfin -configuration Release -destination "generic/platform=$platform" \
    -archivePath "$archive" -derivedDataPath "$output/DerivedData/$platform" -clonedSourcePackagesDirPath "$packages" \
    -disableAutomaticPackageResolution -skipPackageUpdates -allowProvisioningUpdates -quiet || return $archive_failed
  echo "Archived $platform in $((SECONDS - started))s; uploading" >&3
  started=$SECONDS
  # An upload exports nothing to the export path; Xcode prints where it keeps the upload's logs.
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$output/Uploads/$platform" \
    -allowProvisioningUpdates -quiet || return $upload_failed
  echo "Uploaded $platform in $((SECONDS - started))s" >&3
}

say "Archiving and uploading vinnyfin $version ($build) for ${platforms[*]}"
exec 3>&1
pids=()
for platform in "${platforms[@]}"; do
  release "$platform" >"$logs/$platform.log" 2>&1 </dev/null &
  pids+=($!)
done
# Ctrl-C reaches only this script, which stops every platform's builds and uploads with it.
stop() {
  local pid
  for pid in "${pids[@]}"; do kill -- "-$pid" 2>/dev/null || true; done
  exit 130
}
trap stop INT TERM

uploaded=()
failed=()
for index in "${!platforms[@]}"; do
  platform=${platforms[$index]}
  status=0
  wait "${pids[$index]}" || status=$?
  case $status in
    0) uploaded+=("$platform"); continue ;;
    "$archive_failed") step="Archiving for $platform failed." ;;
    "$upload_failed") step="Uploading $platform failed; Xcode's logs are in the .xcdistributionlogs bundle its log names." ;;
    *) step="$platform stopped with status $status." ;;
  esac
  failed+=("$platform")
  printf '\n\033[31m%s\033[0m The end of %s:\n' "$step" "$logs/$platform.log" >&2
  tail -n 15 "$logs/$platform.log" >&2
done

if [ ${#failed[@]} -gt 0 ]; then
  echo >&2
  fail "Failed: ${failed[*]}.${uploaded[*]:+ Uploaded: ${uploaded[*]}.}"
fi
say "Uploaded vinnyfin $version ($build) for ${uploaded[*]} in $((SECONDS / 60))m $((SECONDS % 60))s"
echo "Each is in App Store Connect once it's processed, to submit for review there."
