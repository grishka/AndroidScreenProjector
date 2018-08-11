//
//  AppDelegate.m
//  OpenGLTest
//
//  Created by Grishka on 04.12.16.
//  Copyright (c) 2016 Grishka. All rights reserved.
//

#import "AppDelegate.h"
#import <AVFoundation/AVFoundation.h>

#include <sys/socket.h>

@implementation AppDelegate{
	SPADBWrapper* adb;
	NSMenuItem* placeholderItem;
	NSView* titleBarView;
	bool updatingDevices;
	NSMutableArray<SPDevice*>* devices;
	SPDevice* currentDevice;
	int streamingSocket;
	NSSize videoSize;
	int retryCount;
	
	AVSampleBufferDisplayLayer* videoLayer;
}
@synthesize window, deviceSelectionOverlay, deviceListBox, videoView, connectBtn, progressBar, progressText, progressOverlay;



- (void)applicationWillFinishLaunching:(NSNotification *)aNotification{
	retryCount=0;

	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
	[window setTitle: @"ScreenProjector"];
	[window setMovableByWindowBackground:true];
	adb=[[SPADBWrapper alloc]init];
	[adb setDelegate:self];
	[connectBtn setEnabled:false];
	
	placeholderItem=[[NSMenuItem alloc] initWithTitle:@"(no Android devices are connected)" action:NULL keyEquivalent:@""];
	[placeholderItem setEnabled:false];
	[[deviceListBox cell] setMenuItem:placeholderItem];
	devices=[[NSMutableArray alloc]init];
	updatingDevices=true;
	[self updateConnectedDevices];
	[window setAspectRatio:NSMakeSize(9.0, 16.0)];
	
	for(NSView* view in [[[window contentView] superview] subviews]){
		if([view isKindOfClass:NSClassFromString(@"NSTitlebarContainerView")]){
			titleBarView=view;
			break;
		}
	}
	
	videoLayer=[[AVSampleBufferDisplayLayer alloc] init];
	videoLayer.videoGravity=AVLayerVideoGravityResizeAspect;
	[videoView setLayer:videoLayer];
	[videoView setWantsLayer:true];
	
	[progressOverlay setHidden:true];
	[videoView setHidden:true];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{
	return YES;
}

- (void)updateConnectedDevices{
	/*[adb listConnectedDevicesWithCompletionBlock:^(NSArray<SPDevice*>* devices){
		[deviceListBox removeAllItems];
		for(unsigned int i=0;i<[devices count];i++){
			[deviceListBox addItemWithTitle:devices[i].name];
		}
		[self->devices removeAllObjects];
		[self->devices addObjectsFromArray:devices];
		
		//if(updatingDevices)
		//	[self performSelector:@selector(updateConnectedDevices) withObject:NULL afterDelay:1];
	}];*/
	[adb startTrackingDevices];
}

- (void)startServer{
	[progressText setStringValue:@"Starting server..."];
	[adb runShellCommand:@"am start -n \"me.grishka.screenprojector/me.grishka.screenprojector.MainActivity\" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER" onDeviceWithSerial:currentDevice.serial completion:^(NSString* output){
		[progressText setStringValue:@"Connecting..."];
		[self startStreaming];
		//[self performSelector:@selector(startStreaming) withObject:NULL afterDelay:1];
	}];
}

- (void)installServer{
	[progressText setStringValue:@"Installing server..."];
	[adb pushFileFromLocalPath:[[NSBundle mainBundle] pathForResource:@"server" ofType:@"apk"] toRemotePath:@"/data/local/tmp/screen_projector_server.apk" onDeviceWithSerial:currentDevice.serial completion:^{
		NSString* cmd=@"pm install /data/local/tmp/screen_projector_server.apk";
		[adb runShellCommand:cmd onDeviceWithSerial:currentDevice.serial completion:^(NSString* output) {
			if([output containsString:@"Success"]){
				[adb runShellCommand:@"appops set me.grishka.screenprojector PROJECT_MEDIA allow" onDeviceWithSerial: currentDevice.serial completion:^(NSString* output) {
					[self startServer];
				}];
			}else{
				[self adbCommand:cmd onDeviceWithSerial:NULL didFailWithError:output];
				deviceSelectionOverlay.animator.hidden=false;
				progressOverlay.animator.hidden=true;
				connectBtn.enabled=true;
			}
		}];
	}];
}

- (void)startStreaming{
	NSLog(@"start streaming");
	[adb forwardTcpPort:5050 onDeviceWithSerial:currentDevice.serial toHostPort:35050 completion:^(){
		[adb connectToTcpPortOnLocalHost:35050 completion:^(int sck){
			streamingSocket=sck;
			[self performSelectorInBackground:@selector(runStreamingThread) withObject:NULL];
		}];
	}];
}

- (void)retryConnectionDelayed{
	[self performSelector:@selector(startStreaming) withObject:NULL afterDelay:0.25];
}

- (void)runStreamingThread{
	unsigned char* buffer=malloc(1024*1024);
	send(streamingSocket, buffer, 1, 0);
	uint8_t sps[1024], pps[1024];
	bool recvdSPS=false, recvdPPS=false;
	size_t spsLen, ppsLen;
	CMFormatDescriptionRef formatDesc;
	
	bool receivedFirstFrame=false;
	
	while(true){
		int32_t len;
		unsigned char flags;
		ssize_t rlen=recv(streamingSocket, &len, 4, 0);
		if(rlen!=4){
			NSLog(@"socket closed? rlen=%ld", rlen);
			if(!receivedFirstFrame && retryCount<10){
				NSLog(@"retrying");
				retryCount++;
				[self performSelectorOnMainThread:@selector(retryConnectionDelayed) withObject:NULL waitUntilDone:false];
				close(streamingSocket);
				free(buffer);
				return;
			}
			break;
		}
		len=ntohl(len);
		if(len>1024*1024){
			NSLog(@"packet too long");
			break;
		}
		rlen=recv(streamingSocket, &flags, 1, 0);
		if(rlen!=1){
			NSLog(@"socket closed? rlen=%ld", rlen);
			break;
		}
		size_t totalRecvd=0;
		while(totalRecvd<len){
			ssize_t recvd=recv(streamingSocket, buffer+totalRecvd, len-totalRecvd, 0);
			if(recvd<=0){
				NSLog(@"error receiving");
				break;
			}
			totalRecvd+=(size_t)recvd;
		}
		if((flags & 1) && recvdSPS && recvdPPS){
			NSLog(@"Reset");
			recvdSPS=recvdPPS=false;
			CFRelease(formatDesc);
		}
		if(!receivedFirstFrame){
			[self performSelectorOnMainThread:@selector(didReceiveFirstVideoFrame) withObject:NULL waitUntilDone:false];
			receivedFirstFrame=true;
		}
		//NSLog(@"received frame");
		if(!recvdSPS){
			recvdSPS=true;
			if(len<1024){
				memcpy(sps, buffer+4, len-4);
				spsLen=len-4;
			}else{
				NSLog(@"SPS too big: %u", len);
			}
			continue;
		}else if(!recvdPPS){
			recvdPPS=true;
			if(len<1024){
				memcpy(pps, buffer+4, len-4);
				ppsLen=len-4;
				const uint8_t* params[]={sps, pps};
				size_t paramSizes[]={spsLen, ppsLen};
				OSStatus status=CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, params, paramSizes, 4, &formatDesc);
				if(status!=noErr){
					NSLog(@"CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d", status);
					break;
				}
				CGRect rect=CMVideoFormatDescriptionGetCleanAperture(formatDesc, true);
				videoSize=NSMakeSize(rect.size.width, rect.size.height);
				[self performSelectorOnMainThread:@selector(resizeWindowForNewVideoSize) withObject:NULL waitUntilDone:false];
			}else{
				NSLog(@"PPS too big: %u", len);
			}
			continue;
		}
		CMBlockBufferRef blockBuffer;
		UInt32 nalLen=CFSwapInt32(len-4);
		if(buffer[0]==0 && buffer[1]==0 && buffer[2]==1){
			NSLog(@"3-byte header, moving");
			memmove(buffer+4, buffer+3, len-3);
			len++;
		}
		memcpy(buffer, &nalLen, 4);
		OSStatus status=CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorMalloc, NULL, 0, len, 0, &blockBuffer);
		if(status!=noErr){
			NSLog(@"CMBlockBufferCreateWithMemoryBlock failed: %d", status);
			break;
		}
		CMBlockBufferReplaceDataBytes(buffer, blockBuffer, 0, len);
		CMSampleBufferRef sampleBuffer;
		status=CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true, NULL, NULL, formatDesc, 1, 0, NULL, 0, NULL, &sampleBuffer);
		if(status!=noErr){
			NSLog(@"CMSampleBufferCreate failed: %d", status);
			break;
		}
		
		CFRelease(blockBuffer);
		CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
		CFMutableDictionaryRef dict=(CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
		CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
		
		[videoLayer enqueueSampleBuffer:sampleBuffer];
		NSError* error=[videoLayer error];
		if(error){
			NSLog(@"error: %@", [error description]);
		}
		CFRelease(sampleBuffer);
	}
	
	free(buffer);
	//CFRelease(formatDesc);
	//[NSApp terminate:NULL];
	[self performSelectorOnMainThread:@selector(resetUI) withObject:NULL waitUntilDone:false];
}

