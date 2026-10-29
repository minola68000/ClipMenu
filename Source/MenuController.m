//
//  MenuController.m
//  ClipMenu
//
//  Created by Naotaka Morimoto on 07/12/06.
//  Copyright 2007 Naotaka Morimoto. All rights reserved.
//

#import "MenuController.h"
#import "CMFilterHeaderView.h"
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import "constants.h"
#import "ActionController.h"
#import "ActionNode.h"
#import "ClipsController.h"
#import "Clip.h"
#import "SnippetsController.h"
#import "SnippetEditorController.h"
#import "PrefsWindowController.h"
#import "NSString+NaoAdditions.h"

/* Prefix menu titles so NSMenu type-ahead does not steal filter keystrokes. */
static NSString *const kCMTypeaheadMutePrefix = @"\ufeff";

static EventHandlerRef sCMFilterCarbonHandler = NULL;

/* Debug logging is opt-in (set CLIPMENU_FILTER_LOG=/path/to/file): it records typed text. */
static void CMFilterLog(NSString *fmt, ...)
{
	const char *logPath = getenv("CLIPMENU_FILTER_LOG");
	if (!logPath || !*logPath) {
		return;
	}
	va_list ap;
	va_start(ap, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	FILE *f = fopen(logPath, "a");
	if (f) {
		NSString *ts = [[NSDate date] description];
		fprintf(f, "%s %s\n", [ts UTF8String], [line UTF8String]);
		fclose(f);
	}
	[line release];
}

static CFMachPortRef sCMFilterEventTap = NULL;
static CFRunLoopSourceRef sCMFilterTapSource = NULL;
static BOOL sCMFilterDidPromptAX = NO;
static BOOL sCMFilterDidRequestListen = NO;
/* Items added to the menu while filtering (matches re-packed from the top). */
static NSMutableArray *sCMFilterResultItems = nil;
static CGFloat sCMHistorySubmenuWidth = 0;
/* Set by Shift+Return; consumed by AppController when the item is confirmed. */
static BOOL sCMQuotedPasteRequested = NO;

static CGEventRef CMFilterMenuCGEventTapCallback(CGEventTapProxy proxy,
												 CGEventType type,
												 CGEventRef event,
												 void *refcon)
{
	(void)proxy;
	MenuController *controller = (MenuController *)refcon;
	if (!controller) {
		return event;
	}
	if (type == kCGEventTapDisabledByTimeout ||
		type == kCGEventTapDisabledByUserInput) {
		if (sCMFilterEventTap) {
			CGEventTapEnable(sCMFilterEventTap, true);
		}
		return event;
	}
	if (type != kCGEventKeyDown) {
		return event;
	}
	NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
	if (!nsEvent) {
		return event;
	}
	NSEvent *passed = [controller _handleClipFilterKeyEvent:nsEvent];
	if (passed == nil) {
		return NULL;
	}
	return event;
}

@interface MenuController (CarbonFilterPrivate)
- (OSStatus)_carbonHandleFilterEvent:(EventRef)event;
- (NSEvent *)_handleClipFilterKeyEvent:(NSEvent *)event;
@end

static OSStatus CMFilterCarbonEventHandler(EventHandlerCallRef callRef, EventRef event, void *userData)
{
	(void)callRef;
	MenuController *controller = (MenuController *)userData;
	if (!controller) {
		return eventNotHandledErr;
	}
	UInt32 kc = 0;
	GetEventParameter(event, kEventParamKeyCode, typeUInt32, NULL, sizeof(kc), NULL, &kc);
	return [controller _carbonHandleFilterEvent:event];
}


//#define INLINE_CLIPS_DISPLAY_NUMBER 10
//#define NUMBER_OF_ITEMS_IN_A_FOLDER 10
#define kMaxKeyEquivalents 10

#define DEFAULT_MENU_FONT_SIZE 14.0
#define LARGE_MENU_FONT_SIZE 28.0
#define HUGE_MENU_FONT_SIZE 42.0
#define SMALL_ICON_SIZE 16
#define LARGE_ICON_SIZE 32
#define HUGE_ICON_SIZE 48
#define THUMBNAIL_ICON_SIZE 128
#define MENU_TITLE_FORMAT @"%d. %@"
#define SHORTEN_SYMBOL @"..."

#define STATUS_MENU_ICON @"StatusMenuIcon"
#define STATUS_MENU_ICON_POSTFIX @"_pressed"
#define STATUS_MENU_ICON_FILE_EXTENSION @".png"

#pragma mark Static variables

static MenuController *sharedInstance = nil;

#pragma mark Functions

BOOL CMIsPerformableAction(NSDictionary *action)
{	
	//	NSLog(@"action: %@", action);
	
	NSString *name = [action objectForKey:@"name"];
	NSString *type = [action objectForKey:@"type"]; 	
	NSArray *selectedItemTypes;
	
	ActionController *actionController = [ActionController sharedInstance];
	NSInteger tag = [actionController selectedClipTag];
	
	if (tag < 0) {
		/* it's a snippet */
		selectedItemTypes = [NSArray arrayWithObject:NSStringPboardType];
	}
	else {
		/* its a clip */
		Clip *clip = [[[ClipsController sharedInstance] sortedClips] objectAtIndex:tag];
		selectedItemTypes = [clip types];
	}
		
	//	if ([selectedClipTypes containsObject:NSStringPboardType]) {
	//		return YES;
	//	}
	
	if ([type isEqualToString:CMBuiltinActionTypeKey]) {
		NSDictionary *builtInActions = [[actionController builtInActionController] valueForKey:@"actions"];
		NSDictionary *builtInAction = [builtInActions objectForKey:name];
		//		NSLog(@"builtInAction: %@", builtInAction);
		
		for (NSString *key in [builtInAction objectForKey:@"types"]) {
			//			NSLog(@"key: %@", key);
			if ([selectedItemTypes containsObject:key]) {
				return YES;
			}
		}
	}
	else if ([type isEqualToString:CMJavaScriptActionTypeKey]) {
		if ([selectedItemTypes containsObject:NSStringPboardType]) {
			return YES;
		}
	}
	
	return NO;
}

NSUInteger firstIndexOfMenuItems()
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey:CMPrefMenuItemsTitleStartWithZeroKey]) {
		return 0;
	}
	return 1;
}

NSUInteger incrementListNumber(NSUInteger listNumber, NSUInteger max, NSUInteger start)
{
	listNumber++;
	
	if (listNumber == max 
		&& max == 10
		&& start == 1) {
		listNumber = 0;
	}
	
	return listNumber;
}

NSString *trimTitle(NSString *clipString)
{
	if (clipString == nil) {
		return kEmptyString;
	}
	
	NSString *theString = [clipString strip];
	
	NSRange aRange = NSMakeRange(0,0);
	NSUInteger lineStart = 0, lineEnd	= 0, contentsEnd = 0;
	[theString getLineStart:&lineStart end:&lineEnd contentsEnd:&contentsEnd forRange:aRange];
	
	//	NSLog(@"start:%d, lineEnd:%d, contentsEnd:%d", lineStart, lineEnd, contentsEnd);
	
	NSString *titleString = (lineEnd == [theString length])
	? theString
	: [theString substringToIndex:contentsEnd];
	
	NSUInteger maxMenuItemTitleLength = [[NSUserDefaults standardUserDefaults] integerForKey:CMPrefMaxMenuItemTitleLengthKey];
	if (maxMenuItemTitleLength < [SHORTEN_SYMBOL length]) {
		maxMenuItemTitleLength = [SHORTEN_SYMBOL length];
	}
	
	if ([titleString length] > maxMenuItemTitleLength) {
		titleString = [NSString stringWithFormat:@"%@%@",
					   [titleString substringToIndex:(maxMenuItemTitleLength - [SHORTEN_SYMBOL length])],
					   SHORTEN_SYMBOL];
	}
	
	return titleString;
}

NSAttributedString *makeAttributedTitle(NSString *title)
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	BOOL isChangeFontSize = [defaults boolForKey:CMPrefChangeFontSizeKey];
	NSInteger howToChangeFontSize = [defaults integerForKey:CMPrefHowToChangeFontSizeKey];
	BOOL isShowIcon = [defaults boolForKey:CMPrefShowIconInTheMenuKey];
	
	if (!isChangeFontSize) {
		return nil;
	}
	
	CGFloat fontSize = DEFAULT_MENU_FONT_SIZE;
	
	if (howToChangeFontSize == 0 && isShowIcon) {
		NSUInteger iconSize = [defaults integerForKey:CMPrefMenuIconSizeKey];
		switch (iconSize) {
			case LARGE_ICON_SIZE:
				fontSize = LARGE_MENU_FONT_SIZE;
				break;
			case HUGE_ICON_SIZE:
				fontSize = HUGE_MENU_FONT_SIZE;
				break;
		}
	}
	else if (howToChangeFontSize == 1) {
		fontSize = [defaults floatForKey:CMPrefSelectedFontSizeKey];
	}
	
	NSFont *font = [NSFont systemFontOfSize:fontSize];
	NSDictionary *attrsDict = [NSDictionary dictionaryWithObject:font
														  forKey:NSFontAttributeName];
	NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:title
																	  attributes:attrsDict] autorelease];
	return attrString;
}

#pragma mark -

@interface MenuController ()
- (void)_buildClipMenu;
- (void)_addClipsToMenu:(NSMenu *)aMenu;
- (void)_addSnippetsToMenu:(NSMenu *)aMenu atPosition:(CMPositionOfSnippets)positionOfSnippets;

- (NSString *)_menuItemTitleWithString:(NSString *)titileWithMark listNumber:(NSUInteger)listNumber boolean:(BOOL)isMarkWithNumber;
- (NSMenuItem *)_makeMenuItemForClip:(Clip *)clip withCount:(NSUInteger)count andListNumber:(NSUInteger)listNumber;
- (NSMenuItem *)_makeMenuItemForSnippet:(NSManagedObject *)snippet withListNumber:(NSUInteger)listNumber;
- (NSMenuItem *)_makeSubmenuItemWithCount:(NSUInteger)count start:(NSUInteger)start end:(NSUInteger)end numberOfItems:(NSUInteger)numberOfItems;
- (NSMenuItem *)_makeSubmenuItemWithTitle:(NSString *)title;
- (NSMenuItem *)_makeMenuItemWithTitle:(NSString *)itemName action:(SEL)anAction;
//- (NSMenuItem *)_makeSortMenuItem;

- (NSEvent *)_makeEventFromCurrentEvent:(NSEvent *)currentEvent mousePoint:(NSPoint)mousePoint windowNumber:(NSInteger)windowNumber;
- (NSEvent *)_makeEventForActionFromCurrentEvent:(NSEvent *)currentEvent mousePoint:(NSPoint)mousePoint windowNumber:(NSInteger)windowNumber;
- (NSMenu *)_makeHistoryMenu;
- (NSMenu *)_makeSnippetsMenu;
- (NSMenu *)_makeActionMenu;
- (NSMenuItem *)_makeActionMenuItemFromNode:(ActionNode *)node;
//- (BOOL)_isAppropriateAction:(NSDictionary *)action;

- (void)_changeStatusItem:(NSUInteger)tag;
- (void)statusBarButtonClicked:(id)sender;
- (void)_removeStatusItem;
- (void)_refreshStatusItem;

- (NSImage *)_iconForPboardType:(NSString *)type;
- (NSString *)_iconCacheKeyForType:(NSString *)type;
- (NSImage *)_iconForSnippet;
- (void)_cacheIconForTypes;
- (void)_cacheFolderIcon;
- (void)_cacheOpenFolderIcon;
- (void)_cacheActionIcon;
- (void)_cacheJavaScriptIcon;
- (void)_cacheSnippetIcon;
- (void)_resetMenuIconSize;
- (void)_resetIconCaches;
- (void)_unhighlightMenuItem;

- (void)_handlePreferencePanelWillClose:(NSNotification *)aNotification;
- (void)_handleSnippetEditorWillClose:(NSNotification *)aNotification;
- (void)_handleStatusMenuWillUpdate:(NSNotification *)aNotification;


