#import "AZOptions.h"
#include "AZControllerInput.h"
#include "AZDisplayGeometry.h"
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
        assert([before[@"AzaharPresentation"] isEqual:@"metal"]);
        assert([before[@"AzaharLandscapeLayout"] isEqual:@"corner"]);
        assert(![AZOptionKeys() containsObject:@"AzaharDisplayFPS"]);
        NSMutableDictionary *display = [before mutableCopy];
        display[@"citra_layout_option"] = @"default";
        display[@"citra_swap_screen"] = @"Top";
        const auto corner = AZMakeDisplayGeometry(CGSizeMake(1600,1920),CGSizeMake(800,350),YES,display);
        assert(corner.count == 2 && corner.touchIndex == 1);
        assert(std::abs(corner.destination[0].size.width / corner.destination[0].size.height - 5.0/3) < 0.001);
        assert(CGRectGetMinX(corner.destination[1]) > CGRectGetMaxX(corner.destination[0]));
        display[@"AzaharLandscapeLayout"] = @"stacked";
        const auto stacked = AZMakeDisplayGeometry(CGSizeMake(1600,1920),CGSizeMake(800,350),YES,display);
        assert(stacked.count == 2 && CGRectGetMinY(stacked.destination[1]) > CGRectGetMaxY(stacked.destination[0]));
        assert(std::abs(CGRectGetMidX(stacked.destination[0])-CGRectGetMidX(stacked.destination[1])) < 0.001);
        assert(std::abs(stacked.destination[1].size.height/stacked.destination[0].size.height - 0.30) < 0.001);
        const auto retina = AZMakeDisplayGeometry(CGSizeMake(1600,1920),CGSizeMake(2400,1050),YES,display);
        assert(std::abs(retina.destination[0].size.width/3-stacked.destination[0].size.width) < 0.001);
        assert(std::abs(retina.destination[1].origin.y/3-stacked.destination[1].origin.y) < 0.001);
        display[@"citra_swap_screen"] = @"Bottom";
        const auto swapped = AZMakeDisplayGeometry(CGSizeMake(1600,1920),CGSizeMake(800,350),YES,display);
        assert(swapped.source[0].origin.y == 0.5 && swapped.source[1].origin.y == 0);
        display[@"AzaharLandscapeLayout"] = @"top_only";
        const auto single = AZMakeDisplayGeometry(CGSizeMake(1600,1920),CGSizeMake(800,350),YES,display);
        assert(single.count == 1 && single.touchIndex == -1);
        const auto portrait = AZMakeDisplayGeometry(CGSizeMake(1600,1920),CGSizeMake(350,800),NO,display);
        assert(portrait.count == 1 && portrait.source[0].size.width == 1 && portrait.source[0].size.height == 1);

        assert(!AZLaunchOptionsRequireRestart(before, [before copy]));
        NSMutableDictionary *live = [before mutableCopy];
        live[@"AzaharLandscapeLayout"] = @"stacked";
        assert(!AZLaunchOptionsRequireRestart(before, live));
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
