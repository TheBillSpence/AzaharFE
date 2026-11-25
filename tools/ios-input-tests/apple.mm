#import "AZOptions.h"
#include "AZControllerInput.h"
#include <cassert>

int main() {
    @autoreleasepool {
        NSURL *game = [NSURL fileURLWithPath:@"/Ocarina.3ds"];
        assert([AZLaunchOptions(game)[@"AzaharJITPreset"] isEqual:@"combined"]);
        assert([AZLaunchOptions(game)[@"AzaharJITSpeed"] isEqual:@"fastmem"]);
        assert([AZLaunchOptions(game)[@"AzaharShaderJIT"] isEqual:@"on"]);
        assert([AZChoices(@"AzaharJITSpeed") containsObject:@"hyperfp"]);
        assert([AZLaunchOptions(game)[@"citra_use_disk_shader_cache"] isEqual:@"enabled"]);
        assert([AZLaunchOptions(game)[@"AzaharAsyncShaders"] isEqual:@"off"]);
        AZSetValue(@"citra_use_disk_shader_cache", @"disabled", game);
        assert([AZLaunchOptions(game)[@"citra_use_disk_shader_cache"] isEqual:@"disabled"]);
        AZSetValue(@"citra_use_disk_shader_cache", nil, game);
        assert([AZLaunchOptions(game)[@"AzaharExperimentalJIT"] isEqual:@"on"]);
        AZSetValue(@"AzaharJITSpeed", @"linked", game);
        assert([AZLaunchOptions(game)[@"AzaharJITPreset"] isEqual:@"custom"]);
        assert([AZLaunchOptions(game)[@"AzaharExperimentalJIT"] isEqual:@"off"]);
        AZSetValue(@"AzaharExperimentalJIT", @"on", game);
        assert([AZLaunchOptions(game)[@"AzaharJITSpeed"] isEqual:@"linked"]);
        AZSetValue(@"AzaharJITPreset", @"off", nil);
        assert([AZLaunchOptions(game)[@"AzaharExperimentalJIT"] isEqual:@"on"]);
        AZSetValue(@"AzaharJITPreset", nil, game);
        assert([AZLaunchOptions(game)[@"AzaharExperimentalJIT"] isEqual:@"off"]);
        AZSetValue(@"AzaharJITPreset", @"combined", game);
        assert([AZLaunchOptions(game)[@"AzaharExperimentalJIT"] isEqual:@"on"]);
        assert([AZLaunchOptions(nil)[@"AzaharExperimentalJIT"] isEqual:@"off"]);
        assert([AZLaunchOptions(nil)[@"AzaharShaderJIT"] isEqual:@"off"]);
        assert([AZLaunchOptions(game)[@"AzaharShaderJIT"] isEqual:@"on"]);
        AZResetGameOptions(game);
        NSDictionary *before = AZLaunchOptions(game);
        assert(!AZLaunchOptionsRequireRestart(before, [before copy]));
        NSMutableDictionary *after = [before mutableCopy];
        after[@"citra_graphics_api"] = [before[@"citra_graphics_api"] isEqual:@"Vulkan"] ? @"Software" : @"Vulkan";
        assert(AZLaunchOptionsRequireRestart(before, after));
        after = [before mutableCopy];
        after[@"AzaharExperimentalJIT"] = [before[@"AzaharExperimentalJIT"] isEqual:@"on"] ? @"off" : @"on";
        assert(AZLaunchOptionsRequireRestart(before, after));

        GCController *synthetic = [GCController controllerWithExtendedGamepad];
        GCExtendedGamepad *gc = synthetic.extendedGamepad;
        [gc.buttonB setValue:1.0f];
        [gc.leftShoulder setValue:1.0f];
        [gc.leftThumbstick setValueForXAxis:0.5f yAxis:1.0f];
        const auto pad = AZInput::ReadGamepad(gc);
        assert(pad.buttons & (1u << RETRO_DEVICE_ID_JOYPAD_A));
        assert(!(pad.buttons & (1u << RETRO_DEVICE_ID_JOYPAD_B)));
        assert(pad.buttons & (1u << RETRO_DEVICE_ID_JOYPAD_L));
        assert(pad.axes[0][0] == 16384 && pad.axes[0][1] == -32767);
    }
}
