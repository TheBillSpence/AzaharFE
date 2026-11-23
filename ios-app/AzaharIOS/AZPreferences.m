#import "AZPreferences.h"
#import <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <string.h>

UIColor *AZNavy(void) { return [UIColor colorWithRed:0.035 green:0.080 blue:0.165 alpha:1]; }
UIColor *AZPanel(void) { return [UIColor colorWithRed:0.070 green:0.155 blue:0.285 alpha:1]; }
UIColor *AZBlue(void) { return [UIColor colorWithRed:0.49 green:0.76 blue:1 alpha:1]; }
UIColor *AZYellow(void) { return [UIColor colorWithRed:1 green:0.84 blue:0.27 alpha:1]; }

NSArray<NSString *> *AZOptionKeys(void) {
    return @[@"AzaharExperimentalJIT", @"AzaharJITSpeed", @"citra_layout_option", @"citra_swap_screen"];
}
NSString *AZOptionTitle(NSString *key) {
    return @{@"AzaharExperimentalJIT":@"CPU JIT", @"AzaharJITSpeed":@"JIT performance mode",
             @"citra_layout_option":@"Screen layout",
             @"citra_swap_screen":@"Primary screen"}[key];
}
NSArray<NSString *> *AZChoices(NSString *key) {
    if ([key isEqual:@"AzaharExperimentalJIT"]) return @[@"off", @"on"];
    if ([key isEqual:@"AzaharJITSpeed"]) return @[@"safe", @"linked", @"fast"];
    if ([key isEqual:@"citra_layout_option"]) return @[@"default", @"single_screen", @"large_screen", @"side_by_side"];
    return @[@"Top", @"Bottom"];
}
NSString *AZChoiceTitle(NSString *v) {
    return @{@"on":@"On", @"off":@"Off",
             @"safe":@"Compatibility (current)", @"linked":@"Linked blocks (test)",
             @"fast":@"Fast dispatch (test)", @"default":@"Top and bottom", @"single_screen":@"Single screen",
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
    if ([key isEqual:@"AzaharExperimentalJIT"]) return [defaults boolForKey:key] ? @"on" : @"off";
    NSString *value = [defaults stringForKey:key];
    return [AZChoices(key) containsObject:value ?: @""] ? value : AZChoices(key).firstObject;
}
void AZSetValue(NSString *key, NSString *value, NSURL *game) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (game) {
        NSMutableDictionary *values = [[defaults dictionaryForKey:GameKey(game)] mutableCopy] ?: [NSMutableDictionary new];
        values[key] = value;
        if (values.count) [defaults setObject:values forKey:GameKey(game)];
        else [defaults removeObjectForKey:GameKey(game)];
    } else if ([key isEqual:@"AzaharExperimentalJIT"]) {
        [defaults setBool:[value isEqual:@"on"] forKey:key];
    } else {
        [defaults setObject:value forKey:key];
    }
}
NSURL *AZLogURL(void) {
    return [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"AzaharJITDiagnostics.txt"];
}
NSString *AZVersion(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"v%@  ·  Build %@", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
}
NSURL *AZCustomArtURL(NSURL *game) {
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Covers" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *name = [game.lastPathComponent dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(name.bytes, (CC_LONG)name.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (unsigned i=0; i<sizeof(digest); ++i) [hex appendFormat:@"%02x", digest[i]];
    return [dir URLByAppendingPathComponent:hex];
}
void AZForgetGame(NSURL *game) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:GameKey(game)];
    [NSFileManager.defaultManager removeItemAtURL:AZCustomArtURL(game) error:nil];
}

static uint32_t Word(const uint8_t *p) {
    uint32_t n; memcpy(&n,p,4); return CFSwapInt32LittleToHost(n);
}
static BOOL ReadAt(FILE *f, uint64_t offset, void *dst, size_t count) {
    return fseeko(f, (off_t)offset, SEEK_SET) == 0 && fread(dst, 1, count, f) == count;
}
static UIImage *ReadIcon(FILE *f) {
    uint8_t header[512], entries[512], icon[48*48*2];
    uint64_t base = 0;
    if (!ReadAt(f,0,header,sizeof header)) return nil;
    if (!memcmp(header+0x100,"NCSD",4)) {
        base = (uint64_t)Word(header+0x120)*512;
        if (!ReadAt(f,base,header,sizeof header)) return nil;
    }
    if (memcmp(header+0x100,"NCCH",4) || !(header[0x18f]&4) || header[0x18e]>5) return nil;
    uint64_t exefs = base + (uint64_t)Word(header+0x1a0)*(512u << header[0x18e]);
    if (!ReadAt(f,exefs,entries,sizeof entries)) return nil;
    for (int i=0; i<10; ++i) {
        const uint8_t *e=entries+16*i;
        if (memcmp(e,"icon\0\0\0\0",8) || Word(e+12)<0x36c0) continue;
        uint64_t addr=exefs+512+Word(e+8);
        char magic[4];
        if (!ReadAt(f,addr,magic,4) || memcmp(magic,"SMDH",4) || !ReadAt(f,addr+0x24c0,icon,sizeof icon)) return nil;
        NSMutableData *rgba=[NSMutableData dataWithLength:48*48*4];
        uint8_t *out=(uint8_t *)rgba.mutableBytes;
        for (unsigned y=0;y<48;++y) for (unsigned x=0;x<48;++x) {
            unsigned tile=(y/8*6+x/8)*64;
            unsigned z=(x&1)|((y&1)<<1)|((x&2)<<1)|((y&2)<<2)|((x&4)<<2)|((y&4)<<3);
            unsigned pos=2*(tile+z), v=icon[pos]|(icon[pos+1]<<8);
            *out++=((v>>11)&31)*255/31; *out++=((v>>5)&63)*255/63; *out++=(v&31)*255/31; *out++=255;
        }
        CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
        CGColorSpaceRef rgb=CGColorSpaceCreateDeviceRGB();
        CGImageRef image=CGImageCreate(48,48,8,32,48*4,rgb,kCGBitmapByteOrder32Big|kCGImageAlphaLast,provider,NULL,false,kCGRenderingIntentDefault);
        UIImage *result=image ? [UIImage imageWithCGImage:image] : nil;
        if (image) CGImageRelease(image);
        CGColorSpaceRelease(rgb); CGDataProviderRelease(provider);
        return result;
    }
    return nil;
}
UIImage *AZGameArt(NSURL *game) {
    UIImage *cover=[UIImage imageWithContentsOfFile:AZCustomArtURL(game).path];
    if (cover) return cover;
    FILE *f=fopen(game.fileSystemRepresentation,"rb");
    if (!f) return nil;
    UIImage *icon=ReadIcon(f);
    fclose(f);
    return icon;
}