- (IBAction)connectButtonClicked:(id)sender {
	[adb stopTrackingDevices];
	currentDevice=devices[[deviceListBox indexOfSelectedItem]];
	if(currentDevice.apiLevel<21){
		NSAlert* alert=[[NSAlert alloc] init];
		[alert setAlertStyle:NSAlertStyleCritical];
		[alert addButtonWithTitle:@"OK"];
		[alert setMessageText:@"Screen projection requires Android 5.0 (Lollipop) or newer."];
		[alert setInformativeText:[NSString stringWithFormat:@"%@ runs Android %@.", currentDevice.name, currentDevice.androidVersion]];
		[alert beginSheetModalForWindow:window completionHandler:NULL];
		currentDevice=NULL;
		return;
	}
	[sender setEnabled:false];
	progressOverlay.animator.hidden=false;
	[progressBar startAnimation:progressBar];
	deviceSelectionOverlay.animator.hidden=true;
	[window setTitle:currentDevice.name];
	[progressText setStringValue:@"Checking if the server is installed..."];
	[adb runShellCommand:@"pm path me.grishka.screenprojector > /dev/null; echo $?" onDeviceWithSerial:currentDevice.serial completion:^(NSString* output){
		if([output length]>=1 && [[output substringToIndex:1] isEqualToString:@"0"]){
			NSLog(@"server installed");
			[self startServer];
		}else{
			NSLog(@"server NOT installed");
			[self installServer];
		}
	}];
}

