#!/bin/bash
# Archives vinnyfin for each platform and uploads each archive to App Store Connect: iOS, which
# iPhone and iPad share, macOS, tvOS and visionOS. One target with one bundle ID builds them all,
# so every upload goes to the same app, to its platform's version there. Each platform's version
# is still submitted for review in App Store Connect, which takes a submission per platform. The
# archives stay out of the repo, in AppStore/Output.
#
# The platforms archive at once, and their archives upload one at a time, in the order the
# platforms are named, each once it's archived. Uploads at once fail with "Failed to Use
# Accounts" and sign Xcode out of App Store Connect. One platform that fails leaves the others to
# finish. Each has its own DerivedData, as two builds can't share one's build database, and its
# own log in AppStore/Output/Logs. The packages are fetched once, before any build, into a folder
# they all read.
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

# Archives a platform. The packages are the ones fetched above, as Package.resolved pins them, so
# no build fetches or updates them under another.
archive() { # platform
  local archive="$output/Archives/$1.xcarchive"
  rm -rf "$archive"
  xcodebuild archive -project "$project" -scheme Vinnyfin -configuration Release -destination "generic/platform=$1" \
    -archivePath "$archive" -derivedDataPath "$output/DerivedData/$1" -clonedSourcePackagesDirPath "$packages" \
    -disableAutomaticPackageResolution -skipPackageUpdates -allowProvisioningUpdates -quiet
}

# Uploads a platform's archive. An upload exports nothing to the export path; Xcode prints where
# it keeps the upload's logs.
upload() { # platform
  xcodebuild -exportArchive -archivePath "$output/Archives/$1.xcarchive" -exportOptionsPlist "$options" \
    -exportPath "$output/Uploads/$1" -allowProvisioningUpdates -quiet
}

say "Archiving vinnyfin $version ($build) for ${platforms[*]}, and uploading each in turn"
# The archives, and the upload under way, run as jobs, so Ctrl-C reaches only this script, which
# stops them all with it.
pids=()
for platform in "${platforms[@]}"; do
  archive "$platform" >"$logs/$platform.log" 2>&1 </dev/null &
  pids+=($!)
done
uploading=
stop() {
  local pid
  for pid in "${pids[@]}" $uploading; do kill -- "-$pid" 2>/dev/null || true; done
  exit 130
}
trap stop INT TERM

uploaded=()
failed=()
failure() { # platform, what failed
  failed+=("$1")
  printf '\n\033[31m%s\033[0m The end of %s:\n' "$2" "$logs/$1.log" >&2
  tail -n 15 "$logs/$1.log" >&2
}
for index in "${!platforms[@]}"; do
  platform=${platforms[$index]}
  if ! wait "${pids[$index]}"; then
    failure "$platform" "Archiving for $platform failed."
    continue
  fi
  echo "Archived $platform at $((SECONDS / 60))m $((SECONDS % 60))s; uploading"
  started=$SECONDS
  upload "$platform" >>"$logs/$platform.log" 2>&1 </dev/null &
  uploading=$!
  if wait "$uploading"; then
    uploaded+=("$platform")
    echo "Uploaded $platform in $((SECONDS - started))s"
  else
    failure "$platform" "Uploading $platform failed; Xcode's logs are in the .xcdistributionlogs bundle its log names."
  fi
  uploading=
done

if [ ${#failed[@]} -gt 0 ]; then
  echo >&2
  fail "Failed: ${failed[*]}.${uploaded[*]:+ Uploaded: ${uploaded[*]}.}"
fi
say "Uploaded vinnyfin $version ($build) for ${uploaded[*]} in $((SECONDS / 60))m $((SECONDS % 60))s"
echo "Each is in App Store Connect once it's processed, to submit for review there."
