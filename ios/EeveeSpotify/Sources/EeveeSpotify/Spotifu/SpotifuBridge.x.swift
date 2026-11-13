import UIKit
import SwiftUI
import Orion
import MediaPlayer

@objc private protocol SpotifuPauseController { func setPaused(_ paused: Bool) }

@MainActor enum SpotifuBridge {
    static weak var controller: NSObject?
    static func pauseSpotify() {
        if let controller, controller.responds(to: NSSelectorFromString("setPaused:")) {
            unsafeBitCast(controller, to: SpotifuPauseController.self).setPaused(true)
        }
    }
    static func metadata() -> (id: String, title: String, artist: String, duration: Double)? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              let title = info[MPMediaItemPropertyTitle] as? String,
              let artist = info[MPMediaItemPropertyArtist] as? String,
              let id = capturedTrackId, !id.isEmpty,
              capturedTrackTitle == title, capturedArtistName == artist else { return nil }
        return (id, title, artist, (info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? 0)
    }
    static func openDownloads() {
        let info = metadata()
        let view = DownloadsView(title: info?.title ?? "", artist: info?.artist ?? "", trackID: info?.id ?? "", duration: info?.duration ?? 0, beforePlay: pauseSpotify)
        let host = UIHostingController(rootView: NavigationView { view })
        WindowHelper.shared.present(host)
    }
    static func downloadCurrent() {
        guard let info = metadata(), info.duration > 0 else {
            PopUpHelper.showPopUp(message: "Не удалось определить текущую песню. Открой её текст и попробуй снова.", buttonText: "OK")
            return
        }
        let model = OfflineModel.shared
        guard !model.busy else { return }
        if model.tracks.contains(where: { $0.id == info.id }) {
            PopUpHelper.showPopUp(message: "Уже загружено", buttonText: "OK"); return
        }
        Task {
            await model.download(url: "", id: info.id, title: info.title, artist: info.artist, duration: info.duration)
            PopUpHelper.showPopUp(message: model.error ?? model.status, buttonText: "OK")
        }
    }
    static func attach(to cover: UIView) {
        let tag = 18001991
        guard cover.viewWithTag(tag) == nil else { return }
        let button = UIButton(type: .system)
        button.tag = tag
        button.setImage(UIImage(systemName: "arrow.down.circle.fill"), for: .normal)
        button.accessibilityLabel = "Скачать в Spotifu"
        button.tintColor = .systemGreen
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { _ in downloadCurrent() }, for: .touchUpInside)
        cover.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -12),
            button.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -12),
            button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
}

// Independent of optional gesture settings. Selector compatibility still needs
// on-device validation against each Spotify release before claiming support.
class SpotifuControllerHook: ClassHook<NSObject> {
    static let targetName = "SPTNowPlayingPlaybackControllerImplementation"
    func initWithPlayer(_ player: AnyObject?, testManager: AnyObject?, inStreamClient: AnyObject?) -> Target {
        let result = orig.initWithPlayer(player, testManager: testManager, inStreamClient: inStreamClient)
        DispatchQueue.main.async { SpotifuBridge.controller = result }
        return result
    }
}
class SpotifuCoverHook: ClassHook<UIView> {
    static let targetName = "_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView"
    func layoutSubviews() {
        orig.layoutSubviews()
        let view = target
        DispatchQueue.main.async { SpotifuBridge.attach(to: view) }
    }
}
