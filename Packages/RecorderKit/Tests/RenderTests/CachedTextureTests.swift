// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Dispatch
import Metal
import RecorderKitTestSupport
@testable import Render
import Testing

/// A texture of a texture cache released on one thread while the cache's other owner lets go of it on another, as the
/// renderer's queue releases the last frame of an export after its completion while the export, done, releases the
/// renderer and its cache. Core Video's `CVMetalTexture` does not retain its cache, and a texture released while its
/// cache is being finalized crashes in `CVMetalTextureCache::bufferBackingNotInUse` (`EXC_BAD_ACCESS` in
/// `CFArrayAppendValue`): the segfault that took `ExportTests` down under load. In a process of its own, so that the
/// crash fails this test rather than the whole run.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aTextureReleasedWhileItsCacheGoesDoesNotCrash() async {
    await #expect(processExitsWith: .success) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        releaseCachesAndTheirTexturesAtOnce(device: device, times: 2_000)
    }
}

/// Makes a cache and one of its textures `times` times, and lets go of the two at once on two threads.
private func releaseCachesAndTheirTexturesAtOnce(device: any MTLDevice, times: Int) {
    for _ in 0..<times {
        // Nothing here but the two owners holds the cache and the texture.
        guard let owners = TextureOwners(device: device) else { exit(2) }
        let go = DispatchSemaphore(value: 0)
        let both = DispatchGroup()
        DispatchQueue.global().async(group: both) { go.wait(); owners.cache = nil }
        DispatchQueue.global().async(group: both) { go.wait(); owners.texture = nil }
        go.signal()
        go.signal()
        both.wait()
    }
}

/// A texture cache and a texture it made, of a 64 × 64 pixel buffer, which nothing else holds.
private final class TextureOwners: @unchecked Sendable {
    var cache: CVMetalTextureCache?
    var texture: CachedTexture?

    init?(device: any MTLDevice) {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
                == kCVReturnSuccess,
              let cache, let pixelBuffer,
              let texture = try? CachedTexture(pixelBuffer, cache: cache)
        else { return nil }
        self.texture = texture
    }
}
