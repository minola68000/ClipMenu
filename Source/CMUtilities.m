//
//  CMUtilities.m
//  ClipMenu
//
//  Created by Naotaka Morimoto on 08/02/10.
//  Copyright 2008 Naotaka Morimoto. All rights reserved.
//

#import "CMUtilities.h"
#import "constants.h"
#import "PrefsWindowController.h"
#import <Carbon/Carbon.h>


static NSInteger vKeyCode = 0;


@implementation CMUtilities

#pragma mark Functions

//BOOL postCommandV(BOOL isANSILayout)
//{	
//	/*" fakeCommandV synthesizes keyboard events for Cmd-v Paste shortcut. "*/
////  CGPostKeyboardEvent( (CGCharCode)0, (CGKeyCode)55, true );		// command key down
////	CGPostKeyboardEvent( (CGCharCode)'v', (CGKeyCode)9, true );		// 'v' key down
////	CGPostKeyboardEvent( (CGCharCode)'v', (CGKeyCode)9, false );	// 'v' key up
////	CGPostKeyboardEvent( (CGCharCode)0, (CGKeyCode)55, false );		// command key up
//		
//	
//	CGEventSourceRef sourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
//	if (!sourceRef) {
//		NSLog(@"No event source");
//		return NO;
//	}
//	
//	NSUInteger vKeyCode = (isANSILayout) ? kVK_ANSI_V : kVK_ANSI_Period;
//	CGEventRef eventDown, eventUp;
//	
//	NSLog(@"key: %d", vKeyCode);
//	
//	eventDown = CGEventCreateKeyboardEvent(sourceRef, (CGKeyCode)vKeyCode, true);	// v key down
//	CGEventSetFlags(eventDown, kCGEventFlagMaskCommand);							// command key press
//	eventUp = CGEventCreateKeyboardEvent(sourceRef, (CGKeyCode)vKeyCode, false);	// v key up
//	
//	CGEventPost(kCGSessionEventTap, eventDown);
//	CGEventPost(kCGSessionEventTap, eventUp);
//	
//	CFRelease(eventDown);
//	CFRelease(eventUp);
//	CFRelease(sourceRef);
//	
//	return YES;
//}

NSString *transformKeyCode(NSInteger keyCode)
{
    // Can be -1 when empty
	if ( keyCode < 0 ) return nil;
		
	OSStatus err;
	TISInputSourceRef tisSource = TISCopyCurrentKeyboardLayoutInputSource();
	
	if(!tisSource) return nil;
	
	CFDataRef layoutData;
	UInt32 keysDown = 0;
	layoutData = (CFDataRef)TISGetInputSourceProperty(tisSource, kTISPropertyUnicodeKeyLayoutData);
	CFRelease(tisSource);
	
	if(!layoutData) return nil;	
	const UCKeyboardLayout *keyLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
	
	UniCharCount length = 4, realLength;
	UniChar chars[4];
	
	err = UCKeyTranslate(keyLayout, 
						 keyCode,
						 kUCKeyActionDisplay,
						 0,
						 LMGetKbdType(),
						 kUCKeyTranslateNoDeadKeysBit,
						 &keysDown,
						 length,
						 &realLength,
						 chars);
	
	if ( err != noErr ) return nil;
	
	NSString *keyString = [[NSString stringWithCharacters:chars length:1] uppercaseString];
	
	return keyString;
}

BOOL postCommandV()
{	
	CGEventSourceRef sourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
	if (!sourceRef) {
		NSLog(@"No event source");
		return NO;
	}
	
	if (vKeyCode == 0) {
//		NSString *transformedKey = transformKeyCode(vKeyCode);
//		NSLog(@"transformedKey: %@", transformedKey);
		
		// loop over every keycode (0 - 127) finding its current string mapping...
		NSMutableDictionary *stringToKeyCodeDict = [[NSMutableDictionary alloc] init];
		NSUInteger i;
		for ( i = 0U; i < 128U; i++ )
		{
			NSString *string = transformKeyCode(i);
			if ( ( string ) && ( [string length] ) )
			{
				NSNumber *keyCode = [NSNumber numberWithUnsignedInteger:i];
				[stringToKeyCodeDict setObject:keyCode forKey:string];
			}
		}
		
//		NSLog(@"dict: %@", stringToKeyCodeDict);
		
		NSNumber *keyCodeNum = [stringToKeyCodeDict objectForKey:@"V"];
		[stringToKeyCodeDict release], stringToKeyCodeDict = nil;
		
		if (!keyCodeNum) {
			return NO;
		}
		
		vKeyCode = [keyCodeNum unsignedIntegerValue];
	}
	
//	NSLog(@"key: %d", vKeyCode);
	
	CGEventRef eventDown, eventUp;
	
	eventDown = CGEventCreateKeyboardEvent(sourceRef, (CGKeyCode)vKeyCode, true);	// v key down
	CGEventSetFlags(eventDown, kCGEventFlagMaskCommand);							// command key press
	eventUp = CGEventCreateKeyboardEvent(sourceRef, (CGKeyCode)vKeyCode, false);	// v key up
	CGEventSetFlags(eventUp, kCGEventFlagMaskCommand);								// command key up

	CGEventPost(kCGSessionEventTap, eventDown);
	CGEventPost(kCGSessionEventTap, eventUp);
	
	CFRelease(eventDown);
	CFRelease(eventUp);
	CFRelease(sourceRef);
	
	return YES;
}

