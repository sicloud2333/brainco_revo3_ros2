#!/usr/bin/env bash
set -euo pipefail

# One-time Revo3 serial bootstrap: discover -> udev -> permissions -> check
#
# Usage:
#   bash bootstrap_revo3.sh                    # default: auto-detect connected hands
#   bash bootstrap_revo3.sh --manual           # interactive: discover + type ports
#   bash bootstrap_revo3.sh /dev/ttyACM6 l /dev/ttyACM1 r

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=role_mapping_utils.sh
source "${SCRIPT_DIR}/role_mapping_utils.sh"

usage() {
  cat <<EOF
Usage:
  bash bootstrap_revo3.sh                    Auto-detect connected hands (default)
  bash bootstrap_revo3.sh --auto             Same as default (compat)
  bash bootstrap_revo3.sh --manual           Interactive: discover + enter ports
  bash bootstrap_revo3.sh <dev> <l|r> <dev> <l|r>
  bash bootstrap_revo3.sh <left_dev> <right_dev>
  bash bootstrap_revo3.sh <dev> left|right

Examples:
  bash bootstrap_revo3.sh
  bash bootstrap_revo3.sh --manual
  bash bootstrap_revo3.sh /dev/ttyACM6 l /dev/ttyACM1 r
EOF
}

auto_detect_ports() {
  echo "[1/4] Auto-detect connected Revo3 hands on serial (slave 126=left, 127=right)..."
  # Some drivers (e.g. ch343) require world-readable permissions beyond dialout group
  apply_serial_permissions
  local output left_port right_port
  if ! output="$(bash "${SCRIPT_DIR}/detect_revo3_ports_auto.sh" 2>&1)"; then
    echo "${output}" >&2
    echo >&2
    bash "${SCRIPT_DIR}/discover_revo3_serial.sh" >&2 || true
    echo >&2
    echo "[INFO] If discovery shows no /dev/ttyUSB*, /dev/ttyACM*, or /dev/ttyCH343* devices:" >&2
    echo "       1. Verify both Revo3 USB/RS485 adapters are plugged in and powered." >&2
    echo "       2. Check kernel USB logs: sudo dmesg -T | tail -n 80" >&2
    echo "       3. Check whether the CH34x/CH343 driver is loaded: lsmod | grep -E 'ch34|usbserial'" >&2
    echo "[ERROR] auto-detect failed. Plug in at least one hand, or use: bash bootstrap_revo3.sh --manual" >&2
    return 1
  fi
  echo "${output}"

  left_port="$(echo "${output}" | sed -n 's/^REVO3_LEFT_PORT=//p' | head -n1)"
  right_port="$(echo "${output}" | sed -n 's/^REVO3_RIGHT_PORT=//p' | head -n1)"

  if [[ -z "${left_port}" && -z "${right_port}" ]]; then
    echo "[ERROR] could not parse any REVO3_LEFT_PORT / REVO3_RIGHT_PORT from detector." >&2
    return 1
  fi

  echo "[2/4] Installing udev rules from auto-detect..."
  local -a tokens=()
  if [[ -n "${left_port}" ]]; then
    tokens+=("${left_port}" l)
  fi
  if [[ -n "${right_port}" ]]; then
    tokens+=("${right_port}" r)
  fi
  install_udev_from_tokens "${tokens[@]}"
}

interactive_bootstrap() {
  echo "[1/4] Discovery..."
  bash "${SCRIPT_DIR}/discover_revo3_serial.sh" || true
  echo
  echo "[2/4] Install udev rules"
  read -r -p "Enter LEFT hand serial (e.g. /dev/ttyACM6): " LEFT_DEV
  read -r -p "Enter RIGHT hand serial (e.g. /dev/ttyACM1): " RIGHT_DEV
  if [[ -z "${LEFT_DEV}" || -z "${RIGHT_DEV}" ]]; then
    echo "[ERROR] devices cannot be empty." >&2
    exit 1
  fi
  echo "[*] Installing udev rules..."
  install_udev_from_tokens "${LEFT_DEV}" "${RIGHT_DEV}"
}

