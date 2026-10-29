#import "CMUpdater.h"

@implementation CMUpdater

@synthesize lastUpdateCheckDate;

- (void)dealloc
{
	[lastUpdateCheckDate release];
	[super dealloc];
}

- (IBAction)checkForUpdates:(id)sender
{
	(void)sender;
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Updates", nil)];
	[alert setInformativeText:NSLocalizedString(
		@"Automatic updates are disabled in this maintenance fork.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert runModal];
}

@end
