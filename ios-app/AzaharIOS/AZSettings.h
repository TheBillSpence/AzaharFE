#import <UIKit/UIKit.h>
@interface AZSettings : UITableViewController
@property (nonatomic, copy) NSArray<NSURL *> *games;
@property (nonatomic, strong) NSURL *game;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *sessionOptions;
@property (nonatomic) BOOL restartOnClose;
@property (nonatomic, copy) void (^selectGame)(NSURL *);
- (instancetype)initForGame:(BOOL)perGame;
@end
