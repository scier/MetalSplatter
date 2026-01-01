#import "include/SPZReader.h"
#include "cpp/load-spz.h"
#include "cpp/splat-types.h"
#include <vector>

static NSString * const SPZReaderErrorDomain = @"com.metalsplatter.spzio";

typedef NS_ENUM(NSInteger, SPZReaderErrorCode) {
    SPZReaderErrorCodeFileReadFailed = 1,
    SPZReaderErrorCodeInvalidData = 2,
    SPZReaderErrorCodeNoPoints = 3,
};

@implementation SPZReader

+ (BOOL)loadSPZFileAtURL:(NSURL *)url
         batchHandler:(SPZPointBatchHandler)handler
                error:(NSError **)error {
    // Load file into memory
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) {
        return NO;
    }

    return [self loadSPZData:data batchHandler:handler error:error];
}

+ (BOOL)loadSPZData:(NSData *)data
       batchHandler:(SPZPointBatchHandler)handler
              error:(NSError **)error {
    if (!data || data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:SPZReaderErrorDomain
                                         code:SPZReaderErrorCodeInvalidData
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid or empty SPZ data"}];
        }
        return NO;
    }

    // Load the SPZ file using the C++ library
    // SPZ internally uses RUB coordinate system
    spz::UnpackOptions options;
    options.to = spz::CoordinateSystem::RUB;

    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    spz::GaussianCloud cloud = spz::loadSpz(bytes, (int32_t)data.length, options);

    if (cloud.numPoints == 0) {
        if (error) {
            *error = [NSError errorWithDomain:SPZReaderErrorDomain
                                         code:SPZReaderErrorCodeNoPoints
                                     userInfo:@{NSLocalizedDescriptionKey: @"SPZ file contains no points or failed to load"}];
        }
        return NO;
    }

    // Convert to our point structure and send in batches
    const size_t batchSize = 1024;
    std::vector<SPZGaussianPoint> batch;
    batch.reserve(batchSize);

    for (int32_t i = 0; i < cloud.numPoints; i++) {
        SPZGaussianPoint point;

        // Position
        point.position = simd_make_float3(
            cloud.positions[i * 3 + 0],
            cloud.positions[i * 3 + 1],
            cloud.positions[i * 3 + 2]
        );

        // Rotation (quaternion: w, x, y, z)
        point.rotation = simd_make_float4(
            cloud.rotations[i * 4 + 0], // w
            cloud.rotations[i * 4 + 1], // x
            cloud.rotations[i * 4 + 2], // y
            cloud.rotations[i * 4 + 3]  // z
        );

        // Scale (log scale)
        point.scale = simd_make_float3(
            cloud.scales[i * 3 + 0],
            cloud.scales[i * 3 + 1],
            cloud.scales[i * 3 + 2]
        );

        // Color (SH DC component)
        point.color = simd_make_float3(
            cloud.colors[i * 3 + 0],
            cloud.colors[i * 3 + 1],
            cloud.colors[i * 3 + 2]
        );

        // Alpha (logit)
        point.alpha = cloud.alphas[i];

        // SH degree
        point.shDegree = cloud.shDegree;

        batch.push_back(point);

        // Send batch when full
        if (batch.size() >= batchSize) {
            handler(batch.data(), batch.size());
            batch.clear();
        }
    }

    // Send remaining points
    if (!batch.empty()) {
        handler(batch.data(), batch.size());
    }

    return YES;
}

+ (NSUInteger)pointCountInFileAtURL:(NSURL *)url error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) {
        return 0;
    }

    spz::UnpackOptions options;
    options.to = spz::CoordinateSystem::RUB;

    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    spz::GaussianCloud cloud = spz::loadSpz(bytes, (int32_t)data.length, options);

    return cloud.numPoints;
}

@end
