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

#import <Foundation/Foundation.h>

typedef enum {
  kTrackKind_Unknown = 0,
  kTrackKind_MPEG,
  kTrackKind_AAC,
  kTrackKind_AIFF,
  kTrackKind_WAV
} TrackKind;

@interface Playlist : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, retain) NSArray* tracks;
@end

@interface Track : NSObject
@property(nonatomic, copy) NSString* persistentID;
@property(nonatomic, retain) NSString* path;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* album;
@property(nonatomic, copy) NSString* artist;
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) TrackKind kind;
@property(nonatomic) NSUInteger size;
@end

@interface Track ()
@property(nonatomic) double level;
@property(nonatomic, copy) NSString* transcodedPath;
@property(nonatomic) NSUInteger transcodedSize;
@property(nonatomic, copy) NSError* transcodingError;
@end

@interface ITunesLibrary : NSObject
+ (ITunesLibrary*)sharedLibrary;
+ (NSString*)libraryDefaultPath;
- (NSArray*)loadPlaylistsFromLibraryAtPath:(NSString*)path error:(NSError**)error;
@end
