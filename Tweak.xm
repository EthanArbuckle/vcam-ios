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

static NSString *const kReplacementMediaPath = @"/tmp/test.png";//@"/var/mobile/Media/DCIM/test.mp4";

typedef enum {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
} VCamMode;

static VCamMode currentMode = VCamModeNone;
static BOOL resourcesLoaded = NO;

static CGImageRef replacementImage = NULL;

static NSMutableArray *videoFrames = NULL;
static NSUInteger currentFrameIndex = 0;

static void loadReplacementMedia(void) {    
    if (![[NSFileManager defaultManager] fileExistsAtPath:kReplacementMediaPath]) {
        return;
    }
    
    NSString *extension = [[kReplacementMediaPath pathExtension] lowercaseString];
    if ([extension isEqualToString:@"png"] || [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
        // Image mode
        UIImage *image = [UIImage imageWithContentsOfFile:kReplacementMediaPath];
        if (image && image.CGImage) {
            replacementImage = CGImageRetain(image.CGImage);
            currentMode = VCamModeImage;
            resourcesLoaded = YES;
        } 
        else {
            NSLog(@"[vcam-debug] ERROR: Failed to load image");
        }
    }
    else if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"]) {
        // Video mode
        NSURL *videoURL = [NSURL fileURLWithPath:kReplacementMediaPath];
        AVAsset *asset = [AVAsset assetWithURL:videoURL];
        
        NSError *error = nil;
        AVAssetReader *assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (error) {
            NSLog(@"[vcam-debug] ERROR: Could not create asset reader: %@", error);
            return;
        }
        
        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            NSLog(@"[vcam-debug] ERROR: No video tracks found");
            return;
        }
        
        AVAssetTrack *videoTrack = videoTracks[0];
        NSDictionary *outputSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        AVAssetReaderTrackOutput *videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
        videoOutput.alwaysCopiesSampleData = NO;
        
        if ([assetReader canAddOutput:videoOutput]) {
            [assetReader addOutput:videoOutput];
        }
        else {
            NSLog(@"[vcam-debug] ERROR: Could not add video output to asset reader");
            return;
        }
        
        [assetReader startReading];
        
        videoFrames = [[NSMutableArray alloc] init];
        int frameCount = 0;
        
        while (assetReader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sampleBuffer = [videoOutput copyNextSampleBuffer];
            if (sampleBuffer == NULL) {
                break;
            }

            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer != NULL) {
                CVPixelBufferRetain(pixelBuffer);
                [videoFrames addObject:(__bridge id)pixelBuffer];
                frameCount++;
            }
            
            CFRelease(sampleBuffer);
        }
        
        if (frameCount > 0) {
            currentMode = VCamModeVideo;
            resourcesLoaded = YES;
        }
        else {
            NSLog(@"[vcam-debug] ERROR: No frames extracted from video");
            videoFrames = NULL;
        }
        
        [assetReader cancelReading];
    }
}

static CVPixelBufferRef createPixelBufferForCurrentFrame(size_t width, size_t height) {
    CVPixelBufferRef result = NULL;
    
    if (currentMode == VCamModeImage) {
        NSDictionary *pixelBufferAttributes = @{
            (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &result);
        if (status != kCVReturnSuccess) {
            NSLog(@"[vcam-debug] Failed to create pixel buffer");
            return NULL;
        }
        
        CVPixelBufferLockBaseAddress(result, 0);
        void *pxdata = CVPixelBufferGetBaseAddress(result);
        CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, CVPixelBufferGetBytesPerRow(result), rgbColorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        
        if (context) {
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), replacementImage);
            CGContextRelease(context);
        }
        
        CGColorSpaceRelease(rgbColorSpace);
        CVPixelBufferUnlockBaseAddress(result, 0);
        
    } else if (currentMode == VCamModeVideo) {
        CVPixelBufferRef videoFrame = (__bridge CVPixelBufferRef)videoFrames[currentFrameIndex];
        currentFrameIndex = (currentFrameIndex + 1) % videoFrames.count;
        
        // Check if resize is needed
        if (CVPixelBufferGetWidth(videoFrame) == width && CVPixelBufferGetHeight(videoFrame) == height) {
            result = videoFrame;
            CVPixelBufferRetain(result);
        } else {
            // Resize using Core Image
            CIImage *sourceImage = [CIImage imageWithCVPixelBuffer:videoFrame];
            
            CGFloat scaleX = (CGFloat)width / CVPixelBufferGetWidth(videoFrame);
            CGFloat scaleY = (CGFloat)height / CVPixelBufferGetHeight(videoFrame);
            CGFloat scale = MIN(scaleX, scaleY);
            
            CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
            CIImage *scaledImage = [sourceImage imageByApplyingTransform:transform];
            
            NSDictionary *pixelBufferAttributes = @{
                (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
                (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &result);
            
            if (result) {
                CIContext *context = [CIContext context];
                [context render:scaledImage toCVPixelBuffer:result];
            }
        }
    }
    
    return result;
}

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (self.mediaType == 'vide' && originalImageBuffer) {
        
        if (!resourcesLoaded) {
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                loadReplacementMedia();
            });
            
            if (!resourcesLoaded) {
                %orig(sampleBuffer);
                return;
            }
        }
        
        size_t width = CVPixelBufferGetWidth(originalImageBuffer);
        size_t height = CVPixelBufferGetHeight(originalImageBuffer);
        
        CVPixelBufferRef replacementPixelBuffer = createPixelBufferForCurrentFrame(width, height);
        if (replacementPixelBuffer) {
            CFDictionaryRef propagateAttachments = CVBufferGetAttachments(originalImageBuffer, kCVAttachmentMode_ShouldPropagate);
            if (propagateAttachments) {
                CVBufferSetAttachments(replacementPixelBuffer, propagateAttachments, kCVAttachmentMode_ShouldPropagate);
            }

            CMSampleTimingInfo timingInfo;
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);

            CMVideoFormatDescriptionRef newFormatDescription = NULL;
            OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, replacementPixelBuffer, &newFormatDescription);
            if (formatStatus == kCVReturnSuccess && newFormatDescription) {                    
                CMSampleBufferRef newSampleBuffer = NULL;
                OSStatus createStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, replacementPixelBuffer, newFormatDescription, &timingInfo, &newSampleBuffer);
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
                                }
                            }
                        }
                    }
                    
                    %orig(newSampleBuffer);
                    CFRelease(newSampleBuffer);
                }
                else {
                    %orig(sampleBuffer);
                }

                CFRelease(newFormatDescription);
            }
            else {
                %orig(sampleBuffer);
            }
            
            CFRelease(replacementPixelBuffer);
            return;
        }
    }

    %orig(sampleBuffer);
}

%end