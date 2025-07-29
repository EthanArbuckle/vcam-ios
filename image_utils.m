#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// This can be a static image or video file
static NSString *const kReplacementMediaPath = @"/var/mobile/Media/DCIM/test.mp4";

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
static CIContext *sharedCIContext = NULL;
static CVPixelBufferPoolRef pixelBufferPool = NULL;
static size_t cachedWidth = 0;
static size_t cachedHeight = 0;
static NSObject *vcamLock = nil;

static void createPixelBufferPool(size_t width, size_t height) {
    if (pixelBufferPool && cachedWidth == width && cachedHeight == height) {
        return;
    }

    if (pixelBufferPool) {
        CVPixelBufferPoolRelease(pixelBufferPool);
        pixelBufferPool = NULL;
    }

    NSDictionary *poolAttributes = @{
        (NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        (NSString *)kCVPixelBufferPoolMaximumBufferAgeKey: @(5.0)
    };

    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };

    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes, (__bridge CFDictionaryRef)pixelBufferAttributes, &pixelBufferPool) == kCVReturnSuccess) {
        cachedWidth = width;
        cachedHeight = height;
    }
}

static void loadReplacementMedia(void) {
    if (!vcamLock) {
        vcamLock = [[NSObject alloc] init];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:kReplacementMediaPath]) {
        return;
    }

    NSString *extension = [[kReplacementMediaPath pathExtension] lowercaseString];
    if ([extension isEqualToString:@"png"] || [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
        UIImage *image = [UIImage imageWithContentsOfFile:kReplacementMediaPath];
        if (image && image.CGImage) {
            replacementImage = CGImageRetain(image.CGImage);
            currentMode = VCamModeImage;
            resourcesLoaded = YES;
        }
    }
    else if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"]) {
        NSURL *videoURL = [NSURL fileURLWithPath:kReplacementMediaPath];
        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        NSError *error = nil;
        AVAssetReader *assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (error) {
            return;
        }

        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            return;
        }

        AVAssetTrack *videoTrack = videoTracks[0];
        NSDictionary *outputSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        AVAssetReaderTrackOutput *videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
        videoOutput.alwaysCopiesSampleData = NO;

        if (![assetReader canAddOutput:videoOutput]) {
            return;
        }

        [assetReader addOutput:videoOutput];
        [assetReader startReading];

        videoFrames = [[NSMutableArray alloc] init];
        int frameCount = 0;
        int maxFrames = 60;
        while (assetReader.status == AVAssetReaderStatusReading && frameCount < maxFrames) {
            CMSampleBufferRef sampleBuffer = [videoOutput copyNextSampleBuffer];
            if (sampleBuffer == NULL) {
                break;
            }

            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
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

        [assetReader cancelReading];
    }

    if (sharedCIContext == NULL) {
        sharedCIContext = [CIContext context];
    }
}

static CVPixelBufferRef createPixelBufferForCurrentFrame(size_t width, size_t height) {
    @synchronized(vcamLock) {
        CVPixelBufferRef result = NULL;

        createPixelBufferPool(width, height);

        if (pixelBufferPool) {
            if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &result) != kCVReturnSuccess) {
                return NULL;
            }
        }
        else {
            NSDictionary *pixelBufferAttributes = @{
                (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
                (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };

            if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &result) != kCVReturnSuccess) {
                return NULL;
            }
        }

        if (currentMode == VCamModeImage) {
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

        }
        else if (currentMode == VCamModeVideo) {
            CVPixelBufferRef videoFrame = (__bridge CVPixelBufferRef)videoFrames[currentFrameIndex];
            currentFrameIndex = (currentFrameIndex + 1) % videoFrames.count;

            if (CVPixelBufferGetWidth(videoFrame) == width && CVPixelBufferGetHeight(videoFrame) == height) {
                CVPixelBufferRelease(result);
                result = videoFrame;
                CVPixelBufferRetain(result);
            }
            else {
                CIImage *sourceImage = [CIImage imageWithCVPixelBuffer:videoFrame];

                CGFloat scaleX = (CGFloat)width / CVPixelBufferGetWidth(videoFrame);
                CGFloat scaleY = (CGFloat)height / CVPixelBufferGetHeight(videoFrame);
                CGFloat scale = MIN(scaleX, scaleY);
                CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
                CIImage *scaledImage = [sourceImage imageByApplyingTransform:transform];

                if (sharedCIContext) {
                    [sharedCIContext render:scaledImage toCVPixelBuffer:result];
                }
            }
        }

        return result;
    }
}

CMSampleBufferRef createModifiedSampleBuffer(CMSampleBufferRef originalSampleBuffer) {
    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(originalSampleBuffer);
    if (originalImageBuffer == NULL) {
        return NULL;
    }

    if (!resourcesLoaded) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            loadReplacementMedia();
        });

        if (!resourcesLoaded) {
            return NULL;
        }
    }

    size_t width = CVPixelBufferGetWidth(originalImageBuffer);
    size_t height = CVPixelBufferGetHeight(originalImageBuffer);

    CVPixelBufferRef replacementPixelBuffer = createPixelBufferForCurrentFrame(width, height);
    if (replacementPixelBuffer == NULL) {
        return NULL;
    }

    CMFormatDescriptionRef newFormatDescription = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, replacementPixelBuffer, &newFormatDescription);
    if (formatStatus != kCVReturnSuccess) {
        CFRelease(replacementPixelBuffer);
        return NULL;
    }

    CMSampleTimingInfo timingInfo;
    CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, 0, &timingInfo);

    CMSampleBufferRef newSampleBuffer = NULL;
    OSStatus createStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, replacementPixelBuffer, newFormatDescription, &timingInfo, &newSampleBuffer);

    CFRelease(replacementPixelBuffer);
    CFRelease(newFormatDescription);

    if (createStatus != kCVReturnSuccess) {
        return NULL;
    }

    CMPropagateAttachments(originalSampleBuffer, newSampleBuffer);

    return newSampleBuffer;
}
