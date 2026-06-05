#!/usr/bin/env bash
set -euo pipefail

# devcast — build & run mobile/desktop apps on simulators, emulators, and devices
# Usage: devcast <ios|android|web|mac> <list|explore|run|install> [arg]
#
# Project config lives in ./devcast.config.sh (or set DEVCAST_CONFIG env var).
# Required config vars:
#   IOS_BUNDLE_ID          com.example.app
#   ANDROID_PACKAGE        com.example.app
#   ANDROID_MAIN_ACTIVITY  .MainActivity
#
# Required build hooks (defined in config):
#   devcast_build_ios      builds for iOS, exports APP_PATH
#   devcast_build_android  builds for Android, exports APK_PATH
#   devcast_build_web      builds for web, exports WEB_DIST_DIR
#   devcast_build_mac      builds for macOS, exports APP_PATH
#
# Optional per-platform run hooks (override default install+launch):
#   devcast_run_ios        custom iOS run logic
#   devcast_run_android    custom Android run logic
#   devcast_run_web        custom web serve logic
#   devcast_run_mac        custom macOS run logic

usage() {
  echo "Usage: $(basename "$0") <ios|android|web|mac> <list|explore|run|install> [arg]"
  echo
  echo "  list              List installed simulators / AVDs / connected devices"
  echo "  explore           List downloadable runtimes (iOS) or system images (Android)"
  echo "  run [id|index]    Build, install, and launch"
  echo "                    Omit [id] to auto-pick the first booted device"
  echo "                    web: [arg] = port number (default from WEB_PORT or 8080)"
  echo "  install [index|id] Download & install a runtime (iOS) or system image + create AVD (Android)"
  exit 1
}

PLATFORM="${1:-}"
CMD="${2:-}"
TARGET="${3:-}"

normalize() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '; }

[[ -n "$PLATFORM" && -n "$CMD" ]] || usage
[[ "$PLATFORM" == "ios" || "$PLATFORM" == "android" || "$PLATFORM" == "web" || "$PLATFORM" == "mac" ]] || usage
[[ "$CMD" == "list" || "$CMD" == "explore" || "$CMD" == "run" || "$CMD" == "install" ]] || usage
[[ "$CMD" == "explore" && ("$PLATFORM" == "web" || "$PLATFORM" == "mac") ]] && echo "Error: 'explore' is ios/android only" && exit 1
[[ "$CMD" == "install" && ("$PLATFORM" == "web" || "$PLATFORM" == "mac") ]] && echo "Error: 'install' is ios/android only" && exit 1

# --- Load config -----------------------------------------------------------
DEVCAST_CONFIG="${DEVCAST_CONFIG:-./devcast.config.sh}"
if [[ -f "$DEVCAST_CONFIG" ]]; then
  source "$DEVCAST_CONFIG"
fi

# Validate required config for 'run' command
if [[ "$CMD" == "run" ]]; then
  case "$PLATFORM" in
    ios|mac)
      [[ -z "${IOS_BUNDLE_ID:-}" ]] && echo "Error: IOS_BUNDLE_ID not set in config" >&2 && exit 1 ;;
    android)
      [[ -z "${ANDROID_PACKAGE:-}" ]] && echo "Error: ANDROID_PACKAGE not set in config" >&2 && exit 1
      [[ -z "${ANDROID_MAIN_ACTIVITY:-}" ]] && echo "Error: ANDROID_MAIN_ACTIVITY not set in config" >&2 && exit 1 ;;
  esac
fi

###############################################################################
# iOS — device management (generic)
###############################################################################

