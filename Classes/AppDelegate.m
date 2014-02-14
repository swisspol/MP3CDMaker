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
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/stat.h>

#import "AppDelegate.h"
#import "ITunesLibrary.h"
#import "MP3Transcoder.h"

#define kSectorSize 2048

@interface MP3Disc : NSObject
@property(nonatomic, retain) NSString* name;
@property(nonatomic, retain) NSArray* tracks;
@property(nonatomic) NSRange trackRange;
@property(nonatomic, retain) DRBurn* burn;
@end

@interface AppDelegate ()
@property(nonatomic, getter = isCancelled) BOOL cancelled;
@end

static const char _associatedKey;

static NSUInteger _GetFileSize(NSString* path) {
  struct stat info;
  if (lstat([path fileSystemRepresentation], &info) == 0) {
    return info.st_size;
  }
  return 0;
}

@implementation MP3Disc
@end

@implementation AppDelegate

+ (void)initialize {
  NSDictionary* defaults = @{
    kUserDefaultKey_BitRate: [NSNumber numberWithInteger:kBitRate_165Kbps_VBR],
    kUserDefaultKey_SkipMPEG: @NO
  };
  [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

- (void)_clearCache {
  [[NSFileManager defaultManager] removeItemAtPath:_cachePath error:NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath:_cachePath withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (id)init {
  if ((self = [super init])) {
    _cachePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Transcoded"];
    [self _clearCache];
    
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

- (void)_updateInfo {
  BOOL skipMPEG = [[NSUserDefaults standardUserDefaults] boolForKey:kUserDefaultKey_SkipMPEG];
  NSUInteger bitRate = KBitsPerSecondFromBitRate([[NSUserDefaults standardUserDefaults] integerForKey:kUserDefaultKey_BitRate], true);
  NSTimeInterval duration = 0.0;
  NSUInteger size = 0;
  Playlist* playlist = [_arrayController.selectedObjects firstObject];
  for (Track* track in playlist.tracks) {
    duration += track.duration;
    if (skipMPEG && (track.kind == kTrackKind_MPEG)) {
      size += track.size;
    } else {
      size += track.duration * (NSTimeInterval)bitRate * 1000.0 / 8.0;
    }
  }
  NSUInteger hours = duration / 3600.0;
  NSUInteger minutes = fmod(duration, 3600.0) / 60.0;
  NSUInteger seconds = fmod(fmod(duration, 3600.0), 60.0);
  NSString* countString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:playlist.tracks.count]];
  NSString* sizeString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(size / (1000 * 1000))]];  // Display MB not MiB like in Finder
  NSString* timeString = hours > 0 ? [NSString stringWithFormat:@"%lu:%02lu:%02lu", hours, minutes, seconds] : [NSString stringWithFormat:@"%lu:%02lu", minutes, seconds];
  [_infoTextField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"PLAYLIST_INFO", nil), countString, timeString, sizeString]];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  NSError* error = nil;
  NSArray* playlists = [ITunesLibrary loadPlaylists:&error];
  if (playlists) {
    [_arrayController setContent:playlists];
    [self _updateInfo];
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
  [self _clearCache];
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

@end

@implementation AppDelegate (Actions)

- (IBAction)updatePlaylist:(id)sender {
  [self _updateInfo];
}

- (IBAction)updateQuality:(id)sender {
  [self _updateInfo];
  
  [self _clearCache];
  for (Playlist* playlist in _arrayController.arrangedObjects) {
    for (Track* track in playlist.tracks) {
      track.level = 0.0;
      track.transcodedPath = nil;
      track.transcodedSize = 0;
      track.transcodingError = nil;
    }
  }
  [_tableView reloadData];  // TODO: Works around NSTableView not refreshing properly depending on scrolling position
}

- (IBAction)updateSkip:(id)sender {
  [self _updateInfo];
  
  for (Playlist* playlist in _arrayController.arrangedObjects) {
    for (Track* track in playlist.tracks) {
      if (track.kind == kTrackKind_MPEG) {
        track.level = 0.0;
        track.transcodedPath = nil;  // TODO: This will (temporarily) leak the transcoded file
        track.transcodedSize = 0;
        track.transcodingError = nil;
      }
    }
  }
  [_tableView reloadData];  // TODO: Works around NSTableView not refreshing properly depending on scrolling position
}

- (void)_continueAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSOKButton) {
    [alert.window orderOut:nil];
    [self _prepareDisc:disc];
  }
  CFRelease((__bridge CFTypeRef)disc);
}

