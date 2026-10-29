/* Compatibility shim for Shortcut Recorder 2-era Preferences nibs.
 * ShortcutRecorder 3 removed SRRecorderCell; without this class the
 * Preferences nib fails to load and the prefs window never appears. */

#import <Cocoa/Cocoa.h>

@interface SRRecorderCell : NSActionCell
{
	NSString *autosaveName;
	NSInteger keyComboCode;
	NSUInteger keyComboFlags;
	NSUInteger allowedFlags;
	NSUInteger requiredFlags;
	BOOL allowsKeyOnly;
	BOOL escapeKeysRecord;
	BOOL isAnimating;
	NSInteger style;
}

@property (nonatomic, copy) NSString *autosaveName;
@property (nonatomic, assign) NSInteger keyComboCode;
@property (nonatomic, assign) NSUInteger keyComboFlags;
@property (nonatomic, assign) NSUInteger allowedFlags;
@property (nonatomic, assign) NSUInteger requiredFlags;
@property (nonatomic, assign) BOOL allowsKeyOnly;
@property (nonatomic, assign) BOOL escapeKeysRecord;
@property (nonatomic, assign) BOOL isAnimating;
@property (nonatomic, assign) NSInteger style;

@end
