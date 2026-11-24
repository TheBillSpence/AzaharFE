#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSArray<NSString *> *AZOptionKeys(void);
FOUNDATION_EXPORT NSString *AZOptionTitle(NSString *key);
FOUNDATION_EXPORT NSArray<NSString *> *AZChoices(NSString *key);
FOUNDATION_EXPORT NSString *AZChoiceTitle(NSString *key, NSString *value);
FOUNDATION_EXPORT NSString *AZValue(NSString *key, NSURL *_Nullable game);
FOUNDATION_EXPORT BOOL AZHasOverride(NSString *key, NSURL *game);
FOUNDATION_EXPORT void AZSetValue(NSString *key, NSString *_Nullable value, NSURL *_Nullable game);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *AZLaunchOptions(NSURL *_Nullable game);
FOUNDATION_EXPORT void AZResetGameOptions(NSURL *game);
NS_ASSUME_NONNULL_END