- (void)_finishDisc:(MP3Disc*)disc {
  NSDictionary* status = [disc.burn status];
  if ([[status objectForKey:DRStatusStateKey] isEqualToString:DRStatusStateFailed]) {
    NSDictionary* error = [status objectForKey:DRErrorStatusKey];
    if ([[error objectForKey:DRErrorStatusErrorKey] unsignedIntValue] != (unsigned int)kDRUserCanceledErr) {
      NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_FAILURE_TITLE", nil)
                                       defaultButton:NSLocalizedString(@"ALERT_FAILURE_DEFAULT_BUTTON", nil)
                                     alternateButton:NSLocalizedString(@"ALERT_FAILURE_ALTERNATE_BUTTON", nil)
                                         otherButton:nil
                           informativeTextWithFormat:@"%@", [error objectForKey:DRErrorStatusErrorStringKey]];
      [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_continueAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
    }
  } else {
    disc.trackRange = NSMakeRange(disc.trackRange.location + disc.trackRange.length, disc.tracks.count - (disc.trackRange.location + disc.trackRange.length));
    if (disc.trackRange.length > 0) {
      NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_CONTINUE_TITLE", nil)
                                       defaultButton:NSLocalizedString(@"ALERT_CONTINUE_DEFAULT_BUTTON", nil)
                                     alternateButton:NSLocalizedString(@"ALERT_CONTINUE_ALTERNATE_BUTTON", nil)
                                         otherButton:nil
                           informativeTextWithFormat:NSLocalizedString(@"ALERT_CONTINUE_MESSAGE", nil), (int)disc.trackRange.length];
      [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_continueAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
    } else {
      NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_SUCCESS_TITLE", nil)
                                       defaultButton:NSLocalizedString(@"ALERT_SUCCESS_DEFAULT_BUTTON", nil)
                                     alternateButton:nil
                                         otherButton:nil
                           informativeTextWithFormat:@""];
      [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    }
  }
}

- (BOOL)burnProgressPanel:(DRBurnProgressPanel*)progressPanel burnDidFinish:(DRBurn*)burn {
  MP3Disc* disc = objc_getAssociatedObject(progressPanel, &_associatedKey);
  [self performSelector:@selector(_finishDisc:) withObject:disc afterDelay:0.0];
  objc_setAssociatedObject(progressPanel, &_associatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return YES;
}

- (void)_spaceAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSOKButton) {
    [alert.window orderOut:nil];
    [self _burnDisc:disc force:YES];
  }
  CFRelease((__bridge CFTypeRef)disc);
}

- (void)_burnDisc:(MP3Disc*)disc force:(BOOL)force {
  NSDictionary* deviceStatus = [[disc.burn device] status];
  uint64_t availableFreeSectors = [[[deviceStatus valueForKey:DRDeviceMediaInfoKey] valueForKey:DRDeviceMediaFreeSpaceKey] longLongValue];
  uint64_t availableFreeBytes = availableFreeSectors * kSectorSize;
  while (1) {
    DRFolder* rootFolder = [DRFolder virtualFolderWithName:disc.name];
    uint64_t estimatedTrackLengthInBytes = 0;
    NSUInteger index = 0;
    for (Track* track in [disc.tracks subarrayWithRange:disc.trackRange]) {
      DRFile* file = [DRFile fileWithPath:track.transcodedPath];
      [file setBaseName:[NSString stringWithFormat:@"%03lu - %@.mp3", index + 1, track.title]];
      [rootFolder addChild:file];
      if (force) {
        estimatedTrackLengthInBytes += track.transcodedSize;
        if (estimatedTrackLengthInBytes >= availableFreeBytes) {
          disc.trackRange = NSMakeRange(disc.trackRange.location, index - disc.trackRange.location);
          break;
        }
      }
      index += 1;
    }
    DRTrack* track = [DRTrack trackForRootFolder:rootFolder];
    uint64_t trackLengthInSectors = [track estimateLength];
    if (trackLengthInSectors < availableFreeSectors) {
#ifndef NDEBUG
      NSLog(@"Burning tracks %lu-%lu out of %lu from playlist \"%@\"", disc.trackRange.location + 1, disc.trackRange.location + disc.trackRange.length, disc.tracks.count, disc.name);
#endif
      DRBurnProgressPanel* progressPanel = [DRBurnProgressPanel progressPanel];
      progressPanel.delegate = self;
      [progressPanel beginProgressSheetForBurn:disc.burn layout:track modalForWindow:_mainWindow];
      objc_setAssociatedObject(progressPanel, &_associatedKey, disc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      break;
    }
    if (force) {
      NSUInteger length = disc.trackRange.length;
      if (length > 0) {
        disc.trackRange = NSMakeRange(disc.trackRange.location, length - 1);
      } else {
        break;  // Should never happen
      }
    } else {
      NSString* trackString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(trackLengthInSectors * kSectorSize / (1000 * 1000))]];  // Display MB not MiB like in Finder
      NSString* availableString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(availableFreeSectors * kSectorSize / (1000 * 1000))]];  // Display MB not MiB like in Finder
      NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_SPACE_TITLE", nil)
                                       defaultButton:NSLocalizedString(@"ALERT_SPACE_DEFAULT_BUTTON", nil)
                                     alternateButton:NSLocalizedString(@"ALERT_SPACE_ALTERNATE_BUTTON", nil)
                                         otherButton:nil
                           informativeTextWithFormat:NSLocalizedString(@"ALERT_SPACE_MESSAGE", nil), trackString, availableString];
      alert.alertStyle = NSCriticalAlertStyle;
      [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_spaceAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
      break;
    }
  }
}

