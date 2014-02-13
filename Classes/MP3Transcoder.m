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

#import <libavutil/opt.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libswresample/swresample.h>

#import "MP3Transcoder.h"

// http://www.ffmpeg.org/ffmpeg-formats.html#mp3
// http://www.ffmpeg.org/ffmpeg-codecs.html#Options-9
// http://trac.ffmpeg.org/wiki/Encoding%20VBR%20(Variable%20Bit%20Rate)%20mp3%20audio

// Must match BitRate enum
static int _monoBitRateLUT[][3] = {
  {0, 0, 0},
  {32 * 1000, 0, 0},
  {48 * 1000, 0, 0},
  {64 * 1000, 0, 0},
  {80 * 1000, 0, 0},
  {96 * 1000, 0, 0},
  {128 * 1000, 0, 0},
  {160 * 1000, 0, 0},
  {0, CODEC_FLAG_QSCALE, 9},
  {0, CODEC_FLAG_QSCALE, 9},
  {0, CODEC_FLAG_QSCALE, 8},
  {0, CODEC_FLAG_QSCALE, 7},
  {0, CODEC_FLAG_QSCALE, 5}
};

// Must match BitRate enum
static int _stereoBitRateLUT[][3] = {
  {0, 0, 0},
  {64 * 1000, 0, 0},
  {96 * 1000, 0, 0},
  {128 * 1000, 0, 0},
  {160 * 1000, 0, 0},
  {192 * 1000, 0, 0},
  {256 * 1000, 0, 0},
  {320 * 1000, 0, 0},
  {0, CODEC_FLAG_QSCALE, 9},
  {0, CODEC_FLAG_QSCALE, 6},
  {0, CODEC_FLAG_QSCALE, 4},
  {0, CODEC_FLAG_QSCALE, 2},
  {0, CODEC_FLAG_QSCALE, 0}
};

@implementation MP3Transcoder

+ (void)load {
  av_register_all();
  avcodec_register_all();
}

