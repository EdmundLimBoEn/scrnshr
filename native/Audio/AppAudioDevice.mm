// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
#import "AppAudioDevice.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {
constexpr size_t kChannels = 2;
constexpr size_t kSampleRate = 48000;
constexpr size_t kPacketFrames = 480;
constexpr size_t kCapacityFrames = 4800;
constexpr int64_t kPacketNanoseconds = 10000000;

int64_t FramesToNanoseconds(size_t frames) {
    return static_cast<int64_t>(std::llround(static_cast<double>(frames) * 1000000000.0 / kSampleRate));
}

struct AudioState {
    std::mutex mutex;
    std::condition_variable wake;
    std::thread deliveryThread;
    id<RTCAudioDeviceDelegate> delegate = nil;
    bool initialized = false;
    bool recordingInitialized = false;
    bool playoutInitialized = false;
    bool recording = false;
    bool playing = false;
    bool interrupted = false;
    bool shutdown = false;
    bool timeline = false;
    bool terminating = false;
    bool deliveryInFlight = false;
    std::thread::id callbackThread;
    uint64_t lifecycleGeneration = 0;
    uint64_t interruptionGeneration = 0;
    dispatch_block_t afterDelivery = nil;
    std::array<int16_t, kCapacityFrames * kChannels> ring{};
    size_t head = 0;
    size_t count = 0;
    int64_t headNanoseconds = 0;
    int64_t nextNanoseconds = 0;
    int64_t lastNanoseconds = 0;
    std::atomic<uint64_t> received{0};
    std::atomic<uint64_t> rejected{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<uint64_t> silent{0};

    void resetTimeline() {
        head = 0;
        count = 0;
        headNanoseconds = 0;
        nextNanoseconds = 0;
        timeline = false;
    }

    void discard(size_t frames) {
        head = (head + frames) % kCapacityFrames;
        count -= frames;
        headNanoseconds += FramesToNanoseconds(frames);
    }
};

void WaitForDelivery(AudioState *state, std::unique_lock<std::mutex> &lock) {
    if (state->callbackThread != std::this_thread::get_id()) {
        state->wake.wait(lock, [state] { return !state->deliveryInFlight; });
    }
}

void DeliverAudio(std::shared_ptr<AudioState> state, uint64_t generation) {
    @autoreleasepool {
        [NSThread currentThread].name = @"scrnshr app audio";
    }
    std::unique_lock<std::mutex> lock(state->mutex);
    auto deadline = std::chrono::steady_clock::now();
    while (!state->shutdown && state->lifecycleGeneration == generation) {
        state->wake.wait(lock, [&state, generation] {
            return state->shutdown || state->lifecycleGeneration != generation ||
                (state->recording && !state->interrupted && state->timeline);
        });
        if (state->shutdown || state->lifecycleGeneration != generation) { break; }
        auto now = std::chrono::steady_clock::now();
        if (now > deadline + std::chrono::milliseconds(10)) { deadline = now; }
        deadline += std::chrono::milliseconds(10);
        if (state->wake.wait_until(lock, deadline, [&state, generation] {
                return state->shutdown || state->lifecycleGeneration != generation ||
                    !state->recording || state->interrupted || !state->timeline;
            })) {
            continue;
        }

        int64_t timestamp = std::max(state->nextNanoseconds, state->lastNanoseconds + kPacketNanoseconds);
        if (state->count) {
            timestamp = std::max(timestamp, state->headNanoseconds);
            const int64_t staleNanoseconds = timestamp - state->headNanoseconds;
            if (staleNanoseconds > 100000000) {
                const size_t staleFrames = std::min(state->count,
                    static_cast<size_t>(staleNanoseconds * kSampleRate / 1000000000));
                state->discard(staleFrames);
                state->dropped += staleFrames;
            }
        }
        std::array<int16_t, kPacketFrames * kChannels> packet{};
        const size_t available = std::min(kPacketFrames, state->count);
        for (size_t frame = 0; frame < available; ++frame) {
            const size_t offset = ((state->head + frame) % kCapacityFrames) * kChannels;
            packet[frame * kChannels] = state->ring[offset];
            packet[frame * kChannels + 1] = state->ring[offset + 1];
        }
        state->discard(available);
        state->silent += kPacketFrames - available;
        state->lastNanoseconds = timestamp;
        state->nextNanoseconds = timestamp + kPacketNanoseconds;

        AudioTimeStamp audioTimestamp{};
        audioTimestamp.mHostTime = CMClockConvertHostTimeToSystemUnits(CMTimeMake(timestamp, 1000000000));
        audioTimestamp.mFlags = kAudioTimeStampHostTimeValid;
        AudioUnitRenderActionFlags flags = 0;
        __attribute__((objc_precise_lifetime)) id<RTCAudioDeviceDelegate> delegate = state->delegate;
        state->deliveryInFlight = true;
        state->callbackThread = std::this_thread::get_id();
        // WebRTC callbacks can synchronously query or stop this device.
        lock.unlock();
        @autoreleasepool {
            // The pinned ADM's prefilled stereo path counts frames as samples. Its render path handles both channels.
            delegate.deliverRecordedData(&flags, &audioTimestamp, 0, kPacketFrames, nullptr, packet.data(),
                ^OSStatus(AudioUnitRenderActionFlags *renderFlags, const AudioTimeStamp *renderTimestamp,
                          NSInteger bus, UInt32 frames, AudioBufferList *buffers, void *context) {
                    const UInt32 byteCount = frames * kChannels * sizeof(int16_t);
                    if (!context || buffers->mNumberBuffers != 1 || frames != kPacketFrames ||
                        buffers->mBuffers[0].mNumberChannels != kChannels ||
                        buffers->mBuffers[0].mDataByteSize < byteCount || !buffers->mBuffers[0].mData) {
                        return kAudio_ParamError;
                    }
                    std::memcpy(buffers->mBuffers[0].mData, context, byteCount);
                    buffers->mBuffers[0].mDataByteSize = byteCount;
                    return noErr;
                });
            delegate = nil;
        }
        lock.lock();
        state->deliveryInFlight = false;
        state->callbackThread = std::thread::id();
        dispatch_block_t afterDelivery = state->afterDelivery;
        state->afterDelivery = nil;
        state->wake.notify_all();
        if (afterDelivery) {
            lock.unlock();
            afterDelivery();
            afterDelivery = nil;
            lock.lock();
        }
    }
}

int16_t ReadSample(const uint8_t *bytes, bool floatingPoint) {
    if (!floatingPoint) {
        int16_t sample;
        std::memcpy(&sample, bytes, sizeof(sample));
        return sample;
    }
    float sample;
    std::memcpy(&sample, bytes, sizeof(sample));
    if (!std::isfinite(sample)) { return 0; }
    if (sample <= -1.0f) { return INT16_MIN; }
    if (sample >= 1.0f) { return INT16_MAX; }
    return static_cast<int16_t>(std::lround(sample * 32767.0f));
}

bool ConvertPCM(CMSampleBufferRef sample, std::vector<int16_t> &converted, int64_t &timestamp,
                size_t &discardedFrames) {
    const auto description = CMSampleBufferGetFormatDescription(sample);
    if (!description) { return false; }
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!format || format->mFormatID != kAudioFormatLinearPCM || format->mSampleRate != kSampleRate ||
        (format->mChannelsPerFrame != 1 && format->mChannelsPerFrame != 2) ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian)) {
        return false;
    }
    const bool floatingPoint = format->mFormatFlags & kAudioFormatFlagIsFloat;
    const bool planar = format->mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    const size_t bytesPerSample = floatingPoint ? sizeof(float) : sizeof(int16_t);
    if ((floatingPoint && format->mBitsPerChannel != 32) ||
        (!floatingPoint && (format->mBitsPerChannel != 16 || !(format->mFormatFlags & kAudioFormatFlagIsSignedInteger))) ||
        format->mBytesPerFrame != bytesPerSample * (planar ? 1 : format->mChannelsPerFrame)) {
        return false;
    }
    const CMItemCount sourceFrames = CMSampleBufferGetNumSamples(sample);
    if (sourceFrames <= 0 || sourceFrames > static_cast<CMItemCount>(kSampleRate)) { return false; }

    alignas(AudioBufferList) std::array<uint8_t, sizeof(AudioBufferList) + sizeof(AudioBuffer)> storage{};
    auto buffers = reinterpret_cast<AudioBufferList *>(storage.data());
    CMBlockBufferRef retained = nullptr;
    size_t needed = 0;
    const OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, &needed, buffers, storage.size(), kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained);
    if (status != noErr) {
        if (retained) { CFRelease(retained); }
        return false;
    }
    const size_t expectedBuffers = planar ? format->mChannelsPerFrame : 1;
    bool valid = needed <= storage.size() && buffers->mNumberBuffers == expectedBuffers;
    for (size_t index = 0; valid && index < expectedBuffers; ++index) {
        const AudioBuffer &buffer = buffers->mBuffers[index];
        valid = buffer.mData && buffer.mNumberChannels == (planar ? 1 : format->mChannelsPerFrame) &&
            buffer.mDataByteSize >= sourceFrames * format->mBytesPerFrame;
    }
    if (!valid) {
        if (retained) { CFRelease(retained); }
        return false;
    }

    CMTime presentation = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!CMTIME_IS_NUMERIC(presentation)) { presentation = CMClockGetTime(CMClockGetHostTimeClock()); }
    timestamp = CMTimeConvertScale(presentation, 1000000000, kCMTimeRoundingMethod_Default).value;
    discardedFrames = sourceFrames > kCapacityFrames ? sourceFrames - kCapacityFrames : 0;
    timestamp += FramesToNanoseconds(discardedFrames);
    const size_t frames = sourceFrames - discardedFrames;
    converted.resize(frames * kChannels);
    for (size_t frame = 0; frame < frames; ++frame) {
        for (size_t channel = 0; channel < kChannels; ++channel) {
            const size_t sourceChannel = std::min(channel, static_cast<size_t>(format->mChannelsPerFrame - 1));
            const auto bytes = static_cast<const uint8_t *>(buffers->mBuffers[planar ? sourceChannel : 0].mData);
            const size_t offset = (frame + discardedFrames) * format->mBytesPerFrame + (planar ? 0 : sourceChannel * bytesPerSample);
            converted[frame * kChannels + channel] = ReadSample(bytes + offset, floatingPoint);
        }
    }
    if (retained) { CFRelease(retained); }
    return true;
}
}

