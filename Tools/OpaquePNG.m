#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

static int Fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    return 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            return Fail(@"Usage: OpaquePNG <input-image> <output.png>");
        }

        NSURL *inputURL = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *outputURL = [NSURL fileURLWithPath:@(argv[2])];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)inputURL, NULL);
        if (source == NULL) {
            return Fail([NSString stringWithFormat:@"Unable to read image at %@", inputURL.path]);
        }

        CGImageRef inputImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (inputImage == NULL) {
            return Fail([NSString stringWithFormat:@"Unable to decode image at %@", inputURL.path]);
        }

        size_t width = CGImageGetWidth(inputImage);
        size_t height = CGImageGetHeight(inputImage);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(
            NULL,
            width,
            height,
            8,
            0,
            colorSpace,
            (CGBitmapInfo)kCGImageAlphaNoneSkipLast
        );
        CGColorSpaceRelease(colorSpace);
        if (context == NULL) {
            CGImageRelease(inputImage);
            return Fail(@"Unable to create an opaque RGB bitmap");
        }

        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), inputImage);
        CGImageRelease(inputImage);

        CGImageRef outputImage = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        if (outputImage == NULL) {
            return Fail(@"Unable to create the flattened image");
        }

        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)outputURL,
            CFSTR("public.png"),
            1,
            NULL
        );
        if (destination == NULL) {
            CGImageRelease(outputImage);
            return Fail([NSString stringWithFormat:@"Unable to create %@", outputURL.path]);
        }

        CGImageDestinationAddImage(destination, outputImage, NULL);
        BOOL written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(outputImage);
        return written ? 0 : Fail([NSString stringWithFormat:@"Unable to write %@", outputURL.path]);
    }
}