NSInteger CMRunAlertPanel(NSString *title, NSString *msg, NSString *defaultButton, NSString *alternateButton, NSString *otherButton)
{
	[NSApp activateIgnoringOtherApps:YES];
	
	NSInteger result = NSRunAlertPanel(title,
								 msg,
								 defaultButton,
								 alternateButton,
								 otherButton);
	return result;
}

#pragma mark -

static NSRunningApplication *sPasteTargetApplication = nil;
static BOOL sMenuTracking = NO;
static BOOL sPastePending = NO;
static void (^sAfterPaste)(void) = nil;

static void CMPostPasteAndNotify(void)
{
	postCommandV();
	if (sAfterPaste) {
		void (^block)(void) = sAfterPaste;
		sAfterPaste = nil;
		/* No API tells when the target finished reading; a short grace before the block runs. */
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{ block(); [block release]; });
	}
}

+ (void)setPasteTargetApplication:(NSRunningApplication *)app
{
	[sPasteTargetApplication release];
	sPasteTargetApplication = [app retain];
}

+ (void)menuWillBeginTracking
{
	sMenuTracking = YES;
	sPastePending = NO;
}

+ (void)menuDidFinishTracking
{
	sMenuTracking = NO;
	if (sPastePending) {
		sPastePending = NO;
		[self _sendPasteToTarget];
	}
}

/*
 * Cmd+V must not be sent while our menu is still tracking (it would be lost), nor
 * while ClipMenu is still the active app. Event driven: the paste goes out once
 * tracking has finished and the previous app is frontmost again.
 */
+ (void)_sendPasteToTarget
{
	NSRunningApplication *target = sPasteTargetApplication;
	if (!target || [target isTerminated] || [target isEqual:[NSRunningApplication currentApplication]]) {
		CMPostPasteAndNotify();
		return;
	}
	if ([[[NSWorkspace sharedWorkspace] frontmostApplication] isEqual:target]) {
		dispatch_async(dispatch_get_main_queue(), ^{ CMPostPasteAndNotify(); });
		return;
	}
	
	__block BOOL sent = NO;
	__block id observer = nil;
	void (^send)(void) = ^{
		if (sent) {
			return;
		}
		sent = YES;
		[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:observer];
		CMPostPasteAndNotify();
	};
	observer = [[[NSWorkspace sharedWorkspace] notificationCenter]
				addObserverForName:NSWorkspaceDidActivateApplicationNotification
				object:nil
				queue:[NSOperationQueue mainQueue]
				usingBlock:^(NSNotification *note) {
		NSRunningApplication *activated = [[note userInfo] objectForKey:NSWorkspaceApplicationKey];
		if ([activated isEqual:target]) {
			dispatch_async(dispatch_get_main_queue(), send);
		}
	}];
	/* Safety net only: never leave the paste hanging if the notification does not arrive. */
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), send);
	[target activateWithOptions:NSApplicationActivateIgnoringOtherApps];
}

+ (BOOL)pasteThen:(void (^)(void))afterPaste
{
	if (![[NSUserDefaults standardUserDefaults] boolForKey:CMPrefInputPasteCommandKey]) {
		return NO;
	}
	[sAfterPaste release];
	sAfterPaste = [afterPaste copy];
	return [self paste];
}

+ (BOOL)paste
{
	if (![[NSUserDefaults standardUserDefaults] boolForKey:CMPrefInputPasteCommandKey]) {
		return NO;
	}
	if (sMenuTracking) {
		sPastePending = YES;
		return YES;
	}
	[self _sendPasteToTarget];
	return YES;
}

