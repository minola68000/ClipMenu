//
//  main.m
//  ClipMenu
//

#import <Cocoa/Cocoa.h>
#import "MenuController.h"

/* One-time import of the original app's preferences (com.naotaka.ClipMenu). */
static void CMMigrateLegacyPreferences(void)
{
	static NSString *const legacyDomain = @"com.naotaka.ClipMenu";
	static NSString *const doneKey = @"CMMigratedLegacyPreferences";
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([defaults boolForKey:doneKey]) {
		return;
	}
	NSDictionary *legacy = [defaults persistentDomainForName:legacyDomain];
	for (NSString *key in legacy) {
		[defaults setObject:[legacy objectForKey:key] forKey:key];
	}
	[defaults setBool:YES forKey:doneKey];
	[defaults synchronize];
}

int main(int argc, char *argv[])
{
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--self-test-filter") == 0) {
			return [MenuController runFilterE2ETest];
		}
	}
	@autoreleasepool {
		CMMigrateLegacyPreferences();
	}
	return NSApplicationMain(argc, (const char **)argv);
}