- (void)_addClipFilterFieldToMenu:(NSMenu *)aMenu;
- (BOOL)_clip:(Clip *)clip matchesFilter:(NSString *)filter;
- (void)_updatePendingClipFilter:(NSString *)filter applyImmediately:(BOOL)immediate;
- (void)_cancelClipFilterDebounce;
- (void)_applyPendingClipFilter;
- (void)_applyFilterVisibilityToMenu:(NSMenu *)menu;
- (void)_rebuildFilterResultsInMenu:(NSMenu *)menu filter:(NSString *)filter;
- (BOOL)_isHistoryClipItem:(NSMenuItem *)item;
- (BOOL)_handleReturnKeyWithShift:(BOOL)shift;
- (NSMenuItem *)_highlightedLeafItem;
- (NSString *)_excerptOfClip:(Clip *)clip forFilter:(NSString *)filter;
- (void)_highlightFilter:(NSString *)filter inMenuItem:(NSMenuItem *)item;
- (BOOL)_isHistoryFolderItem:(NSMenuItem *)item;
- (void)_startClipFilterMonitor;
- (void)_stopClipFilterMonitor;
- (NSEvent *)_handleClipFilterKeyEvent:(NSEvent *)event;
- (NSString *)_typeaheadMutedTitle:(NSString *)title;
- (void)_installCarbonFilterHandler;
- (void)_removeCarbonFilterHandler;
- (OSStatus)_carbonHandleFilterEvent:(EventRef)event;
- (BOOL)_menuIsUnderActiveFilter:(NSMenu *)menu;
- (IBAction)_clipFilterIgnore:(id)sender;

- (id)_init;
@end

#pragma mark -
@implementation MenuController

@synthesize clipMenu;
@synthesize dummyWindow;
@synthesize statusItem;
@synthesize shortVersion;
@synthesize iconForStringPboardType;
@synthesize iconForRTFPboardType;
@synthesize iconForRTFDPboardType;
@synthesize iconForPDFPboardType;
@synthesize iconForFilenamesPboardType;
@synthesize iconForURLPboardType;
@synthesize iconForTIFFPboardType;
@synthesize folderIcon;
@synthesize openFolderIcon;
@synthesize actionIcon;
@synthesize javaScriptIcon;
@synthesize snippetIcon;
@synthesize menuIconSize;
@synthesize highlightedMenuItem;

#pragma mark -
#pragma mark Initialize

+ (void)initialize
{
	if (sharedInstance == nil) {
		sharedInstance = [[self alloc] _init];
	}
}

+ (MenuController *)sharedInstance
{
	return [[sharedInstance retain] autorelease];
}

- (id)init
{
	NSAssert(self != sharedInstance, @"Should never send init to the singleton instance");
	
	[self release];
	[sharedInstance retain];
	return sharedInstance;
}

- (id)_init
{
	self = [super init];
	if (self) {
		[self setShortVersion:[[[NSBundle mainBundle] infoDictionary]							   objectForKey:@"CFBundleShortVersionString"]];
		
		[self _buildClipMenu];		// need to edit snippet. should be improved.
		
		dummyWindow = [[NSWindow alloc] initWithContentRect:NSZeroRect
												  styleMask:NSBorderlessWindowMask
													backing:NSBackingStoreBuffered
													  defer:YES];
		[dummyWindow setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
		
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		
//		if ([defaults integerForKey:CMPrefShowStatusItemKey]) {
//			[self _createStatusItem];
//		}
		
		[self _resetIconCaches];
		
		/* KVO */
		[defaults addObserver:self
				   forKeyPath:CMPrefShowStatusItemKey
					  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
					  context:nil];
		[defaults addObserver:self
				   forKeyPath:CMPrefMenuIconSizeKey
					  options:NSKeyValueObservingOptionNew
					  context:nil];
		
		/* Notification */
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self
			   selector:@selector( _handlePreferencePanelWillClose: )
				   name:CMPreferencePanelWillCloseNotification
				 object:nil];
		[nc addObserver:self
			   selector:@selector( _handleSnippetEditorWillClose: )
				   name:CMSnippetEditorWillCloseNotification
				 object:nil];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	/* KVO */
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults removeObserver:self
				  forKeyPath:CMPrefShowStatusItemKey];
	[defaults removeObserver:self
				  forKeyPath:CMPrefMenuIconSizeKey];
	
	[self _stopClipFilterMonitor];
	[self _cancelClipFilterDebounce];
	[clipFilterString release], clipFilterString = nil;
	[pendingClipFilterString release], pendingClipFilterString = nil;
	activeFilterMenu = nil;
	clipFilterHeader = nil;
	
	[clipMenu release], clipMenu = nil;
	[dummyWindow release], dummyWindow = nil;

	if (statusItem) {
		[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
		[statusItem release], statusItem = nil;		
	}
	
	[shortVersion release], shortVersion = nil;
	[iconForStringPboardType release], iconForStringPboardType = nil;
	[iconForRTFPboardType release], iconForRTFPboardType = nil;
	[iconForRTFDPboardType release], iconForRTFDPboardType = nil;
	[iconForPDFPboardType release], iconForPDFPboardType = nil;
	[iconForFilenamesPboardType release], iconForFilenamesPboardType = nil;
	[iconForURLPboardType release], iconForURLPboardType = nil;
	[iconForTIFFPboardType release], iconForTIFFPboardType = nil;
	
	[folderIcon release], folderIcon = nil;
	[openFolderIcon release], openFolderIcon = nil;
	[actionIcon release], actionIcon = nil;
	[javaScriptIcon release], javaScriptIcon = nil;
	[snippetIcon release], snippetIcon = nil;
	
	[highlightedMenuItem release], highlightedMenuItem = nil;
	
	[super dealloc];
}

#pragma mark -
#pragma mark KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
//	NSLog(@"observeValueForKeyPath: %@ - change: %@", keyPath, change);
	
	if ([keyPath isEqualToString:CMPrefShowStatusItemKey]) {
//		[self _toggleStatusItem];
		
		NSInteger old = [[change objectForKey:kOldKey] integerValue];
		NSInteger new = [[change objectForKey:kNewKey] integerValue];
		
		if (new == 0) {
			[self _removeStatusItem];
		}
		else if (new != old) {
			[self _changeStatusItem:new];
		}
	}
	else if ([keyPath isEqualToString:CMPrefMenuIconSizeKey]) {
		[self _resetMenuIconSize];
	}
}

#pragma mark -
#pragma mark Delegate
#pragma mark - NSMenu -

//- (void)menuNeedsUpdate:(NSMenu *)menu
//{
////	NSLog(@"menuNeedsUpdate");
//	
//	[[NSNotificationCenter defaultCenter] postNotificationName:CMClipMenuWillPopUpNotification object:nil];
//}

/* Submenu direction depends on its width; fix widths so filtering doesn't flip it. */
- (void)_lockWidthOfMenu:(NSMenu *)menu
{
	[menu setMinimumWidth:0];
	[menu setMinimumWidth:[menu size].width];
	for (NSMenuItem *mi in [menu itemArray]) {
		if ([mi hasSubmenu]) {
			[self _lockWidthOfMenu:[mi submenu]];
		}
	}
}

- (void)_unlockWidthOfMenu:(NSMenu *)menu
{
	[menu setMinimumWidth:0];
	for (NSMenuItem *mi in [menu itemArray]) {
		if ([mi hasSubmenu]) {
			[self _unlockWidthOfMenu:[mi submenu]];
		}
	}
}

- (void)menuWillOpen:(NSMenu *)menu
{
	NSString *title = [menu title];
	if ([title isEqualToString:kClipMenuIdentifier] ||
		[title isEqualToString:kHistoryMenuIdentifier]) {
		activeFilterMenu = menu;
		clipFilterHeader = nil;
		for (NSMenuItem *mi in [menu itemArray]) {
			if ([[mi view] isKindOfClass:[CMFilterHeaderView class]]) {
				clipFilterHeader = (CMFilterHeaderView *)[mi view];
				break;
			}
		}
		/* Keep the width fixed while filtering so submenus don't flip direction. */
		[self _lockWidthOfMenu:menu];
		sCMHistorySubmenuWidth = 0;
		for (NSMenuItem *mi in [menu itemArray]) {
			if ([self _isHistoryFolderItem:mi] && sCMHistorySubmenuWidth < [[mi submenu] minimumWidth]) {
				sCMHistorySubmenuWidth = [[mi submenu] minimumWidth];
			}
		}
		CMFilterLog(@"[ClipMenu] menuWillOpen title=%@ header=%@", title, clipFilterHeader);
		[self _updatePendingClipFilter:@"" applyImmediately:YES];
		[self _startClipFilterMonitor];
	}
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
	if (highlightedMenuItem && ![item isEqualTo:highlightedMenuItem]) {
		[self _unhighlightMenuItem];
	}
	
	if (![item hasSubmenu]) {
		return;
	}
	
	if ([item image] && openFolderIcon) {
		[self setHighlightedMenuItem:item];
		[item setImage:openFolderIcon];
	}
}

- (void)menuDidClose:(NSMenu *)menu
{
	if (highlightedMenuItem) {
		[self _unhighlightMenuItem];
	}
	if (menu == activeFilterMenu) {
		[self _stopClipFilterMonitor];
		[self _unlockWidthOfMenu:menu];
		activeFilterMenu = nil;
		clipFilterHeader = nil;
		[self _updatePendingClipFilter:@"" applyImmediately:YES];
	}
}

#pragma mark -
#pragma mark Public

- (void)createStatusItem
{
	if (statusItem == nil) {
		NSUInteger statusMenuIconTag = [[NSUserDefaults standardUserDefaults]
										integerForKey:CMPrefShowStatusItemKey];
		
		[self _changeStatusItem:statusMenuIconTag];
	}
	static BOOL sPopObserver = NO;
	if (!sPopObserver) {
		sPopObserver = YES;
		[[NSDistributedNotificationCenter defaultCenter]
		 addObserver:self
			selector:@selector(statusBarButtonClicked:)
				name:@"io.github.minola68000.ClipMenuNeo.popMenu"
			  object:nil
		suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
	}
}

- (void)updateStatusMenu
{
//	NSLog(@"updateStatusMenu: %@", statusItem);

	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self updateStatusMenu];
		});
		return;
	}
	
	if (statusItem) {		
//		[self _resetMenuIconSize];		// XXX Need to modify?
		
		[self _buildClipMenu];
		/*
		 * Do not assign statusItem.menu on modern macOS: Control Center hosts it
		 * out-of-process and keystrokes never reach our filter / CGEventTap.
		 * Pop the menu in-process from the status button action instead.
		 */
		[statusItem setMenu:nil];
		if ([statusItem respondsToSelector:@selector(button)] && statusItem.button) {
			statusItem.button.target = self;
			statusItem.button.action = @selector(statusBarButtonClicked:);
			[statusItem.button sendActionOn:NSEventMaskLeftMouseDown];
		}
	}
}

- (void)statusBarButtonClicked:(id)sender
{
	(void)sender;
	if (!clipMenu) {
		[self _buildClipMenu];
	}
	NSStatusBarButton *button = nil;
	if ([statusItem respondsToSelector:@selector(button)]) {
		button = statusItem.button;
	}
	if (!button || !clipMenu) {
		return;
	}
	CMFilterLog(@"[ClipMenu] statusBarButtonClicked — in-process popUp");
	[button highlight:YES];
	[clipMenu popUpMenuPositioningItem:nil
	                        atLocation:NSMakePoint(0, NSHeight([button bounds]) + 2.0)
	                            inView:button];
	[button highlight:NO];
}