@implementation AppAudioDevice {
    std::shared_ptr<AudioState> _state;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = std::make_shared<AudioState>();
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        [notifications addObserver:self selector:@selector(audioInterruption:)
                              name:AVAudioSessionInterruptionNotification object:nil];
        [notifications addObserver:self selector:@selector(audioServicesReset:)
                              name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self terminateDevice];
}

- (double)deviceInputSampleRate { return kSampleRate; }
- (NSTimeInterval)inputIOBufferDuration { return 0.01; }
- (NSInteger)inputNumberOfChannels { return kChannels; }
- (NSTimeInterval)inputLatency { return 0.01; }
- (double)deviceOutputSampleRate { return kSampleRate; }
- (NSTimeInterval)outputIOBufferDuration { return 0.01; }
- (NSInteger)outputNumberOfChannels { return kChannels; }
- (NSTimeInterval)outputLatency { return 0; }

- (BOOL)isInitialized { std::lock_guard<std::mutex> lock(_state->mutex); return _state->initialized; }
- (BOOL)isRecordingInitialized { std::lock_guard<std::mutex> lock(_state->mutex); return _state->recordingInitialized; }
- (BOOL)isPlayoutInitialized { std::lock_guard<std::mutex> lock(_state->mutex); return _state->playoutInitialized; }
- (BOOL)isRecording { std::lock_guard<std::mutex> lock(_state->mutex); return _state->recording; }
- (BOOL)isPlaying { std::lock_guard<std::mutex> lock(_state->mutex); return _state->playing; }

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    auto state = _state;
    __attribute__((objc_precise_lifetime)) id<RTCAudioDeviceDelegate> previous;
    __attribute__((objc_precise_lifetime)) id<RTCAudioDeviceDelegate> failed;
    bool initialized = false;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->initialized) { return YES; }
        if (state->terminating || state->deliveryInFlight) { return NO; }
        previous = state->delegate;
        state->delegate = delegate;
        state->shutdown = false;
        state->interrupted = false;
        ++state->interruptionGeneration;
        state->lastNanoseconds = 0;
        state->resetTimeline();
        try {
            state->deliveryThread = std::thread(DeliverAudio, state, ++state->lifecycleGeneration);
            state->initialized = true;
            initialized = true;
        } catch (...) {
            failed = state->delegate;
            state->delegate = nil;
        }
    }
    previous = nil;
    failed = nil;
    return initialized;
}

