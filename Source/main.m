//
//  main.m
//  ClipMenu
//

#import <Cocoa/Cocoa.h>
#import "MenuController.h"

int main(int argc, char *argv[])
{
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--self-test-filter") == 0) {
			return [MenuController runFilterE2ETest];
		}
	}
	return NSApplicationMain(argc, (const char **)argv);
}
