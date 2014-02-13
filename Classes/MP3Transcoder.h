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
  kBitRate_Default = 0,
  kBitRate_64Kbps_CBR,
  kBitRate_96Kbps_CBR,
  kBitRate_128Kbps_CBR,
  kBitRate_160Kbps_CBR,
  kBitRate_192Kbps_CBR,
  kBitRate_256Kbps_CBR,
  kBitRate_320Kbps_CBR,
  kBitRate_65Kbps_VBR,
  kBitRate_115Kbps_VBR,
  kBitRate_165Kbps_VBR,
  kBitRate_190Kbps_VBR,
  kBitRate_245Kbps_VBR
} BitRate;

@interface MP3Transcoder : NSObject
+ (BOOL)transcodeAudioFileAtPath:(NSString*)inPath toPath:(NSString*)outPath withBitRate:(BitRate)bitRate progressBlock:(void (^)(float progress, BOOL* stop))block;
@end
