#include <cassert>
#include "AZGameInput.h"

int main() {
    using namespace AZInput;
    auto center = Project(200, 300, 400, 600, 400, 480);
    assert(center.down && center.x == 0 && center.y == 0);
    assert(!Project(200, 59, 400, 600, 400, 480).down);
    assert(!Project(59, 200, 600, 400, 480, 400).down);
    assert(!Project(200, 540, 400, 600, 400, 480).down);
    assert(!Project(0, 0, 400, 600, 0, 0).down);
    auto corner = Project(0, 60, 400, 600, 400, 480);
    assert(corner.down && corner.x == -32767 && corner.y == -32767);

    State state;
    Pad physical;
    physical.Button(RETRO_DEVICE_ID_JOYPAD_A, true);
    physical.axes[0][1] = Axis(-1.0);
    physical.axes[1][0] = Axis(0.5);
    state.Enable(true);
    state.Button(RETRO_DEVICE_ID_JOYPAD_B, true);
    state.Touch(corner);
    state.Touch(center);
    state.Touch({});
    state.Poll(physical);
    assert(state.Read(RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED));
    assert(state.Read(RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_X) == 0);
    assert(state.Read(RETRO_DEVICE_ANALOG, 0, 1) == -32767);
    assert(state.Read(RETRO_DEVICE_ANALOG, 1, 0) == 16384);
    assert(state.Read(RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A));
    assert(state.Read(RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B));
    state.Circle(32767, 0, true);
    // Virtual axes are visible immediately, including without a physical pad.
    assert(state.Read(RETRO_DEVICE_ANALOG, 0, 0) == 32767);
    state.Poll({});
    assert(state.Read(RETRO_DEVICE_ANALOG, 0, 0) == 32767);
    assert(!state.Read(RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED));
    assert(!state.Read(RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A));
    assert(state.Read(RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B));
    state.Circle(0, 0, true);
    state.Poll(physical);
    assert(state.Read(RETRO_DEVICE_ANALOG, 0, 1) == 0);
    state.Circle(0, 0, false);
    assert(state.Read(RETRO_DEVICE_ANALOG, 0, 1) == -32767);
    const auto [dx, dy] = CircleDeflection(30, 0, 30);
    assert(Axis(dx) == 32767 && Axis(dy) == 0);
    const auto [cx, cy] = CircleDeflection(0, 0, 30);
    assert(cx == 0 && cy == 0);
    state.Touch(center);
    state.Enable(false);
    state.Poll(physical);
    state.Enable(true);
    state.Poll({});
    assert(!state.Read(RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED));
    assert(!state.Read(RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B));
    assert(!state.Read(RETRO_DEVICE_ANALOG, 0, 0));
}
