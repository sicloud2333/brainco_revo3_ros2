#!/usr/bin/env bash
set -euo pipefail

LEFT_LINK="/dev/revo3_hand_left"
RIGHT_LINK="/dev/revo3_hand_right"
RULE_FILE="/etc/udev/rules.d/99-revo3-hands.rules"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAILED=1; }
info() { echo "[INFO] $*"; }

check_link() {
  local link="$1"
  if [[ -e "${link}" ]]; then
    local real
    real="$(readlink -f "${link}" || true)"
    pass "${link} -> ${real}"
  else
    fail "${link} does not exist"
  fi
}

check_rule_file() {
  if [[ -f "${RULE_FILE}" ]]; then
    pass "udev rule exists: ${RULE_FILE}"
  else
    fail "udev rule missing: ${RULE_FILE}"
    info "Run: sudo bash ${SCRIPT_DIR}/setup_revo3_udev_rules.sh <left> l <right> r"
  fi
}

rule_has_link() {
  local link_name="$1"
  [[ -f "${RULE_FILE}" ]] && grep -Fq "SYMLINK+=\"${link_name}\"" "${RULE_FILE}"
}

yaml_port_value() {
  local cfg="$1"
  awk -F: '
    $1 ~ /^[[:space:]]*port[[:space:]]*$/ {
      value = $2
      sub(/#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "${cfg}"
}

check_config_port() {
  local cfg="$1"
  local label="$2"
  local expected="$3"

  if [[ ! -f "${cfg}" ]]; then
    info "${label} not found"
    return
  fi

  local current
  current="$(yaml_port_value "${cfg}")"
  if [[ "${current}" == "${expected}" ]]; then
    pass "${label} uses ${expected}"
  else
    fail "${label} port=${current:-<empty>} (expected ${expected})"
  fi
}

check_config_ports() {
  local pkg_root cfg_left cfg_right
  pkg_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

  cfg_left="${pkg_root}/config/protocol_modbus_left.yaml"
  cfg_right="${pkg_root}/config/protocol_modbus_right.yaml"

  if [[ "${EXPECT_LEFT}" -eq 1 ]]; then
    check_config_port "${cfg_left}" "protocol_modbus_left.yaml" "/dev/revo3_hand_left"
  fi
  if [[ "${EXPECT_RIGHT}" -eq 1 ]]; then
    check_config_port "${cfg_right}" "protocol_modbus_right.yaml" "/dev/revo3_hand_right"
  fi
}

select_expected_hands() {
  EXPECT_LEFT=0
  EXPECT_RIGHT=0

  case "${1:-auto}" in
    left|l)
      EXPECT_LEFT=1
      ;;
    right|r)
      EXPECT_RIGHT=1
      ;;
    both|bimanual)
      EXPECT_LEFT=1
      EXPECT_RIGHT=1
      ;;
    auto)
      if rule_has_link "revo3_hand_left"; then
        EXPECT_LEFT=1
      fi
      if rule_has_link "revo3_hand_right"; then
        EXPECT_RIGHT=1
      fi
      if [[ "${EXPECT_LEFT}" -eq 0 && "${EXPECT_RIGHT}" -eq 0 ]]; then
        EXPECT_LEFT=1
        EXPECT_RIGHT=1
      fi
      ;;
    *)
      echo "Usage: $0 [auto|left|right|both]" >&2
      exit 2
      ;;
  esac
}

main() {
  FAILED=0
  select_expected_hands "${1:-auto}"
  echo "=== Revo3 serial setup check ==="
  check_rule_file

  if [[ "${EXPECT_LEFT}" -eq 1 ]] && rule_has_link "revo3_hand_left"; then
    pass "udev maps revo3_hand_left"
  elif [[ "${EXPECT_LEFT}" -eq 1 && -f "${RULE_FILE}" ]]; then
    fail "udev rule has no SYMLINK+=\"revo3_hand_left\""
  fi

  if [[ "${EXPECT_RIGHT}" -eq 1 ]] && rule_has_link "revo3_hand_right"; then
    pass "udev maps revo3_hand_right"
  elif [[ "${EXPECT_RIGHT}" -eq 1 && -f "${RULE_FILE}" ]]; then
    fail "udev rule has no SYMLINK+=\"revo3_hand_right\""
  fi

  if [[ "${EXPECT_LEFT}" -eq 1 ]]; then
    check_link "${LEFT_LINK}"
  fi
  if [[ "${EXPECT_RIGHT}" -eq 1 ]]; then
    check_link "${RIGHT_LINK}"
  fi

  if [[ "${EXPECT_LEFT}" -eq 1 && "${EXPECT_RIGHT}" -eq 1 && -e "${LEFT_LINK}" && -e "${RIGHT_LINK}" ]]; then
    local left_real right_real
    left_real="$(readlink -f "${LEFT_LINK}" || true)"
    right_real="$(readlink -f "${RIGHT_LINK}" || true)"
    if [[ -n "${left_real}" && "${left_real}" == "${right_real}" ]]; then
      fail "revo3_hand_left and revo3_hand_right both resolve to ${left_real}"
      info "Re-run: sudo bash ${SCRIPT_DIR}/setup_revo3_udev_rules.sh --path-mode exact <left> l <right> r"
    else
      pass "left/right symlinks point to distinct serial devices"
    fi
  fi

  check_config_ports

  if [[ "${FAILED}" -eq 0 ]]; then
    echo "[OK] Revo3 serial setup looks good."
    exit 0
  fi
  echo "[WARN] Fix issues above, then re-run bootstrap_revo3.sh"
  exit 1
}

main "$@"
