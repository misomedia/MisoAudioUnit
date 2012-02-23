//
//  AudioInput.m
//  Miso Music InstrumentView Test
//
//  Created by Ryan Hiroaki Tsukamoto on 3/6/11.
//  Copyright 2011 Miso Media Inc. All rights reserved.
//

#import "AudioInput.h"
#import "AudioUnit/AudioUnit.h"
#import "CAXException.h"
#import <math.h>

#import "OGLESView.h"

const double initial_falloff_rate = 0.875;
const int	 fft_undiscretization_coeff = 16;

//const double ppda_filter_coefficient = 0.125;
const double ppda_filter_coefficient = 0.078125;

//END COPYPASTA!!!:

PITCH_DETECTION_CONTEXT* pitch_detection_context	=	NULL;
PPDA_STRUCT* ppda_struct							=	NULL;
CCFB_PITCH_DETECTION_ALGO_STRUCT* ccfb_pda_struct	=	NULL;

bool					should_break_ears = false;
int						tuner_low_octave = -2;		//only for the tuner
GLuint					strobe_texture;

Float64					hwSampleRate;
double					A4_in_Hz = 440.0;			//this should be global, dammit!

bool					analysis_ready		=	false;
AUDIO_INPUT_MODE		audio_input_mode;

#define audio_input_max_slice_size 1024
double					in_slice[audio_input_max_slice_size];

int						ppda_low_note;

bool					using_simple_tuner = true;

int DestroyRemoteIO(AudioUnit& inRIOU)
{
	try
	{
		XThrowIfError(AudioUnitUninitialize(inRIOU), "couldn't uninitialize the remote I/O unit");
	}
	catch(CAXException &e)
	{
		char buf[256];
		fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		return 1;
	}
	catch(...)
	{
		fprintf(stderr, "An unknown error occurred\n");
		return 1;
	}
	return 0;
}

int SetupRemoteIO (AudioUnit& inRemoteIOUnit, AURenderCallbackStruct inRenderProc, CAStreamBasicDescription& outFormat)
{	

	try
	{
		AudioComponentDescription desc;
		desc.componentType = kAudioUnitType_Output;
		desc.componentSubType = kAudioUnitSubType_RemoteIO;
		desc.componentManufacturer = kAudioUnitManufacturer_Apple;
		desc.componentFlags = 0;
		desc.componentFlagsMask = 0;
		AudioComponent comp = AudioComponentFindNext(NULL, &desc);
		XThrowIfError(AudioComponentInstanceNew(comp, &inRemoteIOUnit), "couldn't open the remote I/O unit");
		UInt32 one = 1;
		XThrowIfError(AudioUnitSetProperty(inRemoteIOUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one)), "couldn't enable input on the remote I/O unit");
		XThrowIfError(AudioUnitSetProperty(inRemoteIOUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &inRenderProc, sizeof(inRenderProc)), "couldn't set remote i/o render callback");
        outFormat.SetAUCanonical(2, false);
		outFormat.mSampleRate = hwSampleRate;
		XThrowIfError(AudioUnitSetProperty(inRemoteIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat, sizeof(outFormat)), "couldn't set the remote I/O unit's output client format");
		XThrowIfError(AudioUnitSetProperty(inRemoteIOUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outFormat, sizeof(outFormat)), "couldn't set the remote I/O unit's input client format");
		XThrowIfError(AudioUnitInitialize(inRemoteIOUnit), "couldn't initialize the remote I/O unit");
	}
	catch(CAXException &e)
	{
		char buf[256];
		fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		return 1;
	}
	catch(...)
	{
		fprintf(stderr, "An unknown error occurred\n");
		return 1;
	}	
	return 0;
}
void SilenceData(AudioBufferList *inData)
{
	for(UInt32 i=0; i < inData->mNumberBuffers; i++)	memset(inData->mBuffers[i].mData, 0, inData->mBuffers[i].mDataByteSize);
}
inline SInt32 smul32by16(SInt32 i32, SInt16 i16)
{
#if defined __arm__
	register SInt32 r;
	asm volatile("smulwb %0, %1, %2" : "=r"(r) : "r"(i32), "r"(i16));
	return r;
#else	
	return (SInt32)(((SInt64)i32 * (SInt64)i16) >> 16);
#endif
}
inline SInt32 smulAdd32by16(SInt32 i32, SInt16 i16, SInt32 acc)
{
#if defined __arm__
	register SInt32 r;
	asm volatile("smlawb %0, %1, %2, %3" : "=r"(r) : "r"(i32), "r"(i16), "r"(acc));
	return r;
#else		
	return ((SInt32)(((SInt64)i32 * (SInt64)i16) >> 16) + acc);
#endif
}
const Float32 DCRejectionFilter::kDefaultPoleDist = 0.975f;
DCRejectionFilter::DCRejectionFilter(Float32 poleDist)
{
	mA1 = (SInt16)((float)(1<<15)*poleDist);
	mGain = (mA1 >> 1) + (1<<14); // Normalization factor: (r+1)/2 = r/2 + 0.5
	Reset();
}
void DCRejectionFilter::Reset()
{
	mY1 = mX1 = 0;	
}
void DCRejectionFilter::InplaceFilter(SInt32* ioData, UInt32 numFrames, UInt32 strides)
{
	register SInt32 y1 = mY1, x1 = mX1;
	for (UInt32 i=0; i < numFrames; i++)
	{
		register SInt32 x0, y0;
		x0 = ioData[i*strides];
		y0 = smul32by16(y1, mA1);
		y1 = smulAdd32by16(x0 - x1, mGain, y0) << 1;
		ioData[i*strides] = y1;
		x1 = x0;
	}
	mY1 = y1;
	mX1 = x1;
}


