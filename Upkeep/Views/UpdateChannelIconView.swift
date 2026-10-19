import SwiftUI

struct UpdateChannelIconView: View {
  let application: AppRecord

  var body: some View {
    Group {
      if application.updateConfiguration.mechanism == .appStore {
        HStack(spacing: 2) {
          Image(systemName: application.channelSystemImage)

          if let platformSystemImage = application.channelPlatformSystemImage {
            Image(systemName: platformSystemImage)
              .font(.system(size: 8, weight: .semibold))
          }
        }
      } else {
        Image(systemName: application.channelSystemImage)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(application.channelTitle)
  }
}
