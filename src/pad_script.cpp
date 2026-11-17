// Cobalt Shift - scripted controller for automated runs (see pad_script.h)

#include "pad_script.h"

#include <rex/cvar.h>
#include <rex/input/input_driver.h>
#include <rex/input/input_system.h>
#include <rex/logging.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

REXCVAR_DEFINE_STRING(pad_script_file, "", "Cobalt",
                      "Text file of controller commands to play (polled; deleted once read)");

namespace cobalt {

using rex::X_RESULT;
using rex::X_STATUS;

namespace {

using Clock = std::chrono::steady_clock;
constexpr rex::input::DeviceId kScriptDevice = static_cast<rex::input::DeviceId>(0x5343524950);

struct Command {
  enum class Kind { kButton, kAxis, kWait, kHold, kRelease } kind = Kind::kWait;
  uint16_t button = 0;
  int axis = 0;  // 0 lx, 1 ly, 2 rx, 3 ry, 4 lt, 5 rt
  float value = 0;
  int ms = 0;
};

uint16_t ButtonByName(const std::string& name) {
  struct Entry { const char* name; uint16_t bit; };
  static const Entry kButtons[] = {
      {"A", 0x1000},     {"B", 0x2000},     {"X", 0x4000},      {"Y", 0x8000},
      {"START", 0x0010}, {"BACK", 0x0020},  {"LS", 0x0040},     {"RS", 0x0080},
      {"LB", 0x0100},    {"RB", 0x0200},    {"UP", 0x0001},     {"DOWN", 0x0002},
      {"LEFT", 0x0004},  {"RIGHT", 0x0008},
  };
  for (const auto& entry : kButtons) {
    if (name == entry.name) return entry.bit;
  }
  return 0;
}

int AxisByName(const std::string& name) {
  static const char* kAxes[] = {"lx", "ly", "rx", "ry", "lt", "rt"};
  for (int i = 0; i < 6; ++i) {
    if (name == kAxes[i]) return i;
  }
  return -1;
}

class PadScriptDriver final : public rex::input::InputDriver {
 public:
  explicit PadScriptDriver(std::filesystem::path path)
      : InputDriver(nullptr, 0), path_(std::move(path)) {}

  X_STATUS Setup() override { return X_STATUS_SUCCESS; }

  void EnumerateDevices(std::vector<rex::input::DeviceInfo>& out) override {
    rex::input::DeviceInfo info;
    info.id = kScriptDevice;
    info.name = "Pad script";
    info.synthetic = true;
    out.push_back(info);
  }

