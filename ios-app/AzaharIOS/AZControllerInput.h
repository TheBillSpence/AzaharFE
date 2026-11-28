#pragma once

#import <GameController/GameController.h>
#include "AZGameInput.h"

namespace AZInput {
inline Pad ReadGamepad(GCExtendedGamepad *gamepad) {
    Pad pad;
    // Match the printed Xbox button letters to the corresponding 3DS letters.
    pad.Button(RETRO_DEVICE_ID_JOYPAD_A, gamepad.buttonA.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_B, gamepad.buttonB.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_X, gamepad.buttonX.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_Y, gamepad.buttonY.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_UP, gamepad.dpad.up.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_DOWN, gamepad.dpad.down.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_LEFT, gamepad.dpad.left.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_RIGHT, gamepad.dpad.right.isPressed);
    // Ocarina of Time 3D Z-targets with the 3DS L button. Swap LT/LB.
    pad.Button(RETRO_DEVICE_ID_JOYPAD_L, gamepad.leftTrigger.value >= 0.2f);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_R, gamepad.rightShoulder.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_L2, gamepad.leftShoulder.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_R2, gamepad.rightTrigger.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_L3, gamepad.leftThumbstickButton.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_R3, gamepad.rightThumbstickButton.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_START, gamepad.buttonMenu.isPressed);
    pad.Button(RETRO_DEVICE_ID_JOYPAD_SELECT, gamepad.buttonOptions.isPressed);
    pad.axes[0][0] = AZInput::Axis(gamepad.leftThumbstick.xAxis.value);
    pad.axes[0][1] = AZInput::Axis(-gamepad.leftThumbstick.yAxis.value);
    pad.axes[1][0] = AZInput::Axis(gamepad.rightThumbstick.xAxis.value);
    pad.axes[1][1] = AZInput::Axis(-gamepad.rightThumbstick.yAxis.value);
    return pad;
}
} // namespace AZInput
