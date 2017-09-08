//
//  AESplitterModule.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 30/05/2016.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AESplitterModule.h"
#import "AEAudioBufferListUtilities.h"
#import "AEBufferStack.h"
#import "AEUtilities.h"
#import "AEDSPUtilities.h"
#import <Accelerate/Accelerate.h>

static const float kAvgFalloffPerAnalysis = 0.1;
static const float kPeakFalloffPerAnalysis = 0.01;

@interface AESplitterModule () {
    AudioBufferList * _buffer;
    AudioTimeStamp _timestamp;
    UInt64 _bufferedTime;
    UInt32 _bufferedFrames;
    float _average;
    float _peak;
}
@property (nonatomic, strong, readwrite) AEModule * module;
@end

@implementation AESplitterModule
@dynamic average, peak;

- (instancetype)initWithRenderer:(AERenderer *)renderer module:(AEModule *)module {
    if ( !(self = [super initWithRenderer:renderer]) ) return nil;
    _numberOfChannels = 2;
    _buffer = AEAudioBufferListCreate(AEBufferStackMaxFramesPerSlice);
    _bufferedTime = UINT32_MAX;
    self.module = module;
    self.processFunction = AESplitterModuleProcess;
    return self;
}

- (void)setNumberOfChannels:(int)numberOfChannels {
    _numberOfChannels = numberOfChannels;
    AEAudioBufferListFree(_buffer);
    _buffer = AEAudioBufferListCreateWithFormat(AEAudioDescriptionWithChannelsAndRate(_numberOfChannels, 0),
                                                AEBufferStackMaxFramesPerSlice);
}

- (double)peak {
    return AEDSPRatioToDecibels(_peak);
}

- (double)average {
    return AEDSPRatioToDecibels(_average);
}


static void AESplitterModuleProcess(__unsafe_unretained AESplitterModule * THIS, const AERenderContext * _Nonnull context) {
    
    if ( (UInt64)context->timestamp->mSampleTime != THIS->_bufferedTime ) {
        
        // Run module, cache result
        #ifdef DEBUG
        int priorStackDepth = AEBufferStackCount(context->stack);
        #endif
        
        AEModuleProcess(THIS->_module, context);
        
        #ifdef DEBUG
        if ( AEBufferStackCount(context->stack) != priorStackDepth+1 ) {
            if ( AERateLimit() ) {
                printf("A module within AESplitterModule didn't push a buffer! Sure it's a generator?\n");
            }
            return;
        }
        #endif
        
        // Perform analysis
        const AudioBufferList * buffer = AEBufferStackGet(context->stack, 0);
        if ( buffer ) {
            float max = 0;
            for ( int i=0; i<buffer->mNumberBuffers; i++ ) {
                vDSP_maxmgv((float*)buffer->mBuffers[i].mData, 1, &max, context->frames);
            }
            THIS->_average = (kAvgFalloffPerAnalysis * max) + ((1.0-kAvgFalloffPerAnalysis) * THIS->_average);
            THIS->_peak = MAX(max, ((1.0-kPeakFalloffPerAnalysis) * THIS->_peak));
            
            
            THIS->_timestamp = *AEBufferStackGetTimeStampForBuffer(context->stack, 0);
            AEAudioBufferListCopyContents(THIS->_buffer, AEBufferStackGet(context->stack, 0), 0, 0, context->frames);
        } else {
            THIS->_average = THIS->_peak = 0;
            THIS->_timestamp = *context->timestamp;
            AEAudioBufferListSilence(THIS->_buffer, 0, context->frames);
        }
        
        THIS->_bufferedTime = (UInt64)context->timestamp->mSampleTime;
        THIS->_bufferedFrames = context->frames;
    } else {
        
        // Return cached result
        #ifdef DEBUG
        if ( context->frames != THIS->_bufferedFrames && AERateLimit() ) {
            printf("AESplitterModule has been run with different frame counts. Are you using it from a variable-rate filter?\n");
        }
        #endif
        
        AEBufferStackPushWithChannels(context->stack, 1, THIS->_numberOfChannels);
        *AEBufferStackGetTimeStampForBuffer(context->stack, 0) = THIS->_timestamp;
        AEAudioBufferListCopyContents(AEBufferStackGet(context->stack, 0), THIS->_buffer, 0, 0, context->frames);
    }
}

@end