  X_RESULT GetDeviceCapabilities(rex::input::DeviceId id, uint32_t,
                                 rex::input::X_INPUT_CAPABILITIES* caps) override {
    if (id != kScriptDevice) return X_ERROR_DEVICE_NOT_CONNECTED;
    if (caps) {
      std::memset(caps, 0, sizeof(*caps));
      caps->type = 0x01;
      caps->sub_type = 0x01;
      caps->gamepad.buttons = 0xFFFF;
      caps->gamepad.left_trigger = 0xFF;
      caps->gamepad.right_trigger = 0xFF;
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT GetDeviceState(rex::input::DeviceId id, rex::input::X_INPUT_STATE* out) override {
    if (id != kScriptDevice) return X_ERROR_DEVICE_NOT_CONNECTED;
    std::lock_guard<std::mutex> lock(mutex_);
    Poll();
    Advance();
    if (out) {
      std::memset(out, 0, sizeof(*out));
      out->packet_number = packet_;
      uint16_t buttons = held_buttons_;
      float axes[6];
      std::copy(std::begin(held_axes_), std::end(held_axes_), axes);
      if (active_) {
        if (current_.kind == Command::Kind::kButton) buttons |= current_.button;
        if (current_.kind == Command::Kind::kAxis) axes[current_.axis] = current_.value;
      }
      out->gamepad.buttons = buttons;
      auto stick = [](float v) {
        return static_cast<int16_t>(std::clamp(v, -1.0f, 1.0f) * 32767.0f);
      };
      auto trigger = [](float v) {
        return static_cast<uint8_t>(std::clamp(v, 0.0f, 1.0f) * 255.0f);
      };
      out->gamepad.thumb_lx = stick(axes[0]);
      out->gamepad.thumb_ly = stick(axes[1]);
      out->gamepad.thumb_rx = stick(axes[2]);
      out->gamepad.thumb_ry = stick(axes[3]);
      out->gamepad.left_trigger = trigger(axes[4]);
      out->gamepad.right_trigger = trigger(axes[5]);
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT SetDeviceVibration(rex::input::DeviceId id, rex::input::X_INPUT_VIBRATION*) override {
    return id == kScriptDevice ? X_ERROR_SUCCESS : X_ERROR_DEVICE_NOT_CONNECTED;
  }

  X_RESULT GetDeviceKeystroke(rex::input::DeviceId id, uint32_t,
                              rex::input::X_INPUT_KEYSTROKE*) override {
    return id == kScriptDevice ? X_ERROR_EMPTY : X_ERROR_DEVICE_NOT_CONNECTED;
  }

 private:
  void Poll() {
    const auto now = Clock::now();
    if (now < next_poll_) return;
    next_poll_ = now + std::chrono::milliseconds(100);
    std::error_code ec;
    if (!std::filesystem::exists(path_, ec)) return;
    std::ifstream in(path_);
    std::string line;
    while (std::getline(in, line)) Parse(line);
    in.close();
    std::filesystem::remove(path_, ec);
  }

  void Parse(const std::string& line) {
    std::istringstream words(line);
    std::string head;
    if (!(words >> head) || head[0] == '#') return;
    Command command;
    if (head == "wait") {
      command.kind = Command::Kind::kWait;
      words >> command.ms;
    } else if (head == "release") {
      command.kind = Command::Kind::kRelease;
    } else if (head == "hold") {
      std::string what;
      words >> what;
      command.kind = Command::Kind::kHold;
      command.axis = AxisByName(what);
      if (command.axis < 0) {
        std::transform(what.begin(), what.end(), what.begin(), ::toupper);
        command.button = ButtonByName(what);
      } else {
        words >> command.value;
      }
    } else if (int axis = AxisByName(head); axis >= 0) {
      command.kind = Command::Kind::kAxis;
      command.axis = axis;
      words >> command.value >> command.ms;
    } else {
      std::string upper = head;
      std::transform(upper.begin(), upper.end(), upper.begin(), ::toupper);
      command.button = ButtonByName(upper);
      if (!command.button) {
        REXLOG_WARN("pad script: unknown command '{}'", line);
        return;
      }
      command.kind = Command::Kind::kButton;
      command.ms = 150;
      words >> command.ms;
    }
    queue_.push_back(command);
  }

  void Advance() {
    const auto now = Clock::now();
    if (active_ && now < until_) return;
    active_ = false;
    while (!queue_.empty()) {
      current_ = queue_.front();
      queue_.pop_front();
      ++packet_;
      switch (current_.kind) {
        case Command::Kind::kRelease:
          held_buttons_ = 0;
          std::fill(std::begin(held_axes_), std::end(held_axes_), 0.0f);
          continue;
        case Command::Kind::kHold:
          if (current_.axis >= 0) {
            held_axes_[current_.axis] = current_.value;
          } else {
            held_buttons_ |= current_.button;
          }
          continue;
        default:
          active_ = true;
          until_ = now + std::chrono::milliseconds(current_.ms);
          return;
      }
    }
  }

  std::filesystem::path path_;
  std::mutex mutex_;
  std::deque<Command> queue_;
  Command current_;
  bool active_ = false;
  Clock::time_point until_{};
  Clock::time_point next_poll_{};
  uint16_t held_buttons_ = 0;
  float held_axes_[6] = {};
  uint32_t packet_ = 0;
};

}  // namespace

void InstallPadScript(rex::input::InputSystem* input) {
  const std::string path = REXCVAR_GET(pad_script_file);
  if (!input || path.empty()) return;
  input->AddDriver(std::make_unique<PadScriptDriver>(path));
  REXLOG_INFO("pad script: reading commands from {}", path);
}

}  // namespace cobalt
