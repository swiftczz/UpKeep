import SwiftUI

struct AppSourceIconView: View {
  let application: AppRecord

  var body: some View {
    Group {
      if application.source == .appStore {
        HStack(spacing: 2) {
          Image(systemName: application.sourceSystemImage)

          if let platformSystemImage = application.sourcePlatformSystemImage {
            Image(systemName: platformSystemImage)
              .font(.system(size: 8, weight: .semibold))
          }
        }
      } else {
        Image(systemName: application.sourceSystemImage)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(application.sourceTitle)
  }
}