- (void)popUpMenuForType:(CMPopUpMenuType)type
{
	NSEvent *currentEvent = [NSApp currentEvent];
	NSPoint locationInWindow = [currentEvent locationInWindow];
	NSPoint mouseLocation;		// for Actions
	NSPoint mousePoint;
	NSEvent *newEvent;
	
//	NSLog(@"currentEvent: %@", currentEvent);
//	NSLog(@"origin: %@", NSStringFromPoint([currentEvent locationInWindow]));
	
	[dummyWindow makeKeyAndOrderFront:self];
	[dummyWindow setFrameOrigin:locationInWindow];
	NSInteger windowNumber = [dummyWindow windowNumber];
		
//	NSLog(@"popUpClipMenu: %@", NSStringFromPoint(mousePoint));
	
	NSMenu *menu;
	
	switch (type) {
		case CMPopUpMenuTypeMain:
			mousePoint = [dummyWindow convertScreenToBase:locationInWindow];	
			newEvent = [self _makeEventFromCurrentEvent:currentEvent
											 mousePoint:mousePoint
										   windowNumber:windowNumber];
			[self _buildClipMenu];
			menu = clipMenu;
			break;
		case CMPopUpMenuTypeHistory:
			mousePoint = [dummyWindow convertScreenToBase:locationInWindow];	
			newEvent = [self _makeEventFromCurrentEvent:currentEvent
											 mousePoint:mousePoint
										   windowNumber:windowNumber];
			menu = [self _makeHistoryMenu];
			break;			
		case CMPopUpMenuTypeSnippets:
			mousePoint = [dummyWindow convertScreenToBase:locationInWindow];	
			newEvent = [self _makeEventFromCurrentEvent:currentEvent
											 mousePoint:mousePoint
										   windowNumber:windowNumber];
			menu = [self _makeSnippetsMenu];
			break;
		case CMPopUpMenuTypeActions:
			mouseLocation = [NSEvent mouseLocation];
			mousePoint = [dummyWindow convertScreenToBase:mouseLocation];
			newEvent = [self _makeEventForActionFromCurrentEvent:currentEvent
													  mousePoint:mousePoint
													windowNumber:windowNumber];
			menu = [self _makeActionMenu];
			break;
		default:
			NSAssert(NO, @"Unknown pop up menu type");
			break;
	}
	
//	/* Highlight the first menu item */
//	NSMenuItem *firstItem = [menu itemAtIndex:1];
//	if (firstItem) {
//		NSLog(@"item: %@", firstItem);
//		[menu _setHighlightedItem:firstItem informingDelegate:YES];
//		NSLog(@"hilighted: %@", [menu highlightedItem]);
//	}
	
	[NSMenu popUpContextMenu:menu withEvent:newEvent forView:nil];
	[dummyWindow orderOut:self];
}

#pragma mark -
#pragma mark Private

#pragma mark - Menu -

- (void)_buildClipMenu
{
	NSMenu *newMenu = [[NSMenu allocWithZone:[NSMenu menuZone]] initWithTitle:kClipMenuIdentifier];
	[newMenu setDelegate:self];
	/* Own incremental filter — never let NSMenu type-ahead steal digit/letter keys. */
	if ([newMenu respondsToSelector:@selector(setAllowsTypeSelect:)]) {
		[newMenu setAllowsTypeSelect:NO];
	}
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	CMPositionOfSnippets positionOfSnippets = [defaults integerForKey:CMPrefPositionOfSnippetsKey];
	BOOL addClearHistory = [defaults boolForKey:CMPrefAddClearHistoryMenuItemKey];
	
	if (CMPositionOfSnippetsAboveClips == positionOfSnippets) {
		[self _addSnippetsToMenu:newMenu atPosition:positionOfSnippets];
	}
	
	[self _addClipsToMenu:newMenu];
	
	if (CMPositionOfSnippetsBelowClips == positionOfSnippets) {
		[self _addSnippetsToMenu:newMenu atPosition:positionOfSnippets];
	}
	
	[newMenu addItem:[NSMenuItem separatorItem]];	
	
	if (addClearHistory) {
		[newMenu addItem:[self _makeMenuItemWithTitle:NSLocalizedString(@"Clear History", nil)
											   action:@selector( clearHistory: )]];
	}
	
	[newMenu addItem:[self _makeMenuItemWithTitle:NSLocalizedString(@"Edit Snippets...", nil)
										   action:@selector( showSnippetEditor: )]];
	
	[newMenu addItem:[self _makeMenuItemWithTitle:NSLocalizedString(@"Preferences...", nil)
										   action:@selector( showPreferencePanel: )]];
	
	//	[newMenu addItemWithTitle:NSLocalizedString(@"About ClipMenu", nil)
	//					   action:@selector( orderFrontStandardAboutPanel: )
	//				keyEquivalent:kEmptyString];
	[newMenu addItem:[NSMenuItem separatorItem]];
	[newMenu addItem:[self _makeMenuItemWithTitle:NSLocalizedString(@"Quit ClipMenu", nil)
										   action:@selector( terminate: )]];
	
	[self setValue:newMenu forKey:@"clipMenu"];
	[newMenu release], newMenu = nil;
}

- (void)_addClipsToMenu:(NSMenu *)aMenu
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSUInteger numberOfItemsPlaceInline = [defaults integerForKey:CMPrefNumberOfItemsPlaceInlineKey];
	NSUInteger numberOfItemsPlaceInsideFolder = [defaults integerForKey:CMPrefNumberOfItemsPlaceInsideFolderKey];
	NSUInteger maxHistory = [defaults integerForKey:CMPrefMaxHistorySizeKey];
	BOOL showLabelsInMenu = [defaults boolForKey:CMPrefShowLabelsInMenuKey];
	
	ClipsController *clipsController = [ClipsController sharedInstance];
	NSArray *clips = [clipsController sortedClips];
	NSUInteger currentSize = [clips count];
	if (maxHistory < currentSize) {
		currentSize = maxHistory;
	}
	
	[self _addClipFilterFieldToMenu:aMenu];
	
	if (showLabelsInMenu) {
		NSMenuItem *labelItem = [[NSMenuItem allocWithZone:[NSMenu menuZone]]
								 initWithTitle:NSLocalizedString(@"History", nil)
								 action:NULL 
								 keyEquivalent:kEmptyString]; 
		[labelItem setEnabled:NO];
		[aMenu addItem:labelItem];
		[labelItem release], labelItem = nil;
	}
	
	NSUInteger firstIndex = firstIndexOfMenuItems();
	NSUInteger listNumber = firstIndex;
	NSUInteger submenuCount = numberOfItemsPlaceInline;
	NSUInteger submenuIndex = (0 < [aMenu numberOfItems]) ? [aMenu numberOfItems] : 0;
	submenuIndex += numberOfItemsPlaceInline;
	
	NSUInteger i = 0;
	
	for (i = 0; i < currentSize; i++) {
		Clip *clip = [clips objectAtIndex:i];
		//		NSLog(@"CHECK i: %d", i);
		
		if ((numberOfItemsPlaceInline < 1) ||
			(numberOfItemsPlaceInline - 1) < i) {		
			/* inside a folder */
			if (i == submenuCount) {
				NSMenuItem *submenuItem = [self _makeSubmenuItemWithCount:submenuCount
																	start:firstIndex
																	  end:currentSize
															numberOfItems:numberOfItemsPlaceInsideFolder];
				[aMenu addItem:submenuItem];
				listNumber = firstIndex;
			}
			
			//			NSLog(@"CHECK submenuCount: %d", submenuCount);
			//			NSLog(@"CHECK submenuIndex: %d", submenuIndex);
			
			//			NSUInteger indexOfSubmenu = (enableAction) 
			//			? submenuIndex + numberOfItemsPlaceInline 
			//			: submenuIndex;
			
			NSUInteger indexOfSubmenu = submenuIndex;
			
			//			if (showLabelsInMenu) {
			//				indexOfSubmenu++;
			//			}
			
			//			NSLog(@"CHECK indexOfSubmenu: %d", indexOfSubmenu);
			
			NSMenu *submenu = [[aMenu itemAtIndex:indexOfSubmenu] submenu];		
			NSMenuItem *menuItem = [self _makeMenuItemForClip:clip
													withCount:i
												andListNumber:listNumber];
			[menuItem setTag:i];
			[submenu addItem:menuItem];
			
			listNumber = incrementListNumber(listNumber, numberOfItemsPlaceInsideFolder, firstIndex);
		}
		else {												
			/* display clips inline */
			NSMenuItem *menuItem = [self _makeMenuItemForClip:clip
													withCount:i
												andListNumber:listNumber];
			[menuItem setTag:i];
			[aMenu addItem:menuItem];
			
			listNumber = incrementListNumber(listNumber, numberOfItemsPlaceInline, firstIndex);
		}
		
		if ((i + 1) == (submenuCount + numberOfItemsPlaceInsideFolder)) {
			submenuCount += numberOfItemsPlaceInsideFolder;
			submenuIndex++;
		}
	}
}

#pragma mark - Clip filter -

- (NSString *)_typeaheadMutedTitle:(NSString *)title
{
	if (!title) {
		return kCMTypeaheadMutePrefix;
	}
	return [kCMTypeaheadMutePrefix stringByAppendingString:title];
}

- (void)_addClipFilterFieldToMenu:(NSMenu *)aMenu
{
	CMFilterHeaderView *header = [[[CMFilterHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)] autorelease];
	header.delegate = self;
	NSString *shown = pendingClipFilterString ? pendingClipFilterString
		: (clipFilterString ? clipFilterString : kEmptyString);
	[header setQueryDisplay:shown];
	clipFilterHeader = header;
	
	NSMenuItem *fieldItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]] init] autorelease];
	[fieldItem setTitle:kEmptyString];
	[fieldItem setView:header];
	[aMenu addItem:fieldItem];
}

- (BOOL)_clip:(Clip *)clip matchesFilter:(NSString *)filter
{
	if ([filter length] == 0) {
		return YES;
	}
	NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSWidthInsensitiveSearch | NSDiacriticInsensitiveSearch;
	NSString *stringValue = [clip stringValue];
	if ([stringValue length] > 0 &&
		[stringValue rangeOfString:filter options:opts].location != NSNotFound) {
		return YES;
	}
	for (NSString *filename in [clip filenames]) {
		if ([filename isKindOfClass:[NSString class]] &&
			[filename rangeOfString:filter options:opts].location != NSNotFound) {
			return YES;
		}
	}
	for (id urlObj in [clip URL]) {
		NSString *urlString = nil;
		if ([urlObj isKindOfClass:[NSURL class]]) {
			urlString = [(NSURL *)urlObj absoluteString];
		} else if ([urlObj isKindOfClass:[NSString class]]) {
			urlString = urlObj;
		}
		if ([urlString length] > 0 &&
			[urlString rangeOfString:filter options:opts].location != NSNotFound) {
			return YES;
		}
	}
	return NO;
}

- (void)_updatePendingClipFilter:(NSString *)filter applyImmediately:(BOOL)immediate
{
	NSString *normalized = filter ? filter : kEmptyString;
	if (pendingClipFilterString == nil || ![pendingClipFilterString isEqualToString:normalized]) {
		[pendingClipFilterString release];
		pendingClipFilterString = [normalized copy];
	}
	if (clipFilterHeader) {
		[clipFilterHeader setQueryDisplay:normalized];
	}
	if ([normalized length] > 0) {
		CMFilterLog(@"[ClipMenu] pendingFilter='%@'", normalized);
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:@"CMFilterPendingDidChange"
														object:nil
													  userInfo:[NSDictionary dictionaryWithObject:normalized forKey:@"filter"]];
	if (immediate) {
		[self _cancelClipFilterDebounce];
		[self _applyPendingClipFilter];
		return;
	}
	[self _cancelClipFilterDebounce];
	/* Menu tracking runs in NSEventTrackingRunLoopMode; default-mode timers never fire. */
	[self performSelector:@selector(_applyPendingClipFilter)
			   withObject:nil
			   afterDelay:0.5
				  inModes:[NSArray arrayWithObjects:NSRunLoopCommonModes, NSEventTrackingRunLoopMode, nil]];
}

- (void)_cancelClipFilterDebounce
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self
											 selector:@selector(_applyPendingClipFilter)
											   object:nil];
}

- (void)_applyPendingClipFilter
{
	NSString *pending = pendingClipFilterString ? pendingClipFilterString : kEmptyString;
	NSString *applied = clipFilterString ? clipFilterString : kEmptyString;
	if ([pending isEqualToString:applied]) {
		if (activeFilterMenu) {
			[self _applyFilterVisibilityToMenu:activeFilterMenu];
		}
		return;
	}
	[clipFilterString release];
	clipFilterString = [pending copy];
	if (activeFilterMenu) {
		[self _applyFilterVisibilityToMenu:activeFilterMenu];
	}
}