- (void)mouseEntered:(NSEvent *)event{
	titleBarView.animator.alphaValue=1;
}

- (void)mouseExited:(NSEvent *)event{
	titleBarView.animator.alphaValue=0;
}

- (void)resizeWindowForNewVideoSize{
	float size=MAX(window.frame.size.width, window.frame.size.height);
	NSSize newSize;
	if(videoSize.height>videoSize.width){
		newSize=NSMakeSize(videoSize.width/videoSize.height*size, size);
	}else{
		newSize=NSMakeSize(size, videoSize.height/videoSize.width*size);
	}
	window.aspectRatio=newSize;
	NSRect frame=window.frame;
	float centerX=frame.origin.x+frame.size.width/2;
	float centerY=frame.origin.y+frame.size.height/2;
	frame.origin=NSMakePoint(centerX-roundf(newSize.width/2), centerY-roundf(newSize.height/2));
	frame.size=newSize;
	[window setFrame:frame display:true animate:true];
}

- (void)adbCommand:(NSString *)cmd onDeviceWithSerial:(NSString *)serial didFailWithError:(NSString *)error {
	NSLog(@"command %@ failed with error %@", cmd, error);
	NSAlert* alert=[[NSAlert alloc] init];
	[alert setAlertStyle:NSAlertStyleCritical];
	[alert addButtonWithTitle:@"Quit"];
	[alert setInformativeText:error];
	if([cmd isEqualToString:@"connect"]){
		[alert setMessageText:@"Failed to connect to the ADB daemon. Please make sure it's running. To start the daemon, either open Android Studio or run `adb start-server` in Terminal."];
		[alert addButtonWithTitle:@"Try Again"];
	}else{
		[alert setMessageText:[NSString stringWithFormat:@"ADB command '%@' didn't complete successfully.", cmd]];
	}
	[alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
		if(returnCode==1001){
			[self updateConnectedDevices];
		}else{
			[[NSApplication sharedApplication] terminate:NULL];
		}
	}];
}

- (void)adbDeviceAdded:(SPDevice *)device {
	[devices addObject:device];
	[deviceListBox addItemWithTitle:device.name];
	[connectBtn setEnabled:true];
}

- (void)adbDeviceRemoved:(SPDevice *)device {
	NSUInteger index=[devices indexOfObject:device];
	if(index==NSNotFound)
		return;
	[devices removeObjectAtIndex:index];
	[deviceListBox removeItemAtIndex:index];
	if([devices count]==0){
		[[deviceListBox cell] setMenuItem:placeholderItem];
		[connectBtn setEnabled:false];
	}
}

- (void)didReceiveFirstVideoFrame{
	NSTrackingArea* area=[[NSTrackingArea alloc] initWithRect:NSMakeRect(0, 0, 100, 100) options: NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:NULL];
	[[window contentView] addTrackingArea:area];
	progressOverlay.animator.hidden=true;
	videoView.animator.hidden=false;
}

- (void)resetUI{
	if(streamingSocket)
		close(streamingSocket);
	streamingSocket=0;
	retryCount=0;
	videoView.animator.hidden=true;
	deviceSelectionOverlay.animator.hidden=false;
	[deviceListBox removeAllItems];
	[[deviceListBox cell] setMenuItem:placeholderItem];
	[devices removeAllObjects];
	[adb startTrackingDevices];
}

@end
