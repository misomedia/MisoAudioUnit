//
//  AudioOutput.m
//  Miso Music InstrumentView Test
//
//  Created by Ryan Hiroaki Tsukamoto on 2/28/11.
//  Copyright 2011 Miso Media Inc. All rights reserved.
//

#import "AudioOutput.h"

ALvoid  alBufferDataStaticProc(const ALint bid, ALenum format, ALvoid* data, ALsizei size, ALsizei freq)
{
	static	alBufferDataStaticProcPtr	proc = NULL;
    if (proc == NULL)	proc = (alBufferDataStaticProcPtr) alcGetProcAddress(NULL, (const ALCchar*) "alBufferData");
//    if (proc == NULL)	proc = (alBufferDataStaticProcPtr) alcGetProcAddress(NULL, (const ALCchar*) "alBufferDataStatic");
    if (proc)	proc(bid, format, data, size, freq);
}

void* MyGetOpenALAudioData(CFURLRef inFileURL, ALsizei *outDataSize, ALenum *outDataFormat, ALsizei* outSampleRate)
{
	OSStatus						err = noErr;	
	SInt64							theFileLengthInFrames = 0;
	AudioStreamBasicDescription		theFileFormat;
	UInt32							thePropertySize = sizeof(theFileFormat);
	ExtAudioFileRef					extRef = NULL;
	void*							theData = NULL;
	AudioStreamBasicDescription		theOutputFormat;
	UInt32		dataSize;
	err = ExtAudioFileOpenURL(inFileURL, &extRef);
	if(err) { printf("MyGetOpenALAudioData: ExtAudioFileOpenURL FAILED, Error = %ld\n", err); goto Exit; }
	err = ExtAudioFileGetProperty(extRef, kExtAudioFileProperty_FileDataFormat, &thePropertySize, &theFileFormat);
	if(err) { printf("MyGetOpenALAudioData: ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat) FAILED, Error = %ld\n", err); goto Exit; }
	if (theFileFormat.mChannelsPerFrame > 2)  { printf("MyGetOpenALAudioData - Unsupported Format, channel count is greater than stereo\n"); goto Exit;}
	theOutputFormat.mSampleRate = theFileFormat.mSampleRate;
	theOutputFormat.mChannelsPerFrame = theFileFormat.mChannelsPerFrame;
	theOutputFormat.mFormatID = kAudioFormatLinearPCM;
	theOutputFormat.mBytesPerPacket = 2 * theOutputFormat.mChannelsPerFrame;
	theOutputFormat.mFramesPerPacket = 1;
	theOutputFormat.mBytesPerFrame = 2 * theOutputFormat.mChannelsPerFrame;
	theOutputFormat.mBitsPerChannel = 16;
	theOutputFormat.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger;
	err = ExtAudioFileSetProperty(extRef, kExtAudioFileProperty_ClientDataFormat, sizeof(theOutputFormat), &theOutputFormat);
	if(err) { printf("MyGetOpenALAudioData: ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat) FAILED, Error = %ld\n", err); goto Exit; }
	thePropertySize = sizeof(theFileLengthInFrames);
	err = ExtAudioFileGetProperty(extRef, kExtAudioFileProperty_FileLengthFrames, &thePropertySize, &theFileLengthInFrames);
	if(err) { printf("MyGetOpenALAudioData: ExtAudioFileGetProperty(kExtAudioFileProperty_FileLengthFrames) FAILED, Error = %ld\n", err); goto Exit; }
	dataSize = theFileLengthInFrames * theOutputFormat.mBytesPerFrame;
	//UInt32	dataSize = theFileLengthInFrames * theOutputFormat.mBytesPerFrame;
	theData = malloc(dataSize);
	if (theData)
	{
		AudioBufferList		theDataBuffer;
		theDataBuffer.mNumberBuffers = 1;
		theDataBuffer.mBuffers[0].mDataByteSize = dataSize;
		theDataBuffer.mBuffers[0].mNumberChannels = theOutputFormat.mChannelsPerFrame;
		theDataBuffer.mBuffers[0].mData = theData;
		err = ExtAudioFileRead(extRef, (UInt32*)&theFileLengthInFrames, &theDataBuffer);
		if(err == noErr)
		{
			*outDataSize = (ALsizei)dataSize;
			*outDataFormat = (theOutputFormat.mChannelsPerFrame > 1) ? AL_FORMAT_STEREO16 : AL_FORMAT_MONO16;
			*outSampleRate = (ALsizei)theOutputFormat.mSampleRate;
		}
		else 
		{ 
			free (theData);
			theData = NULL;
			printf("MyGetOpenALAudioData: ExtAudioFileRead FAILED, Error = %ld\n", err); goto Exit;
		}	
	}
Exit:
	if (extRef) ExtAudioFileDispose(extRef);
	return theData;
}

