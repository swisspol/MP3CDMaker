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

#import "ITunesLibrary.h"

static TrackKind _TrackKindFromString(NSString* string) {
  if ([string hasSuffix:@"MPEG audio file"]) {
    return kTrackKind_MPEG;
  }
  if ([string hasSuffix:@"AAC audio file"]) {
    return kTrackKind_AAC;
  }
  if ([string hasSuffix:@"AIFF audio file"]) {
    return kTrackKind_AIFF;
  }
  if ([string hasSuffix:@"WAV audio file"]) {
    return kTrackKind_WAV;
  }
  return kTrackKind_Unknown;
}

@implementation Playlist
@end

@implementation Track
@end

// TODO: Sandbox entitlement bug may prevent accessing iTunes media folder (radr://15266641)
// http://www.cocoabuilder.com/archive/cocoa/312617-music-read-only-sandbox-entitlement-doesn-seem-to-work.html
@implementation ITunesLibrary

+ (ITunesLibrary*)sharedLibrary {
  static ITunesLibrary* library = nil;
  static dispatch_once_t token = 0;
  dispatch_once(&token, ^{
    library = [[ITunesLibrary alloc] init];
  });
  return library;
}

- (NSArray*)loadPlaylistsFromLibraryAtDefaultPath:(NSError**)error {
  NSString* defaultPath = [@"~/Music/iTunes" stringByStandardizingPath];
  return [self loadPlaylistsFromLibraryAtPath:defaultPath error:error];
}

- (NSArray*)loadPlaylistsFromLibraryAtPath:(NSString*)path error:(NSError**)error {
  NSMutableDictionary* cache = [[NSMutableDictionary alloc] init];
  NSMutableArray* array = nil;
  NSString* plistPath = [path stringByAppendingPathComponent:@"iTunes Music Library.xml"];
  NSData* plistData = [NSData dataWithContentsOfFile:plistPath options:NSDataReadingMappedIfSafe error:error];
  if (plistData) {
    NSDictionary* plist = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:NULL error:error];
    if (plist) {
      NSURL* musicURL = [NSURL URLWithString:[plist objectForKey:@"Music Folder"]];
      if ([[NSFileManager defaultManager] contentsOfDirectoryAtPath:musicURL.path error:error]) {  // Ensure the media directory is accessible to the app sandbox
        array = [[NSMutableArray alloc] init];
        NSDictionary* plistTracks = [plist objectForKey:@"Tracks"];
        for (NSDictionary* plistPlaylist in [plist objectForKey:@"Playlists"]) {
          if ([[plistPlaylist objectForKey:@"Master"] boolValue]
              || [[plistPlaylist objectForKey:@"Music"] boolValue]
              || [[plistPlaylist objectForKey:@"Movies"] boolValue]
              || [[plistPlaylist objectForKey:@"TV Shows"] boolValue]
              || [[plistPlaylist objectForKey:@"iTunes U"] boolValue]  // TODO: Is this the right string?
              || [[plistPlaylist objectForKey:@"Purchases"] boolValue]  // TODO: Is this the right string?
              || [[plistPlaylist objectForKey:@"Home Videos"] boolValue]  // TODO: Is this the right string?
              || [[plistPlaylist objectForKey:@"Music Videos"] boolValue]  // TODO: Is this the right string?
              || [[plistPlaylist objectForKey:@"Library Music Videos"] boolValue]) {  // TODO: Is this the right string?
            continue;
          }
          Playlist* playlist = [[Playlist alloc] init];
          playlist.name = [plistPlaylist objectForKey:@"Name"];
          NSMutableArray* tracks = [[NSMutableArray alloc] init];
          for (NSDictionary* item in [plistPlaylist objectForKey:@"Playlist Items"]) {
            NSString* trackID = [[item objectForKey:@"Track ID"] stringValue];
            NSDictionary* plistTrack = [plistTracks objectForKey:trackID];
            TrackKind kind = _TrackKindFromString([plistTrack objectForKey:@"Kind"]);
            if ((kind == kTrackKind_Unknown) || [[plistTrack objectForKey:@"Disabled"] boolValue] || [[plistTrack objectForKey:@"Protected"] boolValue]) {
              continue;
            }
            NSURL* location = [NSURL URLWithString:[plistTrack objectForKey:@"Location"]];
            if (![location isFileURL]) {
              continue;
            }
            NSString* persistentID = [plistTrack objectForKey:@"Persistent ID"];
            Track* track = [cache objectForKey:persistentID];
            if (track == nil) {
              track = [[Track alloc] init];
              track.persistentID = persistentID;
              track.location = location;
              track.title = [plistTrack objectForKey:@"Name"];
              track.album = [plistTrack objectForKey:@"Album"];
              track.artist = [plistTrack objectForKey:@"Artist"];
              track.duration = (NSTimeInterval)[[plistTrack objectForKey:@"Total Time"] integerValue] / 1000.0;
              track.kind = kind;
              track.size = [[plistTrack objectForKey:@"Size"] integerValue];
              [cache setObject:track forKey:persistentID];
            }
            [tracks addObject:track];
          }
          playlist.tracks = tracks;
          [array addObject:playlist];
        }
        [array sortUsingComparator:^NSComparisonResult(Playlist* playlist1, Playlist* playlist2) {
          return [playlist1.name localizedStandardCompare:playlist2.name];
        }];
      }
    }
  }
  return array;
}

@end
