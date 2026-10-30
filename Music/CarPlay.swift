import CarPlay
import UIKit

/// CarPlay audio app: Library, Playlists, Recently Played and Downloads as lists, plus the system Now Playing screen.
/// (Needs the CarPlay Audio entitlement from Apple for device builds; the simulator build carries it for testing.)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let tabs = CPTabBarTemplate(templates: [libraryTemplate(), playlistsTemplate(), recentTemplate(), downloadsTemplate()])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    private var library: LibraryStore? { AppServices.shared.library }
    private var player: PlayerModel? { AppServices.shared.player }

    // MARK: Templates

    private func libraryTemplate() -> CPListTemplate {
        let shuffle = CPListItem(text: "Shuffle All", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffle.handler = { [weak self] _, done in
            if let lib = self?.library { self?.play(lib.tracks.shuffled(), title: "All Songs") }
            done()
        }
        let favorites = CPListItem(text: "Favorites", detailText: nil, image: UIImage(systemName: "star.fill"))
        favorites.handler = { [weak self] _, done in
            if let lib = self?.library { self?.play(lib.tracks.filter(\.isFavorite).shuffled(), title: "Favorites") }
            done()
        }
        let artists = CPListItem(text: "Artists", detailText: nil, image: UIImage(systemName: "music.mic"))
        artists.accessoryType = .disclosureIndicator
        artists.handler = { [weak self] _, done in
            if let self, let lib = library { interfaceController?.pushTemplate(entriesTemplate("Artists", lib.artistEntries), animated: true, completion: nil) }
            done()
        }
        let albums = CPListItem(text: "Albums", detailText: nil, image: UIImage(systemName: "square.stack"))
        albums.accessoryType = .disclosureIndicator
        albums.handler = { [weak self] _, done in
            if let self, let lib = library { interfaceController?.pushTemplate(entriesTemplate("Albums", lib.albumEntries), animated: true, completion: nil) }
            done()
        }
        let t = CPListTemplate(title: "Library", sections: [CPListSection(items: [shuffle, favorites, artists, albums])])
        t.tabImage = UIImage(systemName: "music.note")
        return t
    }

    private func playlistsTemplate() -> CPListTemplate {
        let t = entriesTemplate("Playlists", library?.playlistEntries ?? [])
        t.tabImage = UIImage(systemName: "music.note.list")
        return t
    }

    private func recentTemplate() -> CPListTemplate {
        let played = (library?.tracks ?? []).filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }.prefix(50)
        let t = CPListTemplate(title: "Recent", sections: [CPListSection(items: trackItems(Array(played), title: "Recently Played"))])
        t.tabImage = UIImage(systemName: "clock")
        return t
    }

    private func downloadsTemplate() -> CPListTemplate {
        let offline = SmartShuffle.libraryOrder((library?.tracks ?? []).filter(\.isOffline)).prefix(300)
        let t = CPListTemplate(title: "Downloads", sections: [CPListSection(items: trackItems(Array(offline), title: "On This iPhone"))])
        t.tabImage = UIImage(systemName: "arrow.down.circle")
        return t
    }

    private func entriesTemplate(_ title: String, _ entries: [LibraryEntry]) -> CPListTemplate {
        let items: [CPListItem] = entries.prefix(CPListTemplate.maximumItemCount).map { e in
            let item = CPListItem(text: e.title, detailText: e.subtitle, image: e.tracks.first(where: \.hasArtwork).flatMap { ArtworkCache.image(for: $0, maxPixel: 180) })
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                guard let self else { done(); return }
                let list = CPListTemplate(title: e.title, sections: [CPListSection(items: trackItems(e.tracks, title: e.title))])
                interfaceController?.pushTemplate(list, animated: true, completion: nil)
                done()
            }
            return item
        }
        return CPListTemplate(title: title, sections: [CPListSection(items: items)])
    }

    private func trackItems(_ tracks: [Track], title: String) -> [CPListItem] {
        tracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { i, t in
            let item = CPListItem(text: t.title, detailText: t.artist, image: ArtworkCache.image(for: t, maxPixel: 180))
            item.handler = { [weak self] _, done in
                self?.player?.play(tracks, startAt: i, title: title)
                self?.showNowPlaying()
                done()
            }
            return item
        }
    }

    private func play(_ tracks: [Track], title: String) {
        guard !tracks.isEmpty else { return }
        player?.play(tracks, title: title)
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let ic = interfaceController, ic.topTemplate !== CPNowPlayingTemplate.shared else { return }
        ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
