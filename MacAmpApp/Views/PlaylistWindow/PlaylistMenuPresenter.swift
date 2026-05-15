import SwiftUI
import AppKit

@MainActor
struct PlaylistMenuPresenter {
    let skinManager: SkinManager
    let audioPlayer: AudioPlayer
    let windowHeight: CGFloat
    let windowWidth: CGFloat
    let selectedIndices: Set<Int>

    private static let popupBottomFromWindowBottom: CGFloat = 12
    private static let addPopupLeft: CGFloat = 14
    private static let remPopupLeft: CGFloat = 43
    private static let miscPopupLeft: CGFloat = 101
    private static let listPopupRight: CGFloat = 22

    func showAddMenu() {
        let tiles: [PlaylistSpritePopupTile] = [
            tile("PLAYLIST_ADD_URL", "PLAYLIST_ADD_URL_SELECTED",
                 PlaylistWindowActions.shared.addURL),
            tile("PLAYLIST_ADD_DIR", "PLAYLIST_ADD_DIR_SELECTED",
                 PlaylistWindowActions.shared.addDirectory),
            tile("PLAYLIST_ADD_FILE", "PLAYLIST_ADD_FILE_SELECTED",
                 PlaylistWindowActions.shared.addFile),
        ]
        present(tiles: tiles, barSprite: "PLAYLIST_ADD_MENU_BAR", tilesLeft: Self.addPopupLeft)
    }

    func showRemMenu() {
        PlaylistWindowActions.shared.selectedIndices = selectedIndices

        let tiles: [PlaylistSpritePopupTile] = [
            tile("PLAYLIST_REMOVE_MISC", "PLAYLIST_REMOVE_MISC_SELECTED",
                 PlaylistWindowActions.shared.removeMisc),
            tile("PLAYLIST_REMOVE_ALL", "PLAYLIST_REMOVE_ALL_SELECTED",
                 PlaylistWindowActions.shared.removeAll),
            tile("PLAYLIST_CROP", "PLAYLIST_CROP_SELECTED",
                 PlaylistWindowActions.shared.cropPlaylist),
            tile("PLAYLIST_REMOVE_SELECTED", "PLAYLIST_REMOVE_SELECTED_SELECTED",
                 PlaylistWindowActions.shared.removeSelected),
        ]
        present(tiles: tiles, barSprite: "PLAYLIST_REMOVE_MENU_BAR", tilesLeft: Self.remPopupLeft)
    }

    func showSelNotSupportedAlert() {
        WinampAlertHelper.showInfo(
            title: "Selection Menu",
            message: "Not supported yet. Use Shift+click for multi-select (planned feature)."
        )
    }

    func showMiscMenu() {
        let tiles: [PlaylistSpritePopupTile] = [
            tile("PLAYLIST_SORT_LIST", "PLAYLIST_SORT_LIST_SELECTED",
                 PlaylistWindowActions.shared.sortList),
            tile("PLAYLIST_FILE_INFO", "PLAYLIST_FILE_INFO_SELECTED",
                 PlaylistWindowActions.shared.fileInfo),
            tile("PLAYLIST_MISC_OPTIONS", "PLAYLIST_MISC_OPTIONS_SELECTED",
                 PlaylistWindowActions.shared.miscOptions),
        ]
        present(tiles: tiles, barSprite: "PLAYLIST_MISC_MENU_BAR", tilesLeft: Self.miscPopupLeft)
    }

    func showListMenu() {
        let tiles: [PlaylistSpritePopupTile] = [
            tile("PLAYLIST_NEW_LIST", "PLAYLIST_NEW_LIST_SELECTED",
                 PlaylistWindowActions.shared.newList),
            tile("PLAYLIST_SAVE_LIST", "PLAYLIST_SAVE_LIST_SELECTED",
                 PlaylistWindowActions.shared.saveList),
            tile("PLAYLIST_LOAD_LIST", "PLAYLIST_LOAD_LIST_SELECTED",
                 PlaylistWindowActions.shared.loadList),
        ]
        let tilesLeft = windowWidth - Self.listPopupRight - PlaylistSpritePopup.tileWidth
        present(tiles: tiles, barSprite: "PLAYLIST_LIST_BAR", tilesLeft: tilesLeft)
    }

    private func tile(
        _ normal: String,
        _ selected: String,
        _ action: @escaping (NSMenuItem) -> Void
    ) -> PlaylistSpritePopupTile {
        let player = audioPlayer
        return PlaylistSpritePopupTile(
            normalSprite: normal,
            selectedSprite: selected,
            action: {
                let item = NSMenuItem()
                item.representedObject = player
                action(item)
            }
        )
    }

    private func present(tiles: [PlaylistSpritePopupTile], barSprite: String, tilesLeft: CGFloat) {
        guard let window = WindowCoordinator.shared?.playlistWindow else { return }

        let panelLeft = tilesLeft - PlaylistSpritePopup.barWidth
        let originInWindow = NSPoint(x: panelLeft, y: Self.popupBottomFromWindowBottom)
        let screenOrigin = window.convertPoint(toScreen: originInWindow)

        PlaylistSpritePopupHost.show(
            tiles: tiles,
            barSprite: barSprite,
            screenOrigin: screenOrigin,
            skinManager: skinManager,
            parentWindow: window
        )
    }
}
