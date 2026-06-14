import SwiftUI
import OpenPhotoCore

extension MLCapability {
    var displayName: String {
        switch self {
        case .faceRecognition: return "Face recognition"
        case .semanticSearch:  return "Semantic search"
        }
    }
}

/// Loud, persistent banner shown at the top of the main window whenever a CoreML capability is
/// present-but-broken on this Mac. Renders nothing when everything is fine (or merely `.absent`).
struct MLUnavailableBanner: View {
    @Bindable var state: AppState

    var body: some View {
        let items = state.mlUnavailable
        if !items.isEmpty {
            VStack(spacing: 4) {
                ForEach(items, id: \.capability) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(item.capability.displayName) is unavailable on this Mac — the model couldn't be loaded.")
                            .fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    .help(item.reason)   // full error on hover
                }
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.red)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