+ (NSDictionary *)hotKeyMap
{
	NSMutableDictionary *map = [NSMutableDictionary dictionary];
	NSDictionary *dict;
	NSUInteger index = 0;
	
	dict = [[NSDictionary alloc] initWithObjectsAndKeys:
			[NSNumber numberWithUnsignedInteger:index], kIndex,
			@"popUpClipMenu:", kSelector,
			nil];
	[map setObject:dict forKey:kClipMenuIdentifier];
	[dict release], dict = nil;
	index++;
	
	dict = [[NSDictionary alloc] initWithObjectsAndKeys:
			[NSNumber numberWithUnsignedInteger:index], kIndex,
			@"popUpHistoryMenu:", kSelector,
			nil];
	[map setObject:dict forKey:kHistoryMenuIdentifier];
	[dict release], dict = nil;
	index++;
	
	dict = [[NSDictionary alloc] initWithObjectsAndKeys:
			[NSNumber numberWithUnsignedInteger:index], kIndex,
			@"popUpSnippetsMenu:", kSelector,
			nil];
	[map setObject:dict forKey:kSnippetsMenuIdentifier];
	[dict release], dict = nil;
//	index++;
	
	return map;
}

/* Ignore warnings for this method */
+ (NSString *)localizedFileName:(NSString *)filename
{
	return NSLocalizedString(filename, nil);
}

+ (id)infoValueForKey:(NSString*)key
{
	NSBundle *bundle = [NSBundle mainBundle];
	NSString *value;
	
	// InfoPlist.strings entries have priority over Info.plist ones.
	value = [[bundle localizedInfoDictionary] objectForKey:key];
	if (value) {
		return value;
	}
	
	return [[bundle infoDictionary] objectForKey:key];
}


#pragma mark Archiver

+ (NSString *)applicationSupportFolder
{	
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
	NSString *basePath = (0 < [paths count]) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
	
	return [basePath stringByAppendingPathComponent:kApplicationName];
}

+ (NSString *)scriptLibFolder
{
	NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
	if (!resourcePath) {
		return nil;
	}
	
	NSArray *pathArray = [NSArray arrayWithObjects:
						  resourcePath,
						  kScriptDirectory,
						  kLibraryScriptDirectory,
						  nil];
	if (!pathArray) {
		return nil;
	}
	
	NSString *path = [NSString pathWithComponents:pathArray];
	
	BOOL isDir;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]
		|| !isDir) {
		return nil;
	}
	
	return path;
}

+ (NSString *)userLibFolder
{	
	NSString *applicationSupportFolder = [self applicationSupportFolder];
	
	NSArray *pathArray = [NSArray arrayWithObjects:
						  applicationSupportFolder,
						  kScriptDirectory,
						  kLibraryScriptDirectory,
						  nil];
	if (!pathArray) {
		return nil;
	}
	
	NSString *path = [NSString pathWithComponents:pathArray];
	
	BOOL isDir;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]
		|| !isDir) {
		return nil;
	}
	
	return path;
}

+ (NSString *)bundledActionsFolder
{
	NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
	if (!resourcePath) {
		return nil;
	}
	
	NSArray *pathArray = [NSArray arrayWithObjects:
						  resourcePath,
						  kScriptDirectory,
						  kActionDirectory,
						  nil];
	if (!pathArray) {
		return nil;
	}
	
	NSString *path = [NSString pathWithComponents:pathArray];
	
	BOOL isDir;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]
		|| !isDir) {
		return nil;
	}
	
	return path;
}

+ (NSString *)userActionsFolder
{	
	NSArray *pathArray = [NSArray arrayWithObjects:
						  [self applicationSupportFolder],
						  kScriptDirectory,
						  kActionDirectory,
						  nil];
	if (!pathArray) {
		return nil;
	}
	
	NSString *path = [NSString pathWithComponents:pathArray];
	
	BOOL isDir;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]
		|| !isDir) {
		return nil;
	}
	
	return path;
}

+ (BOOL)prepareSaveToPath:(NSString *)path
{	
	NSFileManager *fileManager = [NSFileManager defaultManager];
	BOOL isDir;
	
	if (([fileManager fileExistsAtPath:path isDirectory:&isDir] && isDir) == NO) {		
		if (![fileManager createDirectoryAtPath:path
					withIntermediateDirectories:YES
									 attributes:nil
										  error:NULL]) {
			return NO;
		}
	}
	
	return YES;
}

@end