@implementation AudioOutput

@synthesize isPlaying = _isPlaying;
@synthesize wasInterrupted = _wasInterrupted;
@synthesize listenerRotation = _listenerRotation;
@synthesize _sources;
@synthesize _sourcePos;

void interruptionListener(void* inClientData, UInt32 inInterruptionState)
{
	AudioOutput *THIS = (AudioOutput*)inClientData;
	if (inInterruptionState == kAudioSessionBeginInterruption)
	{
		[THIS destroy_OpenAL];
		if ([THIS isPlaying]) {
			THIS->_wasInterrupted = YES;
			THIS->_isPlaying = NO;
		}
	}
	else if (inInterruptionState == kAudioSessionEndInterruption)
	{
		OSStatus result = AudioSessionSetActive(true);
		if (result) printf("Error setting audio session active! %ld\n", result);
		[THIS init_OpenAL];
		if (THIS->_wasInterrupted)
		{
			THIS->_wasInterrupted = NO;
		}
	}
}

-(id)init_with_instrument:(MM_INSTRUMENT*)p_i
{
	if(self = [super init])
	{
		p_instrument = p_i;
		num_strings = mm_instrument_type(p_i->instrument_type_idx).num_courses;
		_buffers = (ALuint*)malloc(sizeof(ALuint) * num_strings);
		_sources = (ALuint*)malloc(sizeof(ALuint) * num_strings * 2);
		_sourcePos = CGPointMake(0., 0.);
		_listenerPos = CGPointMake(0., 0.);
		_listenerRotation = 0.;
		_wasInterrupted = NO;
		[self init_OpenAL];

	}
	return self;
}

-(void)dealloc
{
	[self destroy_OpenAL];
	[super dealloc];
}

-(void)initBuffer
{
	//ALenum  error = AL_NO_ERROR;
	ALenum  format;
	ALsizei size;
	ALsizei freq;

	for(int i = 0; i < num_strings; i++)
	{
		NSString*		file_path = [[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"%@_%@_open_string_%d", p_instrument->instrument_maker, p_instrument->instrument_name, i] ofType:@"wav"];
		if(!file_path)	file_path = [NSString stringWithFormat:@"%@/%@_%@_open_string_%d.wav", p_instrument->instrument_sound_path, p_instrument->instrument_maker, p_instrument->instrument_name, i];
		CFURLRef		fileURL = (CFURLRef)[[NSURL fileURLWithPath:file_path] retain];
		if(!fileURL)
		{
		}
		_data = MyGetOpenALAudioData(fileURL, &size, &format, &freq);
		CFRelease(fileURL);
		alBufferDataStaticProc(_buffers[i], format, _data, size, freq);
		if(_data)	free(_data);
	}
}

-(void)initSource
{
	ALenum error = AL_NO_ERROR;
	alGetError(); // Clear the error
	float sourcePosAL[] = {_sourcePos.x, _sourcePos.y, kDefaultDistance};
	for(int i = 0; i < num_strings * 2; i++)
	{
		alSourcefv(_sources[i], AL_POSITION, sourcePosAL);
		alSourcef(_sources[i], AL_REFERENCE_DISTANCE, 1024.0f);
		alSourcei(_sources[i], AL_BUFFER, _buffers[1]);
		alSourcef(_sources[i], AL_GAIN, 1.0f);
		alSourcef(_sources[i], AL_MAX_DISTANCE, 4096.0f);
	}
	if((error = alGetError()) != AL_NO_ERROR)
	{
		printf("Error attaching buffer to source: %x\n", error);
		exit(1);
	}	
	alListenerf(AL_GAIN, 1.0);
}

