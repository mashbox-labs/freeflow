import Foundation

/// Free Flow addition to the vendored FluidAudio (not upstream): lets the app pace long-audio chunks, for example to
/// stay under iOS's background CPU limit (80% of one core over 60 s). `ChunkProcessor` asks `pacing()` before each
/// chunk; when it returns true, the chunks in flight finish first (one chunk at a time) and `beforeChunk(audioSeconds:)`
/// may wait before the next one starts. The chunk layout, the decoding and the text are unchanged.
public protocol ChunkPacer: Sendable {
    func pacing() async -> Bool
    func beforeChunk(audioSeconds: Double) async throws
}