@implementation AudioInput
@synthesize rioUnit;
@synthesize unitIsRunning;
@synthesize inputProc;
void rioInterruptionListener(void* inClientData, UInt32 inInterruption)
{
	//NSLog(@"Session interrupted! --- %@ ---", inInterruption == kAudioSessionBeginInterruption ? @"Begin Interruption" : @"End Interruption");
	AudioInput* THIS = (AudioInput*)inClientData;
//	if (inInterruption == kAudioSessionEndInterruption) {
//		// make sure we are again the active session
//		XThrowIfError(AudioSessionSetActive(true), "couldn't set audio session active");
//		XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
//	}
//	
//	if (inInterruption == kAudioSessionBeginInterruption) {
//		XThrowIfError(AudioOutputUnitStop(THIS->rioUnit), "couldn't stop unit");
//    }
	if(inInterruption == kAudioSessionEndInterruption)
	{
		AudioSessionSetActive(true);
		AudioOutputUnitStart(THIS->rioUnit);
	}
	if(inInterruption == kAudioSessionBeginInterruption)	AudioOutputUnitStop(THIS->rioUnit);
	//NSLog(@"finished handling rioInturruption");
}
void propListener(void* inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void* inData)
{
	AudioInput* THIS = (AudioInput*)inClientData;
	if (inID == kAudioSessionProperty_AudioRouteChange)
	{
		try {
			 UInt32 isAudioInputAvailable; 
			 UInt32 size = sizeof(isAudioInputAvailable);
			 XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable, &size, &isAudioInputAvailable), "couldn't get AudioSession AudioInputAvailable property value");
			 
			 if(THIS->unitIsRunning && !isAudioInputAvailable)
			 {
				 XThrowIfError(AudioOutputUnitStop(THIS->rioUnit), "couldn't stop unit");
				 THIS->unitIsRunning = false;
			 }
			 
			 else if(!THIS->unitIsRunning && isAudioInputAvailable)
			 {
				 XThrowIfError(AudioSessionSetActive(true), "couldn't set audio session active\n");
			 
				 if (!THIS->unitHasBeenCreated)	// the rio unit is being created for the first time
				 {
					 XThrowIfError(SetupRemoteIO(THIS->rioUnit, THIS->inputProc, THIS->thruFormat), "couldn't setup remote i/o unit");
					 THIS->unitHasBeenCreated = true;
					 
//					 THIS->dcFilter = new DCRejectionFilter[THIS->thruFormat.NumberChannels()];
					 
//					 UInt32 maxFPS;
//					 size = sizeof(maxFPS);
//					 XThrowIfError(AudioUnitGetProperty(THIS->rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, &size), "couldn't get the remote I/O unit's max frames per slice");
//					 
//					 THIS->fftBufferManager = new FFTBufferManager(maxFPS);
//					 THIS->l_fftData = new int32_t[maxFPS/2];
//					 
//					 THIS->oscilLine = (GLfloat*)malloc(drawBufferLen * 2 * sizeof(GLfloat));
				 }
				 
				 XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
				 THIS->unitIsRunning = true;
			 }
						
			// we need to rescale the sonogram view's color thresholds for different input
			CFStringRef newRoute;
			size = sizeof(CFStringRef);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute), "couldn't get new audio route");
			if (newRoute)
			{	
				CFShow(newRoute);
//				if (CFStringCompare(newRoute, CFSTR("Headset"), NULL) == kCFCompareEqualTo) // headset plugged in
//				{
//					colorLevels[0] = .3;				
//					colorLevels[5] = .5;
//				}
//				else if (CFStringCompare(newRoute, CFSTR("Receiver"), NULL) == kCFCompareEqualTo) // headset plugged in
//				{
//					colorLevels[0] = 0;
//					colorLevels[5] = .333;
//					colorLevels[10] = .667;
//					colorLevels[15] = 1.0;
//					
//				}			
//				else
//				{
//					colorLevels[0] = 0;
//					colorLevels[5] = .333;
//					colorLevels[10] = .667;
//					colorLevels[15] = 1.0;
//					
//				}
			}
		} catch (CAXException e) {
			char buf[256];
			fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		}
		
	}
	