- (void)_applyFilterVisibilityToMenu:(NSMenu *)menu
{
	if (!menu) {
		return;
	}
	NSString *filter = clipFilterString ? clipFilterString : kEmptyString;
	BOOL filtering = ([filter length] > 0);
	
	for (NSInteger i = 0; i < [menu numberOfItems]; i++) {
		NSMenuItem *item = [menu itemAtIndex:i];
		if ([item view] != nil || [sCMFilterResultItems containsObject:item]) {
			continue;
		}
		if ([self _isHistoryFolderItem:item]) {
			/* Matches are re-packed from the top; original folders stay hidden. */
			[item setHidden:filtering];
			continue;
		}
		if ([item hasSubmenu]) {
			[self _applyFilterVisibilityToMenu:[item submenu]];
			if (!filtering) {
				[item setHidden:NO];
				continue;
			}
			BOOL anyVisible = NO;
			NSMenu *submenu = [item submenu];
			for (NSInteger j = 0; j < [submenu numberOfItems]; j++) {
				if (![[submenu itemAtIndex:j] isHidden]) {
					anyVisible = YES;
					break;
				}
			}
			[item setHidden:!anyVisible];
			continue;
		}
		if ([item action] == @selector(selectMenuItem:)) {
			[item setHidden:filtering];
			continue;
		}
		/* Snippets, separators and the Preferences / Quit footer stay visible while filtering. */
		[item setHidden:NO];
	}
	/* Insert re-packed matches after hiding, so the relayout keeps originals hidden. */
	if (menu == activeFilterMenu) {
		[self _rebuildFilterResultsInMenu:menu filter:filter];
		for (NSMenuItem *mi in [menu itemArray]) {
			if ([self _isHistoryFolderItem:mi] || [self _isHistoryClipItem:mi]) {
				[mi setHidden:(0 < [filter length])];
			}
		}
	}
}

/* The line (or filename / URL) holding the match, starting a little before it. */
- (NSString *)_excerptOfClip:(Clip *)clip forFilter:(NSString *)filter
{
	NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSWidthInsensitiveSearch | NSDiacriticInsensitiveSearch;
	NSMutableArray *sources = [NSMutableArray array];
	if ([[clip stringValue] length] > 0) {
		[sources addObject:[clip stringValue]];
	}
	for (id f in [clip filenames]) {
		if ([f isKindOfClass:[NSString class]]) {
			[sources addObject:f];
		}
	}
	for (id u in [clip URL]) {
		[sources addObject:[u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString] : u];
	}
	for (id src in sources) {
		if (![src isKindOfClass:[NSString class]]) {
			continue;
		}
		NSRange r = [src rangeOfString:filter options:opts];
		if (r.location == NSNotFound) {
			continue;
		}
		NSUInteger lineStart = 0, lineEnd = 0, contentsEnd = 0;
		[src getLineStart:&lineStart end:&lineEnd contentsEnd:&contentsEnd forRange:r];
		NSString *line = [src substringWithRange:NSMakeRange(lineStart, contentsEnd - lineStart)];
		NSUInteger offset = r.location - lineStart;
		if (offset > 15) {
			line = [@"…" stringByAppendingString:[line substringFromIndex:offset - 15]];
		}
		return trimTitle(line);
	}
	return nil;
}

/* Marks every occurrence of the filter string in the item title with a yellow marker. */
- (void)_highlightFilter:(NSString *)filter inMenuItem:(NSMenuItem *)item
{
	NSAttributedString *base = [item attributedTitle];
	if (!base) {
		base = [[[NSAttributedString alloc] initWithString:[item title]] autorelease];
	}
	NSMutableAttributedString *marked = [[base mutableCopy] autorelease];
	NSString *plain = [marked string];
	NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSWidthInsensitiveSearch | NSDiacriticInsensitiveSearch;
	NSRange search = NSMakeRange(0, [plain length]);
	BOOL found = NO;
	while (search.length > 0) {
		NSRange r = [plain rangeOfString:filter options:opts range:search];
		if (r.location == NSNotFound) {
			break;
		}
		[marked addAttribute:NSBackgroundColorAttributeName value:[NSColor yellowColor] range:r];
		[marked addAttribute:NSForegroundColorAttributeName value:[NSColor blackColor] range:r];
		found = YES;
		NSUInteger next = NSMaxRange(r);
		search = NSMakeRange(next, [plain length] - next);
	}
	if (found) {
		[item setAttributedTitle:marked];
	}
}

- (BOOL)_isHistoryClipItem:(NSMenuItem *)item
{
	return [item action] == @selector(selectMenuItem:) && ![sCMFilterResultItems containsObject:item];
}

- (BOOL)_isHistoryFolderItem:(NSMenuItem *)item
{
	if (![item hasSubmenu] || [sCMFilterResultItems containsObject:item]) {
		return NO;
	}
	for (NSMenuItem *sub in [[item submenu] itemArray]) {
		if ([sub action] == @selector(selectMenuItem:)) {
			return YES;
		}
	}
	return NO;
}

- (void)_rebuildFilterResultsInMenu:(NSMenu *)menu filter:(NSString *)filter
{
	if (!sCMFilterResultItems) {
		sCMFilterResultItems = [[NSMutableArray alloc] init];
	}
	for (NSMenuItem *old in sCMFilterResultItems) {
		if ([old menu] == menu) {
			[menu removeItem:old];
		}
	}
	[sCMFilterResultItems removeAllObjects];
	if ([filter length] == 0) {
		return;
	}
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSUInteger inlineCount = [defaults integerForKey:CMPrefNumberOfItemsPlaceInlineKey];
	NSUInteger folderSize = [defaults integerForKey:CMPrefNumberOfItemsPlaceInsideFolderKey];
	NSUInteger maxHistory = [defaults integerForKey:CMPrefMaxHistorySizeKey];
	NSArray *clips = [[ClipsController sharedInstance] sortedClips];
	NSUInteger total = [clips count];
	if (maxHistory < total) {
		total = maxHistory;
	}
	
	NSMutableArray *matches = [NSMutableArray array];
	for (NSUInteger i = 0; i < total; i++) {
		if ([self _clip:[clips objectAtIndex:i] matchesFilter:filter]) {
			[matches addObject:[NSNumber numberWithUnsignedInteger:i]];
		}
	}
	
	/* Insert where the original history items start. */
	NSInteger at = [menu numberOfItems];
	for (NSInteger i = 0; i < [menu numberOfItems]; i++) {
		NSMenuItem *mi = [menu itemAtIndex:i];
		if ([self _isHistoryClipItem:mi] || [self _isHistoryFolderItem:mi]) {
			at = i;
			break;
		}
	}
	
	NSUInteger firstIndex = firstIndexOfMenuItems();
	NSUInteger matchCount = [matches count];
	NSMenu *submenu = nil;
	NSUInteger listNumber = firstIndex;
	for (NSUInteger k = 0; k < matchCount; k++) {
		NSUInteger clipIndex = [[matches objectAtIndex:k] unsignedIntegerValue];
		BOOL inFolder = (inlineCount < 1 || inlineCount <= k) && 0 < folderSize;
		if (inFolder && (k == inlineCount || (k - inlineCount) % folderSize == 0 || (inlineCount < 1 && k % folderSize == 0))) {
			NSMenuItem *folderItem = [self _makeSubmenuItemWithCount:k
															   start:firstIndex
																 end:matchCount
													   numberOfItems:folderSize];
			submenu = [folderItem submenu];
			if (0 < sCMHistorySubmenuWidth) {
				[submenu setMinimumWidth:sCMHistorySubmenuWidth];
			}
			[menu insertItem:folderItem atIndex:at++];
			[sCMFilterResultItems addObject:folderItem];
			listNumber = firstIndex;
		}
		NSMenuItem *menuItem = [self _makeMenuItemForClip:[clips objectAtIndex:clipIndex]
												withCount:clipIndex
											andListNumber:listNumber];
		[menuItem setTag:clipIndex];
		NSStringCompareOptions topts = NSCaseInsensitiveSearch | NSWidthInsensitiveSearch | NSDiacriticInsensitiveSearch;
		if ([[menuItem title] rangeOfString:filter options:topts].location == NSNotFound) {
			/* Match lies on a later line / in the shortened part: show it in context. */
			NSString *excerpt = [self _excerptOfClip:[clips objectAtIndex:clipIndex] forFilter:filter];
			if (excerpt) {
				NSString *shown = [self _typeaheadMutedTitle:excerpt];
				[menuItem setTitle:shown];
				[menuItem setAttributedTitle:makeAttributedTitle(shown)];
			}
		}
		[self _highlightFilter:filter inMenuItem:menuItem];
		if (inFolder) {
			[submenu addItem:menuItem];
			listNumber = incrementListNumber(listNumber, folderSize, firstIndex);
		} else {
			[menu insertItem:menuItem atIndex:at++];
			[sCMFilterResultItems addObject:menuItem];
			listNumber = incrementListNumber(listNumber, inlineCount, firstIndex);
		}
	}
}

- (void)_installCarbonFilterHandler
{
	if (sCMFilterCarbonHandler) {
		return;
	}
	EventTypeSpec specs[2];
	specs[0].eventClass = kEventClassKeyboard;
	specs[0].eventKind = kEventRawKeyDown;
	specs[1].eventClass = kEventClassKeyboard;
	specs[1].eventKind = kEventRawKeyRepeat;
	OSStatus err = InstallEventHandler(GetEventDispatcherTarget(),
									   CMFilterCarbonEventHandler,
									   2,
									   specs,
									   (void *)self,
									   &sCMFilterCarbonHandler);
	if (err != noErr) {
		sCMFilterCarbonHandler = NULL;
		CMFilterLog(@"[ClipMenu] Carbon filter handler failed: %d", (int)err);
	} else {
		CMFilterLog(@"[ClipMenu] Carbon filter handler installed");
	}
}

- (void)_removeCarbonFilterHandler
{
	if (sCMFilterCarbonHandler) {
		RemoveEventHandler(sCMFilterCarbonHandler);
		sCMFilterCarbonHandler = NULL;
	}
}

- (void)_startClipFilterMonitor
{
	[self _stopClipFilterMonitor];
	
	/* Re-arm header tap (status-item menus sometimes skip viewDidMoveToWindow timing). */
	if (clipFilterHeader) {
		[clipFilterHeader ensureKeyIntercept];
	}
	
	/* Local monitor (works for some NSPopupMenuWindow paths). */
	clipFilterEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
																	handler:^NSEvent *(NSEvent *event) {
		NSEvent *passed = [self _handleClipFilterKeyEvent:event];
		return passed;
	}];
	
	/* Carbon — classic menu-tracking path. */
	[self _installCarbonFilterHandler];
	
	/* CGEventTap needs Accessibility. Prompt once per launch if missing —
	 * re-signing / fresh installs often drop the TCC grant. */
	if (!AXIsProcessTrusted() && !sCMFilterDidPromptAX) {
		sCMFilterDidPromptAX = YES;
		NSDictionary *opts = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
															forKey:(id)kAXTrustedCheckOptionPrompt];
		AXIsProcessTrustedWithOptions((CFDictionaryRef)opts);
		CMFilterLog(@"[ClipMenu] prompted for Accessibility (was untrusted)");
	}

	/* macOS 10.15+: keyboard CGEventTap also needs Input Monitoring. */
	if (&CGPreflightListenEventAccess != NULL && !sCMFilterDidRequestListen && !CGPreflightListenEventAccess()) {
		sCMFilterDidRequestListen = YES;
		CMFilterLog(@"[ClipMenu] requesting Input Monitoring (ListenEvent)");
		CGRequestListenEventAccess();
	}

	/* CGEventTap — required when AppKit swallows keys into type-ahead. */
	if (!sCMFilterEventTap) {
		CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
		sCMFilterEventTap = CGEventTapCreate(kCGSessionEventTap,
											 kCGHeadInsertEventTap,
											 kCGEventTapOptionDefault,
											 mask,
											 CMFilterMenuCGEventTapCallback,
											 (void *)self);
		if (!sCMFilterEventTap) {
			sCMFilterEventTap = CGEventTapCreate(kCGHIDEventTap,
												 kCGHeadInsertEventTap,
												 kCGEventTapOptionDefault,
												 mask,
												 CMFilterMenuCGEventTapCallback,
												 (void *)self);
		}
		if (sCMFilterEventTap) {
			sCMFilterTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, sCMFilterEventTap, 0);
			CFRunLoopRef rl = CFRunLoopGetCurrent();
			CFRunLoopAddSource(rl, sCMFilterTapSource, kCFRunLoopCommonModes);
			CFRunLoopAddSource(rl, sCMFilterTapSource, (CFStringRef)NSEventTrackingRunLoopMode);
			CGEventTapEnable(sCMFilterEventTap, true);
			CMFilterLog(@"[ClipMenu] MenuController CGEventTap installed (trusted=%d)", (int)AXIsProcessTrusted());
		} else {
			CMFilterLog(@"[ClipMenu] MenuController CGEventTapCreate failed (trusted=%d)", (int)AXIsProcessTrusted());
		}
	} else {
		CGEventTapEnable(sCMFilterEventTap, true);
	}
}

