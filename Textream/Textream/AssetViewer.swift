//
//  AssetViewer.swift
//  Textream
//

import AVKit
import Quartz
import SwiftUI

/// A file from a project, shown where the script normally is.
///
/// The point of a project is that the take and the script it came from sit together, so watching
/// one back happens in the same window and beside the same teleprompter, not in another app.
struct AssetViewerPane: View {
    let asset: ProjectAsset
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            body(for: asset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(asset.displayName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(asset.url.pathExtension.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(Capsule())

            Spacer(minLength: 0)

            Text(asset.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([asset.url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the script")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func body(for asset: ProjectAsset) -> some View {
        switch asset.kind {
        case .video, .audio:
            // A take is watched with a scrubber and a volume control, which is what AVKit's own
            // player gives and Quick Look does not.
            MoviePlayer(url: asset.url)
                .background(Color.black)
        case .script, .image, .document:
            // Everything else is whatever Quick Look makes of it, which is the same preview
            // Finder would give and needs no per-format code here.
            QuickLookPreview(url: asset.url)
        }
    }
}

/// AVKit's player, kept alive across redraws and stopped when the file is closed.
private struct MoviePlayer: View {
    let url: URL
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
            .onChange(of: url) { _, newValue in
                player.replaceCurrentItem(with: AVPlayerItem(url: newValue))
            }
            .onDisappear { player.pause() }
    }
}

/// Quick Look, the same preview the space bar gives in Finder.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
