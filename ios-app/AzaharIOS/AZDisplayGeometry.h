#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <cmath>

struct AZDisplayGeometry {
    CGRect source[2]{};
    CGRect destination[2]{};
    unsigned count = 0;
    int touchIndex = -1;
};

// Source rectangles are normalized within the original core composite;
// destinations are in view coordinates. The same mapping drives GPU blits,
// CPU fallback CALayers, and touchscreen input.
inline AZDisplayGeometry AZMakeDisplayGeometry(CGSize image, CGSize view, BOOL landscape,
                                                NSDictionary *options) {
    AZDisplayGeometry result;
    const double w = view.width, h = view.height;
    if (image.width <= 0 || image.height <= 0 || w <= 0 || h <= 0) return result;
    const bool split = landscape && [options[@"citra_layout_option"] isEqual:@"default"] &&
                       std::abs(image.width / image.height - 400.0 / 480.0) < 0.002;
    if (!split) {
        const double scale = std::min(w / image.width, h / image.height);
        const double dw = image.width * scale, dh = image.height * scale;
        result.count = 1;
        result.touchIndex = 0; // core rejects touches outside its bottom screen
        result.source[0] = CGRectMake(0, 0, 1, 1);
        result.destination[0] = CGRectMake((w-dw)/2, (h-dh)/2, dw, dh);
        return result;
    }
    const bool swapped = [options[@"citra_swap_screen"] isEqual:@"Bottom"];
    const bool stacked = [options[@"AzaharLandscapeLayout"] isEqual:@"stacked"];
    const bool topOnly = [options[@"AzaharLandscapeLayout"] isEqual:@"top_only"];
    const bool stretch = [options[@"AzaharDisplayAspect"] isEqual:@"stretch"];
    const double ratio = std::clamp([(options[@"AzaharTouchSize"] ?: @"30") doubleValue] / 100.0, 0.15, 0.60);
    const double gap = topOnly ? 0 : std::min(w,h)*0.012;
    const double availableW = std::max(0.0, w-gap), availableH = std::max(0.0,h-gap);
    double th = topOnly ? std::min(h,w*3/5) :
                stacked ? std::min(availableH/(1+ratio),w*3/5) :
                          std::min(h,availableW/(5.0/3+ratio*4.0/3));
    if (stretch)
        th = topOnly ? h : stacked ? availableH/(1+ratio) : std::min(h,availableW/(ratio*4.0/3+1));
    const double bh = topOnly ? 0 : th*ratio, bw = bh*4/3;
    const double tw = stretch ? (stacked || topOnly ? w : availableW-bw) : th*5/3;
    if (th <= 0 || tw <= 0) return result;
    result.count = topOnly ? 1 : 2;
    result.touchIndex = topOnly ? -1 : 1;
    result.source[0] = CGRectMake(0, swapped ? 0.5 : 0, 1, 0.5);
    result.source[1] = CGRectMake(0.1, swapped ? 0 : 0.5, 0.8, 0.5);
    if (topOnly || stacked) {
        const double y = (h-th-bh-gap)/2;
        result.destination[0] = CGRectMake((w-tw)/2, y, tw, th);
        result.destination[1] = CGRectMake((w-bw)/2, y+th+gap, bw, bh);
    } else {
        const double x = (w-tw-bw-gap)/2, y = (h-th)/2;
        // Keep the original top-screen rectangle exactly unchanged. Expand only
        // the touchscreen into the unused right-hand region and anchor it to
        // the lower-right edge. Native mode preserves the 320:240 aspect ratio.
        result.destination[0] = CGRectMake(x,y,tw,th);
        const double rightStart = std::min(w, x+tw+gap);
        const double freeW = std::max(0.0, w-rightStart);
        const double touchW = stretch ? freeW : std::min(freeW, h*4.0/3);
        const double touchH = stretch ? std::min(h, bh*freeW/bw) : touchW*3.0/4;
        result.destination[1] = CGRectMake(w-touchW,h-touchH,touchW,touchH);
    }
    return result;
}