//	AudioInput* THIS = (AudioInput*)inClientData;
//	if(inID == kAudioSessionProperty_AudioRouteChange)
//	{
//		try
//		{
//			XThrowIfError(AudioComponentInstanceDispose(THIS->rioUnit), "couldn't dispose remote i/o unit");		
//			SetupRemoteIO(THIS->rioUnit, THIS->inputProc, THIS->thruFormat);
//			UInt32 size = sizeof(hwSampleRate);
//			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &hwSampleRate), "couldn't get new sample rate");
//			XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
//			CFStringRef newRoute;
//			size = sizeof(CFStringRef);
//			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute), "couldn't get new audio route");
//			if(newRoute)
//			{	
//				CFShow(newRoute);
//				if (CFStringCompare(newRoute, CFSTR("Headset"), NULL) == kCFCompareEqualTo) // headset plugged in
//				{
//					NSLog(@"new route is headset");
//				}
//				else if (CFStringCompare(newRoute, CFSTR("Receiver"), NULL) == kCFCompareEqualTo) // headset plugged in
//				{
//					NSLog(@"new route is receiver");
//				}			
//				else
//				{
//					NSLog(@"new route is i dunno");
//				}
//			}
//		}
//		catch(CAXException e)
//		{
//			char buf[256];
//			fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
//		}
//	}
}
static OSStatus	PerformThru(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData)
{
	AudioInput* THIS = (AudioInput*)inRefCon;
	OSStatus err = AudioUnitRender(THIS->rioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
	if(err)
	{
		//NSLog(@"PerformThru: error %d\n", (int)err);
		return err;
	}
	SInt8* data_ptr = (SInt8*)(ioData->mBuffers[0].mData);
	if(analysis_ready)
	{
		for(int i = 0; i < inNumberFrames; i++)
		{
			in_slice[i] = data_ptr[2];
			data_ptr += 4;
		}
		switch(audio_input_mode)
		{
			case AUDIO_INPUT_MODE_TUNER:
			{
				stroboscopic_tuner_accept_slice(in_slice, inNumberFrames);
				break;
			}
			case AUDIO_INPUT_MODE_PPDA:
			{
				if(ccfb_pda_struct)	for(int i = 0; i < inNumberFrames; i++)	ccfb_ppda_struct_accept_sample(ccfb_pda_struct, in_slice[i]);
				break;
			}
			case AUDIO_INPUT_MODE_SNAC:
			{
				monophonic_pitch_detection_accept_slice(in_slice, inNumberFrames);
				break;
			}
			case AUDIO_INPUT_MODE_OFF:
			{
				break;
			}
//			case AUDIO_INPUT_MODE_EFFECTS:
//			{
//				break;
//			}
		}
	}
	if(!should_break_ears)	SilenceData(ioData);
	else	for(UInt32 i = 1; i < ioData->mNumberBuffers; i++)	memcpy(ioData->mBuffers[i].mData, ioData->mBuffers[0].mData, ioData->mBuffers[i].mDataByteSize);
	return err;
}
-(void)init_helper
{
	tuner_view = NULL;
	inputProc.inputProc = PerformThru;
	inputProc.inputProcRefCon = self;
	
	UInt32 size;
	
	try
	{
		//initialize audio session
		XThrowIfError(AudioSessionInitialize(NULL, NULL, rioInterruptionListener, self), "couldn't initialize audio session");
		
		//set audio category (do some special shit for retarded iPod touch... later...)
		UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory), "couldn't set audio category");
		
		//set property listener
		XThrowIfError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, propListener, self), "couldn't set property listener");
		
		//route output to ringer on iPhone
		UInt32 doChangeDefaultRoute = 1;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(doChangeDefaultRoute), &doChangeDefaultRoute), "couldn't reroute output to ringer");
		
		//determine optimal sample rate
		Float64 preferred_sample_rate;
		if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
		{
			pitch_detection_context = make_pitch_detection_context(44100.0, A4_in_Hz);
			preferred_sample_rate = 44100.0;
		}
		else
		{
			pitch_detection_context = make_pitch_detection_context(22050.0, A4_in_Hz);
			preferred_sample_rate = 22050.0;
		}
		
		//set preferred sample rate
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(preferred_sample_rate), &preferred_sample_rate), "couldn't set preferred hardware sample rate");

		//set minimum latency
		Float32 preferredBufferSize;
		if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)	preferredBufferSize = 0.005;
		else														preferredBufferSize = 0.01;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize), "couldn't set i/o buffer duration");
		
		//activate audio session
		XThrowIfError(AudioSessionSetActive(true), "couldn't set audio session active\n");

		//query sample rate
		Float64 reported_sample_rate;
		size = sizeof(reported_sample_rate);
		XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &reported_sample_rate), "couldn't get hw sample rate");
		NSLog(@"hardware sample rate: %f", reported_sample_rate);
		hwSampleRate = reported_sample_rate;
		
		
		//set up remote io unit
		XThrowIfError(SetupRemoteIO(rioUnit, inputProc, thruFormat), "couldn't setup remote io unit");
		
		unitHasBeenCreated = YES;
		
		//query hardware blabla maxFPS
		
		//start remote io unit
		XThrowIfError(AudioOutputUnitStart(rioUnit), "couldn't start remote io unit");
		
		//query audio stream format
		size = sizeof(thruFormat);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &thruFormat, &size), "couldn't get the remote io unit's output client format");
		
		unitIsRunning = YES;
	}
	catch(CAXException& e)
	{
		char buf[256];
		NSLog(@"Error: %s (%s)", e.mOperation, e.FormatError(buf));
		unitIsRunning = NO;
	}
	catch(...)
	{
		NSLog(@"An unknown error occurred lol");
		unitIsRunning = NO;
	}
}
-(id)init
{
	if(self = [super init])
	{
		[self init_helper];
		[self setup_analysis];
	}
	return self;
}
-(void)setup_analysis
{
	audio_input_mode = AUDIO_INPUT_MODE_OFF;
	setup_monophonic_pitch_detection(pitch_detection_context, self, 0);
	setup_stroboscopic_tuner(pitch_detection_context, 0, tuner_low_octave);
//	ppda_struct = make_ppda_struct(pitch_detection_context, 5, 5);
//	ppda_struct = make_ppda_struct(pitch_detection_context, 4, 5);
	ppda_struct = make_ppda_struct(pitch_detection_context, 4, 4);
	ccfb_pda_struct = NULL;
	analysis_ready = true;
}
-(void)set_strobe_texture:(GLuint)st
{
	strobe_texture = st;
	monophonic_pitch_detection_set_texture(st);
	stroboscopic_tuner_set_texture(st);
}
-(void)draw_simple_tuner
{
	monophonic_pitch_detection_draw();

/*
	glDisableClientState(GL_TEXTURE_COORD_ARRAY);
	glDisable(GL_TEXTURE_2D);
	int winning_needle = -1;
	double norm = 0.0;
	double lo_norm = 0.0;
	double needle_vals[num_needle_wheels];
	for(int i = 0; i < num_needle_wheels; i++)
	{
		double this_val = needles[i].cos_grand_sum * needles[i].cos_grand_sum + needles[i].sin_grand_sum * needles[i].sin_grand_sum;
		if(i == 0 || norm < this_val)
		{
			norm = this_val;
		}
		if(i == 0 || this_val < lo_norm)
		{
			lo_norm = this_val;
		}
		needle_vals[i] = this_val;
	}
	if(norm > 0.0)	for(int i = 0; i < num_needle_wheels; i++)
	{
		double this_val = needle_vals[i];
		this_val /= 255 * norm;
//			this_val /= 255 * (norm - lo_norm);
//			glVertexPointer(2, GL_FLOAT, 0, &(SNAC_meter_verts[8 * i]));
		glVertexPointer(2, GL_FLOAT, 0, &(SNAC_meter_verts_Phone[8 * i]));
		glColor4f(this_val * SNAC_meter_on_colors[32 * i], this_val * SNAC_meter_on_colors[32 * i + 1], this_val * SNAC_meter_on_colors[32 * i + 2], 1.0);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	if(SNAC_found_pitch)
	{
		glEnable(GL_BLEND);
		glBlendFunc(GL_ONE, GL_ONE);
		glEnableClientState(GL_TEXTURE_COORD_ARRAY);
		glDisableClientState(GL_COLOR_ARRAY);
		glEnable(GL_TEXTURE);
		glEnable(GL_TEXTURE_2D);
		glBindTexture(GL_TEXTURE_2D, strobe_texture);
		float neg_2_pow = 1.0;
		const float row_spacing = 48;
		float normed_starting_height = 0.0234375;
		for(int j = 0; j < SNAC_num_wheel_rows; j++)
		{
			for(int i = 0; i < SNAC_phase_buf_len; i++)
			{
				GLfloat this_row_verts[] =
				{
					-160, 232 - row_spacing * j,
					-160, 232 - row_spacing * (j + 1),
					160, 232 - row_spacing * j,
					160, 232 - row_spacing * (j + 1),
				};
				float phase_offset = 1.0 - neg_2_pow * M_1_PI * SNAC_phase_buf[(SNAC_phase_buf_idx + i) % SNAC_phase_buf_len][j];
//					float phase_offset = 1.0 + M_1_PI * SNAC_phase_buf[(SNAC_phase_buf_idx + i) % SNAC_phase_buf_len][j];
				GLfloat this_row_tex_coords[] =
				{
					normed_starting_height, phase_offset,
					normed_starting_height + 0.1953125, phase_offset,
					normed_starting_height, 1.0 + phase_offset,
					normed_starting_height + 0.1953125, 1.0 + phase_offset,
				};
				glVertexPointer(2, GL_FLOAT, 0, this_row_verts);
				glTexCoordPointer(2, GL_FLOAT, 0, this_row_tex_coords);
				double color_coeff = (i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len;
//				glColor4f(color_coeff * simple_r, color_coeff * simple_g, color_coeff * simple_g, color_coeff);
				glColor4f((i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len, 0, 0, (i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len);
				glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
			}
			normed_starting_height += 0.1953125;
			neg_2_pow *= 0.5;
		}
	}
	if(tuner_view)	[tuner_view set_has_pitch:SNAC_found_pitch with_note:SNAC_note];
*/
	
}
-(void)draw_tuner
{
	stroboscopic_tuner_draw();
/*
	if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {

		glEnableClientState(GL_COLOR_ARRAY);
		for(int i = 0; i < 12; i++)//MAGIC NUMBER ALERT!!! (WHITE MAGIC)
		{
			glPushMatrix();
			glLoadIdentity();
//			glTranslatef(-283 + 161 * (i / 6), -444 + 152 * (i % 6), 0);
			glTranslatef(-110 + 161 * (i / 6), -444 + 152 * (i % 6), 0);
			draw_strobe_wheel_Pad(strobe_wheels[i]);
			reprime_strobe_wheel(strobe_wheels[i]);
			glPopMatrix();
		}
	}
	else
	{
		glEnableClientState(GL_COLOR_ARRAY);
		for(int i = 0; i < 12; i++)
		{
			glPushMatrix();
			glLoadIdentity();
			glTranslatef(-152 + 104 * (i % 3), 232 - 108 * (i / 3), 0);
			//		glTranslatef(-152 + 80 * (i % 4), 168 - 80 * (i / 4), 0);
			glRotatef(90, 0, 0, -1);
			draw_strobe_wheel_phone(strobe_wheels[i]);
			reprime_strobe_wheel(strobe_wheels[i]);
			glPopMatrix();
		}
	}
*/
}