- (void)_stopClipFilterMonitor
{
	[self _cancelClipFilterDebounce];
	if (clipFilterEventMonitor) {
		[NSEvent removeMonitor:clipFilterEventMonitor];
		clipFilterEventMonitor = nil;
	}
	[self _removeCarbonFilterHandler];
	if (sCMFilterEventTap) {
		CGEventTapEnable(sCMFilterEventTap, false);
		if (sCMFilterTapSource) {
			CFRunLoopRef rl = CFRunLoopGetCurrent();
			CFRunLoopRemoveSource(rl, sCMFilterTapSource, kCFRunLoopCommonModes);
			CFRunLoopRemoveSource(rl, sCMFilterTapSource, (CFStringRef)NSEventTrackingRunLoopMode);
			CFRelease(sCMFilterTapSource);
			sCMFilterTapSource = NULL;
		}
		CFRelease(sCMFilterEventTap);
		sCMFilterEventTap = NULL;
	}
}

- (OSStatus)_carbonHandleFilterEvent:(EventRef)event
{
	if (!activeFilterMenu) {
		return eventNotHandledErr;
	}
	
	UInt32 keyCode = 0;
	GetEventParameter(event, kEventParamKeyCode, typeUInt32, NULL, sizeof(keyCode), NULL, &keyCode);
	
	UInt32 modifiers = 0;
	GetEventParameter(event, kEventParamKeyModifiers, typeUInt32, NULL, sizeof(modifiers), NULL, &modifiers);
	if (modifiers & (cmdKey | controlKey | optionKey | rightControlKey | rightOptionKey)) {
		return eventNotHandledErr;
	}
	
	NSString *current = pendingClipFilterString ? pendingClipFilterString
		: (clipFilterString ? clipFilterString : kEmptyString);
	
	/* Escape */
	if (keyCode == 53) {
		if ([current length] > 0 || [clipFilterString length] > 0) {
			[self _updatePendingClipFilter:kEmptyString applyImmediately:YES];
			return noErr;
		}
		return eventNotHandledErr;
	}
	/* Return / Enter — apply pending filter, then let the menu confirm (Shift+Return = quoted paste). */
	if (keyCode == 36 || keyCode == 76) {
		BOOL shift = (modifiers & (shiftKey | rightShiftKey)) != 0;
		return [self _handleReturnKeyWithShift:shift] ? noErr : eventNotHandledErr;
	}
	/* Delete / Forward delete */
	if (keyCode == 51 || keyCode == 117) {
		if ([current length] > 0) {
			[self _updatePendingClipFilter:[current substringToIndex:[current length] - 1] applyImmediately:NO];
			return noErr;
		}
		return eventNotHandledErr;
	}
	/* Arrows — menu navigation */
	if (keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126) {
		return eventNotHandledErr;
	}
	
	NSString *digit = nil;
	switch (keyCode) {
		case 29: digit = @"0"; break;
		case 18: digit = @"1"; break;
		case 19: digit = @"2"; break;
		case 20: digit = @"3"; break;
		case 21: digit = @"4"; break;
		case 23: digit = @"5"; break;
		case 22: digit = @"6"; break;
		case 26: digit = @"7"; break;
		case 28: digit = @"8"; break;
		case 25: digit = @"9"; break;
		default: break;
	}
	if (digit) {
		[self _updatePendingClipFilter:[current stringByAppendingString:digit] applyImmediately:NO];
		return noErr;
	}
	
	UniChar buffer[8];
	ByteCount actual = 0;
	OSStatus perr = GetEventParameter(event, kEventParamKeyUnicodes, typeUnicodeText, NULL,
									  sizeof(buffer), &actual, buffer);
	if (perr != noErr || actual == 0) {
		return eventNotHandledErr;
	}
	NSUInteger length = actual / sizeof(UniChar);
	NSString *append = [NSString stringWithCharacters:buffer length:length];
	if ([append length] == 0) {
		return eventNotHandledErr;
	}
	unichar c = [append characterAtIndex:0];
	if (c < 32) {
		return eventNotHandledErr;
	}
	
	[self _updatePendingClipFilter:[current stringByAppendingString:append] applyImmediately:NO];
	return noErr; /* consume — blocks NSMenu type-ahead / folder jumping */
}

- (BOOL)_menuIsUnderActiveFilter:(NSMenu *)menu
{
	if (!activeFilterMenu || !menu) {
		return NO;
	}
	for (NSMenu *m = menu; m != nil; m = [m supermenu]) {
		if (m == activeFilterMenu) {
			return YES;
		}
	}
	return NO;
}

- (IBAction)_clipFilterIgnore:(id)sender
{
	(void)sender;
}

- (NSEvent *)_handleClipFilterKeyEvent:(NSEvent *)event
{
	if (!activeFilterMenu) {
		return event;
	}
	NSUInteger mods = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
	if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) {
		return event;
	}
	NSString *raw = [event characters];
	NSString *chars = [event charactersIgnoringModifiers];
	NSString *current = pendingClipFilterString ? pendingClipFilterString
		: (clipFilterString ? clipFilterString : kEmptyString);
	unsigned short kc = [event keyCode];
	
	/* Digits by keyCode — reliable even when characters are empty / IME oddities. */
	NSString *digit = nil;
	switch (kc) {
		case 29: digit = @"0"; break;
		case 18: digit = @"1"; break;
		case 19: digit = @"2"; break;
		case 20: digit = @"3"; break;
		case 21: digit = @"4"; break;
		case 23: digit = @"5"; break;
		case 22: digit = @"6"; break;
		case 26: digit = @"7"; break;
		case 28: digit = @"8"; break;
		case 25: digit = @"9"; break;
		default: break;
	}
	if (digit) {
		CMFilterLog(@"[ClipMenu] handleKey digit='%@' (was='%@')", digit, current);
		[self _updatePendingClipFilter:[current stringByAppendingString:digit] applyImmediately:NO];
		return nil;
	}
	
	if ([chars length] == 0) {
		return event;
	}
	unichar c = [chars characterAtIndex:0];
	
	if (c == 27) {
		if ([current length] > 0 || [clipFilterString length] > 0) {
			[self _updatePendingClipFilter:kEmptyString applyImmediately:YES];
			return nil;
		}
		return event;
	}
	if (c == NSDeleteCharacter || c == NSBackspaceCharacter || c == 127 || kc == 51) {
		if ([current length] > 0) {
			[self _updatePendingClipFilter:[current substringToIndex:[current length] - 1] applyImmediately:NO];
			return nil;
		}
		return event;
	}
	if (c == NSCarriageReturnCharacter || c == NSEnterCharacter || c == '\r' || c == '\n' ||
		kc == 36 || kc == 76) {
		return [self _handleReturnKeyWithShift:((mods & NSEventModifierFlagShift) != 0)] ? nil : event;
	}
	/* Arrows / function keys — leave to menu navigation. */
	if (kc == 123 || kc == 124 || kc == 125 || kc == 126 ||
		c < 32 || c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey ||
		c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey) {
		return event;
	}
	
	NSString *append = (raw && [raw length] > 0) ? raw : chars;
	CMFilterLog(@"[ClipMenu] handleKey append='%@' (was='%@')", append, current);
	[self _updatePendingClipFilter:[current stringByAppendingString:append] applyImmediately:NO];
	return nil;
}

- (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event target:(id *)target action:(SEL *)action
{
	if (![self _menuIsUnderActiveFilter:menu]) {
		return NO;
	}
	if ([event type] != NSEventTypeKeyDown) {
		return NO;
	}
	NSEvent *passed = [self _handleClipFilterKeyEvent:event];
	if (passed == nil) {
		/* Claim the key so AppKit will not run menu type-ahead / equivalents. */
		if (target) {
			*target = self;
		}
		if (action) {
			*action = @selector(_clipFilterIgnore:);
		}
		return YES;
	}
	return NO;
}


#pragma mark - CMFilterHeaderViewDelegate -

- (NSString *)filterHeaderCurrentString:(CMFilterHeaderView *)header
{
	(void)header;
	return pendingClipFilterString ? pendingClipFilterString
		: (clipFilterString ? clipFilterString : kEmptyString);
}

- (void)filterHeader:(CMFilterHeaderView *)header appendString:(NSString *)string
{
	(void)header;
	NSString *current = [self filterHeaderCurrentString:header];
	/* Text goes to the field now; 0.5s quiet = same as Enter (auto apply). */
	[self _updatePendingClipFilter:[current stringByAppendingString:string] applyImmediately:NO];
}

- (void)filterHeader:(CMFilterHeaderView *)header replaceString:(NSString *)string
{
	(void)header;
	[self _updatePendingClipFilter:(string ?: @"") applyImmediately:NO];
}

- (void)filterHeaderDeleteBackward:(CMFilterHeaderView *)header
{
	(void)header;
	NSString *current = [self filterHeaderCurrentString:header];
	if ([current length] == 0) {
		return;
	}
	[self _updatePendingClipFilter:[current substringToIndex:[current length] - 1] applyImmediately:NO];
}

- (void)filterHeaderClear:(CMFilterHeaderView *)header
{
	(void)header;
	[self _updatePendingClipFilter:kEmptyString applyImmediately:YES];
}

- (BOOL)filterHeaderReturnPressed:(CMFilterHeaderView *)header shift:(BOOL)shift
{
	(void)header;
	return [self _handleReturnKeyWithShift:shift];
}

- (BOOL)consumeQuotedPasteRequest
{
	BOOL requested = sCMQuotedPasteRequested;
	sCMQuotedPasteRequested = NO;
	return requested;
}

/* Deepest highlighted leaf item across the open menu / submenus. */
- (NSMenuItem *)_highlightedLeafItem
{
	NSMenu *menu = activeFilterMenu;
	NSMenuItem *item = nil;
	while (menu) {
		NSMenuItem *highlighted = [menu highlightedItem];
		if (!highlighted) {
			break;
		}
		item = highlighted;
		menu = [highlighted hasSubmenu] ? [highlighted submenu] : nil;
	}
	return ([item hasSubmenu]) ? nil : item;
}

/*
 * Return confirms the highlighted item (NO = pass the key to the menu).
 * Shift+Return confirms it as a quoted paste ("> " on every line).
 */
- (BOOL)_handleReturnKeyWithShift:(BOOL)shift
{
	NSString *current = pendingClipFilterString ? pendingClipFilterString : kEmptyString;
	[self _updatePendingClipFilter:current applyImmediately:YES];
	if (!shift) {
		return NO;
	}
	NSMenuItem *item = [self _highlightedLeafItem];
	SEL action = [item action];
	if (action != @selector(selectMenuItem:) && action != @selector(selectSnippetMenuItem:)) {
		return NO;
	}
	sCMQuotedPasteRequested = YES;
	[activeFilterMenu cancelTracking];
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSApp sendAction:action to:[item target] from:item];
		sCMQuotedPasteRequested = NO;
	});
	return YES;
}

- (void)filterHeaderApply:(CMFilterHeaderView *)header
{
	(void)header;
	NSString *current = [self filterHeaderCurrentString:header];
	[self _updatePendingClipFilter:current applyImmediately:YES];
}