- (BOOL)terminateDevice {
    auto state = _state;
    std::thread deliveryThread;
    __attribute__((objc_precise_lifetime)) id<RTCAudioDeviceDelegate> delegate;
    uint64_t generation;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->initialized && state->shutdown) { return YES; }
        state->terminating = true;
        state->initialized = false;
        state->recordingInitialized = false;
        state->playoutInitialized = false;
        state->recording = false;
        state->playing = false;
        state->shutdown = true;
        generation = ++state->lifecycleGeneration;
        ++state->interruptionGeneration;
        state->resetTimeline();
        delegate = state->delegate;
        state->delegate = nil;
        if (state->deliveryThread.joinable() && state->deliveryThread.get_id() == std::this_thread::get_id()) {
            // The pump's shared state survives a reentrant termination on its own thread.
            state->deliveryThread.detach();
        } else {
            deliveryThread = std::move(state->deliveryThread);
        }
    }
    state->wake.notify_all();
    if (deliveryThread.joinable()) { deliveryThread.join(); }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->lifecycleGeneration == generation) { state->terminating = false; }
    }
    delegate = nil;
    return YES;
}

- (BOOL)initializeRecording {
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->recordingInitialized = _state->initialized;
    return _state->recordingInitialized;
}

- (BOOL)startRecording {
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (!_state->recordingInitialized) { return NO; }
        _state->recording = true;
    }
    _state->wake.notify_all();
    return YES;
}

