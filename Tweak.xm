#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>

@interface BWNode : NSObject
@property (nonatomic, readonly) NSArray *outputs;
@property (nonatomic, readonly) NSString *name;
@end

@interface BWNodeInput : NSObject
@property (nonatomic, readonly) BWNode *node;
@end

@interface BWNodeOutput : NSObject
@property (nonatomic, readonly) unsigned int mediaType;
@property (nonatomic, readonly) NSArray *consumers;
- (void)emitSampleBuffer:(struct opaqueCMSampleBuffer *)arg1;
@end

@interface BWNodeConnection : NSObject
@property (nonatomic, readonly) BWNodeInput *input;
@property (nonatomic, readonly) BWNodeOutput *output;
@end

static AVAssetReader *assetReader = NULL;
static AVAssetReaderTrackOutput *videoOutput = NULL;
static dispatch_queue_t videoQueue = NULL;
static NSMutableArray *frameBuffer = NULL;
static NSUInteger currentFrameIndex = 0;
static BOOL isLoadingFrames = NO;

static void loadVideoFrames(void) {
    if (isLoadingFrames) {
        return;
    }
    isLoadingFrames = YES;

    NSURL *videoURL = [NSURL fileURLWithPath:@"/var/mobile/Media/DCIM/test.mp4"];
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    if (!asset) {
        NSLog(@"[vcam-debug] FAILED: Could not load video asset");
        isLoadingFrames = NO;
        return;
    }
    
    NSError *error = NULL;
    assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error != NULL) {
        NSLog(@"[vcam-debug] FAILED: Could not create asset reader: %@", error);
        isLoadingFrames = NO;
        return;
    }
    
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        NSLog(@"[vcam-debug] FAILED: No video tracks found");
        isLoadingFrames = NO;
        return;
    }
    
    AVAssetTrack *videoTrack = videoTracks[0];
    NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    
    videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
    videoOutput.alwaysCopiesSampleData = NO;
    
    if ([assetReader canAddOutput:videoOutput]) {
        [assetReader addOutput:videoOutput];
    }
    else {
        NSLog(@"[vcam-debug] FAILED: Could not add video output to asset reader");
        isLoadingFrames = NO;
        return;
    }
    
    [assetReader startReading];
    
    frameBuffer = [[NSMutableArray alloc] init];
    
    dispatch_async(videoQueue, ^{
        NSUInteger frameCount = 0;
        while (assetReader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sampleBuffer = [videoOutput copyNextSampleBuffer];
            if (sampleBuffer != NULL) {
                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (pixelBuffer != NULL) {
                    CVPixelBufferRetain(pixelBuffer);
                    [frameBuffer addObject:(__bridge id)pixelBuffer];
                    frameCount++;
                }
                CFRelease(sampleBuffer);
            } else {
                break;
            }
        }
        
        NSLog(@"[vcam-debug] Loaded %lu video frames", (unsigned long)frameCount);
        
        if (frameCount == 0) {
            NSLog(@"[vcam-debug] WARNING: No frames loaded from video");
            frameBuffer = NULL;
        }
        
        [assetReader cancelReading];
        assetReader = NULL;
        videoOutput = NULL;
        isLoadingFrames = NO;
    });
}

static CVPixelBufferRef getNextVideoFrame(void) {
    if (frameBuffer == NULL || frameBuffer.count == 0) {
        return NULL;
    }
    
    CVPixelBufferRef frame = (__bridge CVPixelBufferRef)frameBuffer[currentFrameIndex];
    currentFrameIndex = (currentFrameIndex + 1) % frameBuffer.count;
    return frame;
}

