//
//  CMFilterHeaderView.m
//  ClipMenu — intercept keys while NSMenu is tracking.
//  Primary: CGEventTap on NSEventTrackingRunLoopMode (NSPopupMenuWindow era).
//  Fallback: Carbon GetEventDispatcherTarget handler (MGKMenuWithFilter).
//

#import "CMFilterHeaderView.h"
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

@interface CMFilterHeaderView ()
{
	NSTextField *queryField;
	EventHandlerRef carbonHandler;
	CFMachPortRef eventTap;
	CFRunLoopSourceRef tapSource;
	id localMonitor;
}
- (BOOL)processInterceptedEvent:(EventRef)event;
- (void)_installKeyIntercept;
- (void)_removeKeyIntercept;
- (BOOL)_handleNSEvent:(NSEvent *)ev;
- (void)reenableEventTapIfNeeded;
@end

static BOOL sCMFilterE2EInjection = NO;
static CMFilterHeaderView *sActiveFilterHeader = nil;

static BOOL CMFilterShouldPassthruKeyCode(unsigned short keyCode)
{
	switch (keyCode) {
		case 123: case 124: case 125: case 126:
		case 115: case 119: case 116: case 121:
		case 48:
		case 122: case 120: case 99: case 118:
		case 96: case 97: case 98: case 100:
			return YES;
		default:
			return NO;
	}
}

static CGEventRef CMFilterCGEventTapCallback(CGEventTapProxy proxy,
											 CGEventType type,
											 CGEventRef event,
											 void *refcon)
{
	(void)proxy;
	CMFilterHeaderView *view = (CMFilterHeaderView *)refcon;
	if (!view) {
		return event;
	}
	
	if (type == kCGEventTapDisabledByTimeout ||
		type == kCGEventTapDisabledByUserInput) {
		[view reenableEventTapIfNeeded];
		return event;
	}
	
	if (type != kCGEventKeyDown) {
		return event;
	}
	
	NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
	if (!nsEvent) {
		return event;
	}
	
	if ([view _handleNSEvent:nsEvent]) {
		NSLog(@"[ClipMenu] CGEventTap consumed keyCode=%u chars=%@",
			  [nsEvent keyCode], [nsEvent charactersIgnoringModifiers]);
		return NULL; /* swallow — stops menu type-ahead / folder jump */
	}
	return event;
}

static OSStatus CMFilterCarbonCallback(EventHandlerCallRef handler,
									   EventRef event,
									   void *userData)
{
	if (!event || !userData) {
		return noErr;
	}
	CMFilterHeaderView *view = (CMFilterHeaderView *)userData;
	if ([view processInterceptedEvent:event]) {
		NSLog(@"[ClipMenu] Carbon consumed key");
		return noErr;
	}
	return CallNextEventHandler(handler, event);
}

@implementation CMFilterHeaderView

@synthesize delegate;

- (id)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (self) {
		carbonHandler = NULL;
		eventTap = NULL;
		tapSource = NULL;
		localMonitor = nil;
		[self setAutoresizingMask:NSViewWidthSizable];
		
		queryField = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 2, frameRect.size.width - 16, 20)];
		[queryField setAutoresizingMask:NSViewWidthSizable];
		[queryField setEditable:NO];
		[queryField setSelectable:NO];
		[queryField setBordered:YES];
		[queryField setBezeled:YES];
		[queryField setBezelStyle:NSTextFieldRoundedBezel];
		[queryField setFont:[NSFont menuFontOfSize:13]];
		[queryField setFocusRingType:NSFocusRingTypeNone];
		[queryField setDelegate:self];
		[[queryField cell] setPlaceholderString:NSLocalizedString(@"Type to filter history", nil)];
		[[queryField cell] setUsesSingleLineMode:YES];
		[[queryField cell] setScrollable:YES];
		[self addSubview:queryField];
		[queryField release];
	}
	return self;
}

- (void)dealloc
{
	[self _removeKeyIntercept];
	if (sActiveFilterHeader == self) {
		sActiveFilterHeader = nil;
	}
	delegate = nil;
	[super dealloc];
}

