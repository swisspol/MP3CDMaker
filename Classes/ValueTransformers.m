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

#import "ValueTransformers.h"
#import "ITunesLibrary.h"

@implementation DurationTransformer

+ (Class)transformedValueClass {
  return [NSString class];
}

+ (BOOL)allowsReverseTransformation {
  return NO;
}

- (id)transformedValue:(id)value {
  if (value) {
    NSTimeInterval duration = [value doubleValue];
    if (duration >= 3600.0) {
      return [NSString stringWithFormat:@"%.0f:%02.0f:%02.0f", duration / 3600.0, fmod(duration, 3600.0) / 60.0, fmod(fmod(duration, 3600.0), 60.0)];
    } else {
      return [NSString stringWithFormat:@"%.0f:%02.0f", duration / 60.0, fmod(duration, 60.0)];
    }
  }
  return nil;
}

@end

@implementation KindTransformer

+ (Class)transformedValueClass {
  return [NSString class];
}

+ (BOOL)allowsReverseTransformation {
  return NO;
}

- (id)transformedValue:(id)value {
  if (value) {
    TrackKind kind = [value intValue];
    switch (kind) {
      case kTrackKind_Unknown: return nil;
      case kTrackKind_MPEG: return @"MPEG";
      case kTrackKind_AAC: return @"AAC";
      case kTrackKind_AIFF: return @"AIFF";
      case kTrackKind_WAV: return @"WAV";
    }
  }
  return nil;
}

@end
