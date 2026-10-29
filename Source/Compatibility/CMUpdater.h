/* Stand-in for Sparkle's SUUpdater in Preferences.nib when no appcast is configured. */

#import <Cocoa/Cocoa.h>

@interface CMUpdater : NSObject
{
	NSDate *lastUpdateCheckDate;
}

@property (nonatomic, retain) NSDate *lastUpdateCheckDate;

- (IBAction)checkForUpdates:(id)sender;

@end
