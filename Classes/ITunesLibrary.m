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

#import <iTunesLibrary/ITLibrary.h>
#import <iTunesLibrary/ITLibPlaylist.h>
#import <iTunesLibrary/ITLibMediaItem.h>
#import <iTunesLibrary/ITLibAlbum.h>
#import <iTunesLibrary/ITLibArtist.h>

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

@implementation ITunesLibrary

// TODO: Sandbox entitlement bug may prevent accessing iTunes media folder (http://www.cocoabuilder.com/archive/cocoa/312617-music-read-only-sandbox-entitlement-doesn-seem-to-work.html)
+ (NSArray*)loadPlaylists {
  NSMutableDictionary* cache = [[NSMutableDictionary alloc] init];
  NSMutableArray* array = nil;
  if (NSClassFromString(@"ITLibrary")) {
    NSError* error = nil;
    ITLibrary* library = [ITLibrary libraryWithAPIVersion:@"1.0" error:&error];  // TODO: This leaks thousands of objects as of iTunes 11.1.4
    if (library) {
      array = [[NSMutableArray alloc] init];
      for (ITLibPlaylist* libraryPlaylist in library.allPlaylists) {
        if ((libraryPlaylist.distinguishedKind != ITLibDistinguishedPlaylistKindNone) || libraryPlaylist.master) {
          continue;
        }
        Playlist* playlist = [[Playlist alloc] init];
        playlist.name = libraryPlaylist.name;
        NSMutableArray* tracks = [[NSMutableArray alloc] init];
        for (ITLibMediaItem* libraryItem in libraryPlaylist.items) {
          TrackKind kind = _TrackKindFromString(libraryItem.kind);
          if ((kind == kTrackKind_Unknown) || libraryItem.drmProtected) {
            continue;
          }
          NSURL* location = libraryItem.location;
          if (![location isFileURL]) {
            continue;
          }
          NSString* persistentID = [NSString stringWithFormat:@"%016lX", [libraryItem.persistentID unsignedLongValue]];
          Track* track = [cache objectForKey:persistentID];
          if (track == nil) {
            track = [[Track alloc] init];
            track.persistentID = persistentID;
            track.location = location;
            track.title = libraryItem.title;
            track.album = libraryItem.album.title;
            track.artist = libraryItem.artist.name;
            track.duration = (NSTimeInterval)libraryItem.totalTime / 1000.0;
            track.kind = kind;
            [cache setObject:track forKey:persistentID];
          }
          [tracks addObject:track];
        }
        playlist.tracks = tracks;
        [array addObject:playlist];
      }
    } else {
      NSLog(@"Failed opening iTunes library: %@", error);
    }
  } else {
    NSLog(@"iTunesLibrary.framework not available: falling back to reading iTunes library XML file directly");
    NSString* musicPath = [NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES) firstObject];
    NSString* plistPath = [musicPath stringByAppendingPathComponent:@"iTunes/iTunes Music Library.xml"];
    NSError* error = nil;
    NSData* plistData = [NSData dataWithContentsOfFile:plistPath options:NSDataReadingMappedIfSafe error:&error];
    if (plistData) {
      NSDictionary* plist = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:NULL error:&error];
      if (plist) {
        array = [[NSMutableArray alloc] init];
        NSDictionary* plistTracks = [plist objectForKey:@"Tracks"];
        for (NSDictionary* plistPlaylist in [plist objectForKey:@"Playlists"]) {
          if ([[plistPlaylist objectForKey:@"Master"] boolValue] || [[plistPlaylist objectForKey:@"Music"] boolValue] || [[plistPlaylist objectForKey:@"Movies"] boolValue]
              || [[plistPlaylist objectForKey:@"TV Shows"] boolValue] || [[plistPlaylist objectForKey:@"Podcasts"] boolValue] || [[plistPlaylist objectForKey:@"Purchased Music"] boolValue]) {
            continue;
          }
          Playlist* playlist = [[Playlist alloc] init];
          playlist.name = [plistPlaylist objectForKey:@"Name"];
          NSMutableArray* tracks = [[NSMutableArray alloc] init];
          for (NSDictionary* item in [plistPlaylist objectForKey:@"Playlist Items"]) {
            NSString* trackID = [[item objectForKey:@"Track ID"] stringValue];
            NSDictionary* plistTrack = [plistTracks objectForKey:trackID];
            TrackKind kind = _TrackKindFromString([plistTrack objectForKey:@"Kind"]);
            if ((kind == kTrackKind_Unknown) || [[plistTrack objectForKey:@"Protected"] boolValue]) {
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
              [cache setObject:track forKey:persistentID];
            }
            [tracks addObject:track];
          }
          playlist.tracks = tracks;
          [array addObject:playlist];
        }
      } else {
        NSLog(@"Failed parsing iTunes library XML: %@", error);
      }
    } else {
      NSLog(@"Failed reading iTunes library XML: %@", error);
    }
  }
  [array sortUsingComparator:^NSComparisonResult(Playlist* playlist1, Playlist* playlist2) {
    return [playlist1.name localizedStandardCompare:playlist2.name];
  }];
  return array;
}

@end