-(void)init_OpenAL
{
	ALenum			error;
	ALCcontext		*newContext = NULL;
	ALCdevice		*newDevice = NULL;
	newDevice = alcOpenDevice(NULL);
	if (newDevice != NULL)
	{
		newContext = alcCreateContext(newDevice, 0);
		if (newContext != NULL)
		{
			alcMakeContextCurrent(newContext);
			alGenBuffers(num_strings, &(_buffers[0]));
			if((error = alGetError()) != AL_NO_ERROR)
			{
				printf("Error Generating Buffers: %x", error);
				exit(1);
			}
			alGenSources(num_strings * 2, &(_sources[0]));
			if(alGetError() != AL_NO_ERROR) 
			{
				printf("Error generating sources! %x\n", error);
				exit(1);
			}
			alGenBuffers(1, &_tutorial_buffer);
			if((error = alGetError()) != AL_NO_ERROR)
			{
				exit(1);
			}
			alGenSources(1, &_tutorial_source);
			if((error = alGetError()) != AL_NO_ERROR)
			{
				exit(1);
			}
		}
	}
	alGetError();
	[self initBuffer];	
	[self initSource];
}

-(void)destroy_OpenAL
{
	//NSLog(@"tearing down OpenAL");
    ALCcontext	*context = NULL;
    ALCdevice	*device = NULL;
	int error_num = alGetError();
	if(error_num != AL_NO_ERROR)	NSLog(@"we were doomed anyway...");
    alDeleteSources(2 * num_strings, &(_sources[0]));
	error_num = alGetError();
	if(error_num == AL_NO_ERROR)	NSLog(@"Deleted sources without any errors!");
	else							NSLog(@"AAAAAH IT'S THE END OF THE WORLD!!");
    alDeleteBuffers(num_strings, &(_buffers[0]));
     error_num = alGetError();
	if(error_num == AL_NO_ERROR)	NSLog(@"Deleted buffers without any errors!");
	else							NSLog(@"AAAAAH IT'S THE END OF THE WORLD!!");
	context = alcGetCurrentContext();
    device = alcGetContextsDevice(context);
    alcDestroyContext(context);
    alcCloseDevice(device);
}

-(CGPoint)sourcePos
{
	return _sourcePos;
}

-(void)setSourcePos:(CGPoint)SOURCEPOS
{
	_sourcePos = SOURCEPOS;
	float sourcePosAL[] = {_sourcePos.x, _sourcePos.y, kDefaultDistance};
	alSourcefv(_sources[0], AL_POSITION, sourcePosAL);
}

-(CGPoint)listenerPos
{
	return _listenerPos;
}

-(void)setListenerPos:(CGPoint)LISTENERPOS
{
	_listenerPos = LISTENERPOS;
	float listenerPosAL[] = {_listenerPos.x, _listenerPos.y, 0.};
	alListenerfv(AL_POSITION, listenerPosAL);
}

-(CGFloat)listenerRotation
{
	return _listenerRotation;
}

-(void)setListenerRotation:(CGFloat)radians
{
	_listenerRotation = radians;
	float ori[] = {cos(radians + M_PI_2), sin(radians + M_PI_2), 0., 0., 0., 1.};
	alListenerfv(AL_ORIENTATION, ori);
}