-(void)draw_simple_tuner_Portrait
{
}

-(void)draw_simple_tuner_PortraitUpsideDown
{
}

-(void)draw_simple_tuner_LandscapeLeft
{
	glPushMatrix();
	glScalef(-1.0, -1.0, 1.0);
	monophonic_pitch_detection_draw();
	glPopMatrix();

/*
//	NSLog(@"simple ll");
	glScalef(-1.0, -1.0, 1.0);
	glDisableClientState(GL_TEXTURE_COORD_ARRAY);
	glDisable(GL_TEXTURE_2D);
	double norm = 0.0;
	double lo_norm = 0.0;
	double needle_vals[num_needle_wheels];
	for(int i = 0; i < num_needle_wheels; i++)
	{
		double this_val = needles[i].cos_grand_sum * needles[i].cos_grand_sum + needles[i].sin_grand_sum * needles[i].sin_grand_sum;
		if(i == 0 || norm < this_val)
		{
			norm = this_val;
		}
		if(i == 0 || this_val < lo_norm)
		{
			lo_norm = this_val;
		}
		needle_vals[i] = this_val;
	}
	if(norm > 0.0)	for(int i = 0; i < num_needle_wheels; i++)
	{
		double this_val = needles[i].cos_grand_sum * needles[i].cos_grand_sum + needles[i].sin_grand_sum * needles[i].sin_grand_sum;
		this_val /= 255 * (norm - lo_norm);
		glVertexPointer(2, GL_FLOAT, 0, &(SNAC_meter_verts[8 * i]));
		glColor4f(this_val * SNAC_meter_on_colors[32 * i], this_val * SNAC_meter_on_colors[32 * i + 1], this_val * SNAC_meter_on_colors[32 * i + 2], 1.0);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	if(SNAC_found_pitch)
	{
		glEnable(GL_BLEND);
		glBlendFunc(GL_ONE, GL_ONE);
		glEnableClientState(GL_TEXTURE_COORD_ARRAY);
		glDisableClientState(GL_COLOR_ARRAY);
		glEnable(GL_TEXTURE);
		glEnable(GL_TEXTURE_2D);
		glBindTexture(GL_TEXTURE_2D, strobe_texture);
		float neg_2_pow = 1.0;
		const float row_spacing = 82;
		float normed_starting_height = 0.015625;
		for(int j = 0; j < SNAC_num_wheel_rows; j++)
		{
			for(int i = 0; i < SNAC_phase_buf_len; i++)
			{
				GLfloat this_row_verts[] =
				{
					-167 + row_spacing * j, -69,
					-167 + row_spacing * (j + 1), -69,
					-167 + row_spacing * j, 443,
					-167 + row_spacing * (j + 1), 443,
				};
				float phase_offset = 1.0 - neg_2_pow * M_1_PI * SNAC_phase_buf[(SNAC_phase_buf_idx + i) % SNAC_phase_buf_len][j];
				GLfloat this_row_tex_coords[] =
				{
					normed_starting_height, phase_offset,
					normed_starting_height + 0.16470588235294117, phase_offset,
					normed_starting_height, 1.0 + phase_offset,
					normed_starting_height + 0.16470588235294117, 1.0 + phase_offset,
				};
				glVertexPointer(2, GL_FLOAT, 0, this_row_verts);
				glTexCoordPointer(2, GL_FLOAT, 0, this_row_tex_coords);
				glColor4f((i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len, 0, 0, (i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len);
				glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
			}
			normed_starting_height += 0.16470588235294117;
			neg_2_pow *= 0.5;
		}
	}
	if(tuner_view)	[tuner_view set_has_pitch:SNAC_found_pitch with_note:SNAC_note];
*/
}

