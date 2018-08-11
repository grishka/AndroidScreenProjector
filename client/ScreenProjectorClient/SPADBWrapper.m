//
//  SPADBWrapper.m
//  ScreenProjectorClient
//
//  Created by Grishka on 14.10.2017.
//  Copyright © 2017 Grishka. All rights reserved.
//

#import "SPADBWrapper.h"
#include <sys/socket.h>
#include <errno.h>
#include <assert.h>
#include <netdb.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <assert.h>

@implementation SPADBWrapper{
	NSThread* adbThread;
	id delegate;
	int deviceTrackingSocket;
}

- (id)init{
	adbThread=[[NSThread alloc] init];
	deviceTrackingSocket=0;
	
	return self;
}

- (void)_runBlock: (void (^)(void))block{
	block();
}

- (void)_runInBackground: (void (^)(void))block{
	[self performSelectorInBackground:@selector(_runBlock:) withObject:block];
}

- (void)_runOnMainThread: (void (^)(void))block{
	[self performSelectorOnMainThread:@selector(_runBlock:) withObject:block waitUntilDone:false];
}

- (int)_makeAndConnectSocket{
	int s=socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
	struct sockaddr_in addr;
	inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
	addr.sin_family=AF_INET;
	addr.sin_port=htons(5037);
	int res=connect(s, (struct sockaddr*)&addr, sizeof(addr));
	if(res!=0){
		[self performSelectorOnMainThread:@selector(_reportError:) withObject:@[@"connect",[NSString stringWithUTF8String:strerror(errno)]] waitUntilDone:false];
		close(s);
		return 0;
	}
	
	return s;
}

