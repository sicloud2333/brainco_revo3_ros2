// Copyright (c) 2025 BrainCo
// Setup tool: Revo3 Modbus port scanner (slave_id 126=left, 127=right).
// Built by revo3_driver CMake; used only by setup/bootstrap_revo3.sh --auto.

#include <stark-sdk.h>

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <regex>
#include <string>
#include <unordered_map>
#include <vector>

namespace
{

constexpr uint8_t kLeftSlaveId = 126;
constexpr uint8_t kRightSlaveId = 127;

// ── scan_serial_ports ──────────────────────────────────────────────────────────
// Discover USB serial ports used by Revo3 RS485 adapters.
std::vector<std::string> scan_serial_ports()
{
  std::vector<std::string> ports;
  const std::regex serial_re(R"(^tty(USB|ACM|CH))");
  std::error_code ec;

  for (const auto & entry : std::filesystem::directory_iterator("/dev", ec)) {
    if (ec) { break; }
    if (!entry.is_character_file(ec)) { continue; }
    const std::string name = entry.path().filename().string();
    if (std::regex_search(name, serial_re)) {
      ports.push_back(entry.path().string());
    }
  }

  // Sort for deterministic order
  std::sort(ports.begin(), ports.end());
  return ports;
}

bool probe_port(const std::string & port, uint8_t & slave_id_out)
{
  struct DetectedDeviceListDeleter
  {
    void operator()(CDetectedDeviceList * list) const
    {
      if (list) {
        free_detected_device_list(list);
      }
    }
  };
  using DetectedDeviceListPtr = std::unique_ptr<CDetectedDeviceList, DetectedDeviceListDeleter>;

  DetectedDeviceListPtr list{stark_auto_detect(true, port.c_str(), STARK_PROTOCOL_TYPE_MODBUS)};
  if (!list || list->count == 0 || !list->devices) {
    return false;
  }

  for (std::uintptr_t i = 0; i < list->count; ++i) {
    const CDetectedDevice & device = list->devices[i];
    if (device.protocol != STARK_PROTOCOL_TYPE_MODBUS || !device.port_name) {
      continue;
    }

    const std::string detected_port = device.port_name;
    if (detected_port != port) {
      continue;
    }

    slave_id_out = device.slave_id;
    return true;
  }

  return false;
}

}  // namespace

int main()
{
  init_logging(LOG_LEVEL_ERROR);

  std::unordered_map<uint8_t, std::string> by_slave;
  const auto ports = scan_serial_ports();

  if (ports.empty()) {
    std::fprintf(stderr, "[ERROR] no USB serial ports found in /dev/ (ttyUSB*, ttyACM*, ttyCH*)\n");
    return 1;
  }

  std::printf("[INFO] scanning %zu serial port(s) for Revo3 Modbus...\n", ports.size());

  for (const auto & port : ports) {
    uint8_t slave_id = 0;
    if (!probe_port(port, slave_id)) {
      continue;
    }
    std::printf("[OK] port=%s slave_id=%u\n", port.c_str(), slave_id);

    const auto existing = by_slave.find(slave_id);
    if (existing != by_slave.end() && existing->second != port) {
      std::fprintf(
        stderr, "[WARN] duplicate slave_id %u on %s and %s\n", slave_id, existing->second.c_str(),
        port.c_str());
    }
    by_slave[slave_id] = port;
  }

  const auto left_it = by_slave.find(kLeftSlaveId);
  const auto right_it = by_slave.find(kRightSlaveId);

  if (left_it != by_slave.end()) {
    std::printf("REVO3_LEFT_PORT=%s\n", left_it->second.c_str());
    std::printf("REVO3_LEFT_SLAVE=%u\n", kLeftSlaveId);
  }
  if (right_it != by_slave.end()) {
    std::printf("REVO3_RIGHT_PORT=%s\n", right_it->second.c_str());
    std::printf("REVO3_RIGHT_SLAVE=%u\n", kRightSlaveId);
  }

  if (left_it == by_slave.end() && right_it == by_slave.end()) {
    std::fprintf(
      stderr,
      "[ERROR] need at least one Revo3 hand: slave_id %u (left) or %u (right). Found %zu device(s).\n",
      kLeftSlaveId, kRightSlaveId, by_slave.size());
    for (const auto & entry : by_slave) {
      std::fprintf(stderr, "        slave_id=%u port=%s\n", entry.first, entry.second.c_str());
    }
    return 1;
  }

  if (left_it == by_slave.end() || right_it == by_slave.end()) {
    std::fprintf(
      stderr,
      "[WARN] detected only one Revo3 hand. Missing slave_id %u (%s).\n",
      left_it == by_slave.end() ? kLeftSlaveId : kRightSlaveId,
      left_it == by_slave.end() ? "left" : "right");
  }

  return 0;
}