-(void)draw_simple_tuner_LandscapeRight
{
	monophonic_pitch_detection_draw();

/*
//	NSLog(@"simple lr");
	glDisableClientState(GL_TEXTURE_COORD_ARRAY);
	glDisable(GL_TEXTURE_2D);
	double norm = 0.0;
	double lo_norm = 0.0;
	double needle_vals[num_needle_wheels];
	for(int i = 0; i < num_needle_wheels; i++)
	{
		double this_val = needles[i].cos_grand_sum * needles[i].cos_grand_sum + needles[i].sin_grand_sum * needles[i].sin_grand_sum;
		if(i == 0 || norm < this_val)
		{
			norm = this_val;
		}
		if(i == 0 || this_val < lo_norm)
		{
			lo_norm = this_val;
		}
		needle_vals[i] = this_val;
	}
	if(norm > 0.0)	for(int i = 0; i < num_needle_wheels; i++)
	{
		double this_val = needles[i].cos_grand_sum * needles[i].cos_grand_sum + needles[i].sin_grand_sum * needles[i].sin_grand_sum;
		this_val /= 255 * (norm - lo_norm);
		glVertexPointer(2, GL_FLOAT, 0, &(SNAC_meter_verts[8 * i]));
		glColor4f(this_val * SNAC_meter_on_colors[32 * i], this_val * SNAC_meter_on_colors[32 * i + 1], this_val * SNAC_meter_on_colors[32 * i + 2], 1.0);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	if(SNAC_found_pitch)
	{
		glEnable(GL_BLEND);
		glBlendFunc(GL_ONE, GL_ONE);
		glEnableClientState(GL_TEXTURE_COORD_ARRAY);
		glDisableClientState(GL_COLOR_ARRAY);
		glEnable(GL_TEXTURE);
		glEnable(GL_TEXTURE_2D);
		glBindTexture(GL_TEXTURE_2D, strobe_texture);
		float neg_2_pow = 1.0;
		const float row_spacing = 82;
		float normed_starting_height = 0.015625;
		for(int j = 0; j < SNAC_num_wheel_rows; j++)
		{
			for(int i = 0; i < SNAC_phase_buf_len; i++)
			{
				GLfloat this_row_verts[] =
				{
					-167 + row_spacing * j, -69,
					-167 + row_spacing * (j + 1), -69,
					-167 + row_spacing * j, 443,
					-167 + row_spacing * (j + 1), 443,
				};
				float phase_offset = 1.0 - neg_2_pow * M_1_PI * SNAC_phase_buf[(SNAC_phase_buf_idx + i) % SNAC_phase_buf_len][j];
				GLfloat this_row_tex_coords[] =
				{
					normed_starting_height, phase_offset,
					normed_starting_height + 0.16470588235294117, phase_offset,
					normed_starting_height, 1.0 + phase_offset,
					normed_starting_height + 0.16470588235294117, 1.0 + phase_offset,
				};
				glVertexPointer(2, GL_FLOAT, 0, this_row_verts);
				glTexCoordPointer(2, GL_FLOAT, 0, this_row_tex_coords);
				glColor4f((i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len, 0, 0, (i + 1.0) / SNAC_phase_buf_len / SNAC_phase_buf_len);
				glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
			}
			normed_starting_height += 0.16470588235294117;
			neg_2_pow *= 0.5;
		}
	}
	if(tuner_view)	[tuner_view set_has_pitch:SNAC_found_pitch with_note:SNAC_note];
*/
}

