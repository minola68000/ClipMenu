#import "NSObject+CMHasFolders.h"

@implementation NSObject (CMHasFolders)

/* Preferences.nib contains an enabled↔hasFolders binding (Snippet Editor leftover)
 * whose destination can be a plain NSObject; satisfy KVC so the nib can load. */
- (BOOL)hasFolders
{
	return YES;
}

@end