ios_list() {
  echo "=== iOS Simulators ==="
  local sims_udid=() sims_name=() sims_rt=() sims_booted=()
  local runtime=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^--[[:space:]](.+)[[:space:]]--$ ]]; then
      runtime="${BASH_REMATCH[1]}"
      continue
    fi
    local trimmed name udid state
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    state=$(echo "$trimmed" | sed -E 's/.*\(([^)]+)\)$/\1/')
    case "$state" in Booted|Shutdown|"Shutting down") ;; *) continue ;; esac
    local line_no_state=$(echo "$trimmed" | sed -E 's/ \([^)]+\)$//')
    udid=$(echo "$line_no_state" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
    [[ -z "$udid" ]] && continue
    name=$(echo "$line_no_state" | sed -E 's/ \([A-F0-9-]+\)$//')
    sims_udid+=("$udid")
    sims_name+=("$name")
    sims_rt+=("${runtime:-unknown}")
    [[ "$state" == "Booted" ]] && sims_booted+=(1) || sims_booted+=(0)
  done < <(xcrun simctl list devices available)

  if [[ ${#sims_udid[@]} -eq 0 ]]; then
    echo "  (no simulators installed)"
    echo "  Install a runtime: $0 ios explore"
  else
    local max_name=0
    for n in "${sims_name[@]}"; do [[ ${#n} -gt $max_name ]] && max_name=${#n}; done
    local max_rt=0
    for r in "${sims_rt[@]}"; do [[ ${#r} -gt $max_rt ]] && max_rt=${#r}; done
    for i in "${!sims_udid[@]}"; do
      if [[ "${sims_booted[$i]}" == "1" ]]; then
        printf "● %2d  %-*s | %-*s | %s\n" \
          "$((i+1))" "$max_rt" "${sims_rt[$i]}" "$max_name" "${sims_name[$i]}" "${sims_udid[$i]}"
      else
        printf "  %2d  %-*s | %-*s | %s\n" \
          "$((i+1))" "$max_rt" "${sims_rt[$i]}" "$max_name" "${sims_name[$i]}" "${sims_udid[$i]}"
      fi
    done
  fi

  echo
  echo "  ● = booted   Run: $0 ios run <number|name|udid>"
  echo

  echo "=== Connected / Available iOS Devices ==="
  local dev_output
  dev_output=$(xcrun devicectl list devices 2>/dev/null) || true
  if [[ -z "$dev_output" ]]; then
    echo "  (devicectl unavailable — install Xcode)"
  else
    local d_idx=$(( ${#sims_udid[@]} + 1 )) d_printed=0
    while IFS= read -r dline; do
      [[ -z "$dline" ]] && continue
      [[ "$dline" =~ ^Name[[:space:]] ]] && continue
      [[ "$dline" =~ ^-+ ]] && continue
      [[ "$dline" == *connected* || "$dline" == *available* ]] || continue
      local d_id d_name d_state d_model
      d_id=$(echo "$dline" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
      [[ -z "$d_id" ]] && continue
      d_name=$(echo "$dline" | awk '{print $1}')
      if [[ "$dline" == *connected* ]]; then
        d_state="connected"
        d_model=$(echo "$dline" | sed -E 's/.*connected[[:space:]]+(.+)$/\1/' | sed -E 's/[[:space:]]+$//')
      else
        d_state="available"
        d_model=$(echo "$dline" | sed -E 's/.*available[[:space:]]+(.+)$/\1/' | sed -E 's/[[:space:]]+$//')
      fi
      if [[ "$d_state" == "connected" ]]; then
        printf "● %2d  %-15s | %s | %s\n" "$d_idx" "$d_name" "[${d_model}]" "$d_id"
      else
        printf "  %2d  %-15s | %s | %s\n" "$d_idx" "$d_name" "[${d_model}]" "$d_id"
      fi
      d_printed=1
      ((d_idx++))
    done <<< "$dev_output"
    [[ $d_printed -eq 0 ]] && echo "  (no connected or available devices)"
  fi
  echo
  echo "  ● = connected   Run: $0 ios run <number|name|udid>"
}

ios_explore() {
  echo "=== Downloadable iOS Runtimes ==="
  local rt_output
  rt_output=$(xcrun simctl runtime list 2>/dev/null) || true
  if [[ -z "$rt_output" ]] || [[ "$rt_output" == *"Error"* ]] || [[ "$rt_output" == *"error"* ]]; then
    echo "  (simdiskimaged not available — run on a Mac with Xcode.app)"
    return
  fi
  local in_dl=0 j=1
  while IFS= read -r rt_line; do
    if [[ "$rt_line" =~ ^==[[:space:]]Downloadable ]]; then in_dl=1; continue; fi
    [[ "$rt_line" =~ ^== && $in_dl -eq 1 ]] && in_dl=0
    if [[ $in_dl -eq 1 && "$rt_line" =~ \([0-9a-f-]{36}\) ]]; then
      local rt_name rt_id
      rt_name=$(echo "$rt_line" | sed -E 's/^(.*) - .*/\1/')
      rt_id=$(echo "$rt_line" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
      printf "  %2d  %s  %s\n" "$j" "$rt_id" "$rt_name"
      ((j++))
    fi
  done <<< "$rt_output"
  if [[ $j -eq 1 ]]; then
    echo "  (none — all runtimes already installed)"
  else
    echo
    echo "Install with: $0 ios install <number|runtime_id>"
  fi
}

ios_resolve_device() {
  local id="$1"
  DEVICE_KIND=""
  DEVICE_UDID=""
  DEVICE_NAME=""

  local s_udids=() s_names=() s_rts=()
  local runtime=""
  while IFS= read -r line; do
    [[ "$line" =~ ^--[[:space:]](.+)[[:space:]]--$ ]] && runtime="${BASH_REMATCH[1]}" && continue
    local trimmed name udid state
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    echo "$trimmed" | grep -qE '\((Booted|Shutdown|Shutting down)\)$' || continue
    state=$(echo "$trimmed" | sed -E 's/.*\(([^)]+)\)$/\1/')
    local line_no_state=$(echo "$trimmed" | sed -E 's/ \([^)]+\)$//')
    udid=$(echo "$line_no_state" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
    [[ -z "$udid" ]] && continue
    name=$(echo "$line_no_state" | sed -E 's/ \([A-F0-9-]+\)$//')
    s_udids+=("$udid"); s_names+=("$name"); s_rts+=("${runtime:-unknown}")
  done < <(xcrun simctl list devices available)

  local d_udids=() d_names=()
  local d_output
  d_output=$(xcrun devicectl list devices 2>/dev/null) || true
  if [[ -n "$d_output" ]]; then
    while IFS= read -r dline; do
      [[ "$dline" == *connected* || "$dline" == *available* ]] || continue
      local d_id
      d_id=$(echo "$dline" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
      [[ -z "$d_id" ]] && continue
      d_udids+=("$d_id"); d_names+=("$(echo "$dline" | awk '{print $1}')")
    done <<< "$d_output"
  fi

  local sim_count=${#s_udids[@]}
  local total=$((sim_count + ${#d_udids[@]}))

  if [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= total )); then
    if (( id <= sim_count )); then
      DEVICE_KIND="sim"; DEVICE_UDID="${s_udids[$((id-1))]}"; DEVICE_NAME="${s_names[$((id-1))]}"
    else
      local di=$((id - 1 - sim_count))
      DEVICE_KIND="device"; DEVICE_UDID="${d_udids[$di]}"; DEVICE_NAME="${d_names[$di]}"
    fi
    return
  fi

  for u in "${s_udids[@]}"; do
    if [[ "$u" == "$id" ]]; then DEVICE_KIND="sim"; DEVICE_UDID="$u"; return; fi
  done

  local norm_id
  norm_id=$(normalize "$id")
  for i in "${!s_names[@]}"; do
    local norm_name norm_name_rt
    norm_name=$(normalize "${s_names[$i]}")
    norm_name_rt="${norm_name}$(normalize "${s_rts[$i]}")"
    if [[ "$norm_name" == *"$norm_id"* ]] || [[ "$norm_name_rt" == *"$norm_id"* ]]; then
      DEVICE_KIND="sim"; DEVICE_UDID="${s_udids[$i]}"; DEVICE_NAME="${s_names[$i]}"
      return
    fi
  done

  for i in "${!d_udids[@]}"; do
    if [[ "${d_udids[$i]}" == "$id" ]] || [[ "$(normalize "${d_names[$i]}")" == *"$norm_id"* ]]; then
      DEVICE_KIND="device"; DEVICE_UDID="${d_udids[$i]}"; DEVICE_NAME="${d_names[$i]}"
      return
    fi
  done

  echo "Error: no simulator or device matching '$id'" >&2
  echo "Run '$0 ios list' to see available targets." >&2
  exit 1
}

ios_install() {
  local id="$1"
  local rt_output rt_ids=() rt_names=()
  rt_output=$(xcrun simctl runtime list 2>/dev/null) || true
  if [[ -z "$rt_output" ]]; then
    echo "Error: cannot fetch runtime list (is Xcode installed?)" >&2
    exit 1
  fi

  local in_dl=0
  while IFS= read -r rt_line; do
    if [[ "$rt_line" =~ ^==[[:space:]]Downloadable ]]; then in_dl=1; continue; fi
    [[ "$rt_line" =~ ^== && $in_dl -eq 1 ]] && in_dl=0
    if [[ $in_dl -eq 1 && "$rt_line" =~ \([0-9a-f-]{36}\) ]]; then
      rt_names+=("$(echo "$rt_line" | sed -E 's/^(.*) - .*/\1/')")
      rt_ids+=("$(echo "$rt_line" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')")
    fi
  done <<< "$rt_output"

  if [[ ${#rt_ids[@]} -eq 0 ]]; then echo "All runtimes already installed."; return; fi

  local target_id=""
  if [[ -z "$id" ]]; then
    target_id="${rt_ids[-1]}"
    echo "Auto-picking latest: ${rt_names[-1]} ($target_id)"
  elif [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= ${#rt_ids[@]} )); then
    target_id="${rt_ids[$((id-1))]}"
    echo "Installing: ${rt_names[$((id-1))]} ($target_id)"
  else
    for j in "${!rt_ids[@]}"; do
      if [[ "${rt_ids[$j]}" == "$id" ]] || [[ "${rt_names[$j]}" == *"$id"* ]]; then
        target_id="${rt_ids[$j]}"
        echo "Installing: ${rt_names[$j]} ($target_id)"
        break
      fi
    done
  fi

  if [[ -z "$target_id" ]]; then
    echo "Error: no downloadable runtime matching '$id'" >&2
    echo "Run '$0 ios explore' to see downloadable runtimes." >&2
    exit 1
  fi

  echo "Downloading and installing runtime... (this may take a while)"
  xcrun simctl runtime add "$target_id"
  echo "Runtime installed. Run '$0 ios list' for updated simulator list."
}

ios_ensure_booted() {
  local state
  state=$(xcrun simctl list devices | grep "$DEVICE_UDID" | grep -oE '(Booted|Shutdown)')
  if [[ "$state" == "Shutdown" ]]; then
    echo "Booting $DEVICE_UDID..."
    xcrun simctl boot "$DEVICE_UDID"
    sleep 2
  fi
  open -a Simulator --args -CurrentDeviceUDID "$DEVICE_UDID"
}

###############################################################################
# Android — device management (generic)
###############################################################################

android_list() {
  echo "=== Android Emulators (AVDs) ==="
  local avds=()
  local i=1
  while IFS= read -r avd; do
    [[ -z "$avd" ]] && continue
    avds+=("$avd")
    if adb devices 2>/dev/null | grep -q "emulator.*$avd"; then
      printf "● %2d  %s\n" "$i" "$avd"
    else
      printf "  %2d  %s\n" "$i" "$avd"
    fi
    ((i++))
  done < <("$ANDROID_HOME/emulator/emulator" -list-avds 2>/dev/null)
  local avd_count=$(( i - 1 ))
  echo
  echo "=== Connected ADB Devices ==="
  local adb_lines=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    adb_lines+=("$line")
  done < <(adb devices -l 2>/dev/null | tail -n +2 | grep -v '^$')
  if [[ ${#adb_lines[@]} -eq 0 ]]; then
    echo "  (no connected devices)"
  else
    local j=$(( avd_count + 1 ))
    for line in "${adb_lines[@]}"; do
      local dev_serial dev_state
      dev_serial=$(echo "$line" | awk '{print $1}')
      dev_state=$(echo "$line" | awk '{print $2}')
      if [[ "$dev_state" == "device" ]]; then
        printf "● %2d  %s\n" "$j" "$dev_serial"
      else
        printf "  %2d  %s\n" "$j" "$dev_serial"
      fi
      ((j++))
    done
  fi
  echo
  echo "  ● = online   Run: $0 android run <number|avd_name|serial>"
  echo "  Other system images: $0 android explore"
}

android_explore() {
  echo "=== Downloadable Android System Images ==="
  if [[ -z "${ANDROID_HOME:-}" ]]; then
    echo "  Error: ANDROID_HOME is not set" >&2
    return
  fi
  local sm="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  if [[ ! -x "$sm" ]]; then
    echo "  Error: sdkmanager not found at $sm" >&2
    return
  fi

  local tmpfile
  tmpfile=$(mktemp -t devcast-imgs.XXXXXX)
  trap "rm -f $tmpfile" EXIT
  "$sm" --list 2>/dev/null | grep 'system-images;' | grep 'arm64-v8a' | grep -vE 'android-(1[0-9]|2[0-9]|3[0-3])[;.-]' | grep -vE ';(default|aosp_atd|google_atd);' | grep -vE 'android-(wear|tv|automotive|desktop)|google-(tv|xr)|google_atd' | awk -F'|' '{print $1}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' > "$tmpfile" || true
  if [[ ! -s "$tmpfile" ]]; then
    echo "  (could not fetch system images)"
    return
  fi

  local j=1
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    printf "  %2d  %s\n" "$j" "$img"
    ((j++))
  done < "$tmpfile"
  echo
  echo "Install with: $0 android install <number|image_name>"
}

android_install() {
  local id="$1"
  if [[ -z "${ANDROID_HOME:-}" ]]; then
    echo "Error: ANDROID_HOME is not set" >&2; exit 1
  fi
  local sm="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  local am="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
  if [[ ! -x "$sm" ]]; then
    echo "Error: sdkmanager not found at $sm" >&2; exit 1
  fi

  local imgs=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    imgs+=("$line")
  done < <("$sm" --list 2>/dev/null | grep 'system-images;' | grep 'arm64-v8a' | grep -vE 'android-(1[0-9]|2[0-9]|3[0-3])[;.-]' | grep -vE ';(default|aosp_atd|google_atd);' | grep -vE 'android-(wear|tv|automotive|desktop)|google-(tv|xr)|google_atd' | awk -F'|' '{print $1}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)

  if [[ ${#imgs[@]} -eq 0 ]]; then
    echo "Error: no system images available" >&2; exit 1
  fi

  local img=""
  if [[ -z "$id" ]]; then
    for entry in "${imgs[@]}"; do
      if [[ "$entry" == *"google_apis"* ]] && [[ "$entry" == *"arm64"* ]]; then
        img="$entry"; break
      fi
    done
    [[ -z "$img" ]] && img="${imgs[-1]}"
    echo "Auto-picking: $img"
  elif [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= ${#imgs[@]} )); then
    img="${imgs[$((id-1))]}"
  else
    for entry in "${imgs[@]}"; do
      if [[ "$entry" == *"$id"* ]]; then img="$entry"; break; fi
    done
  fi

  if [[ -z "$img" ]]; then
    echo "Error: no system image matching '$id'" >&2
    echo "Run '$0 android explore' to see available images." >&2
    exit 1
  fi

  echo "Downloading and installing: $img ..."
  yes 2>/dev/null | "$sm" --install "$img" || true

  local api_level
  api_level=$(echo "$img" | sed -nE 's/^system-images;android-([0-9]+)[^;]*;.*/\1/p')
  local avd_name="Pixel_5_API_${api_level}"

  echo "Creating AVD: $avd_name (API $api_level) ..."
  if ! echo "no" | "$am" create avd -n "$avd_name" -k "$img" -f 2>&1; then
    echo "Error: AVD creation failed." >&2; exit 1
  fi
  echo "AVD created. Run '$0 android list' to see it."
}

android_resolve_device() {
  local id="$1"

  if adb devices 2>/dev/null | grep -q "^${id}"; then
    DEVICE_ID="$id"; return
  fi

  local norm_id is_numeric=0
  norm_id=$(normalize "$id")
  [[ "$id" =~ ^[0-9]+$ ]] && is_numeric=1
  local avds=()
  local i=1
  while IFS= read -r avd; do
    [[ -z "$avd" ]] && continue
    avds+=("$avd")
    if [[ $is_numeric -eq 1 && "$id" == "$i" ]] || \
       [[ $is_numeric -eq 0 && "$(normalize "$avd")" == *"$norm_id"* ]]; then
      DEVICE_ID="$avd"; return
    fi
    ((i++))
  done < <("$ANDROID_HOME/emulator/emulator" -list-avds 2>/dev/null)

  if [[ $is_numeric -eq 1 ]]; then
    local avd_count=${#avds[@]}
    local j=$(( avd_count + 1 ))
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local dev_serial
      dev_serial=$(echo "$line" | awk '{print $1}')
      if [[ "$id" == "$j" ]]; then DEVICE_ID="$dev_serial"; return; fi
      ((j++))
    done < <(adb devices -l 2>/dev/null | tail -n +2 | grep -v '^$')
  fi

  echo "Error: no device matching '$id'" >&2
  echo "Run '$0 android list' to see available devices." >&2
  exit 1
}

android_ensure_booted() {
  if adb devices 2>/dev/null | grep -q "^${DEVICE_ID}"; then return; fi

  local serial
  while IFS= read -r serial; do
    [[ -z "$serial" ]] && continue
    local avd_name
    avd_name=$(adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r' || true)
    if [[ "$avd_name" == "$DEVICE_ID" ]]; then DEVICE_ID="$serial"; return; fi
  done < <(adb devices 2>/dev/null | grep "emulator" | awk '{print $1}' || true)

  local before=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && before+=("$s")
  done < <(adb devices 2>/dev/null | grep "emulator" | awk '{print $1}' || true)

  echo "Starting AVD: $DEVICE_ID ..."
  "$ANDROID_HOME/emulator/emulator" "@$DEVICE_ID" -no-boot-anim >/dev/null 2>&1 &

  echo "Waiting for device to appear..."
  local new_serial=""
  local deadline=$(( $(date +%s) + 120 ))
  while [[ -z "$new_serial" && $(date +%s) -lt $deadline ]]; do
    sleep 2
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      local known=0
      for b in "${before[@]}"; do [[ "$b" == "$s" ]] && known=1 && break; done
      if [[ $known -eq 0 ]]; then new_serial="$s"; break; fi
    done < <(adb devices 2>/dev/null | grep "emulator" | awk '{print $1}' || true)
  done

  if [[ -z "$new_serial" ]]; then
    echo "Error: timed out waiting for AVD $DEVICE_ID to appear" >&2; exit 1
  fi
  DEVICE_ID="$new_serial"

  echo "Waiting for boot to complete..."
  adb -s "$DEVICE_ID" wait-for-device shell \
    'while [[ "$(getprop sys.boot_completed)" != "1" ]]; do sleep 1; done'
}

###############################################################################
# Web — device management (informational only)
###############################################################################

web_list() {
  echo "Web preview uses the system browser."
  echo
  echo "Run with: $0 web run [port]"
}

###############################################################################
# Mac — device management (informational only)
###############################################################################

mac_list() {
  echo "Mac runs on the current machine."
  echo
  echo "Run with: $0 mac run"
}

###############################################################################
# Default run implementations (install + launch using config vars)
###############################################################################

_default_run_ios() {
  # Source the build hook
  if declare -f devcast_build_ios >/dev/null 2>&1; then
    devcast_build_ios
  else
    echo "Error: devcast_build_ios hook not defined in config" >&2; exit 1
  fi

  if [[ "$DEVICE_KIND" == "device" ]]; then
    echo "Installing on device $DEVICE_NAME ($DEVICE_UDID)..."
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"
    echo "Launching..."
    xcrun devicectl device process launch --device "$DEVICE_UDID" "$IOS_BUNDLE_ID"
  else
    ios_ensure_booted
    echo "Installing on $DEVICE_UDID..."
    xcrun simctl install "$DEVICE_UDID" "$APP_PATH"
    echo "Launching..."
    xcrun simctl launch "$DEVICE_UDID" "$IOS_BUNDLE_ID"
  fi
}

_default_run_android() {
  if declare -f devcast_build_android >/dev/null 2>&1; then
    devcast_build_android
  else
    echo "Error: devcast_build_android hook not defined in config" >&2; exit 1
  fi

  android_ensure_booted
  echo "Installing on $DEVICE_ID..."
  adb -s "$DEVICE_ID" install -r "$APK_PATH"
  echo "Launching..."
  adb -s "$DEVICE_ID" shell am start -n "${ANDROID_PACKAGE}/${ANDROID_MAIN_ACTIVITY}"
}

_default_run_web() {
  local port="${1:-${WEB_PORT:-8080}}"
  if declare -f devcast_build_web >/dev/null 2>&1; then
    devcast_build_web
  else
    echo "Error: devcast_build_web hook not defined in config" >&2; exit 1
  fi

  local dist_dir="${WEB_DIST_DIR:-./dist}"
  echo "Serving on http://localhost:${port}/ ..."

  if command -v npx &>/dev/null; then
    npx serve -l "$port" --no-clipboard "$dist_dir"
  elif command -v python3 &>/dev/null; then
    cd "$dist_dir" && python3 -m http.server "$port"
  else
    echo "Error: no HTTP server found (install 'serve': npm i -g serve)" >&2; exit 1
  fi
}

_default_run_mac() {
  if declare -f devcast_build_mac >/dev/null 2>&1; then
    devcast_build_mac
  else
    echo "Error: devcast_build_mac hook not defined in config" >&2; exit 1
  fi

  echo "Launching $APP_PATH..."
  open "$APP_PATH"
}

###############################################################################
# Main dispatch
###############################################################################

if [[ "$CMD" == "list" ]]; then
  case "$PLATFORM" in
    ios)     ios_list ;;
    android) android_list ;;
    web)     web_list ;;
    mac)     mac_list ;;
  esac
fi

if [[ "$CMD" == "explore" ]]; then
  case "$PLATFORM" in
    ios)     ios_explore ;;
    android) android_explore ;;
  esac
fi

if [[ "$CMD" == "install" ]]; then
  case "$PLATFORM" in
    ios)     ios_install "$TARGET" ;;
    android) android_install "$TARGET" ;;
  esac
fi

if [[ "$CMD" == "run" ]]; then
  case "$PLATFORM" in
    ios)
      # Allow config to override the entire run logic
      if declare -f devcast_run_ios >/dev/null 2>&1; then
        devcast_run_ios "$TARGET"
        exit 0
      fi
      if [[ -z "$TARGET" ]]; then
        TARGET=$(xcrun simctl list devices booted | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1)
        [[ -z "$TARGET" ]] && TARGET="1"
      fi
      ios_resolve_device "$TARGET"
      echo "Target: $DEVICE_NAME ($DEVICE_UDID)"
      _default_run_ios
      ;;
    android)
      if declare -f devcast_run_android >/dev/null 2>&1; then
        devcast_run_android "$TARGET"
        exit 0
      fi
      if [[ -z "$TARGET" ]]; then
        TARGET=$(adb devices 2>/dev/null | grep -E '^(emulator|[0-9]+)' | awk '{print $1}' | head -1)
        [[ -z "$TARGET" ]] && TARGET="1"
      fi
      android_resolve_device "$TARGET"
      echo "Target: $DEVICE_ID"
      _default_run_android
      ;;
    web)
      if declare -f devcast_run_web >/dev/null 2>&1; then
        devcast_run_web "$TARGET"
        exit 0
      fi
      _default_run_web "$TARGET"
      ;;
    mac)
      if declare -f devcast_run_mac >/dev/null 2>&1; then
        devcast_run_mac "$TARGET"
        exit 0
      fi
      _default_run_mac
      ;;
  esac
fi
