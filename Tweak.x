#import "image_utils.h"

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)arg1 {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType == 'vide') {
        
        CMSampleBufferRef newSampleBuffer = createModifiedSampleBuffer(arg1);
        if (newSampleBuffer) {
            %orig(newSampleBuffer);
            CFRelease(newSampleBuffer);

            return;
        }
    }

    // could also handle audio here, when mediaType='soun'

    %orig(arg1);
}

%end