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
#import <libavfilter/avfilter.h>
#import <libavfilter/buffersrc.h>
#import <libavfilter/buffersink.h>

#import "MP3Transcoder.h"

// http://www.ffmpeg.org/ffmpeg-formats.html#mp3
// http://www.ffmpeg.org/ffmpeg-codecs.html#Options-9
// http://trac.ffmpeg.org/wiki/Encoding%20VBR%20(Variable%20Bit%20Rate)%20mp3%20audio

static void _SetTranscoderErrorFromAVError(NSError** error, int code, NSString* format, ...) NS_FORMAT_FUNCTION(3,4);

// Must match BitRate enum
static int _monoBitRateLUT[][4] = {
  {0, 0, 0, 0},
  {32 * 1000, 0, 0, 32},
  {48 * 1000, 0, 0, 48},
  {64 * 1000, 0, 0, 64},
  {80 * 1000, 0, 0, 80},
  {96 * 1000, 0, 0, 96},
  {128 * 1000, 0, 0, 128},
  {160 * 1000, 0, 0, 160},
  {0, CODEC_FLAG_QSCALE, 9, 65},
  {0, CODEC_FLAG_QSCALE, 9, 65},
  {0, CODEC_FLAG_QSCALE, 8, 85},
  {0, CODEC_FLAG_QSCALE, 7, 100},
  {0, CODEC_FLAG_QSCALE, 5, 130}
};

// Must match BitRate enum
static int _stereoBitRateLUT[][4] = {
  {0, 0, 0, 0},
  {64 * 1000, 0, 0, 64},
  {96 * 1000, 0, 0, 96},
  {128 * 1000, 0, 0, 128},
  {160 * 1000, 0, 0, 160},
  {192 * 1000, 0, 0, 192},
  {256 * 1000, 0, 0, 256},
  {320 * 1000, 0, 0, 320},
  {0, CODEC_FLAG_QSCALE, 9, 65},
  {0, CODEC_FLAG_QSCALE, 6, 115},
  {0, CODEC_FLAG_QSCALE, 4, 165},
  {0, CODEC_FLAG_QSCALE, 2, 190},
  {0, CODEC_FLAG_QSCALE, 0, 245}
};

NSString* const MP3TranscoderErrorDomain = @"MP3TranscoderErrorDomain";

NSUInteger KBitsPerSecondFromBitRate(BitRate bitRate, BOOL isStereo) {
  return (isStereo ? _stereoBitRateLUT[bitRate][3] : _monoBitRateLUT[bitRate][3]);
}

