#import "SRRecorderCell.h"

@implementation SRRecorderCell

@synthesize autosaveName;
@synthesize keyComboCode;
@synthesize keyComboFlags;
@synthesize allowedFlags;
@synthesize requiredFlags;
@synthesize allowsKeyOnly;
@synthesize escapeKeysRecord;
@synthesize isAnimating;
@synthesize style;

- (void)dealloc
{
	[autosaveName release];
	[super dealloc];
}

@end
