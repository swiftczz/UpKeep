import Foundation

extension AppRecord {
    var channelTitle: String { updateConfiguration.channel.title }

    var mechanismTitle: String { updateConfiguration.mechanism.title }

    var channelSystemImage: String { updateConfiguration.channel.systemImage }

    var channelPlatformSystemImage: String? {
        guard updateConfiguration.mechanism == .appStore else { return nil }
        return appStorePlatform?.systemImage
    }

}