+ (BOOL)transcodeAudioFileAtPath:(NSString*)inPath toPath:(NSString*)outPath withBitRate:(BitRate)bitRate progressBlock:(void (^)(float progress, BOOL* stop))block {
  BOOL success = NO;
  BOOL stop = NO;
  AVFormatContext* inContext = NULL;
  int result = avformat_open_input(&inContext, [inPath fileSystemRepresentation], NULL, NULL);
  if (result == 0) {
    result = avformat_find_stream_info(inContext, NULL);
    if (result >= 0) {
      BOOL foundAudioStream = NO;
      for (int i = 0; i < inContext->nb_streams; ++i) {
        if (inContext->streams[i]->codec->codec_type == AVMEDIA_TYPE_AUDIO) {
          AVStream* inStream = inContext->streams[i];
          AVCodecContext* inCodecContext = inStream->codec;
          AVCodec* inCodec = avcodec_find_decoder(inCodecContext->codec_id);
          if (inCodec) {
            result = avcodec_open2(inCodecContext, inCodec, NULL);
            if (result == 0) {
              
              AVFormatContext* outContext = NULL;
              result = avformat_alloc_output_context2(&outContext, NULL, "mp3", NULL);
              if (result >= 0) {
                av_dict_copy(&outContext->metadata, inContext->metadata, 0);
                av_dict_set(&outContext->metadata, "major_brand", NULL, 0);  // Strip iTMS metadata from purchased AACs
                av_dict_set(&outContext->metadata, "compatible_brands", NULL, 0);  // Strip iTMS metadata from purchased AACs
                av_dict_set(&outContext->metadata, "minor_version", NULL, 0);  // Strip iTMS metadata from purchased AACs
                AVCodec* outCodec = avcodec_find_encoder(outContext->oformat->audio_codec);
                if (outCodec) {
                  AVStream* outStream = avformat_new_stream(outContext, outCodec);
                  AVCodecContext* outCodecContext = outStream->codec;
                  if (inCodecContext->channels == 1) {
                    outCodecContext->bit_rate = _monoBitRateLUT[bitRate][0];
                    outCodecContext->flags = _monoBitRateLUT[bitRate][1];
                    outCodecContext->global_quality = _monoBitRateLUT[bitRate][2] * FF_QUALITY_SCALE;
                  } else {
                    outCodecContext->bit_rate = _stereoBitRateLUT[bitRate][0];
                    outCodecContext->flags = _stereoBitRateLUT[bitRate][1];
                    outCodecContext->global_quality = _stereoBitRateLUT[bitRate][2] * FF_QUALITY_SCALE;
                  }
                  outCodecContext->compression_level = FF_COMPRESSION_DEFAULT;  // [0(best/slow)-9(worst/fast)]
                  outCodecContext->sample_rate = inCodecContext->sample_rate;
                  outCodecContext->sample_fmt = inCodecContext->sample_fmt;
                  outCodecContext->channels = inCodecContext->channels;
                  outCodecContext->channel_layout = inCodecContext->channel_layout;
                  result = avcodec_open2(outCodecContext, outCodec, NULL);
                  if (result == 0) {
                    result = avio_open(&outContext->pb, [outPath fileSystemRepresentation], AVIO_FLAG_WRITE);
                    if (result >= 0) {
                      
                      result = avformat_write_header(outContext, NULL);
                      if (result == 0) {
                        block(0.0, &stop);
                        float lastProgress = 0.0;
                        AVFrame* inFrame = avcodec_alloc_frame();
                        AVPacket inPacket;
                        do {
                          if (stop) {
                            result = -1;
                            break;
                          }
                          result = av_read_frame(inContext, &inPacket);
                          if (result < 0) {
                            if (result == AVERROR_EOF) {
                              result = 0;
                            }
                            break;
                          }
                          if (inPacket.stream_index == i) {
                            int hasFrame;
                            result = avcodec_decode_audio4(inCodecContext, inFrame, &hasFrame, &inPacket);
                            if (result >= 0) {
                              if (hasFrame) {
                                AVPacket outPacket;
                                av_init_packet(&outPacket);
                                outPacket.data = NULL;
                                outPacket.size = 0;
                                int hasPacket;
                                result = avcodec_encode_audio2(outCodecContext, &outPacket, inFrame, &hasPacket);
                                if (result == 0) {
                                  if (hasPacket) {
                                    result = av_write_frame(outContext, &outPacket);
                                    if (result < 0) {
                                      NSLog(@"%@: %s", outPath, av_err2str(result));
                                    }
                                  }
                                  av_free_packet(&outPacket);
                                } else {
                                  NSLog(@"%@: %s", outPath, av_err2str(result));
                                }
                              }
                            } else {
                              NSLog(@"%@: %s", inPath, av_err2str(result));
                            }
                            float progress = floorf(100.0 * (double)inPacket.pts / (double)inStream->duration);
                            if (progress > lastProgress) {
                              block(progress / 100.0, &stop);
                              lastProgress = progress;
                            }
                          }
                          av_free_packet(&inPacket);
                        } while (result >= 0);
                        avcodec_free_frame(&inFrame);
                        if (result >= 0) {
                          while (1) {
                            AVPacket outPacket;
                            av_init_packet(&outPacket);
                            outPacket.data = NULL;
                            outPacket.size = 0;
                            int hasPacket;
                            result = avcodec_encode_audio2(outCodecContext, &outPacket, NULL, &hasPacket);
                            if (result == 0) {
                              if (hasPacket) {
                                result = av_write_frame(outContext, &outPacket);
                                if (result < 0) {
                                   NSLog(@"%@: %s", outPath, av_err2str(result));
                                  break;
                                }
                              } else {
                                break;
                              }
                              av_free_packet(&outPacket);
                            } else {
                              NSLog(@"%@: %s", outPath, av_err2str(result));
                              break;
                            }
                          }
                          if (result >= 0) {
                            result = av_write_trailer(outContext);
                            if (result == 0) {
                              block(1.0, &stop);
                              success = stop ? NO : YES;
                            } else {
                              NSLog(@"%@: %s", outPath, av_err2str(result));
                            }
                          }
                        }
                      } else {
                        NSLog(@"%@: %s", outPath, av_err2str(result));
                      }
                      
                      avio_close(outContext->pb);
                    } else {
                      NSLog(@"%@: %s", outPath, av_err2str(result));
                    }
                    avcodec_close(outCodecContext);
                  } else {
                    NSLog(@"%@: %s", outPath, av_err2str(result));
                  }
                } else {
                  NSLog(@"%@: no audio codec", outPath);
                }
                avformat_free_context(outContext);
              } else {
                NSLog(@"%@: %s", outPath, av_err2str(result));
              }
              
              avcodec_close(inCodecContext);
            } else {
              NSLog(@"%@: %s", inPath, av_err2str(result));
            }
          } else {
            NSLog(@"%@: no audio codec", inPath);
          }
          foundAudioStream = YES;
          break;
        }
      }
      if (!foundAudioStream) {
        NSLog(@"%@: no audio stream", inPath);
      }
    } else {
      NSLog(@"%@: %s", inPath, av_err2str(result));
    }
    avformat_close_input(&inContext);
  } else {
    NSLog(@"%@: %s", inPath, av_err2str(result));
  }
  if (!success) {
    unlink([outPath fileSystemRepresentation]);
  }
  return success;
}

@end