- (NSString *)query
{
	return [queryField stringValue];
}

- (void)setQuery:(NSString *)query
{
	[self setQueryDisplay:query];
}

- (void)setQueryDisplay:(NSString *)query
{
	if (!query) {
		query = @"";
	}
	if ([[queryField stringValue] isEqualToString:query]) {
		return;
	}
	[queryField setStringValue:query];
	[queryField setNeedsDisplay:YES];
	[self setNeedsDisplay:YES];
}

- (BOOL)isFilterFieldFirstResponder
{
	NSWindow *win = [self window];
	if (!win) {
		return NO;
	}
	NSResponder *fr = [win firstResponder];
	if (fr == queryField) {
		return YES;
	}
	/* Field editor */
	if ([fr isKindOfClass:[NSText class]] && [(id)fr delegate] == queryField) {
		return YES;
	}
	return NO;
}


- (void)ensureKeyIntercept
{
	[self _installKeyIntercept];
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	
	if (![self window]) {
		[self _removeKeyIntercept];
		if (sActiveFilterHeader == self) {
			sActiveFilterHeader = nil;
		}
		return;
	}
	
	sActiveFilterHeader = self;
	[self _installKeyIntercept];
	
	NSString *kind = eventTap ? @"tap" : (carbonHandler ? @"carbon" : @"none");
	[[NSNotificationCenter defaultCenter]
	 postNotificationName:@"CMFilterHandlerInstalled"
	 object:self
	 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
			   [[self window] className], @"windowClass",
			   kind, @"intercept",
			   nil]];
	
}

- (void)controlTextDidChange:(NSNotification *)note
{
	(void)note;
	id <CMFilterHeaderViewDelegate> del = delegate;
	if (!del || ![del respondsToSelector:@selector(filterHeader:replaceString:)]) {
		return;
	}
	[del filterHeader:self replaceString:([queryField stringValue] ?: @"")];
}


- (void)_installKeyIntercept
{
	[self _removeKeyIntercept];
	
	/* Never prompt here — menu open must not spam the Accessibility dialog.
	 * CGEventTap simply no-ops if the process is not trusted. */
	Boolean trusted = AXIsProcessTrusted();
	
	/* 1) Local NSEvent monitor (may work for NSPopupMenuWindow). */
	localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
														 handler:^NSEvent *(NSEvent *event) {
		if ([self _handleNSEvent:event]) {
			NSLog(@"[ClipMenu] localMonitor consumed keyCode=%u", [event keyCode]);
			return nil;
		}
		return event;
	}];
	
	/* 2) CGEventTap — strongest; requires Accessibility. */
	CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
	eventTap = CGEventTapCreate(kCGSessionEventTap,
								kCGHeadInsertEventTap,
								kCGEventTapOptionDefault,
								mask,
								CMFilterCGEventTapCallback,
								(void *)self);
	if (!eventTap) {
		eventTap = CGEventTapCreate(kCGHIDEventTap,
									kCGHeadInsertEventTap,
									kCGEventTapOptionDefault,
									mask,
									CMFilterCGEventTapCallback,
									(void *)self);
	}
	
	if (eventTap) {
		tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
		CFRunLoopRef rl = CFRunLoopGetCurrent();
		CFRunLoopAddSource(rl, tapSource, kCFRunLoopCommonModes);
		CFRunLoopAddSource(rl, tapSource, (CFStringRef)NSEventTrackingRunLoopMode);
		CGEventTapEnable(eventTap, true);
		NSLog(@"[ClipMenu] CGEventTap installed (window=%@ trusted=%d)", [[self window] className], (int)trusted);
	} else {
		NSLog(@"[ClipMenu] CGEventTapCreate failed (trusted=%d) — enable ClipMenu in Privacy > Accessibility", (int)trusted);
	}
	
	/* 3) Carbon fallback */
	EventTargetRef dispatcher = GetEventDispatcherTarget();
	if (dispatcher) {
		EventTypeSpec evts[2];
		evts[0].eventClass = kEventClassKeyboard;
		evts[0].eventKind = kEventRawKeyDown;
		evts[1].eventClass = kEventClassKeyboard;
		evts[1].eventKind = kEventRawKeyRepeat;
		OSStatus result = InstallEventHandler(dispatcher,
											  CMFilterCarbonCallback,
											  2,
											  evts,
											  (void *)self,
											  &carbonHandler);
		if (result != noErr) {
			carbonHandler = NULL;
		} else {
			NSLog(@"[ClipMenu] Carbon handler installed (window=%@)", [[self window] className]);
		}
	}
}

