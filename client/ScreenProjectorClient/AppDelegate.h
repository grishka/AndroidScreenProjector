//
//  AppDelegate.h
//  OpenGLTest
//
//  Created by Grishka on 04.12.16.
//  Copyright (c) 2016 Grishka. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "SPADBWrapper.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, SPADBDelegate>

@property (assign) IBOutlet NSWindow *window;
@property (assign) IBOutlet NSView* deviceSelectionOverlay;
@property (assign) IBOutlet NSView* progressOverlay;
@property (assign) IBOutlet NSPopUpButton* deviceListBox;
@property (assign) IBOutlet NSView* videoView;
@property (assign) IBOutlet NSButton* connectBtn;
@property (assign) IBOutlet NSProgressIndicator* progressBar;
@property (assign) IBOutlet NSTextField* progressText;

@end