static void _SetTranscoderErrorFromAVError(NSError** error, int code, NSString* format, ...) {
  if (error) {
    va_list arguments;
    va_start(arguments, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSDictionary* info = @{
                           NSLocalizedDescriptionKey: message,
                           NSLocalizedFailureReasonErrorKey: [NSString stringWithUTF8String:av_err2str(code)]
                           };
    *error = [NSError errorWithDomain:MP3TranscoderErrorDomain code:code userInfo:info];
  }
}

@implementation MP3Transcoder

+ (void)load {
  av_register_all();
  avcodec_register_all();
  avfilter_register_all();
}

+ (BOOL)transcodeAudioFileAtPath:(NSString*)inPath
                          toPath:(NSString*)outPath
                     withBitRate:(BitRate)bitRate
                           error:(NSError**)error
                   progressBlock:(void (^)(float progress, BOOL* stop))block {
  BOOL success = NO;
  BOOL stop = NO;
  if (error) {
    *error = nil;
  }
  AVFormatContext* inContext = NULL;
  int result = avformat_open_input(&inContext, [inPath fileSystemRepresentation], NULL, NULL);
  if (result == 0) {
    result = avformat_find_stream_info(inContext, NULL);
    if (result >= 0) {
      result = av_find_best_stream(inContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
      if (result >= 0) {
        unsigned int streamIndex = result;
        AVStream* inStream = inContext->streams[streamIndex];
        AVCodecContext* inCodecContext = inStream->codec;
        if ((inCodecContext->channels == 1) || (inCodecContext->channels == 2)) {
          if (inCodecContext->channel_layout == 0) {
            inCodecContext->channel_layout = av_get_default_channel_layout(inCodecContext->channels);  // Should be AV_CH_LAYOUT_MONO or AV_CH_LAYOUT_STEREO
          }
          AVCodec* inCodec = avcodec_find_decoder(inCodecContext->codec_id);
          if (inCodec) {
            result = avcodec_open2(inCodecContext, inCodec, NULL);  // MP3 codec outputs AV_SAMPLE_FMT_FLTP, AAC codec outputs AV_SAMPLE_FMT_FLTP, ALAC codec outputs AV_SAMPLE_FMT_S16P and AIFF / WAV codecs output non-planar data like AV_SAMPLE_FMT_S16
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
                  outCodecContext->channels = inCodecContext->channels;
                  outCodecContext->channel_layout = inCodecContext->channel_layout;
                  outCodecContext->sample_rate = inCodecContext->sample_rate;
                  outCodecContext->sample_fmt = inCodecContext->sample_fmt;
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
                  
                  AVFilterGraph* filterGraph = NULL;
                  AVFilterContext* filterSourceContext = NULL;
                  AVFilterContext* filterSinkContext = NULL;
                  if ((outCodecContext->sample_fmt != AV_SAMPLE_FMT_S16P) && (outCodecContext->sample_fmt != AV_SAMPLE_FMT_S32P) && (outCodecContext->sample_fmt != AV_SAMPLE_FMT_FLTP)) {  // MP3 codec supported formats
                    switch (outCodecContext->sample_fmt) {
                      case AV_SAMPLE_FMT_NONE: break;
                      case AV_SAMPLE_FMT_U8: outCodecContext->sample_fmt = AV_SAMPLE_FMT_S16P; break;  // TODO: Is this ideal?
                      case AV_SAMPLE_FMT_S16: outCodecContext->sample_fmt = AV_SAMPLE_FMT_S16P; break;
                      case AV_SAMPLE_FMT_S32: outCodecContext->sample_fmt = AV_SAMPLE_FMT_S32P; break;
                      case AV_SAMPLE_FMT_FLT: outCodecContext->sample_fmt = AV_SAMPLE_FMT_FLTP; break;
                      case AV_SAMPLE_FMT_DBL: outCodecContext->sample_fmt = AV_SAMPLE_FMT_FLTP; break;
                      case AV_SAMPLE_FMT_U8P: outCodecContext->sample_fmt = AV_SAMPLE_FMT_S16P; break;  // TODO: Is this ideal?
                      case AV_SAMPLE_FMT_S16P: break;
                      case AV_SAMPLE_FMT_S32P: break;
                      case AV_SAMPLE_FMT_FLTP: break;
                      case AV_SAMPLE_FMT_DBLP: outCodecContext->sample_fmt = AV_SAMPLE_FMT_FLTP; break;
                      case AV_SAMPLE_FMT_NB: break;
                    }
                    filterGraph = avfilter_graph_alloc();
                    AVFilterInOut* outputs = NULL;
                    AVFilterInOut* inputs = NULL;
                    
                    AVFilter* sourceFilter = avfilter_get_by_name("abuffer");
                    AVRational timeBase = inContext->streams[streamIndex]->time_base;
                    char args[512];
                    snprintf(args, sizeof(args), "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=0x%"PRIx64,
                             timeBase.num, timeBase.den, inCodecContext->sample_rate, av_get_sample_fmt_name(inCodecContext->sample_fmt), inCodecContext->channel_layout);
                    result = avfilter_graph_create_filter(&filterSourceContext, sourceFilter, "in", args, NULL, filterGraph);
                    if (result >= 0) {
                      outputs = avfilter_inout_alloc();
                      outputs->name = av_strdup("in");
                      outputs->filter_ctx = filterSourceContext;
                      outputs->pad_idx = 0;
                      outputs->next = NULL;
                    }
                    
                    AVFilter* sinkFilter = avfilter_get_by_name("abuffersink");
                    result = avfilter_graph_create_filter(&filterSinkContext, sinkFilter, "out", NULL, NULL, filterGraph);
                    if (result >= 0) {
                      enum AVSampleFormat out_sample_fmts[] = {outCodecContext->sample_fmt, -1};
                      result = av_opt_set_int_list(filterSinkContext, "sample_fmts", out_sample_fmts, -1, AV_OPT_SEARCH_CHILDREN);
                    }
                    if (result >= 0) {
                      int64_t out_channel_layouts[] = {outCodecContext->channel_layout, -1};
                      result = av_opt_set_int_list(filterSinkContext, "channel_layouts", out_channel_layouts, -1, AV_OPT_SEARCH_CHILDREN);
                    }
                    if (result >= 0) {
                      int out_sample_rates[] = {outCodecContext->sample_rate, -1};
                      result = av_opt_set_int_list(filterSinkContext, "sample_rates", out_sample_rates, -1, AV_OPT_SEARCH_CHILDREN);
                    }
                    if (result >= 0) {
                      inputs = avfilter_inout_alloc();
                      inputs->name = av_strdup("out");
                      inputs->filter_ctx = filterSinkContext;
                      inputs->pad_idx = 0;
                      inputs->next = NULL;
                    }
                    
                    if (result >= 0) {
                      char desc[512];
                      snprintf(desc, sizeof(desc), "aresample=%d,aformat=sample_fmts=%s:channel_layouts=0x%"PRIx64,
                               outCodecContext->sample_rate, av_get_sample_fmt_name(outCodecContext->sample_fmt), outCodecContext->channel_layout);
                      result = avfilter_graph_parse_ptr(filterGraph, desc, &inputs, &outputs, NULL);
                    }
                    if (result >= 0) {
                      result = avfilter_graph_config(filterGraph, NULL);
                    }
                    
                    avfilter_inout_free(&inputs);
                    avfilter_inout_free(&outputs);
                    if (result < 0) {
                      _SetTranscoderErrorFromAVError(error, result, @"Failed creating filter graph");
                      avfilter_graph_free(&filterGraph);
                    }
                  }
                  
                  if (result >= 0) {
                    result = avcodec_open2(outCodecContext, outCodec, NULL);
                    if (result == 0) {
                      result = avio_open(&outContext->pb, [outPath fileSystemRepresentation], AVIO_FLAG_WRITE);
                      if (result >= 0) {
                        
                        result = avformat_write_header(outContext, NULL);
                        if (result == 0) {
                          block(0.0, &stop);
                          float lastProgress = 0.0;
                          AVPacket rawPacket;
                          AVFrame* rawFrame = avcodec_alloc_frame();
                          AVFrame* filteredFrame = NULL;
                          if (filterGraph) {
                            filteredFrame = avcodec_alloc_frame();
                          }
                          do {
                            if (stop) {
                              result = -1;
                              break;
                            }
                            result = av_read_frame(inContext, &rawPacket);
                            if (result < 0) {
                              if (result == AVERROR_EOF) {
                                result = 0;
                              }
                              break;
                            }
                            if (rawPacket.stream_index == streamIndex) {
                              AVPacket inPacket = rawPacket;
                              do {
                                int hasFrame = 0;
                                result = avcodec_decode_audio4(inCodecContext, rawFrame, &hasFrame, &inPacket);
                                if (result >= 0) {
                                  inPacket.size -= result;
                                  inPacket.data += result;
                                  if (hasFrame) {
                                    if (filterGraph) {
                                      
                                      result = av_buffersrc_add_frame_flags(filterSourceContext, rawFrame, 0);
                                      if (result >= 0) {
                                        do {
                                          result = av_buffersink_get_frame(filterSinkContext, filteredFrame);
                                          if (result >= 0) {
                                            
                                            AVPacket outPacket;
                                            av_init_packet(&outPacket);
                                            outPacket.data = NULL;
                                            outPacket.size = 0;
                                            int hasPacket = 0;
                                            result = avcodec_encode_audio2(outCodecContext, &outPacket, filteredFrame, &hasPacket);
                                            if (result == 0) {
                                              if (hasPacket) {
                                                result = av_write_frame(outContext, &outPacket);
                                                if (result < 0) {
                                                  _SetTranscoderErrorFromAVError(error, result, @"Failed writing samples to output file");
                                                }
                                              }
                                              av_free_packet(&outPacket);
                                            } else {
                                              _SetTranscoderErrorFromAVError(error, result, @"Failed encoding samples with output codec");
                                            }
                                            
                                            av_frame_unref(filteredFrame);
                                          } else if ((result == AVERROR(EAGAIN)) || (result == AVERROR_EOF)) {
                                            result = 0;
                                            break;
                                          } else {
                                            _SetTranscoderErrorFromAVError(error, result, @"Failed retrieving samples from filter graph");
                                          }
                                        } while (result >= 0);
                                      } else {
                                        _SetTranscoderErrorFromAVError(error, result, @"Failed passing samples to filter graph");
                                      }
                                      
                                    } else {
                                      
                                      AVPacket outPacket;
                                      av_init_packet(&outPacket);
                                      outPacket.data = NULL;
                                      outPacket.size = 0;
                                      int hasPacket = 0;
                                      result = avcodec_encode_audio2(outCodecContext, &outPacket, rawFrame, &hasPacket);
                                      if (result == 0) {
                                        if (hasPacket) {
                                          result = av_write_frame(outContext, &outPacket);
                                          if (result < 0) {
                                            _SetTranscoderErrorFromAVError(error, result, @"Failed writing samples to output file");
                                          }
                                        }
                                        av_free_packet(&outPacket);
                                      } else {
                                        _SetTranscoderErrorFromAVError(error, result, @"Failed encoding samples with output codec");
                                      }
                                      
                                    }
                                  }
                                  if (inPacket.size <= 0) {
                                    break;
                                  }
                                } else {
                                  _SetTranscoderErrorFromAVError(error, result, @"Failed decoding samples with input codec");
                                }
                              } while (result >= 0);
                              float progress = floorf(100.0 * (double)rawPacket.pts / (double)inStream->duration);
                              if (progress > lastProgress) {
                                block(progress / 100.0, &stop);
                                lastProgress = progress;
                              }
                            }
                            av_free_packet(&rawPacket);
                          } while (result >= 0);
                          if (filterGraph) {
                            avcodec_free_frame(&filteredFrame);
                          }
                          avcodec_free_frame(&rawFrame);
                          if (result >= 0) {
                            while (1) {
                              
                              AVPacket outPacket;
                              av_init_packet(&outPacket);
                              outPacket.data = NULL;
                              outPacket.size = 0;
                              int hasPacket = 0;
                              result = avcodec_encode_audio2(outCodecContext, &outPacket, NULL, &hasPacket);
                              if (result == 0) {
                                if (hasPacket) {
                                  result = av_write_frame(outContext, &outPacket);
                                  if (result < 0) {
                                     _SetTranscoderErrorFromAVError(error, result, @"Failed writing samples to output file");
                                    break;
                                  }
                                } else {
                                  break;
                                }
                                av_free_packet(&outPacket);
                              } else {
                                _SetTranscoderErrorFromAVError(error, result, @"Failed encoding samples with output codec");
                                break;
                              }
                              
                            }
                            if (result >= 0) {
                              result = av_write_trailer(outContext);
                              if (result == 0) {
                                block(1.0, &stop);
                                success = stop ? NO : YES;
                              } else {
                                _SetTranscoderErrorFromAVError(error, result, @"Failed writing output file trailer");
                              }
                            }
                          }
                        } else {
                          _SetTranscoderErrorFromAVError(error, result, @"Failed writing output file header");
                        }
                        
                        avio_close(outContext->pb);
                      } else {
                        _SetTranscoderErrorFromAVError(error, result, @"Failed opening output file");
                      }
                      avcodec_close(outCodecContext);
                    } else {
                      _SetTranscoderErrorFromAVError(error, result, @"Failed opening output audio codec");
                    }
                  }
                  
                  if (filterGraph) {
                    avfilter_graph_free(&filterGraph);
                  }
                } else {
                  _SetTranscoderErrorFromAVError(error, 0, @"Failed finding audio codec for output context");
                }
                avformat_free_context(outContext);
              } else {
                _SetTranscoderErrorFromAVError(error, result, @"Failed creating MP3 output context");
              }
              
              avcodec_close(inCodecContext);
            } else {
              _SetTranscoderErrorFromAVError(error, result, @"Failed opening input audio codec");
            }
          } else {
            _SetTranscoderErrorFromAVError(error, 0, @"Failed finding audio codec for input file");
          }
        } else {
          _SetTranscoderErrorFromAVError(error, 0, @"Unsupported number of channels in input file (%i)", inCodecContext->channels);
        }
      } else {
        _SetTranscoderErrorFromAVError(error, result, @"Failed finding audio stream in input file");
      }
    } else {
      _SetTranscoderErrorFromAVError(error, result, @"Failed parsing input file");
    }
    avformat_close_input(&inContext);
  } else {
    _SetTranscoderErrorFromAVError(error, result, @"Failed opening input file");
  }
  if (!success) {
    unlink([outPath fileSystemRepresentation]);
  }
  return success;
}

@end
