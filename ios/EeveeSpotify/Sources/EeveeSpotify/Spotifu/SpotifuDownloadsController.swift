import UIKit

/// Own-library browser inside Spotify. Audio stays with Spotify's native player.
@MainActor final class SpotifuDownloadsController: UITableViewController {
    private var albums: [(String, [OfflineTrack])] = []
    private var refreshTimer: Timer?
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Скачанное · Spotifu"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        reloadLibrary()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadLibrary() }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate(); refreshTimer = nil
    }
    @objc private func close() { dismiss(animated: true) }
    private func reloadLibrary() {
        let model = OfflineModel.shared
        try? model.reload()
        albums = Dictionary(grouping: model.tracks, by: { $0.album?.isEmpty == false ? $0.album! : "Без альбома" })
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
        navigationItem.prompt = SpotifuBridge.downloadStatus
        tableView.backgroundView = model.tracks.isEmpty ? emptyLabel() : nil
        tableView.reloadData()
    }
    private func emptyLabel() -> UILabel {
        let label = UILabel(); label.text = "Здесь появятся только загрузки Spotifu"; label.textAlignment = .center
        label.textColor = .secondaryLabel; label.numberOfLines = 0; return label
    }
    override func numberOfSections(in tableView: UITableView) -> Int { albums.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { albums[section].1.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { albums[section].0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let track = albums[indexPath.section].1[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = track.title; cell.detailTextLabel?.text = track.artist
        cell.imageView?.image = UIImage(systemName: "checkmark.circle.fill"); cell.imageView?.tintColor = .systemGreen
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.accessibilityLabel = "Действия со скачанной песней"
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIAction(title: "Удалить из скачанного", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            OfflineModel.shared.remove(track); self?.reloadLibrary()
        }])
        more.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        cell.accessoryView = more
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let track = albums[indexPath.section].1[indexPath.row]
        // Standard Spotify local-file URI; exact iOS scanner resolution needs
        // device acceptance testing for this pinned Spotify release.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let parts = [track.artist, "Spotifu", track.title].map { $0.addingPercentEncoding(withAllowedCharacters: safe) ?? "" }
        guard let url = URL(string: "spotify:local:" + parts.joined(separator: ":") + ":" + String(Int(track.duration))) else { return }
        dismiss(animated: true) { UIApplication.shared.open(url, options: [:]) }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let track = albums[indexPath.section].1[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Удалить") { [weak self] _, _, finish in
            OfflineModel.shared.remove(track); self?.reloadLibrary(); finish(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}
