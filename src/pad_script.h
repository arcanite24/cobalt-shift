// Cobalt Shift - scripted controller for automated runs
//
// --pad_script_file=<path> adds a synthetic controller for user 0 that reads
// commands from a text file. The file is polled; when it appears, its lines
// are queued and the file is deleted, so a tool can drive the game while the
// window is in the background. One command per line:
//
//   A 150            hold a button (A B X Y START BACK LB RB LS RS UP DOWN
//                    LEFT RIGHT) for 150 ms, then release it
//   wait 500         idle for 500 ms
//   lx -1.0 2000     hold a stick axis (lx ly rx ry, -1..1) for 2000 ms
//   rt 1.0 3000      hold a trigger (lt rt, 0..1) for 3000 ms
//   hold rt 1.0      set a value with no end (until "release")
//   release          clear every held value
//
// Commands run one after another. Lines starting with # are ignored.

#pragma once

namespace rex::input {
class InputSystem;
}

namespace cobalt {

void InstallPadScript(rex::input::InputSystem* input);

}  // namespace cobalt
