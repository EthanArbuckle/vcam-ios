#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// This can be a static image or video file
static NSString *const kReplacementMediaPath = @"/tmp/test.png";//@"/var/mobile/Media/DCIM/test.mp4";

typedef enum {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
} VCamMode;

static VCamMode currentMode = VCamModeNone;
static CGImageRef replacementImage = NULL;
static NSMutableArray *videoFrames = NULL;
static NSUInteger currentFrameIndex = 0;
static CIContext *sharedCIContext = NULL;
static NSObject *vcamLock = nil;

void loadReplacementMedia(void) {
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
        }

        [assetReader cancelReading];
    }

    if (sharedCIContext == NULL) {
        sharedCIContext = [CIContext context];
    }
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    @synchronized(vcamLock) {
        CIImage *replacementCIImage = nil;

        if (currentMode == VCamModeImage) {
            replacementCIImage = [CIImage imageWithCGImage:replacementImage];
        } 
        else if (currentMode == VCamModeVideo) {
            CVPixelBufferRef videoFrame = (__bridge CVPixelBufferRef)videoFrames[currentFrameIndex];
            currentFrameIndex = (currentFrameIndex + 1) % videoFrames.count;
            replacementCIImage = [CIImage imageWithCVPixelBuffer:videoFrame];
        }

        if (!replacementCIImage) {
            return;
        }

        CGFloat targetWidth = CVPixelBufferGetWidth(targetBuffer);
        CGFloat targetHeight = CVPixelBufferGetHeight(targetBuffer);
        CGRect replacementExtent = replacementCIImage.extent;

        CGFloat scaleX = targetWidth / replacementExtent.size.width;
        CGFloat scaleY = targetHeight / replacementExtent.size.height;
        CGFloat scale = MIN(scaleX, scaleY);

        CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
        CIImage *scaledImage = [replacementCIImage imageByApplyingTransform:transform];
        
        CGRect scaledExtent = scaledImage.extent;
        CGFloat offsetX = (targetWidth - scaledExtent.size.width) / 2.0;
        CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;        
        CGAffineTransform translationTransform = CGAffineTransformMakeTranslation(offsetX, offsetY);
        CIImage *finalImage = [scaledImage imageByApplyingTransform:translationTransform];

        if (sharedCIContext) {
            [sharedCIContext render:finalImage toCVPixelBuffer:targetBuffer];
        }
    }
}