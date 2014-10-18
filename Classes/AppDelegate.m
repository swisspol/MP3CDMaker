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

#import <Crashlytics/Crashlytics.h>

#import "AppDelegate.h"
#import "ITunesLibrary.h"
#import "MP3Transcoder.h"
#import "MixpanelTracker.h"
#if DEBUG
#import "XLAppKitOverlayLogger.h"
#endif

#define kUserDefaultKey_LibraryPath @"libraryPath"
#define kUserDefaultKey_BitRate @"bitRate"
#define kUserDefaultKey_SkipMPEG @"skipMPEG"
#define kUserDefaultKey_ProductPrice @"productPrice"

#define kLimitedModeMaxTracks 50
#define kInAppProductIdentifier @"mp3_cd_maker_unlimited"

#define kDiscSectorSize 2048

@interface MP3Disc : NSObject
@property(nonatomic, retain) NSString* name;
@property(nonatomic, retain) NSArray* tracks;
@property(nonatomic) NSRange trackRange;
@property(nonatomic, retain) DRBurn* burn;
@end

static const char _associatedKey;

static BOOL _CanAccessFile(NSString* path, NSError** error) {
  int fd = open([path fileSystemRepresentation], O_RDONLY);
  if (fd <= 0) {
    NSDictionary* info = @{
                           NSLocalizedDescriptionKey: [NSString stringWithUTF8String:strerror(errno)]
                           };
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:info];
    return NO;
  }
  close(fd);
  return YES;
}

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
#if DEBUG
  if (getenv("resetDefaults")) {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
#endif
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
  NSArray* tracks = _trackController.selectedObjects;
  NSString* format = NSLocalizedString(@"PLAYLIST_INFO_SELECTED", nil);
  if (!tracks.count) {
    tracks = _trackController.arrangedObjects;
    format = NSLocalizedString(@"PLAYLIST_INFO_ALL", nil);
  }
  for (Track* track in tracks) {
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
  NSString* countString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:tracks.count]];
  NSString* sizeString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(size / (1000 * 1000))]];  // Display MB not MiB like in Finder
  NSString* timeString = hours > 0 ? [NSString stringWithFormat:@"%lu:%02lu:%02lu", hours, minutes, seconds] : [NSString stringWithFormat:@"%lu:%02lu", minutes, seconds];
  [_infoTextField setStringValue:[NSString stringWithFormat:format, countString, timeString, sizeString]];
}

- (BOOL)_saveBookmark:(NSString*)defaultKey withURL:(NSURL*)url {
  NSError* error = nil;
  NSData* data = [url bookmarkDataWithOptions:(NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess) includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
  if (data) {
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:defaultKey];
    return YES;
  }
  XLOG_ERROR(@"Failed saving bookmark: %@", error);
  return NO;
}