- (bool)_sendCommand: (NSString*)cmd toSocket: (int)sck{
	uint16_t len=[cmd lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	const char* ccmd=[[NSString stringWithFormat:@"%04X%@", len, cmd] cStringUsingEncoding:NSUTF8StringEncoding];
	NSLog(@"Sending adb command: %@", cmd);
	send(sck, ccmd, len+4, 0);
	char buffer[4];
	size_t recvd=recv(sck, buffer, 4, 0);
	if(recvd<=0)
		return false;
	if(strncmp(buffer, "OKAY", 4)==0){
		return true;
	}else{
		NSLog(@"Failed: %s", buffer);
		[self performSelectorOnMainThread:@selector(_reportError:) withObject:@[cmd,[NSString stringWithUTF8String:buffer]] waitUntilDone:false];
		return false;
	}
}

- (NSString*)_receiveLengthPrefixedStringFromSocket: (int)sck{
	char lbuf[5];
	ssize_t rlen=recv(sck, lbuf, 4, 0);
	if(rlen!=4){
		return NULL;
	}
	lbuf[4]=0;
	size_t slen;
	sscanf(lbuf, "%4zX", &slen);
	char sbuf[slen+1];
	sbuf[slen]=0;
	size_t totalRecvd=0;
	while(totalRecvd<slen){
		rlen=recv(sck, sbuf+totalRecvd, slen-totalRecvd, 0);
		if(rlen<=0){
			return NULL;
		}
		totalRecvd+=(size_t)rlen;
	}
	return [NSString stringWithUTF8String:sbuf];
}

- (void)listConnectedDevicesWithCompletionBlock: (void (^)(NSArray<SPDevice*>*))completion{
	[self _runInBackground:^{
		int sck=[self _makeAndConnectSocket];
		if([self _sendCommand:@"host:devices-l" toSocket:sck]){
			char buffer[1024];
			size_t recvd=recv(sck, buffer, 1023, 0);
			if(recvd<=0){
				NSLog(@"Failed to list devices [2]");
			}else{
				NSMutableArray<SPDevice*>* result=[[NSMutableArray alloc]init];
				buffer[recvd]=0;
				NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[ ]+" options:NSRegularExpressionCaseInsensitive error:NULL];
				NSString* unparsedList=[NSString stringWithUTF8String:buffer+4];
				unparsedList = [regex stringByReplacingMatchesInString:unparsedList options:0 range:NSMakeRange(0, [unparsedList length]) withTemplate:@"\t"];
				NSArray<NSString*>* list=[unparsedList componentsSeparatedByString:@"\n"];
				for(unsigned int i=0;i<[list count];i++){
					NSArray<NSString*>* parts=[list[i] componentsSeparatedByString:@"\t"];
					if([parts count]<2)
						break;
					NSString* serial=parts[0];
					NSString* state=parts[1];
					if(![state isEqualToString:@"device"])
						continue;
					SPDevice* dev=[[SPDevice alloc]init];
					dev.serial=serial;
					for(unsigned int j=2;j<[parts count];j++){
						NSArray<NSString*>* kv=[[parts objectAtIndex:j] componentsSeparatedByString:@":"];
						NSString* key=kv[0];
						NSString* value=kv[1];
						if([key isEqualToString:@"model"]){
							NSLog(@"Device: serial=%@, model=%@", serial, value);
							dev.name=value;
						}
					}
					[result addObject:dev];
				}
				[self _runOnMainThread:^{
					completion(result);
				}];
			}
		}else{
			NSLog(@"Failed to list devices!");
		}
		close(sck);
	}];
}

- (void)runShellCommand: (NSString*)cmd onDeviceWithSerial: (NSString*)serial completion: (void (^)(NSString*))completion{
	[self _runInBackground:^{
		int sck=[self _makeAndConnectSocket];
		if([self _sendCommand:[NSString stringWithFormat:@"host:transport:%@", serial] toSocket:sck]){
			if([self _sendCommand:[NSString stringWithFormat:@"shell:%@", cmd] toSocket:sck]){
				NSString* result=@"";
				size_t recvd=0;
				do{
					char buffer[1024];
					recvd=recv(sck, buffer, 1023, 0);
					if(recvd>0){
						buffer[recvd]=0;
						NSLog(@"received: %s", buffer);
						NSString* part=[NSString stringWithUTF8String:buffer];
						result=[result stringByAppendingString:part];
					}
				}while(recvd>0);
				[self _runOnMainThread:^{
					completion(result);
				}];
			}
		}
		close(sck);
	}];
}

- (void)connectToTcpPort: (uint16_t)port onDeviceWithSerial: (NSString*)serial completion: (void (^)(int))completion{
	[self _runInBackground:^{
		int sck=[self _makeAndConnectSocket];
		if([self _sendCommand:[NSString stringWithFormat:@"host:transport:%@", serial] toSocket:sck]){
			if([self _sendCommand:[NSString stringWithFormat:@"tcp:%u", port] toSocket:sck]){
				[self _runOnMainThread:^{
					completion(sck);
				}];
			}
		}
	}];
}

- (void)forwardTcpPort: (uint16_t)port onDeviceWithSerial: (NSString*)serial toHostPort: (uint16_t)hport completion: (void (^)())completion{
    [self _runInBackground:^{
        int sck=[self _makeAndConnectSocket];
        //if([self _sendCommand:[NSString stringWithFormat:@"host:transport:%@", serial] toSocket:sck]){
        if([self _sendCommand:[NSString stringWithFormat:@"host-serial:%@:forward:tcp:%u;tcp:%u", serial, hport, port] toSocket:sck]){
                [self _runOnMainThread:^{
                    completion();
                }];
            }
        //}
    }];
}

- (void)connectToTcpPortOnLocalHost: (uint16_t)port completion: (void (^)(int))completion{
    [self _runInBackground:^{
        int s=socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
        struct sockaddr_in addr;
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        addr.sin_family=AF_INET;
        addr.sin_port=htons(port);
        int result=connect(s, (struct sockaddr*)&addr, sizeof(addr));
        NSLog(@"connect to port %u: result %d error %d %s", port, result, errno, strerror(errno));
        [self _runOnMainThread:^{
            completion(s);
        }];
    }];
}

- (void)setDelegate:(id)_delegate{
	delegate=_delegate;
}

- (void)startTrackingDevices{
	[self _runInBackground:^{
		int sck=[self _makeAndConnectSocket];
		if(!sck)
			return;
		deviceTrackingSocket=sck;
		if([self _sendCommand:@"host:track-devices" toSocket:sck]){
			NSMutableArray<SPDevice*>* devices=[[NSMutableArray alloc]init];
			while(deviceTrackingSocket){
				NSString* resp=[self _receiveLengthPrefixedStringFromSocket:deviceTrackingSocket];
				if(!resp)
					break;
				NSArray<NSString*>* lines=[resp componentsSeparatedByString:@"\n"];
				NSMutableArray<NSString*>* newDevList=[[NSMutableArray alloc] init];
				for(NSString* line in lines){
					NSArray<NSString*>* parts=[line componentsSeparatedByString:@"\t"];
					if([parts count]<2)
						continue;
					NSString* serial=parts[0];
					NSString* state=parts[1];
					if(![state isEqualToString:@"device"])
						continue;
					[newDevList addObject:serial];
					bool found=false;
					for(SPDevice* dev in devices){
						if([dev.serial isEqualToString:serial]){
							found=true;
							break;
						}
					}
					if(!found){
						int tmpsck=[self _makeAndConnectSocket];
						if([self _sendCommand:[NSString stringWithFormat:@"host:transport:%@", serial] toSocket:tmpsck]){
							if([self _sendCommand:@"shell:echo \"$(getprop ro.product.manufacturer) $(getprop ro.product.model)|$(getprop ro.build.version.sdk)|$(getprop ro.build.version.release)|\"" toSocket:tmpsck]){
								char buffer[1024];
								size_t recvd=recv(tmpsck, buffer, 1023, 0);
								if(recvd<=0){
									NSLog(@"Failed to run shell command");
								}else{
									buffer[recvd]=0;
									NSLog(@"received: %s", buffer);
									NSString* devinfo=[NSString stringWithUTF8String:buffer];
									NSArray<NSString*>* infoParts=[devinfo componentsSeparatedByString:@"|"];
									SPDevice* dev=[[SPDevice alloc] init];
									dev.serial=serial;
									dev.name=infoParts[0];
									dev.apiLevel=infoParts[1].intValue;
									dev.androidVersion=infoParts[2];
									[devices addObject:dev];
									[delegate performSelectorOnMainThread:@selector(adbDeviceAdded:) withObject:dev waitUntilDone:false];
								}
							}else{
								NSLog(@"Failed to get device info for %@", serial);
							}
						}else{
							NSLog(@"Failed to transport to %@", serial);
						}
						close(tmpsck);
					}
				}
				NSMutableArray<SPDevice*>* devicesToRemove=[[NSMutableArray alloc] init];
				for(SPDevice* dev in devices){
					if([newDevList indexOfObject:dev.serial]==NSNotFound){
						[delegate performSelectorOnMainThread:@selector(adbDeviceRemoved:) withObject:dev waitUntilDone:false];
						[devicesToRemove addObject:dev];
					}
				}
				if([devicesToRemove count])
					[devices removeObjectsInArray:devicesToRemove];
				//NSLog(@"devices: %@", resp);
			}
		}else{
			NSLog(@"Failed to list devices!");
			//[self performSelectorOnMainThread:@selector(_reportError:) withObject:@[@"host:track-devices",(NSString*)nil,[NSString stringWithUTF8String:strerror(errno)]] waitUntilDone:false];
		}
		if(deviceTrackingSocket)
			close(deviceTrackingSocket);
	}];
}

- (void)stopTrackingDevices{
	if(deviceTrackingSocket){
		int s=deviceTrackingSocket;
		deviceTrackingSocket=0;
		close(s);
	}
}

- (void)_reportError:(NSArray*)params{
	[delegate adbCommand:params[0] onDeviceWithSerial:nil didFailWithError:params[1]];
}

- (void)pushFileFromLocalPath: (NSString*)localPath toRemotePath: (NSString*)remotePath onDeviceWithSerial: (NSString*)serial completion: (void (^)())completion{
	[self _runInBackground:^{
		int sck=[self _makeAndConnectSocket];
		if([self _sendCommand:[NSString stringWithFormat:@"host:transport:%@", serial] toSocket:sck]){
			if([self _sendCommand:@"sync:" toSocket:sck]){
				char buf[512];
				memcpy(buf, "SEND", 4);
				NSString* rpath=[NSString stringWithFormat:@"%@,0666",remotePath];
				UInt32 nameLen=(UInt32)[rpath lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
				assert(nameLen+8<=sizeof(buf));
				memcpy(buf+4, &nameLen, 4);
				memcpy(buf+8, [rpath cStringUsingEncoding:NSUTF8StringEncoding], nameLen);
				send(sck, buf, nameLen+8, 0);
				FILE* file=fopen([localPath cStringUsingEncoding:NSUTF8StringEncoding], "r");
				if(!file){
					close(sck);
					return;
				}
				unsigned char* fbuf=malloc(64*1024);
				while(!feof(file)){
					size_t _count=fread(fbuf, 1, 64*1024, file);
					UInt32 count=(UInt32)_count;
					memcpy(buf, "DATA", 4);
					memcpy(buf+4, &count, 4);
					NSLog(@"sending file part of length %u", count);
					send(sck, buf, 8, 0);
					send(sck, fbuf, _count, 0);
				}
				free(fbuf);
				UInt32 lastmod=(UInt32)time(NULL);
				memcpy(buf, "DONE", 4);
				memcpy(buf+4, &lastmod, 4);
				send(sck, buf, 8, 0);
				ssize_t recvd=recv(sck, buf, 8, 0);
				if(recvd==8){
					buf[4]=0;
					NSLog(@"push done: %s", buf);
				}
				close(sck);
				fclose(file);
				[self _runOnMainThread:^{
					completion();
				}];
			}
		}
	}];
}

@end


@implementation SPDevice
@end