- (BOOL)stopRecording {
    {
        std::unique_lock<std::mutex> lock(_state->mutex);
        _state->recording = false;
        _state->resetTimeline();
        WaitForDelivery(_state.get(), lock);
    }
    _state->wake.notify_all();
    return YES;
}

- (BOOL)initializePlayout {
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->playoutInitialized = _state->initialized;
    return _state->playoutInitialized;
}

- (BOOL)startPlayout {
    std::lock_guard<std::mutex> lock(_state->mutex);
    if (!_state->playoutInitialized) { return NO; }
    _state->playing = true;
    return YES;
}

- (BOOL)stopPlayout {
    std::lock_guard<std::mutex> lock(_state->mutex);
    _state->playing = false;
    return YES;
}

- (BOOL)pushSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) { return NO; }
    std::vector<int16_t> samples;
    int64_t timestamp;
    size_t discarded;
    if (!ConvertPCM(sampleBuffer, samples, timestamp, discarded)) {
        _state->rejected++;
        return NO;
    }
    const size_t frames = samples.size() / kChannels;
    _state->received += frames;
    _state->dropped += discarded;
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (!_state->initialized || !_state->recording || _state->interrupted) { return YES; }
        if (_state->count) {
            const int64_t expected = _state->headNanoseconds + FramesToNanoseconds(_state->count);
            if (std::llabs(timestamp - expected) > 2000000) {
                _state->dropped += _state->count;
                _state->count = 0;
            }
        }
        if (_state->count + frames > kCapacityFrames) {
            const size_t overflow = _state->count + frames - kCapacityFrames;
            _state->discard(overflow);
            _state->dropped += overflow;
        }
        if (!_state->count) { _state->headNanoseconds = timestamp; }
        for (size_t frame = 0; frame < frames; ++frame) {
            const size_t offset = ((_state->head + _state->count + frame) % kCapacityFrames) * kChannels;
            _state->ring[offset] = samples[frame * kChannels];
            _state->ring[offset + 1] = samples[frame * kChannels + 1];
        }
        _state->count += frames;
        if (!_state->timeline) {
            _state->timeline = true;
            _state->nextNanoseconds = timestamp;
        }
    }
    _state->wake.notify_all();
    return YES;
}

