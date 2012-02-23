//
//  AudioOutput.h
//  Miso Music InstrumentView Test
//
//  Created by Ryan Hiroaki Tsukamoto on 2/28/11.
//  Copyright 2011 Miso Media Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <OpenAL/al.h>
#import <OpenAL/alc.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/ExtendedAudioFile.h>
#import "InstrumentViewBase.h"
#import "TutorialDefines.h"

#define kDefaultDistance 16.0

typedef ALvoid	AL_APIENTRY	(*alBufferDataStaticProcPtr) (const ALint bid, ALenum format, ALvoid* data, ALsizei size, ALsizei freq);
ALvoid  alBufferDataStaticProc(const ALint bid, ALenum format, ALvoid* data, ALsizei size, ALsizei freq);
void* MyGetOpenALAudioData(CFURLRef inFileURL, ALsizei *outDataSize, ALenum *outDataFormat, ALsizei* outSampleRate);

@interface AudioOutput : NSObject
{
	ALuint*						_sources;
	ALuint*						_buffers;
	ALuint						_tutorial_source;
	ALuint						_tutorial_buffer;
	void*						_data;
	CGPoint						_sourcePos;
	CGPoint						_listenerPos;
	CGFloat						_listenerRotation;
	ALfloat						_sourceVolume;
	BOOL						_isPlaying;
	BOOL						_wasInterrupted;
	MM_INSTRUMENT*				p_instrument;
	int							num_strings;
	int							num_frets;
	int							lowest_string;
	int							highest_string;
	int							needed_range;
}

@property			BOOL isPlaying; // Whether the sound is playing or stopped
@property			BOOL wasInterrupted; // Whether playback was interrupted by the system
@property			CGPoint sourcePos; // The coordinates of the sound source
@property			CGPoint listenerPos; // The coordinates of the listener
@property			CGFloat listenerRotation; // The rotation angle of the listener in radians
@property			ALuint*	_sources;
@property			CGPoint _sourcePos;

-(id)init_with_instrument:(MM_INSTRUMENT*)p_i;
-(void)init_OpenAL;
-(void)destroy_OpenAL;
-(void)playString:(int)s andFret:(int)f;
-(bool)isStringPlaying:(int)s;
-(bool)tutorial_playing;						//is the tutorial playing?
-(void)play_tutorial;							//do this to play the sound we want.
-(void)stop_tutorial;							//do this to stop (ie before loading the next one for non-retarded users)
-(void)play_intro_tutorial:(int)n;				//loads and plays the nth sound byte for the tutorial
-(void)play_virtual_instrument_tutorial:(int)n;	//(safely) loads and plays the nth sound byte for the virtual instrument tutorial 
-(void)play_real_instrument_tutorial:(int)n;	//loads and plays the nth sound byte for the real instrument tutorial

-(void)play_virtual_instrument_tutorial_step:(VI_TUTORIAL_STEP)vi_t_s;
-(void)play_real_instrument_tutorial_step:(RI_TUTORIAL_STEP)ri_t_s;
@end