- (void)_addSnippetsToMenu:(NSMenu *)aMenu atPosition:(CMPositionOfSnippets)positionOfSnippets
{	
	SnippetsController *snippetsController = [SnippetsController sharedInstance];
	NSArray *snippetFolders = [snippetsController folders];
	if (!snippetFolders || [snippetFolders count] < 1) {
		return;
	}
	
	if (CMPositionOfSnippetsBelowClips == positionOfSnippets) {
		[aMenu addItem:[NSMenuItem separatorItem]];
	}
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	BOOL showLabelsInMenu = [defaults boolForKey:CMPrefShowLabelsInMenuKey];
	
	if (showLabelsInMenu) {
		NSMenuItem *snippetsLabelItem = [[NSMenuItem allocWithZone:[NSMenu menuZone]]
										 initWithTitle:NSLocalizedString(@"Snippets", nil)
										 action:NULL 
										 keyEquivalent:kEmptyString]; 
		[snippetsLabelItem setEnabled:NO];
		[aMenu addItem:snippetsLabelItem];
		[snippetsLabelItem release], snippetsLabelItem = nil;
	}
	
	NSArray *sortDescriptors = [SnippetsController sortDescriptors];
	
	BOOL enabled;
	NSUInteger submenuIndex = [aMenu numberOfItems] - 1;
	NSUInteger firstIndex = firstIndexOfMenuItems();
	
	//	NSLog(@"numberOfItems: %d", [aMenu numberOfItems]);
	//	NSLog(@"submenuIndex: %@", [aMenu itemAtIndex:submenuIndex]);
	
	for (NSManagedObject *folder in snippetFolders) {		
		/* Add folder to menu */
		enabled = [[folder valueForKey:kEnabled] boolValue];
		if (!enabled) {
			continue;
		}
		
		NSString *folderTitle = [folder valueForKey:kTitle];		
		NSMenuItem *subMenuItem = [self _makeSubmenuItemWithTitle:folderTitle];
		[aMenu addItem:subMenuItem];
		submenuIndex++;
		
		/* Get snippets */
		NSManagedObjectContext *managedObjectContext = [folder managedObjectContext];
		NSEntityDescription *entity = [NSEntityDescription entityForName:kSnippetEntity
												  inManagedObjectContext:managedObjectContext];
		NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
		[request setEntity:entity];
		[request setSortDescriptors:sortDescriptors];
		
		NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K == %@", kFolder, folder];
		[request setPredicate:predicate];
		
		NSError *error = nil;
		NSArray *fetchResluts = [managedObjectContext executeFetchRequest:request
																	error:&error];
		if (!fetchResluts || [fetchResluts count] < 1) {
			continue;
		}
		
		/* Add snippets into submenu */
		NSUInteger i = firstIndex;
		
		for (NSManagedObject *snippet in fetchResluts) {
			enabled = [[snippet valueForKey:kEnabled] boolValue];
			if (!enabled) {
				continue;
			}
			
//			NSLog(@"snippet: %@", snippet);
			
			NSMenuItem *menuItem = [self _makeMenuItemForSnippet:snippet withListNumber:i];
			
			NSMenu *subMenu = [[aMenu itemAtIndex:submenuIndex] submenu];
			[subMenu addItem:menuItem];
			i++;
		}
	}
	
	if (CMPositionOfSnippetsAboveClips == positionOfSnippets) {
		[aMenu addItem:[NSMenuItem separatorItem]];
	}
}

- (NSString *)_menuItemTitleWithString:(NSString *)titleString listNumber:(NSUInteger)listNumber boolean:(BOOL)isMarkWithNumber
{	
	if (isMarkWithNumber) {
		return [NSString stringWithFormat:MENU_TITLE_FORMAT, listNumber, titleString];
	}
	
	return titleString;
}

- (NSMenuItem *)_makeMenuItemForClip:(Clip *)clip withCount:(NSUInteger)count andListNumber:(NSUInteger)listNumber
{	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	/* Leading list numbers collide with incremental search type-ahead; never show them. */
	BOOL isMarkWithNumber = NO;
	BOOL isShowToolTip = [defaults boolForKey:CMPrefShowToolTipOnMenuItemKey];
	BOOL isShowIcon = [defaults boolForKey:CMPrefShowIconInTheMenuKey];
	BOOL isShowImage = [defaults boolForKey:CMPrefShowImageInTheMenuKey];
	BOOL addNumericKeyEquivalents = [defaults boolForKey:CMPrefAddNumericKeyEquivalentsKey];
	
	NSString *keyEquivalent = kEmptyString;
	/*
	 * Numeric key equivalents are disabled: they collide with incremental search
	 * and make "1 - 30" folders jump when digits are typed.
	 */
	(void)addNumericKeyEquivalents;
	(void)count;
	
	NSArray *pbTypes = [clip types];
	NSString *primaryPboardType = [clip primaryPboardType];
	NSImage *icon = nil;
	
	if (pbTypes && [pbTypes count] > 0) {
		if (isShowIcon) {
			icon = [self _iconForPboardType:primaryPboardType];
		}
	}
	
	/* stringValue */
	NSString *clipString = [clip stringValue];
	NSString *title = trimTitle(clipString);
	NSString *titleWithMark = [self _menuItemTitleWithString:title
												  listNumber:listNumber 
													 boolean:isMarkWithNumber];
	NSString *mutedTitle = [self _typeaheadMutedTitle:titleWithMark];
	
	NSMenuItem *menuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]]
							 initWithTitle:mutedTitle
							 action:@selector( selectMenuItem: )
							 keyEquivalent:keyEquivalent] autorelease];
	[menuItem setTag:count];
	
	/* Tool Tip */
	if (isShowToolTip) {
		NSUInteger maxLengthOfToolTip = [defaults integerForKey:CMPrefMaxLengthOfToolTipKey];
		NSUInteger toIndex = ([clipString length] < maxLengthOfToolTip) 
		? [clipString length]
		: maxLengthOfToolTip;
		[menuItem setToolTip:[clipString substringToIndex:toIndex]];
	}
	
	/* Change Menu Font Size */
	NSAttributedString *attrString = makeAttributedTitle(mutedTitle);
	if (attrString) {
		[menuItem setAttributedTitle:attrString];
	}
	
	if ([primaryPboardType isEqualToString:NSTIFFPboardType]
		|| [primaryPboardType isEqualToString:NSPICTPboardType]) {
		[menuItem setTitle:[self _typeaheadMutedTitle:[self _menuItemTitleWithString:@"(Image)"
											   listNumber:listNumber
												  boolean:isMarkWithNumber]]];
	}
	else if ([primaryPboardType isEqualToString:NSPDFPboardType]) {
		[menuItem setTitle:[self _typeaheadMutedTitle:[self _menuItemTitleWithString:@"(PDF)"
											   listNumber:listNumber
												  boolean:isMarkWithNumber]]];
	}
	else if ([primaryPboardType isEqualToString:NSFilenamesPboardType]
			 && [title isEqualToString:kEmptyString]) {
		[menuItem setTitle:[self _typeaheadMutedTitle:[self _menuItemTitleWithString:@"(Filenames)"
											   listNumber:listNumber
												  boolean:isMarkWithNumber]]];
	}
	
	/* image */
	NSImage *image = clip.image;
	if (isShowImage &&
		image &&
		![primaryPboardType isEqualToString:NSFilenamesPboardType]) {		
		NSInteger thumbnailWidth = [defaults integerForKey:CMPrefThumbnailWidthKey];
		NSInteger thumbnailHeight = [defaults integerForKey:CMPrefThumbnailHeightKey];
		
		image = [clip thumbnailOfSize:NSMakeSize(thumbnailWidth, thumbnailHeight)];
		if (image) {
			[menuItem setImage:image];
		}
	}
	
	/* icon for menuItem */
	if (icon && !image) {
		[icon setSize:NSMakeSize(menuIconSize,menuIconSize)];
		[menuItem setImage:icon];
	}
	
	return menuItem;
}

- (NSMenuItem *)_makeMenuItemForSnippet:(NSManagedObject *)snippet withListNumber:(NSUInteger)listNumber
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	/* Leading list numbers collide with incremental search type-ahead; never show them. */
	BOOL isMarkWithNumber = NO;
	BOOL isShowIcon = [defaults boolForKey:CMPrefShowIconInTheMenuKey];
	//	BOOL addNumericKeyEquivalents = [defaults boolForKey:CMPrefAddNumericKeyEquivalentsKey];
	
	NSString *keyEquivalent = kEmptyString;
	//	if (addNumericKeyEquivalents) {
	//		BOOL isStartFromZero = [defaults boolForKey:CMPrefMenuItemsTitleStartWithZeroKey];
	//		NSUInteger shortCutNumber = (isStartFromZero)
	//		? listNumber
	//		: ((listNumber == kMaxKeyEquivalents) ? 0 : listNumber);
	//		
	//		if (listNumber <= kMaxKeyEquivalents) {
	//			keyEquivalent = [NSString stringWithFormat:@"%d", shortCutNumber];
	//		}
	//	}
	
	NSImage *icon = nil;
	
	if (isShowIcon) {
		icon = [self _iconForSnippet];
	}
	
	/* stringValue */
	NSString *title = trimTitle([snippet valueForKey:kTitle]);
	NSString *titleWithMark = [self _menuItemTitleWithString:title
												  listNumber:listNumber 
													 boolean:isMarkWithNumber];
	
	NSString *mutedTitle = [self _typeaheadMutedTitle:titleWithMark];
	NSMenuItem *menuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]]
							 initWithTitle:mutedTitle
							 action:@selector( selectSnippetMenuItem: )
							 keyEquivalent:keyEquivalent] autorelease];
	[menuItem setRepresentedObject:snippet];
	//	[menuItem setTag:count];
	[menuItem setToolTip:[snippet valueForKey:kContent]];
	
	/* Change Menu Font Size */
	NSAttributedString *attrString = makeAttributedTitle(mutedTitle);
	if (attrString) {
		[menuItem setAttributedTitle:attrString];
	}
	
	/* icon for menuItem */
	if (icon) {
		[icon setSize:NSMakeSize(menuIconSize,menuIconSize)];
		[menuItem setImage:icon];
	}
	
	return menuItem;
}

- (NSMenuItem *)_makeSubmenuItemWithCount:(NSUInteger)count start:(NSUInteger)start end:(NSUInteger)end numberOfItems:(NSUInteger)numberOfItems
{
	if (start == 0) {
		count--;
	}
	
	NSUInteger lastNumber = count + numberOfItems;
	//	NSLog(@"count: %d, start:%d, end:%d, lastNumber: %d", count, start, end, lastNumber);
	
	if (end < lastNumber) {
		lastNumber = end;
	}
	
	/* Leading bullet avoids digit type-ahead jumping between range folders. */
	NSString *menuItemTitle = [NSString stringWithFormat:@"• %d – %d",
							   count + 1,
							   lastNumber];
	return [self _makeSubmenuItemWithTitle:menuItemTitle];
}

- (NSMenuItem *)_makeSubmenuItemWithTitle:(NSString *)title
{
	//	NSLog(@"_makeSubmenu");
	
	NSMenu *submenu = [[NSMenu allocWithZone:[NSMenu menuZone]] init];
	if ([submenu respondsToSelector:@selector(setAllowsTypeSelect:)]) {
		[submenu setAllowsTypeSelect:NO];
	}
	NSMenuItem *submenuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]] 
								initWithTitle:[self _typeaheadMutedTitle:title]
								action:NULL
								keyEquivalent:kEmptyString] autorelease];
	[submenuItem setSubmenu:submenu];
	[submenu release], submenu = nil;
	
	NSAttributedString *attrString = makeAttributedTitle([self _typeaheadMutedTitle:title]);
	if (attrString) {
		[submenuItem setAttributedTitle:attrString];
	}
	
	/* icon */	
	if ([[NSUserDefaults standardUserDefaults] boolForKey:CMPrefShowIconInTheMenuKey]
		&& folderIcon) {
		//		[folderIcon setSize:NSMakeSize(menuIconSize,menuIconSize)];
		[submenuItem setImage:folderIcon];
	}
	
	return submenuItem;
}

- (NSMenuItem *)_makeMenuItemWithTitle:(NSString *)itemName action:(SEL)anAction
{
	NSString *muted = [self _typeaheadMutedTitle:itemName];
	NSMenuItem *menuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]]
							 initWithTitle:muted
							 action:anAction
							 keyEquivalent:kEmptyString] autorelease];
	/* Status-item menus have no responder chain to AppController; set targets. */
	if (anAction == @selector(terminate:)) {
		[menuItem setTarget:NSApp];
	} else if (anAction != NULL) {
		id delegate = [NSApp delegate];
		if (delegate && [delegate respondsToSelector:anAction]) {
			[menuItem setTarget:delegate];
		}
	}
	
	NSAttributedString *attrString = makeAttributedTitle(muted);
	if (attrString) {
		[menuItem setAttributedTitle:attrString];
	}
	
	return menuItem;
}

//- (NSMenuItem *)_makeSortMenuItem
//{
//	NSString *title = @"Sort";
//	BOOL isAscending = NO;
//	
//	NSCellStateValue ascMenuItemState;
//	NSCellStateValue descMenuItemState;
//	
//	if (isAscending) {
//		ascMenuItemState = NSOnState;
//		descMenuItemState = NSOffState;
//	}
//	else {
//		ascMenuItemState = NSOffState;
//		descMenuItemState = NSOnState;
//	}
//	
//	NSMenu *submenu = [[NSMenu allocWithZone:[NSMenu menuZone]] init];
//	
//	NSMenuItem *ascMenuItem = [self _makeMenuItemWithTitle:@"Ascending" action:NULL];
//	[ascMenuItem setState:ascMenuItemState];
//	[submenu addItem:ascMenuItem];
//	
//	NSMenuItem *descMenuItem = [self _makeMenuItemWithTitle:@"Descending" action:NULL];
//	[descMenuItem setState:descMenuItemState];
//	[submenu addItem:descMenuItem];
//	
//	NSMenuItem *submenuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]] 
//								initWithTitle:title
//								action:NULL
//								keyEquivalent:kEmptyString] autorelease];
//	[submenuItem setSubmenu:submenu];
//	[submenu release], submenu = nil;
//	
//	NSAttributedString *attrString = makeAttributedTitle(title);
//	if (attrString) {
//		[submenuItem setAttributedTitle:attrString];
//	}
//	
//	return submenuItem;
//}