- (NSString*)_loadBookmark:(NSString*)defaultKey {
  NSData* data = [[NSUserDefaults standardUserDefaults] objectForKey:defaultKey];
  if (data) {
    BOOL isStale;
    NSError* error = nil;
    NSURL* url = [NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
    if (url) {
      if ([url startAccessingSecurityScopedResource]) {
#if 0  // TODO: This doesn't work on 10.9.1: re-saving a staled bookmark will be prevent it to be saved again if becoming staled again
        if (!isStale || [self _saveBookmark:defaultKey withURL:url]) {
          return url.path;
        }
#else
        return url.path;
#endif
      } else {
        XLOG_ERROR(@"Failed accessing bookmark");
      }
    } else {
      XLOG_ERROR(@"Failed resolving bookmark: %@", error);
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:defaultKey];
  }
  return nil;
}

// Under App Sandbox, the "com.apple.security.assets.music.read-only" entitlement gives access to the entire content of "~/Music"
// EXCEPT for anything inside "~/Music/iTunes Music/" and anything inside "~/iTunes/iTunes Media/"
// HOWEVER the specific subdirectories "~/iTunes/iTunes Music/Music/" and "~/iTunes/iTunes Media/Music/" are accessible
// ("iTunes Music" was the name used by iTunes 8 or earlier)
// This creates a number of problems:
// - It doesn't handle old iTunes library which may have their music at the top level of the media folder
// - It doesn't handle the case of the user having relocated the iTunes library
// - Podcasts cannot be accessed since they are in "~/iTunes/iTunes Media/Music/Podcasts/"
// In conclusion, it doesn't really make sense to use the "com.apple.security.assets.music.read-only" entitlement
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
#if DEBUG
  [XLSharedFacility addLogger:[XLAppKitOverlayLogger sharedLogger]];
#endif
  
#if !DEBUG
  [Crashlytics startWithAPIKey:@"936a419a4a141683e2eb17db02a13b72ee02b362"];
#endif
  
  [[InAppStore sharedStore] setDelegate:self];
  
#if !DEBUG
  [MixpanelTracker startWithToken:@"71588ec5096841ed7cf8ac7960ef2a4b"];
#else
  [MixpanelTracker startWithToken:@"0be0a548637919d5b1579a67b8bad560"];
#endif
  
  NSError* error = nil;
  NSArray* playlists = nil;
  NSString* libraryPath = [self _loadBookmark:kUserDefaultKey_LibraryPath];
  NSURL* libraryURL = nil;
  while (1) {
    if (libraryPath == nil) {
      MIXPANEL_TRACK_EVENT(@"Select Library", nil);
      NSOpenPanel* openPanel = [NSOpenPanel openPanel];
      openPanel.canChooseFiles = NO;
      openPanel.canChooseDirectories = YES;
      openPanel.prompt = NSLocalizedString(@"LIBRARY_SELECT_BUTTON", nil);
      openPanel.title = NSLocalizedString(@"LIBRARY_SELECT_TITLE", nil);
      openPanel.accessoryView = _accessoryView;
      if (libraryURL == nil) {
        openPanel.directoryURL = [NSURL fileURLWithPath:[ITunesLibrary libraryDefaultPath] isDirectory:YES];
      }
      if ([openPanel runModal] == NSFileHandlingPanelOKButton) {
        libraryURL = [openPanel URL];
        libraryPath = libraryURL.path;
      }
    }
    
    if (libraryPath) {
      playlists = [[ITunesLibrary sharedLibrary] loadPlaylistsFromLibraryAtPath:libraryPath error:&error];
      if (playlists) {
        if (libraryURL) {
          [self _saveBookmark:kUserDefaultKey_LibraryPath withURL:libraryURL];
        }
        break;
      }
    }
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_NO_LIBRARY_TITLE", nil)
                                     defaultButton:NSLocalizedString(@"ALERT_NO_LIBRARY_DEFAULT_BUTTON", nil)
                                   alternateButton:NSLocalizedString(@"ALERT_NO_ALTERNATE_BUTTON", nil)
                                       otherButton:nil
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_NO_LIBRARY_MESSAGE", nil), error.localizedDescription];
    alert.alertStyle = NSCriticalAlertStyle;
    if ([alert runModal] == NSAlertAlternateReturn) {
      [NSApp terminate:nil];
    }
    libraryPath = nil;
  }
  MIXPANEL_TRACK_EVENT(@"Load Playlists", nil);
  [_playlistController setContent:playlists];
  [self _updateInfo];
  
  [_mainWindow makeKeyAndOrderFront:nil];
}

- (void)_quitAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  [NSApp replyToApplicationShouldTerminate:(returnCode == NSAlertDefaultReturn ? YES : NO)];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
  if ([[InAppStore sharedStore] isPurchasing] || [[InAppStore sharedStore] isRestoring]) {
    return NSTerminateCancel;
  }
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

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
  [self _updateInfo];
}

- (NSString*)tableView:(NSTableView*)tableView toolTipForCell:(NSCell*)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
  if ([tableColumn.identifier isEqualToString:@"conversion"]) {
    Track* track = [_trackController.arrangedObjects objectAtIndex:row];
    if (track.transcodingError) {
      return [NSString stringWithFormat:NSLocalizedString(@"TOOLTIP_ERROR", nil), track.transcodingError.localizedDescription, track.transcodingError.localizedFailureReason];
    }
  }
  return nil;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
  return [NSNumber numberWithInteger:(row + 1)];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
  if ((menuItem.action == @selector(purchaseFeature:)) || (menuItem.action == @selector(restorePurchases:))) {
    return ![[InAppStore sharedStore] hasPurchasedProductWithIdentifier:kInAppProductIdentifier] && ![[InAppStore sharedStore] isPurchasing] && ![[InAppStore sharedStore] isRestoring];
  }
  return YES;
}