- (void)reset {
    {
        std::unique_lock<std::mutex> lock(_state->mutex);
        _state->resetTimeline();
        WaitForDelivery(_state.get(), lock);
    }
    _state->wake.notify_all();
}

- (void)audioInterruption:(NSNotification *)notification {
    const BOOL began = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
    [self interruptAudioAndResume:!began];
}

- (void)interruptAudioAndResume:(BOOL)resume {
    id<RTCAudioDeviceDelegate> delegate;
    uint64_t generation;
    bool deferNotification;
    {
        std::unique_lock<std::mutex> lock(_state->mutex);
        generation = ++_state->interruptionGeneration;
        _state->interrupted = true;
        _state->resetTimeline();
        deferNotification = _state->deliveryInFlight && _state->callbackThread == std::this_thread::get_id();
        if (!deferNotification) { WaitForDelivery(_state.get(), lock); }
        delegate = _state->delegate;
    }
    _state->wake.notify_all();
    if (delegate) {
        __weak AppAudioDevice *weakSelf = self;
        dispatch_block_t notification = ^{
            [delegate dispatchAsync:^{
                AppAudioDevice *device = weakSelf;
                if (!device) { return; }
                {
                    std::lock_guard<std::mutex> lock(device->_state->mutex);
                    if (!device->_state->initialized || device->_state->interruptionGeneration != generation ||
                        device->_state->delegate != delegate) { return; }
                }
                [delegate notifyAudioInputInterrupted];
                if (resume) {
                    {
                        std::lock_guard<std::mutex> lock(device->_state->mutex);
                        if (device->_state->interruptionGeneration != generation || device->_state->delegate != delegate) { return; }
                        device->_state->interrupted = false;
                    }
                    device->_state->wake.notify_all();
                }
            }];
        };
        if (deferNotification) {
            __attribute__((objc_precise_lifetime)) dispatch_block_t previous;
            {
                std::lock_guard<std::mutex> lock(_state->mutex);
                previous = _state->afterDelivery;
                _state->afterDelivery = notification;
            }
            previous = nil;
        } else {
            notification();
        }
    } else if (resume) {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (_state->interruptionGeneration == generation) { _state->interrupted = false; }
    }
}

- (void)audioServicesReset:(NSNotification *)notification {
    [self interruptAudioAndResume:YES];
}

- (uint64_t)receivedAudioFrames { return _state->received.load(); }
- (uint64_t)rejectedAudioBuffers { return _state->rejected.load(); }
- (uint64_t)droppedAudioFrames { return _state->dropped.load(); }
- (uint64_t)silentAudioFrames { return _state->silent.load(); }

@end
