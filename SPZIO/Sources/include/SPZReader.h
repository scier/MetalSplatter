#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// A structure representing a single Gaussian point loaded from an SPZ file
typedef struct {
    simd_float3 position;
    simd_float4 rotation; // quaternion (w, x, y, z)
    simd_float3 scale;    // log scale
    simd_float3 color;    // SH DC component
    float alpha;          // logit alpha
    int32_t shDegree;     // degree of spherical harmonics for this point
} SPZGaussianPoint;

/// A block that receives batches of Gaussian points during streaming
typedef void (^SPZPointBatchHandler)(const SPZGaussianPoint *points, NSUInteger count);

/// Objective-C wrapper for SPZ file loading
@interface SPZReader : NSObject

/// Load an SPZ file and call the handler for each batch of points
/// @param url The URL of the SPZ file to load
/// @param handler Block called with batches of points during loading
/// @param error Error pointer for failure cases
/// @return YES on success, NO on failure
+ (BOOL)loadSPZFileAtURL:(NSURL *)url
         batchHandler:(SPZPointBatchHandler)handler
                error:(NSError **)error;

/// Load SPZ data from memory and call the handler for each batch of points
/// @param data The SPZ data to load
/// @param handler Block called with batches of points during loading
/// @param error Error pointer for failure cases
/// @return YES on success, NO on failure
+ (BOOL)loadSPZData:(NSData *)data
       batchHandler:(SPZPointBatchHandler)handler
              error:(NSError **)error;

/// Get the total number of points in an SPZ file without loading all data
/// @param url The URL of the SPZ file
/// @param error Error pointer for failure cases
/// @return The number of points, or 0 on error
+ (NSUInteger)pointCountInFileAtURL:(NSURL *)url error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