- (void)inAppStore:(InAppStore*)store didFindProductWithIdentifier:(NSString*)identifier price:(NSDecimalNumber*)price currencyLocale:(NSLocale*)locale {
  [[NSUserDefaults standardUserDefaults] setObject:price forKey:kUserDefaultKey_ProductPrice];
}

- (void)inAppStore:(InAppStore*)store didPurchaseProductWithIdentifier:(NSString*)identifier {
  MIXPANEL_TRACK_EVENT(@"Finish Purchase", nil);
  MIXPANEL_TRACK_PURCHASE([[NSUserDefaults standardUserDefaults] floatForKey:kUserDefaultKey_ProductPrice], nil);
  if ([[InAppStore sharedStore] isPurchasing]) {
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_PURCHASE_TITLE", nil)
                                     defaultButton:NSLocalizedString(@"ALERT_PURCHASE_DEFAULT_BUTTON", nil)
                                   alternateButton:nil
                                       otherButton:nil
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_PURCHASE_MESSAGE", nil), (int)kLimitedModeMaxTracks];
    [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
  }
}

- (void)inAppStoreDidCancelPurchase:(InAppStore*)store {
  MIXPANEL_TRACK_EVENT(@"Cancel Purchase", nil);
}

- (void)inAppStore:(InAppStore*)store didRestoreProductWithIdentifier:(NSString*)identifier {
  MIXPANEL_TRACK_EVENT(@"Finish Restore", nil);
  if ([identifier isEqualToString:kInAppProductIdentifier] && [[InAppStore sharedStore] isRestoring]) {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_RESTORE_TITLE", nil)
                                     defaultButton:NSLocalizedString(@"ALERT_RESTORE_DEFAULT_BUTTON", nil)
                                   alternateButton:nil
                                       otherButton:nil
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_RESTORE_MESSAGE", nil), (int)kLimitedModeMaxTracks];
    [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
  }
}

- (void)inAppStoreDidCancelRestore:(InAppStore*)store {
  MIXPANEL_TRACK_EVENT(@"Cancel Restore", nil);
}

- (void)_reportIAPError:(NSError*)error {
  MIXPANEL_TRACK_EVENT(@"IAP Error", @{@"Description": error.localizedDescription ? error.localizedDescription : @""});
  [NSApp activateIgnoringOtherApps:YES];
  NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_IAP_FAILED_TITLE", nil)
                                   defaultButton:NSLocalizedString(@"ALERT_IAP_FAILED_BUTTON", nil)
                                 alternateButton:nil
                                     otherButton:nil
                       informativeTextWithFormat:NSLocalizedString(@"ALERT_IAP_FAILED_MESSAGE", nil), error.localizedDescription];
  [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
}

- (void)inAppStore:(InAppStore*)store didFailFindingProductWithIdentifier:(NSString*)identifier {
  [self _reportIAPError:nil];
}

- (void)inAppStore:(InAppStore*)store didFailPurchasingProductWithIdentifier:(NSString*)identifier error:(NSError*)error {
  [self _reportIAPError:error];
}

- (void)inAppStore:(InAppStore*)store didFailRestoreWithError:(NSError*)error {
  [self _reportIAPError:error];
}

@end

@implementation AppDelegate (Actions)

- (IBAction)updatePlaylist:(id)sender {
  [self _updateInfo];
}

- (IBAction)updateQuality:(id)sender {
  [self _updateInfo];
  
  [self _clearCache];
  for (Playlist* playlist in _playlistController.arrangedObjects) {
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
  
  for (Playlist* playlist in _playlistController.arrangedObjects) {
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
  MIXPANEL_TRACK_EVENT(@"Prompt Continue", @{@"Choice": [NSNumber numberWithInteger:returnCode]});
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSAlertDefaultReturn) {
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
      MIXPANEL_TRACK_EVENT(@"Burn Error", @{@"Description": [error objectForKey:DRErrorStatusErrorStringKey]});
      NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_BURN_FAILED_TITLE", nil)
                                       defaultButton:NSLocalizedString(@"ALERT_BURN_FAILED_DEFAULT_BUTTON", nil)
                                     alternateButton:NSLocalizedString(@"ALERT_BURN_FAILED_ALTERNATE_BUTTON", nil)
                                         otherButton:nil
                           informativeTextWithFormat:@"%@", [error objectForKey:DRErrorStatusErrorStringKey]];
      [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_continueAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
    } else {
      MIXPANEL_TRACK_EVENT(@"Cancel Burn", nil);
    }
  } else {
    MIXPANEL_TRACK_EVENT(@"Finish Burn", nil);
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
  MIXPANEL_TRACK_EVENT(@"Prompt Space", @{@"Choice": [NSNumber numberWithInteger:returnCode]});
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSAlertDefaultReturn) {
    [alert.window orderOut:nil];
    [self _burnDisc:disc force:YES];
  }
  CFRelease((__bridge CFTypeRef)disc);
}

- (void)_burnDisc:(MP3Disc*)disc force:(BOOL)force {
  NSDictionary* deviceStatus = [[disc.burn device] status];
  uint64_t availableFreeSectors = [[[deviceStatus valueForKey:DRDeviceMediaInfoKey] valueForKey:DRDeviceMediaFreeSpaceKey] longLongValue];
  uint64_t availableFreeBytes = availableFreeSectors * kDiscSectorSize;
  while (1) {
    DRFolder* rootFolder = [DRFolder virtualFolderWithName:disc.name];
    uint64_t estimatedTrackLengthInBytes = 0;
    NSUInteger index = 0;
    NSUInteger count = disc.trackRange.length;
    for (Track* track in [disc.tracks subarrayWithRange:disc.trackRange]) {
      DRFile* file = [DRFile fileWithPath:track.transcodedPath];
      if (count >= 100) {
        [file setBaseName:[NSString stringWithFormat:@"%03lu - %@.mp3", index + 1, track.title]];
      } else if (count >= 10) {
        [file setBaseName:[NSString stringWithFormat:@"%02lu - %@.mp3", index + 1, track.title]];
      } else {
        [file setBaseName:[NSString stringWithFormat:@"%lu - %@.mp3", index + 1, track.title]];
      }
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
      MIXPANEL_TRACK_EVENT(@"Perform Burn", @{
                                               @"Start Track": [NSNumber numberWithInteger:(disc.trackRange.location + 1)],
                                               @"End Track": [NSNumber numberWithInteger:(disc.trackRange.location + disc.trackRange.length)],
                                               @"Total Tracks": [NSNumber numberWithInteger:disc.tracks.count]
                                               });
      XLOG_VERBOSE(@"Burning tracks %lu-%lu out of %lu from playlist \"%@\"", disc.trackRange.location + 1, disc.trackRange.location + disc.trackRange.length, disc.tracks.count, disc.name);
      for (DRFile* file in rootFolder.children) {
        XLOG_VERBOSE(@"  %@", file.baseName);
      }
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
      NSString* trackString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(trackLengthInSectors * kDiscSectorSize / (1000 * 1000))]];  // Display MB not MiB like in Finder
      NSString* availableString = [_numberFormatter stringFromNumber:[NSNumber numberWithUnsignedInteger:(availableFreeSectors * kDiscSectorSize / (1000 * 1000))]];  // Display MB not MiB like in Finder
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
  MIXPANEL_TRACK_EVENT(@"Prompt Setup", @{@"Choice": [NSNumber numberWithInteger:returnCode]});
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSAlertDefaultReturn) {
    [panel orderOut:nil];
    disc.burn = [(DRBurnSetupPanel*)panel burnObject];
    [self _burnDisc:disc force:(disc.trackRange.location > 0 ? YES : NO)];
  }
  CFRelease((__bridge CFTypeRef)disc);
}

- (void)_prepareDisc:(MP3Disc*)disc {
  DRBurnSetupPanel* setupPanel = [DRBurnSetupPanel setupPanel];
#if DEBUG
  [setupPanel setCanSelectTestBurn:YES];
#endif
  [setupPanel beginSetupSheetForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_burnSetupPanelDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(disc)];
}

- (void)_missingAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  MIXPANEL_TRACK_EVENT(@"Prompt Missing", @{@"Choice": [NSNumber numberWithInteger:returnCode]});
  MP3Disc* disc = (__bridge MP3Disc*)contextInfo;
  if (returnCode == NSAlertDefaultReturn) {
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
        NSError* error = nil;
        if (_CanAccessFile(track.path, &error)) {
          track.level = 100.0;
          track.transcodedPath = track.path;
          track.transcodedSize = _GetFileSize(track.transcodedPath);
          track.transcodingError = nil;
        } else {
          track.level = 0.0;
          track.transcodingError = error;
        }
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
              NSString* inPath = track.path;
              NSString* outPath = [_cachePath stringByAppendingPathComponent:[[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingPathExtension:@"mp3"]];
              NSError* error = nil;
              BOOL success = [[MP3Transcoder sharedTranscoder] transcodeAudioFileAtPath:inPath
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
          if (transcodedTracks.count < tracks.count) {
            MIXPANEL_TRACK_EVENT(@"Fail Transcoding", @{@"In": [NSNumber numberWithInteger:tracks.count], @"Out": [NSNumber numberWithInteger:transcodedTracks.count]});
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

- (void)_burnTracks:(NSArray*)tracks {
  Playlist* playlist = [_playlistController.selectedObjects firstObject];
  [self _prepareDiscWithName:playlist.name tracks:tracks];
}

- (void)_purchaseAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo {
  MIXPANEL_TRACK_EVENT(@"Prompt Purchase", @{@"Choice": [NSNumber numberWithInteger:returnCode]});
  NSArray* tracks = (__bridge NSArray*)contextInfo;
  if (returnCode == NSAlertDefaultReturn) {
    [alert.window orderOut:nil];
    [self _burnTracks:tracks];
  } else if (returnCode == NSAlertAlternateReturn) {
    [self purchaseFeature:nil];
  }
  CFRelease((__bridge CFTypeRef)tracks);
}

- (IBAction)burnDisc:(id)sender {
  NSArray* tracks = _trackController.selectedObjects;
  if (!tracks.count) {
    tracks = _trackController.arrangedObjects;
  }
  MIXPANEL_TRACK_EVENT(@"Start Burn", @{
                                     @"Tracks": [NSNumber numberWithInteger:tracks.count],
                                     @"Bit Rate": [NSNumber numberWithInteger:KBitsPerSecondFromBitRate([[NSUserDefaults standardUserDefaults] integerForKey:kUserDefaultKey_BitRate], true)],
                                     @"VBR": [NSNumber numberWithBool:BitRateIsVBR([[NSUserDefaults standardUserDefaults] integerForKey:kUserDefaultKey_BitRate])],
                                     @"Skip MPEG": [NSNumber numberWithBool:[[NSUserDefaults standardUserDefaults] boolForKey:kUserDefaultKey_SkipMPEG]]
                                     });
  if ((tracks.count <= kLimitedModeMaxTracks) || [[InAppStore sharedStore] hasPurchasedProductWithIdentifier:kInAppProductIdentifier]) {
    [self _burnTracks:tracks];
  } else {
    tracks = [tracks subarrayWithRange:NSMakeRange(0, kLimitedModeMaxTracks)];
    NSAlert* alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"ALERT_LIMITED_TITLE", nil), (int)kLimitedModeMaxTracks]
                                     defaultButton:NSLocalizedString(@"ALERT_LIMITED_DEFAULT_BUTTON", nil)
                                   alternateButton:NSLocalizedString(@"ALERT_LIMITED_ALTERNATE_BUTTON", nil)
                                       otherButton:NSLocalizedString(@"ALERT_LIMITED_OTHER_BUTTON", nil)
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_LIMITED_MESSAGE", nil), (int)kLimitedModeMaxTracks, (int)kLimitedModeMaxTracks];
    [alert beginSheetModalForWindow:_mainWindow modalDelegate:self didEndSelector:@selector(_purchaseAlertDidEnd:returnCode:contextInfo:) contextInfo:(void*)CFBridgingRetain(tracks)];
  }
}

- (IBAction)cancelTranscoding:(id)sender {
  MIXPANEL_TRACK_EVENT(@"Cancel Transcoding", nil);
  _cancelled = YES;
}

- (IBAction)purchaseFeature:(id)sender {
  if ([[InAppStore sharedStore] purchaseProductWithIdentifier:kInAppProductIdentifier]) {
    MIXPANEL_TRACK_EVENT(@"Start Purchase", nil);
  } else {
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_UNAVAILABLE_TITLE", nil)
                                     defaultButton:NSLocalizedString(@"ALERT_UNAVAILABLE_DEFAULT_BUTTON", nil)
                                   alternateButton:nil
                                       otherButton:nil
                         informativeTextWithFormat:NSLocalizedString(@"ALERT_UNAVAILABLE_MESSAGE", nil)];
    [alert beginSheetModalForWindow:_mainWindow modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
  }
}

- (IBAction)restorePurchases:(id)sender {
  MIXPANEL_TRACK_EVENT(@"Restore Purchase", nil);
  [[InAppStore sharedStore] restorePurchases];
}

@end
