//
//  AudioInput.h
//  Miso Music InstrumentView Test
//
//  Created by Ryan Hiroaki Tsukamoto on 3/6/11.
//  Copyright 2011 Miso Media Inc. All rights reserved.
//
#import <Foundation/Foundation.h>
#import "OGLESView.h"
#include <libkern/OSAtomic.h>
#import <AudioToolbox/AudioToolbox.h>
#import "CAStreamBasicDescription.h"
//#import "PPDABase.h"
//#import "r2intFFT.h"

#import "TunerViewProtocol.h"
#import "AudioInputProtocol.h"

#import "StroboscopicTuner.h"
#import "MonophonicPitchDetection.h"
#import "PolyphonicPitchDetection.h"

#define MAX_WHEEL_LENGTH 1024

//COPYPASTA FROM THE NEW PITCH DETECTION ALGO! (EARLY JUNE 2011)!!!:


#define	__FLOATING_POINT_BINS__

//END COPYPASTA!!!:
void configure_ppda(int low_note);


int DestroyRemoteIO(AudioUnit& inRIOU);
int SetupRemoteIO (AudioUnit& inRemoteIOUnit, AURenderCallbackStruct inRenderProcm, CAStreamBasicDescription& outFormat);
void SilenceData(AudioBufferList *inData);
class DCRejectionFilter
{
public:
	DCRejectionFilter(Float32 poleDist = DCRejectionFilter::kDefaultPoleDist);
	void InplaceFilter(SInt32* ioData, UInt32 numFrames, UInt32 strides);
	void Reset();
protected:
	SInt16 mA1;
	SInt16 mGain;
	SInt32 mY1;
	SInt32 mX1;
	static const Float32 kDefaultPoleDist;
};
inline double linearInterp(double valA, double valB, double fract)	{	return valA + ((valB - valA) * fract);	}

@interface AudioInput : NSObject <AudioInputProtocol, MonophonicPitchDetectionDelegate>
{
	id<TunerViewProtocol>		tuner_view;
	AudioUnit					rioUnit;
	int							unitIsRunning;
//	BOOL						unitIsRunning;
	BOOL						unitHasBeenCreated;
//	DCRejectionFilter*			dcFilter;
	CAStreamBasicDescription	thruFormat;
	AURenderCallbackStruct		inputProc;
}
@property (nonatomic, assign)	AudioUnit				rioUnit;
@property (nonatomic, assign)	int						unitIsRunning;
@property (nonatomic, assign)	AURenderCallbackStruct	inputProc;
//-(id)init_for_pad;
//-(id)init_for_phone;
-(void)setup_analysis;
void rioInterruptionListener(void* inClientData, UInt32 inInterruption);
-(void)configure_ppda_with_low_note:(int)n;
-(void)set_throughput:(bool)bleeding_ears;
-(void)accept_TunerView:(id)tv;
-(void)shut_off_pda;
-(void)set_tuner_mode:(bool)is_simple;
-(void)accept_starting_octave:(int)starting_octave;
-(void)accept_A4_in_Hz:(double)A4;
-(void)switch_to_tuner:(bool)to_tuner;
-(void)set_audio_input_mode:(AUDIO_INPUT_MODE)aim;

-(void)set_audio_input_mode:(AUDIO_INPUT_MODE)aim;
-(void)compute_goodnesses:(double*)p_goodnesses for_notes:(int*)p_notes_in_semitones_from_middle_C num_notes:(int)num_notes;
@end

//void draw_strobe_wheel_Pad(AUTOCORRELATION_WHEEL* w);
//void draw_strobe_wheel_phone(AUTOCORRELATION_WHEEL* w);
NSString* non_enharmonic_pitch_class_name(int pitch_class);