#pragma mark - Menu Pop Up -

- (NSEvent *)_makeEventFromCurrentEvent:(NSEvent *)currentEvent mousePoint:(NSPoint)mousePoint windowNumber:(NSInteger)windowNumber
{
	return [NSEvent otherEventWithType:[currentEvent type]
							  location:mousePoint
						 modifierFlags:[currentEvent modifierFlags]
							 timestamp:[currentEvent timestamp]
						  windowNumber:windowNumber
							   context:[currentEvent context]
							   subtype:[currentEvent subtype]
								 data1:[currentEvent data1]
								 data2:[currentEvent data2]];
}

- (NSEvent *)_makeEventForActionFromCurrentEvent:(NSEvent *)currentEvent mousePoint:(NSPoint)mousePoint windowNumber:(NSInteger)windowNumber
{
	NSEvent *newEvent;
	
	switch ([currentEvent type]) {
		case NSLeftMouseDown:
		case NSLeftMouseUp:
		case NSRightMouseDown:
		case NSRightMouseUp:
		case NSKeyDown:
			/* default behavior */
			newEvent = [NSEvent otherEventWithType:NSApplicationDefined
										  location:mousePoint
									 modifierFlags:0
										 timestamp:0
									  windowNumber:windowNumber
										   context:nil
										   subtype:0
											 data1:0
											 data2:0];
			break;
		default:			
			/* not reach here? */			
			newEvent = [NSEvent otherEventWithType:[currentEvent type]
										  location:mousePoint
									 modifierFlags:[currentEvent modifierFlags]
										 timestamp:[currentEvent timestamp]
									  windowNumber:windowNumber
										   context:[currentEvent context]
										   subtype:[currentEvent subtype]
											 data1:[currentEvent data1]
											 data2:[currentEvent data2]];
			break;
	}
	
	return newEvent;
}

- (NSMenu *)_makeHistoryMenu
{
	NSMenu *newMenu = [[[NSMenu allocWithZone:[NSMenu menuZone]]
						initWithTitle:kHistoryMenuIdentifier] autorelease];
	[newMenu setDelegate:self];
	if ([newMenu respondsToSelector:@selector(setAllowsTypeSelect:)]) {
		[newMenu setAllowsTypeSelect:NO];
	}
	[self _addClipsToMenu:newMenu];
	
	return newMenu;
}

- (NSMenu *)_makeSnippetsMenu
{
	//	NSLog(@"_makeSnippetsMenu");
	
	NSMenu *newMenu = [[[NSMenu allocWithZone:[NSMenu menuZone]]
						initWithTitle:kSnippetsMenuIdentifier] autorelease];
	[newMenu setDelegate:self];
	[self _addSnippetsToMenu:newMenu atPosition:CMPositionOfSnippetsNone];
	
	return newMenu;
}

- (NSMenu *)_makeActionMenu
{
	//	NSLog(@"_makeActionMenu");
	
	NSMenu *newMenu = [[[NSMenu allocWithZone:[NSMenu menuZone]]
						initWithTitle:kActionMenuIdentifier] autorelease];
	[newMenu setDelegate:self];
	
	NSArray *actionNodes = [[ActionController sharedInstance] actionNodes];
	for (ActionNode *node in actionNodes) {
		//		NSLog(@"node: %@", [node nodeTitle]);
		
		NSMenuItem *newActionMenuItem = nil;
		if (newActionMenuItem = [self _makeActionMenuItemFromNode:node]) {
			[newMenu addItem:newActionMenuItem];
		}
	}
	
	//	[newMenu addItem:[NSMenuItem separatorItem]];
	//	
	//	NSMenuItem *menuItem = [[NSMenuItem allocWithZone:[NSMenu menuZone]] initWithTitle:NSLocalizedString(@"Remove", nil)
	//													  action:@selector(selectAction:)
	//											   keyEquivalent:kEmptyString];
	//	[menuItem setRepresentedObject:[NSString stringWithString:@"Remove"]];
	//	[newMenu addItem:menuItem];
	//	[menuItem release], menuItem = nil;
	
	return newMenu;
}

- (NSMenuItem *)_makeActionMenuItemFromNode:(ActionNode *)node
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	BOOL isShowIcon = [defaults boolForKey:CMPrefShowIconInTheMenuKey];
	
	if ([node isLeaf]) {			
		NSMenuItem *actionMenuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]] 
									   initWithTitle:[node nodeTitle]
									   action:@selector( selectActionMenuItem: )
									   keyEquivalent:kEmptyString] autorelease];
		
		NSDictionary *action = [node action];
		
		if (action) {
			//			if (![self _isAppropriateAction:action]) {
			//				return nil;
			//			}
			
			if (!CMIsPerformableAction(action)) {
				return nil;
			}
			
			[actionMenuItem setRepresentedObject:action];
			
			/* Tool Tip */
			BOOL isShowToolTip = [defaults boolForKey:CMPrefShowToolTipOnMenuItemKey];
			if (isShowToolTip) {
				NSDictionary *toolTips = [[[ActionController sharedInstance] builtInActionController] valueForKey:@"toolTips"];
				NSString *actionName = [action objectForKey:@"name"];
				NSString *toolTipOfAction = nil;
				if (toolTipOfAction = [toolTips objectForKey:actionName]) {
					[actionMenuItem setToolTip:toolTipOfAction];
				}
			}
		}
		
		/* icon for menuItem */
		if (isShowIcon) {
			NSString *type = [action objectForKey:@"type"];
			if ([type isEqualToString:CMBuiltinActionTypeKey] && actionIcon) {
				[actionMenuItem setImage:actionIcon];
			}
			else if ([type isEqualToString:CMJavaScriptActionTypeKey] && javaScriptIcon) {
				[actionMenuItem setImage:javaScriptIcon];
			}
		}
		
		return actionMenuItem;
	}
	else {
		NSMenu *subMenu = [[[NSMenu allocWithZone:[NSMenu menuZone]] init] autorelease];
		
		for (ActionNode *childNode in [node children]) {
			NSMenuItem *newActionMenuItem = nil;
			if (newActionMenuItem = [self _makeActionMenuItemFromNode:childNode]) {
				[subMenu addItem:newActionMenuItem];
			}
		}
		
		if ([subMenu numberOfItems] == 0) {
			return nil;
		}
		
		NSMenuItem *folderMenuItem = [[[NSMenuItem allocWithZone:[NSMenu menuZone]] 
									   initWithTitle:[node nodeTitle]
									   action:NULL
									   keyEquivalent:kEmptyString] autorelease];
		[folderMenuItem setSubmenu:subMenu];
		
		/* icon for menuItem */
		if (isShowIcon && folderIcon) {
			//			[icon setSize:NSMakeSize(menuIconSize,menuIconSize)];
			[folderMenuItem setImage:folderIcon];
		}
		
		return folderMenuItem;
	}
}

//- (BOOL)_isAppropriateAction:(NSDictionary *)action
//{	
////	NSLog(@"action: %@", action);
//	
//	NSString *name = [action objectForKey:@"name"];
//	NSString *type = [action objectForKey:@"type"]; 
////	if ([type isEqualToString:CMBuiltinActionTypeKey]) {
////		return YES;
////	}
//	
//	ActionController *actionController = [ActionController sharedInstance];
//	NSInteger tag = [actionController selectedClipTag];
//	Clip *clip = [[[ClipsController sharedInstance] clips] objectAtIndex:tag];
//	NSArray *selectedClipTypes = [clip types];
//	
////	NSLog(@"selectedClipTypes: %@", selectedClipTypes);
//	
////	if ([selectedClipTypes containsObject:NSStringPboardType]) {
////		return YES;
////	}
//	
//	if ([type isEqualToString:CMBuiltinActionTypeKey]) {
//		NSDictionary *builtInActions = [[actionController builtInActionController] valueForKey:@"actions"];
//		NSDictionary *builtInAction = [builtInActions objectForKey:name];
////		NSLog(@"builtInAction: %@", builtInAction);
//		
//		for (NSString *key in [builtInAction objectForKey:@"types"]) {
////			NSLog(@"key: %@", key);
//			if ([selectedClipTypes containsObject:key]) {
//				return YES;
//			}
//		}
//	}
//	else if ([type isEqualToString:CMJavaScriptActionTypeKey]) {
//		if ([selectedClipTypes containsObject:NSStringPboardType]) {
//			return YES;
//		}
//	}
//	
//	return NO;
//}

#pragma mark - StatusItem -

- (void)_changeStatusItem:(NSUInteger)tag
{
	[self _removeStatusItem];
	
	NSString *statusMenuIconName;
	
	switch (tag) {
		case 1:
			statusMenuIconName = STATUS_MENU_ICON;
			break;
		case 2:
			statusMenuIconName = @"StatusMenuIconFirst";
			break;
		case 3:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors1-bw-left";
			break;
		case 4:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors1-bw-right";
			break;
		case 5:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors1-color-left";
			break;
		case 6:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors1-color-right";
			break;
		case 7:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-diagonal-bw";
			break;
		case 8:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-diagonal-color";
			break;
		case 9:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors2-bw-left";
			break;
		case 10:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors2-bw-right";
			break;
		case 11:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors2-color-left";
			break;
		case 12:
			statusMenuIconName = @"StatusMenuIconByDaveUlrich-scissors2-color-right";
			break;
		case 13:
			statusMenuIconName = @"StatusMenuIconBySuphiAksoy";
			break;
		default:
			/* default filename */
			statusMenuIconName = STATUS_MENU_ICON;
			break;
	}
	
	NSString *pressedStatusMenuIconName = [statusMenuIconName stringByAppendingString:STATUS_MENU_ICON_POSTFIX];
	
	NSImage *statusIcon = [NSImage imageNamed:
						   [statusMenuIconName stringByAppendingString:STATUS_MENU_ICON_FILE_EXTENSION]];
	if (statusIcon == nil) {
		statusIcon = [NSImage imageNamed:STATUS_MENU_ICON];
	}
	
	NSImage *statusIconPressed = [NSImage imageNamed:
								  [pressedStatusMenuIconName stringByAppendingString:STATUS_MENU_ICON_FILE_EXTENSION]];
	if (statusIconPressed == nil) {
		statusIconPressed = statusIcon;
	}
	
	NSString *toolTipLabel = [NSString stringWithFormat:@"%@ %@", @"ClipMenuNeo", self.shortVersion];
	
	NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
	
	statusItem = [[statusBar statusItemWithLength:NSVariableStatusItemLength] retain];
	/* Prefer NSStatusBarButton API (macOS 10.10+); keep legacy setters as fallback. */
	if ([statusItem respondsToSelector:@selector(button)] && statusItem.button) {
		statusItem.button.image = statusIcon;
		statusItem.button.toolTip = toolTipLabel;
		statusItem.button.imageScaling = NSImageScaleProportionallyDown;
		if ([statusIcon respondsToSelector:@selector(setTemplate:)]) {
			[statusIcon setTemplate:YES];
			statusItem.button.image = statusIcon;
		}
	} else {
		[statusItem setImage:statusIcon];
		[statusItem setAlternateImage:statusIconPressed];
		[statusItem setHighlightMode:YES];
		[statusItem setToolTip:toolTipLabel];
	}
	
	if (clipMenu) {
		[statusItem setMenu:nil];
		if ([statusItem respondsToSelector:@selector(button)] && statusItem.button) {
			statusItem.button.target = self;
			statusItem.button.action = @selector(statusBarButtonClicked:);
			[statusItem.button sendActionOn:NSEventMaskLeftMouseDown];
		}
	}
}

