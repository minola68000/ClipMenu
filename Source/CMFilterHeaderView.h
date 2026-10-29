//
//  CMFilterHeaderView.h
//  ClipMenu — NSMenu tracking key intercept (MGKMenuWithFilter pattern)
//

#import <Cocoa/Cocoa.h>

@class CMFilterHeaderView;

@protocol CMFilterHeaderViewDelegate <NSObject>
- (void)filterHeader:(CMFilterHeaderView *)header appendString:(NSString *)string;
- (void)filterHeader:(CMFilterHeaderView *)header replaceString:(NSString *)string;
- (void)filterHeaderDeleteBackward:(CMFilterHeaderView *)header;
- (void)filterHeaderClear:(CMFilterHeaderView *)header;
- (void)filterHeaderApply:(CMFilterHeaderView *)header;
- (NSString *)filterHeaderCurrentString:(CMFilterHeaderView *)header;
@end

@interface CMFilterHeaderView : NSView <NSTextFieldDelegate>
@property (nonatomic, assign) id <CMFilterHeaderViewDelegate> delegate;
@property (nonatomic, copy) NSString *query;
- (void)setQueryDisplay:(NSString *)query;
- (BOOL)handleRawKeyCode:(unsigned short)keyCode characters:(NSString *)chars;
- (void)ensureKeyIntercept;
- (BOOL)isFilterFieldFirstResponder;
+ (void)setE2EInjectionEnabled:(BOOL)enabled;
@end
