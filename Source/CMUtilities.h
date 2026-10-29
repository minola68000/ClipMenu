//
//  CMUtilities.h
//  ClipMenu
//
//  Created by Naotaka Morimoto on 08/02/10.
//  Copyright 2008 Naotaka Morimoto. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface CMUtilities : NSObject 
{
}

NSInteger CMRunAlertPanel(NSString *title, NSString *msg, NSString *defaultButton, NSString *alternateButton, NSString *otherButton);

+ (BOOL)paste;
/* Like +paste; block runs shortly after Cmd+V has been sent (not run if pasting is disabled). */
+ (BOOL)pasteThen:(void (^)(void))afterPaste;
/* App that was frontmost before the menu opened; Cmd+V is sent to it. */
+ (void)setPasteTargetApplication:(NSRunningApplication *)app;
/* Menu tracking bracket: a paste requested while tracking is sent once it has finished. */
+ (void)menuWillBeginTracking;
+ (void)menuDidFinishTracking;
+ (NSDictionary *)hotKeyMap;

+ (NSString *)localizedFileName:(NSString *)filename;
+ (id)infoValueForKey:(NSString*)key;

+ (NSString *)applicationSupportFolder;
+ (NSString *)scriptLibFolder;
+ (NSString *)userLibFolder;
+ (NSString *)bundledActionsFolder;
+ (NSString *)userActionsFolder;
+ (BOOL)prepareSaveToPath:(NSString *)path;

@end
