// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <WebRTC/RTCAudioDevice.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppAudioDevice : NSObject <RTCAudioDevice>

- (BOOL)pushSampleBuffer:(CMSampleBufferRef)sampleBuffer NS_SWIFT_NAME(push(sampleBuffer:));
- (void)reset;

@property(nonatomic, readonly) uint64_t receivedAudioFrames;
@property(nonatomic, readonly) uint64_t rejectedAudioBuffers;
@property(nonatomic, readonly) uint64_t droppedAudioFrames;
@property(nonatomic, readonly) uint64_t silentAudioFrames;
@property(nonatomic, readonly) OSStatus lastRejectedAudioStatus;
@property(nonatomic, readonly, copy) NSString *lastAudioRejectionReason;

@end

NS_ASSUME_NONNULL_END
