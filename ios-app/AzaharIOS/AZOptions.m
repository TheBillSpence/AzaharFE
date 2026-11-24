#import "AZOptions.h"

NSArray<NSString *> *AZOptionKeys(void) {
    return @[@"AzaharJITPreset", @"AzaharExperimentalJIT", @"AzaharJITSpeed", @"AzaharDeepProfile",
             @"AzaharSoftwareThreads", @"citra_graphics_api", @"citra_resolution_factor",
             @"citra_layout_option", @"citra_swap_screen", @"citra_use_disk_shader_cache",
             @"AzaharAsyncShaders"];
}
NSString *AZOptionTitle(NSString *key) {
    return @{@"AzaharJITPreset":@"JIT", @"AzaharExperimentalJIT":@"CPU JIT", @"AzaharJITSpeed":@"JIT performance mode",
             @"AzaharDeepProfile":@"Detailed CPU/GPU profiling",
             @"AzaharSoftwareThreads":@"Software graphics threads",
             @"citra_graphics_api":@"Graphics API",
             @"citra_resolution_factor":@"Output resolution",
             @"citra_layout_option":@"Screen layout",
             @"citra_swap_screen":@"Primary screen",
             @"citra_use_disk_shader_cache":@"Shader precompilation / cache",
             @"AzaharAsyncShaders":@"Async shader compilation"}[key];
}
NSArray<NSString *> *AZChoices(NSString *key) {
    if ([key isEqual:@"AzaharJITPreset"]) return @[@"combined", @"off", @"custom"];
    if ([key isEqual:@"AzaharExperimentalJIT"]) return @[@"off", @"on"];
    // The first value preserves the speed default for legacy manual configurations.
    if ([key isEqual:@"AzaharJITSpeed"]) return @[@"fast", @"fastmem", @"fastmemfp", @"hyper", @"hyperfp", @"turbo", @"direct", @"linked", @"safe"];
    if ([key isEqual:@"AzaharDeepProfile"] || [key isEqual:@"AzaharAsyncShaders"]) return @[@"off", @"on"];
    if ([key isEqual:@"citra_use_disk_shader_cache"]) return @[@"enabled", @"disabled"];
    if ([key isEqual:@"AzaharSoftwareThreads"]) return @[@"auto", @"2", @"4", @"6"];
    // Safe default, per-game overrides require explicit experimental opt-in.
    if ([key isEqual:@"citra_graphics_api"]) return @[@"Software", @"Vulkan"];
    if ([key isEqual:@"citra_resolution_factor"]) return @[@"1", @"2", @"3", @"4"];
    if ([key isEqual:@"citra_layout_option"]) return @[@"default", @"single_screen", @"large_screen", @"side_by_side"];
    return @[@"Top", @"Bottom"];
}
NSString *AZChoiceTitle(NSString *key, NSString *v) {
    if ([key isEqual:@"AzaharSoftwareThreads"] && ![v isEqual:@"auto"])
        return [NSString stringWithFormat:@"%@ threads", v];
    return @{@"combined":@"Automatic (128 MiB Fastmem)", @"custom":@"Advanced settings",
             @"on":@"On", @"off":@"Off", @"enabled":@"Enabled", @"disabled":@"Disabled",
             @"safe":@"Compatibility (fallback)", @"linked":@"Linked blocks (test)",
             @"fast":@"Fast dispatch", @"fastmem":@"128 MiB + True Fastmem",
             @"fastmemfp":@"128 MiB + Fastmem + relaxed FP", @"hyper":@"Hyper JIT (page table)",
             @"hyperfp":@"Hyper JIT + relaxed FP (highest risk)", @"turbo":@"Turbo JIT (experimental)",
             @"direct":@"Turbo + Direct RAM (high risk)",
             @"auto":@"Automatic", @"Software":@"Software (safe default)",
             @"Vulkan":@"Vulkan via MoltenVK (experimental)",
             @"1":@"1× Native (400×240)", @"2":@"2× (800×480)",
             @"3":@"3× (1200×720)", @"4":@"4× (1600×960)",
             @"default":@"Top and bottom", @"single_screen":@"Single screen",
             @"large_screen":@"Large and small", @"side_by_side":@"Side by side"}[v] ?: v;
}
static NSString *GameKey(NSURL *game) {
    return [@"AZGameOptions/" stringByAppendingString:game.lastPathComponent];
}
BOOL AZHasOverride(NSString *key, NSURL *game) {
    return [AZChoices(key) containsObject:[NSUserDefaults.standardUserDefaults dictionaryForKey:GameKey(game)][key] ?: @""];
}
NSString *AZValue(NSString *key, NSURL *game) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (game && AZHasOverride(key, game)) return [defaults dictionaryForKey:GameKey(game)][key];
    if ([key isEqual:@"AzaharJITPreset"]) {
        // Existing per-game tuning still takes precedence over the universal preset.
        if (game && (AZHasOverride(@"AzaharExperimentalJIT", game) ||
                     AZHasOverride(@"AzaharJITSpeed", game))) return @"custom";
        NSString *saved = [defaults stringForKey:key];
        if ([AZChoices(key) containsObject:saved ?: @""]) return saved;
        if ([defaults objectForKey:@"AzaharExperimentalJIT"] || [defaults objectForKey:@"AzaharJITSpeed"])
            return @"custom";
        return @"combined";
    }
    if ([key isEqual:@"AzaharExperimentalJIT"]) return [defaults boolForKey:key] ? @"on" : @"off";
    NSString *value = [defaults stringForKey:key];
    return [AZChoices(key) containsObject:value ?: @""] ? value : AZChoices(key).firstObject;
}
NSDictionary<NSString *, NSString *> *AZLaunchOptions(NSURL *game) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in AZOptionKeys()) values[key] = AZValue(key, game);
    NSString *preset = values[@"AzaharJITPreset"];
    if ([preset isEqual:@"combined"]) {
        values[@"AzaharExperimentalJIT"] = @"on";
        values[@"AzaharJITSpeed"] = @"fastmem";
    } else if ([preset isEqual:@"off"]) {
        values[@"AzaharExperimentalJIT"] = @"off";
    } else if (game && (AZHasOverride(@"AzaharJITPreset", game) ||
                        [NSUserDefaults.standardUserDefaults objectForKey:@"AzaharJITPreset"])) {
        NSString *universal = AZValue(@"AzaharJITPreset", nil);
        if (!AZHasOverride(@"AzaharExperimentalJIT", game) && ![universal isEqual:@"custom"])
            values[@"AzaharExperimentalJIT"] = [universal isEqual:@"combined"] ? @"on" : @"off";
        if (!AZHasOverride(@"AzaharJITSpeed", game) && [universal isEqual:@"combined"])
            values[@"AzaharJITSpeed"] = @"fastmem";
    }
    return [values copy];
}
void AZSetValue(NSString *key, NSString *value, NSURL *game) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (game) {
        NSMutableDictionary *values = [[defaults dictionaryForKey:GameKey(game)] mutableCopy] ?: [NSMutableDictionary new];
        values[key] = value;
        if (!value && [key isEqual:@"AzaharJITPreset"]) {
            [values removeObjectForKey:@"AzaharExperimentalJIT"];
            [values removeObjectForKey:@"AzaharJITSpeed"];
        }
        if (values.count) [defaults setObject:values forKey:GameKey(game)];
        else [defaults removeObjectForKey:GameKey(game)];
    } else if ([key isEqual:@"AzaharExperimentalJIT"]) {
        [defaults setBool:[value isEqual:@"on"] forKey:key];
    } else {
        [defaults setObject:value forKey:key];
    }
}
void AZResetGameOptions(NSURL *game) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:GameKey(game)];
}