- (void)_removeStatusItem
{
	if (statusItem) {
		[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
		[statusItem release], statusItem = nil;		
	}
}

- (void)_refreshStatusItem
{
	if (statusItem) {
		[statusItem setMenu:nil];
		if ([statusItem respondsToSelector:@selector(button)] && statusItem.button) {
			statusItem.button.target = self;
			statusItem.button.action = @selector(statusBarButtonClicked:);
			[statusItem.button sendActionOn:NSEventMaskLeftMouseDown];
		}
	}
}

#pragma mark - Icon -

- (NSImage *)_iconForPboardType:(NSString *)type
{			
	if (!type) {
		return nil;
	}
	
	NSString *key = [self _iconCacheKeyForType:type];
	if (!key) {
		return nil;
	}
	
	NSImage *icon = [self valueForKey:key];
	
	return icon;
}

- (NSString *)_iconCacheKeyForType:(NSString *)type
{
	if (!type) {
		return nil;
	}
	
	//	NSRange range = [type rangeOfString:@"NS"];
	//	NSMutableString *key = [NSMutableString stringWithString:type];
	//	[key replaceCharactersInRange:range withString:@"iconFor"];
	//		
	//	return key;
	
	if ([type isEqualToString:NSStringPboardType]) {
		return @"iconForStringPboardType";
	}
	else if ([type isEqualToString:NSRTFPboardType]) {
		return @"iconForRTFPboardType";
	}
	else if ([type isEqualToString:NSRTFDPboardType]) {
		return @"iconForRTFDPboardType";
	}
	else if ([type isEqualToString:NSPDFPboardType]) {
		return @"iconForPDFPboardType";
	} 
	else if ([type isEqualToString:NSFilenamesPboardType]) {
		return @"iconForFilenamesPboardType";
	}
	else if ([type isEqualToString:NSURLPboardType]) {
		return @"iconForURLPboardType";
	}
	else if ([type isEqualToString:NSTIFFPboardType] || [type isEqualToString:NSPICTPboardType]) {
		return @"iconForTIFFPboardType";
	}
	
	return nil;
}

- (NSImage *)_iconForSnippet
{
	return [self valueForKey:@"snippetIcon"];
}

- (void)_cacheIconForTypes
{
	NSArray *types = [Clip availableTypes];
	for (NSString *type in types) {
		NSImage *icon = [Clip fileTypeIconForPboardType:type];
		if (icon) {
			//			NSRange range = [type rangeOfString:@"NS"];
			//			NSMutableString *key = [NSMutableString stringWithString:type];
			//			[key replaceCharactersInRange:range withString:@"iconFor"];
			
			NSString *key = [self _iconCacheKeyForType:type];
			if (key) {
				[self setValue:icon forKey:key];
			}
		}
	}
}

- (void)_cacheFolderIcon
{
	//	[self _resetMenuIconSize];
	
	NSImage *icon = [[NSWorkspace sharedWorkspace] 
					 iconForFileType:NSFileTypeForHFSTypeCode(kGenericFolderIcon)];
	[icon setSize:NSMakeSize(menuIconSize,menuIconSize)];
	[self setFolderIcon:icon];
}

- (void)_cacheOpenFolderIcon
{
	NSImage *icon = [[NSWorkspace sharedWorkspace] 
					 iconForFileType:NSFileTypeForHFSTypeCode(kOpenFolderIcon)];
	[icon setSize:NSMakeSize(menuIconSize,menuIconSize)];
	[self setOpenFolderIcon:icon];
}

- (void)_cacheActionIcon
{
	NSString *imageResource = nil;
	switch (menuIconSize) {
		case SMALL_ICON_SIZE:
			imageResource = @"ActionIcon";
			break;
		case LARGE_ICON_SIZE:
			imageResource = @"ActionIconLarge";
			break;
		default:
			imageResource = @"ActionIconLarge";
			break;
	}
	
	NSString *fileName = [[NSBundle mainBundle] pathForImageResource:imageResource];
	if (fileName) {
		[self setActionIcon:[[[NSImage alloc] initWithContentsOfFile:fileName] autorelease]];
	}
}

- (void)_cacheJavaScriptIcon
{
	NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFileType:@"js"];
	[icon setSize:NSMakeSize(menuIconSize,menuIconSize)];
	[self setJavaScriptIcon:icon];
}

- (void)_cacheSnippetIcon
{
	NSImage *icon = [[NSWorkspace sharedWorkspace]
					 iconForFileType:NSFileTypeForHFSTypeCode(kClippingTextTypeIcon)];
	[icon setSize:NSMakeSize(menuIconSize, menuIconSize)];
	[self setSnippetIcon:icon];
}

- (void)_resetMenuIconSize
{
	NSUInteger iconSize = [[NSUserDefaults standardUserDefaults] integerForKey:CMPrefMenuIconSizeKey];	
	[self setMenuIconSize:iconSize];
}

- (void)_resetIconCaches
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey:CMPrefShowIconInTheMenuKey]) {
		[self _cacheIconForTypes];
		[self _resetMenuIconSize];
		
		[self _cacheFolderIcon];
		[self _cacheOpenFolderIcon];
		[self _cacheActionIcon];
		[self _cacheJavaScriptIcon];
		[self _cacheSnippetIcon];
	}
}

- (void)_unhighlightMenuItem
{
	[highlightedMenuItem setImage:folderIcon];
	[self setHighlightedMenuItem:nil];
}

#pragma mark - Notification -

- (void)_handlePreferencePanelWillClose:(NSNotification *)aNotification
{
	[self _resetIconCaches];
	
	NSUInteger showStatusItem = [[NSUserDefaults standardUserDefaults]
								 integerForKey:CMPrefShowStatusItemKey];
	if (showStatusItem) {
		[self updateStatusMenu];
	}
}

- (void)_handleSnippetEditorWillClose:(NSNotification *)aNotification
{	
	[self updateStatusMenu];
}

- (void)_handleStatusMenuWillUpdate:(NSNotification *)aNotification
{	
	[self updateStatusMenu];
}

#pragma mark - E2E filter harness -

+ (int)runFilterE2ETest
{
	[NSApplication sharedApplication];
	MenuController *mc = [MenuController sharedInstance];
	
	__block NSString *seenFilter = [[NSMutableString string] retain];
	__block NSString *windowClass = [[NSMutableString string] retain];
	__block NSString *interceptKind = [[NSMutableString string] retain];
	__block BOOL matchVisibleAtApply = NO;
	__block BOOL otherHiddenAtApply = NO;
	__block NSMenu *menuRef = nil;
	__block NSMenuItem *clipDigitRef = nil;
	__block NSMenuItem *clipOtherRef = nil;
	__block BOOL postedKeys = NO;
	
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:kHistoryMenuIdentifier] autorelease];
	[menu setDelegate:mc];
	menuRef = menu;
	
	CMFilterHeaderView *header = [[[CMFilterHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)] autorelease];
	header.delegate = mc;
	NSMenuItem *headerItem = [[[NSMenuItem alloc] init] autorelease];
	[headerItem setView:header];
	[menu addItem:headerItem];
	
	NSMenuItem *folderA = [[[NSMenuItem alloc] initWithTitle:@"• 1 – 30" action:NULL keyEquivalent:@""] autorelease];
	NSMenu *subA = [[[NSMenu alloc] init] autorelease];
	[folderA setSubmenu:subA];
	NSMenuItem *folderB = [[[NSMenuItem alloc] initWithTitle:@"• 31 – 60" action:NULL keyEquivalent:@""] autorelease];
	[folderB setSubmenu:[[[NSMenu alloc] init] autorelease]];
	[menu addItem:folderA];
	[menu addItem:folderB];
	
	NSMenuItem *clipDigit = [[[NSMenuItem alloc] initWithTitle:@"zzz-match-333" action:@selector(selectMenuItem:) keyEquivalent:@""] autorelease];
	[clipDigit setTag:0];
	[subA addItem:clipDigit];
	clipDigitRef = clipDigit;
	NSMenuItem *clipOther = [[[NSMenuItem alloc] initWithTitle:@"other-plain" action:@selector(selectMenuItem:) keyEquivalent:@""] autorelease];
	[clipOther setTag:1];
	[subA addItem:clipOther];
	clipOtherRef = clipOther;
	
	id obs1 = [[NSNotificationCenter defaultCenter]
			   addObserverForName:@"CMFilterPendingDidChange" object:nil queue:nil
			   usingBlock:^(NSNotification *note) {
		NSString *f = [[note userInfo] objectForKey:@"filter"];
		if ([f length] > 0) {
			[(NSMutableString *)seenFilter setString:f];
		}
	}];
	id obs2 = [[NSNotificationCenter defaultCenter]
			   addObserverForName:@"CMFilterHandlerInstalled" object:nil queue:nil
			   usingBlock:^(NSNotification *note) {
		NSString *wc = [[note userInfo] objectForKey:@"windowClass"];
		NSString *ik = [[note userInfo] objectForKey:@"intercept"];
		if (wc) [(NSMutableString *)windowClass setString:wc];
		if (ik) [(NSMutableString *)interceptKind setString:ik];
		
		/* Real event path: CGEventPost must be seen by CGEventTap during tracking. */
		dispatch_async(dispatch_get_main_queue(), ^{
			[mc filterHeaderClear:header];
			[(NSMutableString *)seenFilter setString:@""];
		});
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			usleep(250000);
			CGKeyCode codes[2] = { 20, 20 }; /* '3' '3' */
			for (int i = 0; i < 2; i++) {
				CGEventRef down = CGEventCreateKeyboardEvent(NULL, codes[i], true);
				CGEventRef up = CGEventCreateKeyboardEvent(NULL, codes[i], false);
				if (down && up) {
					CGEventSetFlags(down, 0);
					CGEventSetFlags(up, 0);
					CGEventPost(kCGSessionEventTap, down);
					CGEventPost(kCGSessionEventTap, up);
					postedKeys = YES;
				}
				if (down) CFRelease(down);
				if (up) CFRelease(up);
				usleep(80000);
			}
			usleep(150000);
			dispatch_async(dispatch_get_main_queue(), ^{
				NSString *cur = [mc filterHeaderCurrentString:header];
				if ([cur length] > 0) {
					[(NSMutableString *)seenFilter setString:cur];
				}
				[mc filterHeaderApply:header];
				otherHiddenAtApply = [folderA isHidden]; /* original folders are replaced by re-packed matches */
				matchVisibleAtApply = ![clipDigitRef isHidden];
				NSLog(@"[E2E] after CGEventPost pending='%@' posted=%d", cur, (int)postedKeys);
				[menuRef cancelTracking];
			});
		});
	}];
	
	NSWindow *host = [[[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 40, 40)
												  styleMask:NSWindowStyleMaskTitled
													backing:NSBackingStoreBuffered
													  defer:NO] autorelease];
	[host setIsVisible:YES];
	
	NSPoint pt = NSMakePoint(10, 10);
	NSEvent *evt = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
									  location:pt
								 modifierFlags:0
									 timestamp:[[NSProcessInfo processInfo] systemUptime]
								  windowNumber:[host windowNumber]
									   context:nil
								   eventNumber:1
									clickCount:1
									  pressure:1];
	[NSMenu popUpContextMenu:menu withEvent:evt forView:[host contentView]];
	
	[[NSNotificationCenter defaultCenter] removeObserver:obs1];
	[[NSNotificationCenter defaultCenter] removeObserver:obs2];
	[host orderOut:nil];
	
	int failures = 0;
	if ([windowClass length] == 0) {
		NSLog(@"[E2E] FAIL intercept not installed");
		failures++;
	} else {
		NSLog(@"[E2E] OK intercept on %@ (%@)", windowClass, interceptKind);
	}
	if (!postedKeys) {
		NSLog(@"[E2E] FAIL CGEventPost did not run");
		failures++;
	} else {
		NSLog(@"[E2E] OK CGEventPost ran");
	}
	if (!([seenFilter hasPrefix:@"33"])) {
		NSLog(@"[E2E] FAIL filter pending expected prefix '33' got '%@'", seenFilter);
		failures++;
	} else {
		NSLog(@"[E2E] OK filter pending starts with 33 via CGEventTap ('%@')", seenFilter);
	}
	if (!otherHiddenAtApply) {
		NSLog(@"[E2E] FAIL non-matching clip should be hidden at apply");
		failures++;
	} else {
		NSLog(@"[E2E] OK non-matching clip hidden");
	}
	if (!matchVisibleAtApply) {
		NSLog(@"[E2E] FAIL matching clip should stay visible at apply");
		failures++;
	} else {
		NSLog(@"[E2E] OK matching clip visible");
	}
	
	[seenFilter release];
	[windowClass release];
	[interceptKind release];
	
	if (failures) {
		NSLog(@"[E2E] FAILED (%d)", failures);
		return 1;
	}
	NSLog(@"[E2E] PASSED");
	return 0;
}


@end

