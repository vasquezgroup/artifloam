import AVKit
import Photos
import PhotosUI
import SwiftUI

/// What a tap on a picture opens: the picture full screen, videos playing, swipe for the next one, and a large button to choose it.
/// The way Photos works, so nobody has to learn holding or long presses.
struct PhotoViewer: View {
    let items: [PhotoItem]
    /// Copies that stay. They can be looked at but not chosen.
    let keeps: Set<String>
    @Binding var selection: Set<String>
    let start: String
    @State private var position: String?
    @Environment(\.dismiss) private var dismiss

    private var current: PhotoItem? { items.first { $0.id == (position ?? start) } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        ViewerPage(item: item, showing: item.id == (position ?? start)).containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44).background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel("Close")
            .padding(.leading, 16).padding(.top, 8)
        }
        .overlay(alignment: .bottom) { if let current { bar(current) } }
        .onAppear { position = start }
        .statusBarHidden()
    }

    private func bar(_ item: PhotoItem) -> some View {
        let chosen = selection.contains(item.id)
        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                // iOS's own LIVE badge, so it's clear holding will play it.
                if item.asset.mediaSubtypes.contains(.photoLive) {
                    Image(uiImage: PHLivePhotoView.livePhotoBadgeImage(options: .overContent)).accessibilityLabel("Live Photos")
                }
                Text("\(formatted(item.saving)) · \(item.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                    .font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.85)).monospacedDigit()
            }
            if keeps.contains(item.id) {
                Text("Stays").font(.headline).foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 12).background(StewardTheme.cleanup.vivid, in: .capsule)
            } else {
                Button {
                    if !selection.insert(item.id).inserted { selection.remove(item.id) }
                } label: {
                    Label(chosen ? "Selected" : "Select", systemImage: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.headline).foregroundStyle(.white).padding(.horizontal, 26).padding(.vertical, 13)
                        .background(chosen ? AnyShapeStyle(StewardTheme.care.vivid) : AnyShapeStyle(.ultraThinMaterial), in: .capsule)
                }
                .sensoryFeedback(.selection, trigger: chosen)
            }
        }
        .padding(.bottom, 24)
    }
}

/// One picture, as large as the screen allows. A video plays only while it's the one showing, without sound until unmuted.
private struct ViewerPage: View {
    let item: PhotoItem
    let showing: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player, item.asset.mediaType == .video {
                VideoPlayer(player: player)
            } else if let picture = image ?? Thumbnails.cached(item.id) {
                // The grid's small version straight away, the sharp one as soon as it arrives.
                Image(uiImage: picture).resizable().scaledToFit()
                // Moves while held, as in Photos.
                if item.asset.mediaSubtypes.contains(.photoLive) && showing { LivePhotoView(asset: item.asset) }
                if item.asset.mediaType == .video && showing { ProgressView().tint(.white).padding(12).background(.black.opacity(0.45), in: Circle()) }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) { await Thumbnails.load(item.asset, id: item.id, side: 1200) { image = $0 } }
        .task(id: showing) {
            guard showing, item.asset.mediaType == .video else { player?.pause(); return }
            if player == nil {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                // Starts streaming from iCloud much sooner than the original, and looks the same on a phone screen.
                options.deliveryMode = .mediumQualityFormat
                let playerItem: AVPlayerItem? = await withCheckedContinuation { continuation in
                    PHImageManager.default().requestPlayerItem(forVideo: item.asset, options: options) { result, _ in continuation.resume(returning: result) }
                }
                if let playerItem { player = AVPlayer(playerItem: playerItem) }
            }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }
}

/// A Live Photo that moves: while held, as in Photos, or straight away for a preview.
struct LivePhotoView: UIViewRepresentable {
    let asset: PHAsset
    var autoplay = false

    final class Coordinator { var request: PHImageRequestID? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        // A preview plays silently, like videos there. Held full screen, it has its sound, as in Photos.
        view.isMuted = autoplay
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let autoplay = autoplay
        context.coordinator.request = PHImageManager.default().requestLivePhoto(for: asset, targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit, options: options) { [weak view] photo, _ in
            guard let view, let photo else { return }
            view.livePhoto = photo
            if autoplay { view.startPlayback(with: .full) }
        }
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {}

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        if let request = coordinator.request { PHImageManager.default().cancelImageRequest(request) }
    }
}