apply_serial_permissions() {
  local dev
  shopt -s nullglob
  # udev symlinks
  for dev in /dev/revo3_hand_left /dev/revo3_hand_right; do
    sudo chmod a+rw "$dev" 2>/dev/null || true
  done
  # USB serial ports used by Revo3 RS485 adapters.
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/ttyCH*; do
    sudo chmod a+rw "$dev" 2>/dev/null || true
  done
  shopt -u nullglob
}

install_udev_from_tokens() {
  local -a tokens=("$@")
  local -a setup_args=()

  if [[ "${#tokens[@]}" -eq 4 ]]; then
    setup_args=("${tokens[@]}")
  elif [[ "${#tokens[@]}" -eq 2 ]]; then
    role_map_resolve_tokens tokens || return 1
    if [[ -n "${ROLE_MAP_LEFT_DEV}" && -n "${ROLE_MAP_RIGHT_DEV}" ]]; then
      setup_args=("${ROLE_MAP_LEFT_DEV}" "${ROLE_MAP_RIGHT_DEV}")
    elif [[ -n "${ROLE_MAP_LEFT_DEV}" ]]; then
      setup_args=("${ROLE_MAP_LEFT_DEV}" "left")
    else
      setup_args=("${ROLE_MAP_RIGHT_DEV}" "right")
    fi
  else
    return 1
  fi

  role_map_resolve_tokens setup_args || return 1
  [[ -n "${ROLE_MAP_LEFT_DEV}" ]] && echo "      LEFT  -> ${ROLE_MAP_LEFT_DEV}"
  [[ -n "${ROLE_MAP_RIGHT_DEV}" ]] && echo "      RIGHT -> ${ROLE_MAP_RIGHT_DEV}"

  sudo bash "${SCRIPT_DIR}/setup_revo3_udev_rules.sh" "${setup_args[@]}"
}

finish_bootstrap() {
  echo "[3/4] Waiting for symlinks (3s)..."
  sleep 3
  echo "[*] Serial permissions..."
  apply_serial_permissions
  echo "[*] Updating protocol configs..."
  update_protocol_config_ports
  echo "[4/4] Health check..."
  bash "${SCRIPT_DIR}/check_revo3_setup.sh"
  echo
  echo "[DONE] protocol_modbus_left/right.yaml use:"
  echo "  port: /dev/revo3_hand_left  (slave_id 126)"
  echo "  port: /dev/revo3_hand_right (slave_id 127)"
  echo ""
  echo "Launch: ros2 launch revo3_driver dual_revo3_system.launch.py"
}

set_protocol_config_port() {
  local cfg="$1"
  local port="$2"

  if [[ ! -f "${cfg}" ]]; then
    echo "[WARN] config not found: ${cfg}" >&2
    return 0
  fi

  sed -i -E "s#^([[:space:]]*port:).*#\\1 ${port}#" "${cfg}"
}

update_protocol_config_ports() {
  local pkg_root
  pkg_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

  set_protocol_config_port "${pkg_root}/config/protocol_modbus_left.yaml" "/dev/revo3_hand_left"
  set_protocol_config_port "${pkg_root}/config/protocol_modbus_right.yaml" "/dev/revo3_hand_right"
}

main() {
  echo "== Revo3 Serial Bootstrap (revo3_hand_left / revo3_hand_right) =="
  bash "${SCRIPT_DIR}/build_detect_revo3_ports.sh"

  if [[ "$#" -eq 0 || "${1:-}" == "--auto" ]]; then
    auto_detect_ports
    finish_bootstrap
    return 0
  fi

  if [[ "${1:-}" == "--manual" ]]; then
    interactive_bootstrap
    finish_bootstrap
    return 0
  fi

  if [[ "$#" -eq 2 || "$#" -eq 4 ]]; then
    echo "[1/3] Installing udev rules..."
    install_udev_from_tokens "$@" || {
      usage
      role_map_usage_lines
      exit 1
    }
    finish_bootstrap
    return 0
  fi

  usage
  exit 1
}

main "$@"