-(void)playString:(int)s andFret:(int)f
{
	ALint state;
	alGetSourcei(_sources[s], AL_SOURCE_STATE, &state);
	if(state == AL_PLAYING)
	{
		alSourceStop(_sources[s]);
	}
	alSourcei(_sources[s], AL_BUFFER, _buffers[s % num_strings]);
	float qx, qy, qz;
	alGetSource3f(_sources[s], AL_POSITION, &qx, &qy, &qz);


//-(void)play_string:(int)s fret:(int)f harmonic:(int)h
//{
//	[self play_string:s fret:f];
//	float mag = sqrtf(oal_playback._sourcePos.x * oal_playback._sourcePos.x + oal_playback._sourcePos.y * oal_playback._sourcePos.y + kDefaultDistance * kDefaultDistance);
//	float v = 343.3 * (1.0 - 1.0 / h);
//	alSource3f(oal_playback._sources[s], AL_VELOCITY, -v * oal_playback._sourcePos.x / mag, -v * oal_playback._sourcePos.y / mag, -v * kDefaultDistance / mag);
//}

	float h = pow(2.0, f / 12.0);
	float mag = sqrtf(qx * qx + qy * qy + qz * qz);
	float v = 343.3 * (1.0 - 1.0 / h);
	alSource3f(_sources[s], AL_VELOCITY, -v * qx / mag, -v * qy / mag, -v * qz / mag);

	alSourcePlay(_sources[s]);
}

-(bool)isStringPlaying:(int)s
{
	ALint state;
	alGetSourcei(_sources[s], AL_SOURCE_STATE, &state);
	return state == AL_PLAYING;
}

