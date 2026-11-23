#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT UIColor *AZNavy(void);
FOUNDATION_EXPORT UIColor *AZPanel(void);
FOUNDATION_EXPORT UIColor *AZBlue(void);
FOUNDATION_EXPORT UIColor *AZYellow(void);
FOUNDATION_EXPORT NSArray<NSString *> *AZOptionKeys(void);
FOUNDATION_EXPORT NSString *AZOptionTitle(NSString *key);
FOUNDATION_EXPORT NSArray<NSString *> *AZChoices(NSString *key);
FOUNDATION_EXPORT NSString *AZChoiceTitle(NSString *value);
FOUNDATION_EXPORT NSString *AZValue(NSString *key, NSURL *_Nullable game);
FOUNDATION_EXPORT BOOL AZHasOverride(NSString *key, NSURL *game);
FOUNDATION_EXPORT void AZSetValue(NSString *key, NSString *_Nullable value, NSURL *_Nullable game);
FOUNDATION_EXPORT void AZForgetGame(NSURL *game);
FOUNDATION_EXPORT UIImage *_Nullable AZGameArt(NSURL *game);
FOUNDATION_EXPORT NSURL *AZCustomArtURL(NSURL *game);
FOUNDATION_EXPORT NSURL *AZLogURL(void);
FOUNDATION_EXPORT NSString *AZVersion(void);
NS_ASSUME_NONNULL_END