-(void)draw_tuner_Portrait
{
}

-(void)draw_tuner_PortraitUpsideDown
{
}

-(void)draw_tuner_LandscapeLeft
{
	glPushMatrix();
	glScalef(-1.0f, -1.0f, 1.0f);
	stroboscopic_tuner_draw();
	glPopMatrix();
/*
	glEnableClientState(GL_COLOR_ARRAY);
	for(int i = 0; i < 12; i++)
	{
		glPushMatrix();
		glLoadIdentity();
		//glTranslatef by whatever
		glScalef(-1, -1, 1);
		glTranslatef(-110 + 161 * (i / 6), -444 + 152 * (i % 6), 0);
//			glTranslatef(110 - 161 * (i / 6), 444 - 152 * (i % 6), 0);
		draw_strobe_wheel_Pad(strobe_wheels[i]);
		reprime_strobe_wheel(strobe_wheels[i]);
		glPopMatrix();
	}
	return;
*/
}

-(void)draw_tuner_LandscapeRight
{
	stroboscopic_tuner_draw();
/*
	glEnableClientState(GL_COLOR_ARRAY);
	for(int i = 0; i < 12; i++)//MAGIC NUMBER ALERT!!! (WHITE MAGIC)
	{
		glPushMatrix();
		glLoadIdentity();
//			glTranslatef(-283 + 161 * (i / 6), -444 + 152 * (i % 6), 0);
		//glTranslatef to the correct position (with the new artwork)
		glTranslatef(-110 + 161 * (i / 6), -444 + 152 * (i % 6), 0);
		draw_strobe_wheel_Pad(strobe_wheels[i]);
		reprime_strobe_wheel(strobe_wheels[i]);
		glPopMatrix();
	}
	return;
*/
}

