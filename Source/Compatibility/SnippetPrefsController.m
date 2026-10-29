#import "SnippetPrefsController.h"

@implementation SnippetPrefsController

@synthesize snippetsController;

- (void)dealloc
{
	[snippetsController release];
	[super dealloc];
}

- (BOOL)hasFolders
{
	return NO;
}

/* Bindings use snippetsController.managedObjectContext; expose moc on self too. */
- (NSManagedObjectContext *)managedObjectContext
{
	return nil;
}

- (id)valueForKeyPath:(NSString *)keyPath
{
	if ([keyPath isEqualToString:@"snippetsController.managedObjectContext"]) {
		return nil;
	}
	return [super valueForKeyPath:keyPath];
}

/* Allow bindings to treat this object as the snippetsController. */
- (id)snippetsController
{
	if (snippetsController) {
		return snippetsController;
	}
	return self;
}

@end
