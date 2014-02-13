//  Copyright (C) 2014 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import <DiscRecording/DiscRecording.h>
#import <DiscRecordingUI/DiscRecordingUI.h>
#import <sys/sysctl.h>

#import "AppDelegate.h"
#import "ITunesLibrary.h"
#import "MP3Transcoder.h"

@interface AppDelegate ()
@property(nonatomic, getter = isCancelled) BOOL cancelled;
@end

@implementation AppDelegate

+ (void)initialize {
  NSDictionary* defaults = @{
    kUserDefaultKey_BitRate: [NSNumber numberWithInteger:kBitRate_165Kbps_VBR]
  };
  [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

- (id)init {
  if ((self = [super init])) {
    _cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Transcoded"];
    [[NSFileManager defaultManager] removeItemAtPath:_cachePath error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:_cachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    
    uint32_t cores;
    size_t length = sizeof(cores);
    if (sysctlbyname("hw.physicalcpu", &cores, &length, NULL, 0)) {
      cores = 1;
    }
    _transcoders = MIN(MAX(cores, 1), 4);
    _transcodingSemaphore = dispatch_semaphore_create(_transcoders);
    _numberFormatter = [[NSNumberFormatter alloc] init];
    _numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
  }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  NSError* error = nil;
  NSArray* playlists = [ITunesLibrary loadPlaylists:&error];
  if (playlists.count) {
    [_arrayController setContent:playlists];
    [self updateInfo:nil];
    [_mainWindow makeKeyAndOrderFront:nil];
  } else {
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_FATAL_TITLE", nil)
                                     defaultButton:NSLocalizedString(@"ALERT_FATAL_DEFAULT_BUTTON", nil)
                                   alternateButton:nil
                                       otherButton:nil
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_FATAL_MESSAGE", nil), error.localizedDescription];
    [alert runModal];
    [NSApp terminate:nil];
  }
}

- (void)_quitAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  [NSApp replyToApplicationShouldTerminate:(returnCode == NSOKButton ? YES : NO)];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  if (self.transcoding) {
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_QUIT_TITLE", nil)
                                     defaultButton:NSLocalizedString(@"ALERT_QUIT_DEFAULT_BUTTON", nil)
                                   alternateButton:NSLocalizedString(@"ALERT_QUIT_ALTERNATE_BUTTON", nil)
                                       otherButton:nil
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_QUIT_MESSAGE", nil)];
    [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_quitAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
    return NSTerminateLater;
  }
  return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
  [[NSFileManager defaultManager] removeItemAtPath:_cachePath error:NULL];
}

- (BOOL)windowShouldClose:(id)sender {
  [NSApp terminate:nil];
  return NO;
}

- (BOOL)tableView:(NSTableView*)tableView shouldSelectRow:(NSInteger)row {
  return NO;
}

- (NSString*)tableView:(NSTableView*)tableView toolTipForCell:(NSCell*)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
  if ([tableColumn.identifier isEqualToString:@"conversion"]) {
    Playlist* playlist = [_arrayController.selectedObjects firstObject];
    Track* track = [playlist.tracks objectAtIndex:row];
    if (track.transcodingError) {
      return [NSString stringWithFormat:NSLocalizedString(@"TOOLTIP_ERROR", nil), track.transcodingError.localizedDescription, track.transcodingError.localizedFailureReason];
    }
  }
  return nil;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
  return [NSNumber numberWithInteger:(row + 1)];
}

- (IBAction)updateInfo:(id)sender {
  NSTimeInterval duration = 0.0;
  Playlist* playlist = [_arrayController.selectedObjects firstObject];
  for (Track* track in playlist.tracks) {
    duration += track.duration;
  }
  NSUInteger hours = duration / 3600.0;
  NSUInteger minutes = fmod(duration, 3600.0) / 60.0;
  NSUInteger seconds = fmod(fmod(duration, 3600.0), 60.0);
  BitRate bitRate = [[NSUserDefaults standardUserDefaults] integerForKey:kUserDefaultKey_BitRate];
  NSUInteger size = duration * (NSTimeInterval)KBitsPerSecondFromBitRate(bitRate, true) * 1000.0 / 8.0;
  NSString* countString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:playlist.tracks.count]];
  NSString* sizeString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(size / (1000 * 1000))]];  // Display MB not MiB like in Finder
  [_infoTextField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"PLAYLIST_INFO", nil), countString, (int)hours, (int)minutes, (int)seconds, sizeString]];
}