-(bool)is_tuner	{	return audio_input_mode == AUDIO_INPUT_MODE_TUNER;	}

-(void)configure_ppda_with_low_note:(int)n
{
	//NSLog(@"configuring with %d", n);
//	configure_ppda(n);
	ppda_low_note = n;
	if(ccfb_pda_struct)
	{
		CCFB_PITCH_DETECTION_ALGO_STRUCT* temp = ccfb_pda_struct;
		ccfb_pda_struct = NULL;
		destroy_ccfb_ppda_struct(temp);
	}
	ccfb_pda_struct = make_ccfb_ppda_struct(n, ppda_struct, ppda_filter_coefficient);
}

-(void)switch_to_last_tuner_mode
{
	audio_input_mode = using_simple_tuner ? AUDIO_INPUT_MODE_SNAC : AUDIO_INPUT_MODE_TUNER;
}

-(void)switch_to_tuner:(bool)to_tuner
{
	audio_input_mode = to_tuner ? (using_simple_tuner ? AUDIO_INPUT_MODE_SNAC : AUDIO_INPUT_MODE_TUNER) : AUDIO_INPUT_MODE_PPDA;
}

-(void)set_audio_input_mode:(AUDIO_INPUT_MODE)aim
{
	audio_input_mode = aim;
}