- (void)reenableEventTapIfNeeded
{
	if (eventTap) {
		CGEventTapEnable(eventTap, true);
		NSLog(@"[ClipMenu] CGEventTap re-enabled after disable");
	}
}

- (void)_removeKeyIntercept
{
	if (localMonitor) {
		[NSEvent removeMonitor:localMonitor];
		localMonitor = nil;
	}
	if (eventTap) {
		CGEventTapEnable(eventTap, false);
		if (tapSource) {
			CFRunLoopRef rl = CFRunLoopGetCurrent();
			CFRunLoopRemoveSource(rl, tapSource, kCFRunLoopCommonModes);
			CFRunLoopRemoveSource(rl, tapSource, (CFStringRef)NSEventTrackingRunLoopMode);
			CFRelease(tapSource);
			tapSource = NULL;
		}
		CFRelease(eventTap);
		eventTap = NULL;
	}
	if (carbonHandler) {
		RemoveEventHandler(carbonHandler);
		carbonHandler = NULL;
	}
}

- (BOOL)processInterceptedEvent:(EventRef)event
{
	NSEvent *ev = [NSEvent eventWithEventRef:event];
	if (!ev || [ev type] != NSEventTypeKeyDown) {
		return NO;
	}
	return [self _handleNSEvent:ev];
}

- (BOOL)_handleNSEvent:(NSEvent *)ev
{
	NSUInteger modFlags = [ev modifierFlags];
	if ((modFlags & NSEventModifierFlagCommand) ||
		(modFlags & NSEventModifierFlagControl) ||
		(modFlags & NSEventModifierFlagOption)) {
		return NO;
	}
	unsigned short kc = [ev keyCode];
	if (kc == 36 || kc == 76) {
		return [delegate filterHeaderReturnPressed:self shift:((modFlags & NSEventModifierFlagShift) != 0)];
	}
	return [self handleRawKeyCode:kc characters:[ev charactersIgnoringModifiers]];
}

- (BOOL)handleRawKeyCode:(unsigned short)kc characters:(NSString *)chars
{
	if (CMFilterShouldPassthruKeyCode(kc)) {
		return NO;
	}
	
	id <CMFilterHeaderViewDelegate> del = delegate;
	if (!del) {
		return NO;
	}
	
	NSString *current = [del filterHeaderCurrentString:self];
	if (!current) {
		current = @"";
	}
	
	if (kc == 53) {
		if ([current length] > 0) {
			[del filterHeaderClear:self];
			return YES;
		}
		return NO;
	}
	if (kc == 36 || kc == 76) {
		return [del filterHeaderReturnPressed:self shift:NO];
	}
	if (kc == 51) {
		if ([current length] > 0) {
			[del filterHeaderDeleteBackward:self];
			return YES;
		}
		return NO;
	}
	if (kc == 117) {
		return NO;
	}
	
	/* ANSI digit keyCodes — always treat as filter input (never menu type-ahead / Quit). */
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
		[del filterHeader:self appendString:digit];
		return YES;
	}
	
	if (chars && [chars length] >= 1) {
		unichar c = [chars characterAtIndex:0];
		if (c >= '0' && c <= '9') {
			[del filterHeader:self appendString:[NSString stringWithCharacters:&c length:1]];
			return YES;
		}
		if (c >= 32) {
			[del filterHeader:self appendString:chars];
			return YES;
		}
	}
	return NO;
}

+ (void)setE2EInjectionEnabled:(BOOL)enabled
{
	sCMFilterE2EInjection = enabled;
}

@end