- (void)_burnSetupPanelDidEnd:(DRSetupPanel*)panel returnCode:(int)returnCode contextInfo:(void*)contextInfo {
  Playlist* playlist = (__bridge Playlist*)contextInfo;
  if (returnCode == NSOKButton) {
    [panel orderOut:nil];
    
    DRFolder* rootFolder = [DRFolder virtualFolderWithName:playlist.name];
    NSUInteger index = 0;
    for (Track* track in playlist.tracks) {
      if (track.transcodedPath) {
        DRFile* file = [DRFile fileWithPath:track.transcodedPath];
        [file setBaseName:[NSString stringWithFormat:@"%03lu - %@.mp3", (unsigned long)++index, track.title]];
        [rootFolder addChild:file];
      }
    }
    DRTrack* track = [DRTrack trackForRootFolder:rootFolder];
    
    DRBurn* burn = [(DRBurnSetupPanel*)panel burnObject];
    NSDictionary* deviceStatus = [[burn device] status];
    uint64_t availableFreeSectors = [[[deviceStatus valueForKey:DRDeviceMediaInfoKey] valueForKey:DRDeviceMediaFreeSpaceKey] longLongValue];
    uint64_t trackLengthInSectors = [track estimateLength];
    if (trackLengthInSectors < availableFreeSectors) {
      DRBurnProgressPanel* progressPanel = [DRBurnProgressPanel progressPanel];
      [progressPanel beginProgressSheetForBurn:burn layout:track modalForWindow:_mainWindow];
    } else {
      NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_SPACE_TITLE", nil)
                                       defaultButton:NSLocalizedString(@"ALERT_SPACE_DEFAULT_BUTTON", nil)
                                     alternateButton:nil
                                         otherButton:nil
                           informativeTextWithFormat:NSLocalizedString(@"ALERT_SPACE_MESSAGE", nil), (int)(trackLengthInSectors * 2048 / (1000 * 1000)), (int)(availableFreeSectors * 2048 / (1000 * 1000))];  // Display MB not MiB like in Finder
      alert.alertStyle = NSCriticalAlertStyle;
      [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    }
  }
  CFRelease((__bridge CFTypeRef)playlist);
}

- (void)_burnPlaylist:(Playlist*)playlist {
  DRBurnSetupPanel* setupPanel = [DRBurnSetupPanel setupPanel];
  [setupPanel setCanSelectTestBurn:YES];
  [setupPanel beginSetupSheetForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_burnSetupPanelDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(playlist)];
}

- (void)_missingAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  Playlist* playlist = (__bridge Playlist*)contextInfo;
  if (returnCode == NSOKButton) {
    [alert.window orderOut:nil];
    [self _burnPlaylist:playlist];
  }
  CFRelease((__bridge CFTypeRef)playlist);
}

- (void)_transcodePlaylist:(Playlist*)playlist {
  BitRate bitRate = [[NSUserDefaults standardUserDefaults] integerForKey:kUserDefaultKey_BitRate];
  self.transcoding = YES;
  _cancelled = NO;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @autoreleasepool {
      NSMutableSet* transcodedTracks = [NSMutableSet set];
      for (Track* track in playlist.tracks) {
        if (_cancelled) {
          break;
        }
        if (!track.transcodedPath && ![transcodedTracks containsObject:track]) {
          [transcodedTracks addObject:track];
          dispatch_semaphore_wait(_transcodingSemaphore, DISPATCH_TIME_FOREVER);
          dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @autoreleasepool {
              NSString* inPath = [track.location path];
              NSString* outPath = [_cachePath stringByAppendingPathComponent:[[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"mp3"]];
              NSError* error = nil;
              BOOL success = [MP3Transcoder transcodeAudioFileAtPath:inPath
                                                              toPath:outPath
                                                         withBitRate:bitRate
                                                               error:&error
                                                       progressBlock:^(float progress, BOOL* stop) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  track.level = 100.0 * progress;
                });
                *stop = _cancelled;
              }];
              dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                  track.level = 100.0;
                  track.transcodedPath = outPath;
                  track.transcodingError = nil;
                } else {
                  track.level = 0.0;
                  track.transcodingError = error;
                }
              });
            }
            dispatch_semaphore_signal(_transcodingSemaphore);
          });
        }
      }
      for (NSUInteger i = 0; i < _transcoders; ++i) {
        dispatch_semaphore_wait(_transcodingSemaphore, DISPATCH_TIME_FOREVER);
      }
      for (NSUInteger i = 0; i < _transcoders; ++i) {
        dispatch_semaphore_signal(_transcodingSemaphore);
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        self.transcoding = NO;
        if (_cancelled == NO) {
          NSUInteger totalCount = playlist.tracks.count;
          NSUInteger transcodedCount = 0;
          for (Track* track in playlist.tracks) {
            if (track.transcodedPath) {
              ++transcodedCount;
            }
          }
          if (transcodedCount == 0) {
            NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_EMPTY_TITLE", nil)
                                             defaultButton:NSLocalizedString(@"ALERT_EMPTY_DEFAULT_BUTTON", nil)
                                           alternateButton:nil
                                               otherButton:nil
                                 informativeTextWithFormat:NSLocalizedString(@"ALERT_EMPTY_MESSAGE", nil)];
            alert.alertStyle = NSCriticalAlertStyle;
            [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
          } else if (transcodedCount < totalCount) {
            NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_MISSING_TITLE", nil)
                                             defaultButton:NSLocalizedString(@"ALERT_MISSING_DEFAULT_BUTTON", nil)
                                           alternateButton:NSLocalizedString(@"ALERT_MISSING_ALTERNATE_BUTTON", nil)
                                               otherButton:nil
                                 informativeTextWithFormat:NSLocalizedString(@"ALERT_MISSING_MESSAGE", nil), (int)(totalCount - transcodedCount), (int)totalCount];
            [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_missingAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(playlist)];
          } else {
            [self _burnPlaylist:playlist];
          }
        }
      });
    }
  });
}

- (IBAction)make:(id)sender {
  Playlist* playlist = [_arrayController.selectedObjects firstObject];
  [self _transcodePlaylist:playlist];
}

- (IBAction)cancelTranscoding:(id)sender {
  _cancelled = YES;
}

@end
