import AVFoundation
import FreeFlowKit
import SwiftUI

/// Build 23 (the first-load wait needs a real experience). While the picked Core ML model is built for
/// this device's Neural Engine for the first time (about 2 min for Whisper large-v3-turbo), a full-screen loader covers
/// the app. It shows once the load has run ModelManager.loaderAfter seconds (a model already built here loads in about
/// a second, so a warm load never shows it), loops for as long as the build runs, and is gone with no transition the
/// moment the model is ready. Build 24: only on a new install's first launch, for its first model (later
/// prepares show on the model's card), with no Dictate button, only a plain
/// way Home; its clock counts time in front only (iOS pauses the prepare in the background). The motion graphic plays
/// when its files are in the app (LoaderArt); without them it is a plain MASHBOX screen.
struct PrepareLoader: View {
    @EnvironmentObject private var models: ModelManager
    @State private var hiddenFor: Date?

    var body: some View {
        if !models.building.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let id = models.loaderID(now: context.date), let began = models.building[id], hiddenFor != began {
                    LoaderScreen(id: id, now: context.date) { hiddenFor = began }
                }
            }
            .transaction { $0.animation = nil }
        }
    }
}

private struct LoaderScreen: View {
    @EnvironmentObject private var models: ModelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let now: Date
    let hide: () -> Void

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let art = LoaderArt.url(landscape: landscape)
            let poster = LoaderArt.poster(landscape: landscape)
            ZStack {
                Palette.bg.ignoresSafeArea()
                // The poster is the first frame under the video, and the still when Reduce Motion is on.
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height)
                        .clipped().ignoresSafeArea().accessibilityHidden(true)
                }
                if let art, !reduceMotion { LoopingVideo(url: art).ignoresSafeArea().accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 12) {
                    Spacer()
                    if art == nil, poster == nil { BrandMark(withSound: false).frame(width: 64, height: 64) }
                    Text("Getting \(ModelCatalog.model(id)?.name ?? id) ready").font(FFFont.display(30))
                        .foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("loader.title")
                    Text(models.loadLabel(id, now: now) ?? "").font(FFFont.text(17, .semibold))
                        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("loader.label")
                    Text("Keep Free Flow open while it prepares. It pauses while Free Flow is in the background.")
                        .font(FFFont.text(15)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Go to Home", action: hide).font(FFFont.text(15, .semibold)).foregroundStyle(Palette.fg)
                        .buttonStyle(.plain).accessibilityIdentifier("loader.hide").padding(.top, 4)
                }
                .padding(24)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .bottomLeading)
                .background(alignment: .bottom) {
                    if art != nil || poster != nil {      // the text stays readable over the graphic
                        LinearGradient(colors: [Palette.bg.opacity(0), Palette.bg.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 340).ignoresSafeArea()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loader")
    }
}

/// The loader's motion graphic, when it is in the app: Resources/Loader/loop-portrait.mov and loop-landscape.mov
/// (HEVC, muted loops). Either one stands in for the other.
enum LoaderArt {
    static func url(landscape: Bool) -> URL? {
        let first = landscape ? "loop-landscape" : "loop-portrait", second = landscape ? "loop-portrait" : "loop-landscape"
        return Bundle.main.url(forResource: first, withExtension: "mov") ?? Bundle.main.url(forResource: second, withExtension: "mov")
    }
    /// poster-portrait.png / poster-landscape.png: the loop's first frame.
    static func poster(landscape: Bool) -> UIImage? {
        let first = landscape ? "poster-landscape" : "poster-portrait", second = landscape ? "poster-portrait" : "poster-landscape"
        let url = Bundle.main.url(forResource: first, withExtension: "png") ?? Bundle.main.url(forResource: second, withExtension: "png")
        return url.flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

/// A muted, endless loop of one video file (AVPlayerLooper). Muted always: Free Flow never plays sound over the user's audio.
private struct LoopingVideo: UIViewRepresentable {
    let url: URL

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.looper = nil
        view.playerLayer.player = nil
    }
}