static CVPixelBufferRef createResizedPixelBuffer(CVPixelBufferRef sourceBuffer, size_t targetWidth, size_t targetHeight) {
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVPixelBufferRef targetBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &targetBuffer) != kCVReturnSuccess) {
        NSLog(@"[vcam-debug] FAILED to create target pixel buffer");
        return NULL;
    }
    
    CIImage *sourceImage = [CIImage imageWithCVPixelBuffer:sourceBuffer];
    
    CGFloat scaleX = (CGFloat)targetWidth / CVPixelBufferGetWidth(sourceBuffer);
    CGFloat scaleY = (CGFloat)targetHeight / CVPixelBufferGetHeight(sourceBuffer);
    CGFloat scale = MIN(scaleX, scaleY);
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    CIImage *scaledImage = [sourceImage imageByApplyingTransform:transform];
    
    CIContext *context = [CIContext context];
    [context render:scaledImage toCVPixelBuffer:targetBuffer];
    
    return targetBuffer;
}

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (self.mediaType == 'vide' && originalImageBuffer) {
        
        if (frameBuffer == NULL && !isLoadingFrames) {
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                videoQueue = dispatch_queue_create("com.vcam.videoloader", DISPATCH_QUEUE_SERIAL);
                loadVideoFrames();
            });
        }
        
        CVPixelBufferRef videoFrame = getNextVideoFrame();
        if (videoFrame != NULL) {
            size_t width = CVPixelBufferGetWidth(originalImageBuffer);
            size_t height = CVPixelBufferGetHeight(originalImageBuffer);
            OSType originalFormat = CVPixelBufferGetPixelFormatType(originalImageBuffer);
            NSLog(@"[vcam-debug] Original format: 0x%x (%c%c%c%c), target size: %zux%zu", (unsigned int)originalFormat, (char)(originalFormat >> 24), (char)(originalFormat >> 16), (char)(originalFormat >> 8), (char)(originalFormat), width, height);
            
            CVPixelBufferRef resizedBuffer = createResizedPixelBuffer(videoFrame, width, height);
            if (resizedBuffer != NULL) {
                CFDictionaryRef propagateAttachments = CVBufferGetAttachments(originalImageBuffer, kCVAttachmentMode_ShouldPropagate);
                if (propagateAttachments) {
                    CVBufferSetAttachments(resizedBuffer, propagateAttachments, kCVAttachmentMode_ShouldPropagate);
                }

                CMSampleTimingInfo timingInfo;
                CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);

                CMVideoFormatDescriptionRef newFormatDescription = NULL;
                OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, resizedBuffer, &newFormatDescription);
                if (formatStatus == kCVReturnSuccess && newFormatDescription) {                    
                    CMSampleBufferRef newSampleBuffer = NULL;
                    OSStatus createStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, resizedBuffer, newFormatDescription, &timingInfo, &newSampleBuffer);
                    if (createStatus == kCVReturnSuccess && newSampleBuffer) {
                        CMPropagateAttachments(sampleBuffer, newSampleBuffer);
                        
                        CFArrayRef originalAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
                        CFArrayRef newAttachments = CMSampleBufferGetSampleAttachmentsArray(newSampleBuffer, true);
                        if (originalAttachments && CFArrayGetCount(originalAttachments) > 0) {
                            if (newAttachments == NULL || CFArrayGetCount(newAttachments) == 0) {
                                CMSampleBufferSetDataReady(newSampleBuffer);
                                newAttachments = CMSampleBufferGetSampleAttachmentsArray(newSampleBuffer, true);
                            }
                            
                            if (newAttachments && CFArrayGetCount(newAttachments) > 0) {
                                CFDictionaryRef oldDict = (CFDictionaryRef)CFArrayGetValueAtIndex(originalAttachments, 0);
                                CFMutableDictionaryRef newDict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(newAttachments, 0);
                                
                                if (oldDict && newDict) {
                                    CFDictionaryRef immutableCopy = CFDictionaryCreateCopy(kCFAllocatorDefault, oldDict);
                                    if (immutableCopy) {
                                        CFIndex count = CFDictionaryGetCount(immutableCopy);
                                        if (count > 0) {
                                            const void **keys = (const void **)malloc(sizeof(void*) * count);
                                            const void **values = (const void **)malloc(sizeof(void*) * count);
                                            CFDictionaryGetKeysAndValues(immutableCopy, keys, values);
                                            
                                            for (CFIndex i = 0; i < count; i++) {
                                                CFDictionarySetValue(newDict, keys[i], values[i]);
                                            }
                                            
                                            free(keys);
                                            free(values);
                                        }

                                        CFRelease(immutableCopy);
                                        NSLog(@"[vcam-debug] Copied %ld attachment entries", count);
                                    }
                                }
                            }
                        }
                        
                        %orig(newSampleBuffer);
                        CFRelease(newSampleBuffer);
                    }
                    else {
                        NSLog(@"[vcam-debug] FAILED: Could not create sample buffer. Status: %d", (int)createStatus);
                        %orig(sampleBuffer);
                    }

                    CFRelease(newFormatDescription);
                }
                else {
                    NSLog(@"[vcam-debug] FAILED: Could not create format description. Status: %d", (int)formatStatus);
                    %orig(sampleBuffer);
                }
                
                CFRelease(resizedBuffer);
                return;
            }
        }
    }

    %orig(sampleBuffer);
}

%end

%ctor {
    NSLog(@"injected");
}
