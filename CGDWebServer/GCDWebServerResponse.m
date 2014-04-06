/*
 Copyright (c) 2012-2014, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <zlib.h>

#import "GCDWebServerPrivate.h"

#define kZlibErrorDomain @"ZlibErrorDomain"
#define kGZipInitialBufferSize (256 * 1024)

@interface GCDWebServerBodyEncoder : NSObject <GCDWebServerBodyReader>
- (id)initWithResponse:(GCDWebServerResponse*)response reader:(id<GCDWebServerBodyReader>)reader;
@end

@interface GCDWebServerChunkEncoder : GCDWebServerBodyEncoder
@end

@interface GCDWebServerGZipEncoder : GCDWebServerBodyEncoder
@end

@interface GCDWebServerBodyEncoder () {
@private
  GCDWebServerResponse* __unsafe_unretained _response;
  id<GCDWebServerBodyReader> __unsafe_unretained _reader;
}
@end

@implementation GCDWebServerBodyEncoder

- (id)initWithResponse:(GCDWebServerResponse*)response reader:(id<GCDWebServerBodyReader>)reader {
  if ((self = [super init])) {
    _response = response;
    _reader = reader;
  }
  return self;
}

- (BOOL)open:(NSError**)error {
  return [_reader open:error];
}

- (NSData*)readData:(NSError**)error {
  return [_reader readData:error];
}

- (void)close {
  [_reader close];
}

@end

@interface GCDWebServerChunkEncoder () {
@private
  BOOL _finished;
}
@end

@implementation GCDWebServerChunkEncoder

- (id)initWithResponse:(GCDWebServerResponse*)response reader:(id<GCDWebServerBodyReader>)reader {
  if ((self = [super initWithResponse:response reader:reader])) {
    response.contentLength = NSNotFound;  // Make sure "Content-Length" header is not set
    [response setValue:@"chunked" forAdditionalHeader:@"Transfer-Encoding"];
  }
  return self;
}

- (NSData*)readData:(NSError**)error {
  NSData* chunk;
  if (_finished) {
    chunk = [[NSData alloc] init];
  } else {
    NSData* data = [super readData:error];
    if (data == nil) {
      return nil;
    }
    if (data.length) {
      const char* hexString = [[NSString stringWithFormat:@"%lx", (unsigned long)data.length] UTF8String];
      size_t hexLength = strlen(hexString);
      chunk = [[NSMutableData alloc] initWithLength:(hexLength + 2 + data.length + 2)];
      if (chunk == nil) {
        DNOT_REACHED();
        return nil;
      }
      char* ptr = (char*)[(NSMutableData*)chunk mutableBytes];
      bcopy(hexString, ptr, hexLength);
      ptr += hexLength;
      *ptr++ = '\r';
      *ptr++ = '\n';
      bcopy(data.bytes, ptr, data.length);
      ptr += data.length;
      *ptr++ = '\r';
      *ptr = '\n';
    } else {
      chunk = [[NSData alloc] initWithBytes:"0\r\n\r\n" length:5];
      DCHECK(chunk);
      _finished = YES;
    }
  }
  return ARC_AUTORELEASE(chunk);
}

@end

@interface GCDWebServerGZipEncoder () {
@private
  z_stream _stream;
  BOOL _finished;
}
@end

@implementation GCDWebServerGZipEncoder

- (id)initWithResponse:(GCDWebServerResponse*)response reader:(id<GCDWebServerBodyReader>)reader {
  if ((self = [super initWithResponse:response reader:reader])) {
    response.contentLength = NSNotFound;  // Make sure "Content-Length" header is not set
    [response setValue:@"gzip" forAdditionalHeader:@"Content-Encoding"];
  }
  return self;
}

- (BOOL)open:(NSError**)error {
  int result = deflateInit2(&_stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
  if (result != Z_OK) {
    *error = [NSError errorWithDomain:kZlibErrorDomain code:result userInfo:nil];
    return NO;
  }
  if (![super open:error]) {
    deflateEnd(&_stream);
    return NO;
  }
  return YES;
}

- (NSData*)readData:(NSError**)error {
  NSMutableData* gzipData;
  if (_finished) {
    gzipData = [[NSMutableData alloc] init];
  } else {
    gzipData = [[NSMutableData alloc] initWithLength:kGZipInitialBufferSize];
    if (gzipData == nil) {
      DNOT_REACHED();
      return nil;
    }
    NSUInteger length = 0;
    do {
      NSData* data = [super readData:error];
      if (data == nil) {
        return nil;
      }
      _stream.next_in = (Bytef*)data.bytes;
      _stream.avail_in = (uInt)data.length;
      while (1) {
        NSUInteger maxLength = gzipData.length - length;
        _stream.next_out = (Bytef*)((char*)gzipData.mutableBytes + length);
        _stream.avail_out = (uInt)maxLength;
        int result = deflate(&_stream, data.length ? Z_NO_FLUSH : Z_FINISH);
        if (result == Z_STREAM_END) {
          _finished = YES;
        } else if (result != Z_OK) {
          ARC_RELEASE(gzipData);
          *error = [NSError errorWithDomain:kZlibErrorDomain code:result userInfo:nil];
          return nil;
        }
        length += maxLength - _stream.avail_out;
        if (_stream.avail_out > 0) {
          break;
        }
        gzipData.length = 2 * gzipData.length;  // zlib has used all the output buffer so resize it and try again in case more data is available
      }
      DCHECK(_stream.avail_in == 0);
    } while (length == 0);  // Make sure we don't return an empty NSData if not in finished state
    gzipData.length = length;
  }
  return ARC_AUTORELEASE(gzipData);
}

- (void)close {
  deflateEnd(&_stream);
  [super close];
}

@end

@interface GCDWebServerResponse () {
@private
  NSString* _type;
  NSUInteger _length;
  NSInteger _status;
  NSUInteger _maxAge;
  NSMutableDictionary* _headers;
  BOOL _gzipped;
  BOOL _chunked;
  
  BOOL _opened;
  NSMutableArray* _encoders;
  id<GCDWebServerBodyReader> __unsafe_unretained _reader;
}
@end

@implementation GCDWebServerResponse

@synthesize contentType=_type, contentLength=_length, statusCode=_status, cacheControlMaxAge=_maxAge,
            gzipContentEncoding=_gzipped, chunkedTransferEncoding=_chunked, additionalHeaders=_headers;

+ (GCDWebServerResponse*)response {
  return ARC_AUTORELEASE([[[self class] alloc] init]);
}

- (id)init {
  if ((self = [super init])) {
    _type = nil;
    _length = NSNotFound;
    _status = 200;
    _maxAge = 0;
    _headers = [[NSMutableDictionary alloc] init];
    _encoders = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)dealloc {
  ARC_RELEASE(_type);
  ARC_RELEASE(_headers);
  ARC_RELEASE(_encoders);
  
  ARC_DEALLOC(super);
}

- (void)setValue:(NSString*)value forAdditionalHeader:(NSString*)header {
  [_headers setValue:value forKey:header];
}

- (BOOL)hasBody {
  return _type ? YES : NO;
}

- (BOOL)open:(NSError**)error {
  return YES;
}

- (NSData*)readData:(NSError**)error {
  return nil;
}

- (void)close {
  ;
}

- (BOOL)performOpen:(NSError**)error {
  if (_opened) {
    DNOT_REACHED();
    return NO;
  }
  _opened = YES;
  
  _reader = self;
  if (_gzipped) {
    GCDWebServerGZipEncoder* encoder = [[GCDWebServerGZipEncoder alloc] initWithResponse:self reader:_reader];
    [_encoders addObject:encoder];
    ARC_RELEASE(encoder);
    _reader = encoder;
  }
  if (_chunked) {
    GCDWebServerChunkEncoder* encoder = [[GCDWebServerChunkEncoder alloc] initWithResponse:self reader:_reader];
    [_encoders addObject:encoder];
    ARC_RELEASE(encoder);
    _reader = encoder;
  }
  return [_reader open:error];
}

- (NSData*)performReadData:(NSError**)error {
  return [_reader readData:error];
}

- (void)performClose {
  [_reader close];
}

@end

@implementation GCDWebServerResponse (Extensions)

+ (GCDWebServerResponse*)responseWithStatusCode:(NSInteger)statusCode {
  return ARC_AUTORELEASE([[self alloc] initWithStatusCode:statusCode]);
}

+ (GCDWebServerResponse*)responseWithRedirect:(NSURL*)location permanent:(BOOL)permanent {
  return ARC_AUTORELEASE([[self alloc] initWithRedirect:location permanent:permanent]);
}

- (id)initWithStatusCode:(NSInteger)statusCode {
  if ((self = [self init])) {
    self.statusCode = statusCode;
  }
  return self;
}

- (id)initWithRedirect:(NSURL*)location permanent:(BOOL)permanent {
  if ((self = [self init])) {
    self.statusCode = permanent ? 301 : 307;
    [self setValue:[location absoluteString] forAdditionalHeader:@"Location"];
  }
  return self;
}

@end
