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

#import "GCDWebServerPrivate.h"

@interface GCDWebServerFileRequest () {
@private
  NSString* _filePath;
  int _file;
}
@end

@implementation GCDWebServerFileRequest

@synthesize filePath=_filePath;

- (id)initWithMethod:(NSString*)method url:(NSURL*)url headers:(NSDictionary*)headers path:(NSString*)path query:(NSDictionary*)query {
  if ((self = [super initWithMethod:method url:url headers:headers path:path query:query])) {
    _filePath = ARC_RETAIN([NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]);
  }
  return self;
}

- (void)dealloc {
  DCHECK(_file < 0);
  unlink([_filePath fileSystemRepresentation]);
  ARC_RELEASE(_filePath);
  
  ARC_DEALLOC(super);
}

- (BOOL)open {
  DCHECK(_file == 0);
  _file = open([_filePath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
  return (_file > 0 ? YES : NO);
}

- (NSInteger)write:(const void*)buffer maxLength:(NSUInteger)length {
  DCHECK(_file > 0);
  return write(_file, buffer, length);
}

- (BOOL)close {
  DCHECK(_file > 0);
  int result = close(_file);
  _file = -1;
  return (result == 0 ? YES : NO);
}

@end
