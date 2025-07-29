#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

@interface BWNodeOutput : NSObject
@property (nonatomic, readonly) unsigned int mediaType;
@end

static CGImageRef replacementCGImage = NULL;

static CVPixelBufferRef createBGRA_PixelBufferFromCGImage(CGImageRef image, size_t width, size_t height) {
    NSDictionary *pixelBufferAttributes = @{
        (NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pixelBufferAttributes, &pxbuffer);
    if (status != kCVReturnSuccess) {
        NSLog(@"[vcam-debug] FAILED to create CVPixelBuffer. CVReturn status: %d", status);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pxbuffer, 0);

    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, CVPixelBufferGetBytesPerRow(pxbuffer), rgbColorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    
    CGColorSpaceRelease(rgbColorSpace);
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    return pxbuffer;
}

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (self.mediaType == 'vide' && originalImageBuffer) {

        if (replacementCGImage == NULL) {
            UIImage *image = [UIImage imageWithContentsOfFile:@"/tmp/test.png"];
            if (image) {
                replacementCGImage = CGImageRetain(image.CGImage);
            }
        }

        if (replacementCGImage) {
            size_t width = CVPixelBufferGetWidth(originalImageBuffer);
            size_t height = CVPixelBufferGetHeight(originalImageBuffer);
            OSType originalFormat = CVPixelBufferGetPixelFormatType(originalImageBuffer);
            NSLog(@"[vcam-debug] Original format: 0x%x (%c%c%c%c)", (unsigned int)originalFormat, (char)(originalFormat >> 24), (char)(originalFormat >> 16), (char)(originalFormat >> 8), (char)(originalFormat));
            
            CVPixelBufferRef replacementPixelBuffer = createBGRA_PixelBufferFromCGImage(replacementCGImage, width, height);
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
                
                CFRelease(replacementPixelBuffer);
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