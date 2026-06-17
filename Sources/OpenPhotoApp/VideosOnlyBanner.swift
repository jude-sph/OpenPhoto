import SwiftUI
import OpenPhotoCore

/// Slim, dismissible indicator shown wherever browse counts/contents are filtered to videos only.
/// The "videos only" toggle is a small unlabelled toolbar button whose state persists across
/// launches, so without this banner a stray tap silently shrinks every folder count — which reads
/// as "my photos vanished" (a real support confusion). Renders nothing when the filter is off.
/// Tapping "Show all" clears the filter (its `didSet` refreshes every query).
struct VideosOnlyBanner: View {
    @Bindable var state: AppState

    var body: some View {
        if state.videoOnly {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10))
                Text("Showing videos only")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .help("Photos are hidden by the videos-only filter — they are not lost.")
                Spacer(minLength: 4)
                Button { state.videoOnly = false } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        Text("Show all").font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("Clear the videos-only filter and show all photos and videos.")
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.14))
            .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