-(bool)tutorial_playing							//is the tutorial playing?
{
	ALint s;
	alGetSourcei(_tutorial_source, AL_SOURCE_STATE, &s);
	return s == AL_PLAYING;
}
-(void)play_tutorial							//do this to play the sound we want.
{
	ALint s;
	alGetSourcei(_tutorial_source, AL_SOURCE_STATE, &s);
	if(s == AL_PLAYING)
	{
		alSourceStop(_tutorial_source);
	}
	alSourcei(_tutorial_source, AL_BUFFER, _tutorial_buffer);
	alSourcePlay(_tutorial_source);
}
-(void)stop_tutorial
{
	alSourceStop(_tutorial_source);
}
-(void)play_intro_tutorial:(int)n
{
	ALenum e;
	if([self tutorial_playing])	[self stop_tutorial];
	alDeleteSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial source");
	alDeleteBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial buffer");
	
	alGenBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	alGenSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	
	ALenum format;
	ALsizei size;
	ALsizei freq;
	NSString* file_path = [[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"tutorial_intro_%d", n] ofType:@"wav"];
	CFURLRef fileURL = (CFURLRef)[[NSURL fileURLWithPath:file_path] retain];
	if(!fileURL)	NSLog(@"WTF!!!");
	_data = MyGetOpenALAudioData(fileURL, &size, &format, &freq);
	CFRelease(fileURL);
	alBufferDataStaticProc(_tutorial_buffer, format, _data, size, freq);
	if(_data)	free(_data);
	
	float sourcePosAL[] = {0, 0, 0};
	alSourcefv(_tutorial_source, AL_POSITION, sourcePosAL);
	alSourcef(_tutorial_source, AL_REFERENCE_DISTANCE, 1024.0f);
	alSourcei(_tutorial_source, AL_BUFFER, _tutorial_buffer);
	alSourcef(_tutorial_source, AL_GAIN, 1.0f);
	alSourcef(_tutorial_source, AL_MAX_DISTANCE, 4096.0f);
	if((e = alGetError()) != AL_NO_ERROR)
	{
	}
	alListenerf(AL_GAIN, 1.0);
	[self play_tutorial];
}
-(void)play_virtual_instrument_tutorial:(int)n	//(safely) loads and plays the nth sound byte for the virtual instrument tutorial 
{
	ALenum e;
	if([self tutorial_playing])	[self stop_tutorial];
	alDeleteSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial source");
	alDeleteBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial buffer");
	
	alGenBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	alGenSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	
	ALenum format;
	ALsizei size;
	ALsizei freq;
	NSString* file_path = [[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"vi_tutorial_%d", n] ofType:@"wav"];
	CFURLRef fileURL = (CFURLRef)[[NSURL fileURLWithPath:file_path] retain];
    if(fileURL)
        _data = MyGetOpenALAudioData(fileURL, &size, &format, &freq);
	CFRelease(fileURL);
	alBufferDataStaticProc(_tutorial_buffer, format, _data, size, freq);
	if(_data)	free(_data);
	
	float sourcePosAL[] = {0, 0, 0};
	alSourcefv(_tutorial_source, AL_POSITION, sourcePosAL);
	alSourcef(_tutorial_source, AL_REFERENCE_DISTANCE, 1024.0f);
	alSourcei(_tutorial_source, AL_BUFFER, _tutorial_buffer);
	alSourcef(_tutorial_source, AL_GAIN, 1.0f);
	alSourcef(_tutorial_source, AL_MAX_DISTANCE, 4096.0f);
	if((e = alGetError()) != AL_NO_ERROR)
	{
	}
	alListenerf(AL_GAIN, 1.0);
	[self play_tutorial];
}
-(void)play_real_instrument_tutorial:(int)n
{
	ALenum e;
	if([self tutorial_playing])	[self stop_tutorial];
	alDeleteSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial source");
	alDeleteBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial buffer");
	
	alGenBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	alGenSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	
	ALenum format;
	ALsizei size;
	ALsizei freq;
	NSString* file_path = [[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"ri_tutorial_%d", n] ofType:@"wav"];
	CFURLRef fileURL = (CFURLRef)[[NSURL fileURLWithPath:file_path] retain];
	if(fileURL)	
        _data = MyGetOpenALAudioData(fileURL, &size, &format, &freq);
	CFRelease(fileURL);
	alBufferDataStaticProc(_tutorial_buffer, format, _data, size, freq);
	if(_data)	free(_data);
	
	float sourcePosAL[] = {0, 0, 0};
	alSourcefv(_tutorial_source, AL_POSITION, sourcePosAL);
	alSourcef(_tutorial_source, AL_REFERENCE_DISTANCE, 1024.0f);
	alSourcei(_tutorial_source, AL_BUFFER, _tutorial_buffer);
	alSourcef(_tutorial_source, AL_GAIN, 1.0f);
	alSourcef(_tutorial_source, AL_MAX_DISTANCE, 4096.0f);
	if((e = alGetError()) != AL_NO_ERROR)
	{
	}
	alListenerf(AL_GAIN, 1.0);
	[self play_tutorial];
}
-(void)play_virtual_instrument_tutorial_step:(VI_TUTORIAL_STEP)vi_t_s
{
	ALenum e;
	if([self tutorial_playing])	[self stop_tutorial];
	alDeleteSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial source");
	alDeleteBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial buffer");
	
	alGenBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	alGenSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	
	ALenum format;
	ALsizei size;
	ALsizei freq;
	NSString* step_string;
	switch(vi_t_s)
	{
		case VI_TUTORIAL_DECIDE_HANDEDNESS:		{	step_string = @"VI_TUTORIAL_DECIDE_HANDEDNESS";		break;	}
		case VI_TUTORIAL_WELCOME_VIDEO:			{	step_string = @"VI_TUTORIAL_WELCOME_VIDEO";			break;	}
		case VI_TUTORIAL_WELCOME_IMAGES:		{	step_string = @"VI_TUTORIAL_WELCOME_IMAGES";		break;	}
		case VI_TUTORIAL_STRUM_OPEN_STRINGS:	{	step_string = @"VI_TUTORIAL_STRUM_OPEN_STRINGS";	break;	}
		case VI_TUTORIAL_FRET:					{	step_string = @"VI_TUTORIAL_FRET";					break;	}
		case VI_TUTORIAL_NOTE:					{	step_string = @"VI_TUTORIAL_NOTE";					break;	}
		case VI_TUTORIAL_BARRE:					{	step_string = @"VI_TUTORIAL_BARRE";					break;	}
		case VI_TUTORIAL_SCROLLING_TABS:		{	step_string = @"VI_TUTORIAL_SCROLLING_TABS";		break;	}
		case VI_TUTORIAL_TAB_0:					{	step_string = @"VI_TUTORIAL_TAB_0";					break;	}
		case VI_TUTORIAL_TAB_1:					{	step_string = @"VI_TUTORIAL_TAB_1";					break;	}
		case VI_TUTORIAL_TAB_2:					{	step_string = @"VI_TUTORIAL_TAB_2";					break;	}
		case VI_TUTORIAL_SHIFT_UP_ipad:			{	step_string = @"VI_TUTORIAL_SHIFT_UP_ipad";			break;	}
		case VI_TUTORIAL_SHIFT_UP_iphone:		{	step_string = @"VI_TUTORIAL_SHIFT_UP_iphone";		break;	}
		case VI_TUTORIAL_TAB_3:					{	step_string = @"VI_TUTORIAL_TAB_3";					break;	}
		case VI_TUTORIAL_SHIFT_DOWN_ipad:		{	step_string = @"VI_TUTORIAL_SHIFT_DOWN_ipad";		break;	}
		case VI_TUTORIAL_SHIFT_DOWN_iphone:		{	step_string = @"VI_TUTORIAL_SHIFT_DOWN_iphone";		break;	}
		case VI_TUTORIAL_TAB_4:					{	step_string = @"VI_TUTORIAL_TAB_4";					break;	}
		case VI_TUTORIAL_TAB_5:					{	step_string = @"VI_TUTORIAL_TAB_5";					break;	}
		case VI_TUTORIAL_TAB_REMAINDER:			{	step_string = @"VI_TUTORIAL_TAB_REMAINDER";			break;	}
		case VI_TUTORIAL_PAUSE:					{	step_string = @"VI_TUTORIAL_PAUSE";					break;	}
		case VI_TUTORIAL_REWIND:				{	step_string = @"VI_TUTORIAL_REWIND";				break;	}
		case VI_TUTORIAL_PLAY:					{	step_string = @"VI_TUTORIAL_PLAY";					break;	}
		case VI_TUTORIAL_OPEN_SETTINGS:			{	step_string = @"VI_TUTORIAL_OPEN_SETTINGS";			break;	}
		case VI_TUTORIAL_SETTINGS:				{	step_string = @"VI_TUTORIAL_SETTINGS";				break;	}
		case VI_TUTORIAL_QUIT:					{	step_string = @"VI_TUTORIAL_QUIT";					break;	}
		case VI_TUTORIAL_DONE:					{	step_string = @"VI_TUTORIAL_DONE";					break;	}
	}
	NSString* file_path = [[NSBundle mainBundle] pathForResource:step_string ofType:@"wav"];
	CFURLRef fileURL = (CFURLRef)[[NSURL fileURLWithPath:file_path] retain];
	if(fileURL)
        _data = MyGetOpenALAudioData(fileURL, &size, &format, &freq);
	CFRelease(fileURL);
	alBufferDataStaticProc(_tutorial_buffer, format, _data, size, freq);
	if(_data)	free(_data);
	
	float sourcePosAL[] = {0, 0, 0};
	alSourcefv(_tutorial_source, AL_POSITION, sourcePosAL);
	alSourcef(_tutorial_source, AL_REFERENCE_DISTANCE, 1024.0f);
	alSourcei(_tutorial_source, AL_BUFFER, _tutorial_buffer);
	alSourcef(_tutorial_source, AL_GAIN, 1.0f);
	alSourcef(_tutorial_source, AL_MAX_DISTANCE, 4096.0f);
	if((e = alGetError()) != AL_NO_ERROR)
	{
	}
	alListenerf(AL_GAIN, 1.0);
	[self play_tutorial];
}
-(void)play_real_instrument_tutorial_step:(RI_TUTORIAL_STEP)ri_t_s
{
	ALenum e;
	if([self tutorial_playing])	[self stop_tutorial];
	alDeleteSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial source");
	alDeleteBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)	NSLog(@"error deleting tutorial buffer");
	
	alGenBuffers(1, &_tutorial_buffer);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	alGenSources(1, &_tutorial_source);
	if((e = alGetError()) != AL_NO_ERROR)
	{
		exit(1);
	}
	
	ALenum format;
	ALsizei size;
	ALsizei freq;
	NSString* step_string;
	switch(ri_t_s)
	{
		case RI_TUTORIAL_OPEN_TUNER:		{	step_string = @"RI_TUTORIAL_OPEN_TUNER";		break;	}
		case RI_TUTORIAL_TUNER_DISABLED:	{	step_string = @"RI_TUTORIAL_TUNER_DISABLED";	break;	}
		case RI_TUTORIAL_TUNER:				{	step_string = @"RI_TUTORIAL_TUNER";				break;	}
		case RI_TUTORIAL_SETTINGS:			{	step_string = @"RI_TUTORIAL_SETTINGS";			break;	}
		case RI_TUTORIAL_CLOSE_SETTINGS:	{	step_string = @"RI_TUTORIAL_CLOSE_SETTINGS";	break;	}
		case RI_TUTORIAL_FINGERING_CHARTS:	{	step_string = @"RI_TUTORIAL_FINGERING_CHARTS";	break;	}
		case RI_TUTORIAL_SCROLLING_TABS:	{	step_string = @"VI_TUTORIAL_SCROLLING_TABS";	break;	}
		case RI_TUTORIAL_TAB_0:				{	step_string = @"RI_TUTORIAL_TAB_0";				break;	}
		case RI_TUTORIAL_TAB_1:				{	step_string = @"VI_TUTORIAL_TAB_1";				break;	}
		case RI_TUTORIAL_TAB_2:				{	step_string = @"VI_TUTORIAL_TAB_2";				break;	}
		case RI_TUTORIAL_TAB_3:				{	step_string = @"VI_TUTORIAL_TAB_4";				break;	}
		case RI_TUTORIAL_TAB_REMAINDER:		{	step_string = @"VI_TUTORIAL_TAB_REMAINDER";		break;	}
		case RI_TUTORIAL_PAUSE:				{	step_string = @"VI_TUTORIAL_PAUSE";				break;	}
		case RI_TUTORIAL_REWIND:			{	step_string = @"VI_TUTORIAL_REWIND";			break;	}
		case RI_TUTORIAL_PLAY:				{	step_string = @"VI_TUTORIAL_PLAY";				break;	}
		case RI_TUTORIAL_OPEN_SETTINGS:		{	step_string = @"VI_TUTORIAL_OPEN_SETTINGS";		break;	}
		case RI_TUTORIAL_QUIT:				{	step_string = @"VI_TUTORIAL_QUIT";				break;	}
		case RI_TUTORIAL_DONE:				{	step_string = @"RI_TUTORIAL_DONE";				break;	}
	}
	NSString* file_path = [[NSBundle mainBundle] pathForResource:step_string ofType:@"wav"];
	CFURLRef fileURL = (CFURLRef)[[NSURL fileURLWithPath:file_path] retain];
	if(fileURL)
        _data = MyGetOpenALAudioData(fileURL, &size, &format, &freq);
	CFRelease(fileURL);
	alBufferDataStaticProc(_tutorial_buffer, format, _data, size, freq);
	if(_data)	free(_data);
	
	float sourcePosAL[] = {0, 0, 0};
	alSourcefv(_tutorial_source, AL_POSITION, sourcePosAL);
	alSourcef(_tutorial_source, AL_REFERENCE_DISTANCE, 1024.0f);
	alSourcei(_tutorial_source, AL_BUFFER, _tutorial_buffer);
	alSourcef(_tutorial_source, AL_GAIN, 1.0f);
	alSourcef(_tutorial_source, AL_MAX_DISTANCE, 4096.0f);
	if((e = alGetError()) != AL_NO_ERROR)
	{
	}
	alListenerf(AL_GAIN, 1.0);
	[self play_tutorial];
}

@end