-(void)accept_A4_in_Hz:(double)A4
{
	A4_in_Hz = A4;
	pitch_detection_context->A4_in_Hz = A4_in_Hz;
	monophonic_pitch_detection_pdc_updated();
	stroboscopic_tuner_pdc_updated();
	ccfb_ppda_pdc_updated();
}
-(void)accept_starting_octave:(int)starting_octave
{
	tuner_low_octave = starting_octave;
	stroboscopic_tuner_set_octave(tuner_low_octave);
}

-(void)set_throughput:(bool)bleeding_ears
{
	should_break_ears = bleeding_ears;
}

-(void)set_tuner_mode:(bool)is_simple
{
	audio_input_mode = is_simple ? AUDIO_INPUT_MODE_SNAC : AUDIO_INPUT_MODE_TUNER;
	using_simple_tuner = is_simple;
}

-(void)shut_off_pda
{
	audio_input_mode = AUDIO_INPUT_MODE_OFF;
}

-(void)accept_TunerView:(id)tv
{
	tuner_view = tv;
}

// CL: warning silence
- (void)set_aux_texture:(GLuint)at{}

//
-(void)accept_note:(int)n
{
	if(tuner_view)
	{
		[tuner_view set_has_pitch:true with_note:n];
	}
}

-(void)accept_no_note
{
	if(tuner_view)
	{
		[tuner_view set_has_pitch:false with_note:420];
	}
}

-(void)compute_goodnesses:(double*)p_goodnesses for_notes:(int*)p_notes_in_semitones_from_middle_C num_notes:(int)num_notes
{
	ccfb_ppda_detect_pitches(ccfb_pda_struct, p_goodnesses, p_notes_in_semitones_from_middle_C, num_notes);
}

-(void)set_notes:(double*)notes num_notes:(int)num_notes
{
	
}

@end

NSString* non_enharmonic_pitch_class_name(int pitch_class)
{
	switch(pitch_class)
	{
		case 0:		return @"C";
		case 1:		return @"C♯";
		case 2:		return @"D";
		case 3:		return @"E♭";
		case 4:		return @"E";
		case 5:		return @"F";
		case 6:		return @"F♯";
		case 7:		return @"G";
		case 8:		return @"A♭";
		case 9:		return @"A";
		case 10:	return @"B♭";
		case 11:	return @"B";
	}
	return @"";
}