- (void)_burnSetupPanelDidEnd:(DRSetupPanel*)panel returnCode:(int)returnCode contextInfo:(void*)contextInfo {
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSOKButton) {
    [panel orderOut:nil];
    disc.burn = [(DRBurnSetupPanel*)panel burnObject];
    [self _burnDisc:disc force:(disc.trackRange.location > 0 ? YES : NO)];
  }
  CFRelease((__bridge CFTypeRef)disc);
}

- (void)_prepareDisc:(MP3Disc*)disc {
  DRBurnSetupPanel* setupPanel = [DRBurnSetupPanel setupPanel];
#ifndef NDEBUG
  [setupPanel setCanSelectTestBurn:YES];
#endif
  [setupPanel beginSetupSheetForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_burnSetupPanelDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
}

- (void)_missingAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSOKButton) {
    [alert.window orderOut:nil];
    [self _prepareDisc:disc];
  }
  CFRelease((__bridge CFTypeRef)disc);
}

- (void)_prepareDiscWithName:(NSString*)name tracks:(NSArray*)tracks {
  _cancelled = NO;
  BitRate bitRate = [[NSUserDefaults standardUserDefaults] integerForKey:kUserDefaultKey_BitRate];
  self.transcoding = YES;
  if ([[NSUserDefaults standardUserDefaults] boolForKey:kUserDefaultKey_SkipMPEG]) {
    for (Track* track in tracks) {
      if ((track.kind == kTrackKind_MPEG) && !track.transcodedPath) {
        track.level = 100.0;
        track.transcodedPath = [track.location path];
        track.transcodedSize = _GetFileSize(track.transcodedPath);  // TODO: Could we trust iTunes metadata?
        track.transcodingError = nil;
      }
    }
    [_tableView reloadData];  // TODO: Works around NSTableView not refreshing properly depending on scrolling position
  }
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @autoreleasepool {
      NSMutableSet* processedTracks = [NSMutableSet set];
      for (Track* track in tracks) {
        if (_cancelled) {
          break;
        }
        if (!track.transcodedPath && ![processedTracks containsObject:track]) {
          [processedTracks addObject:track];
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
                  track.transcodedSize = _GetFileSize(outPath);
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
          NSMutableArray* transcodedTracks = [NSMutableArray array];
          for (Track* track in tracks) {
            if (track.transcodedPath) {
              [transcodedTracks addObject:track];
            }
          }
          if (transcodedTracks.count == 0) {
            NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_EMPTY_TITLE", nil)
                                             defaultButton:NSLocalizedString(@"ALERT_EMPTY_DEFAULT_BUTTON", nil)
                                           alternateButton:nil
                                               otherButton:nil
                                 informativeTextWithFormat:NSLocalizedString(@"ALERT_EMPTY_MESSAGE", nil)];
            alert.alertStyle = NSCriticalAlertStyle;
            [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
          } else {
            MP3Disc* disc = [[MP3Disc alloc] init];
            disc.name = name;
            disc.tracks = transcodedTracks;
            disc.trackRange = NSMakeRange(0, transcodedTracks.count);
            if (transcodedTracks.count < tracks.count) {
              NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_MISSING_TITLE", nil)
                                               defaultButton:NSLocalizedString(@"ALERT_MISSING_DEFAULT_BUTTON", nil)
                                             alternateButton:NSLocalizedString(@"ALERT_MISSING_ALTERNATE_BUTTON", nil)
                                                 otherButton:nil
                                   informativeTextWithFormat:NSLocalizedString(@"ALERT_MISSING_MESSAGE", nil), (int)(tracks.count - transcodedTracks.count), (int)tracks.count];
              [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_missingAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
            } else {
              [self _prepareDisc:disc];
            }
          }
        }
      });
    }
  });
}

- (IBAction)make:(id)sender {
  Playlist* playlist = [_arrayController.selectedObjects firstObject];
  [self _prepareDiscWithName:playlist.name tracks:playlist.tracks];
}

- (IBAction)cancelTranscoding:(id)sender {
  _cancelled = YES;
}

@end
