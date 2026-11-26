import SwiftUI
import AppKit

@MainActor
struct PlaylistMenuPresenter {
    let skinManager: SkinManager
    let audioPlayer: AudioPlayer
    let windowHeight: CGFloat
    let windowWidth: CGFloat
    let interactionState: PlaylistWindowInteractionState

    private static let popupBottomFromWindowBottom: CGFloat = 12
    private static let addPopupLeft: CGFloat = 14
    private static let remPopupLeft: CGFloat = 43
    private static let selPopupLeft: CGFloat = 72
    private static let miscPopupLeft: CGFloat = 101
    private static let listPopupRight: CGFloat = 22

    func showAddMenu() {
        let tiles: [PlaylistSpritePopupTile] = [
            tile("PLAYLIST_ADD_URL", "PLAYLIST_ADD_URL_SELECTED", "Add an internet radio URL",
                 PlaylistWindowActions.shared.addURL),
            tile("PLAYLIST_ADD_DIR", "PLAYLIST_ADD_DIR_SELECTED", "Add a directory to the playlist",
                 PlaylistWindowActions.shared.addDirectory),
            tile("PLAYLIST_ADD_FILE", "PLAYLIST_ADD_FILE_SELECTED", "Add files to the playlist",
                 PlaylistWindowActions.shared.addFile),
        ]
        present(tiles: tiles, barSprite: "PLAYLIST_ADD_MENU_BAR", tilesLeft: Self.addPopupLeft)
    }

    func showRemMenu() {
        present(tiles: Self.makeRemoveTiles(audioPlayer: audioPlayer, interactionState: interactionState,
                                          removeMisc: { showRemoveMiscMenu() }),
                barSprite: "PLAYLIST_REMOVE_MENU_BAR", tilesLeft: Self.remPopupLeft)
    }

    static func makeRemoveTiles(
        audioPlayer: AudioPlayer,
        interactionState: PlaylistWindowInteractionState,
        actions: PlaylistWindowActions = .shared,
        removeMisc: @escaping () -> Void
    ) -> [PlaylistSpritePopupTile] {
        [
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_REMOVE_MISC",
                selectedSprite: "PLAYLIST_REMOVE_MISC_SELECTED",
                help: "Open options to remove missing entries or move selected files to Trash",
                action: removeMisc
            ),
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_REMOVE_ALL", selectedSprite: "PLAYLIST_REMOVE_ALL_SELECTED",
                help: "Clear the playlist", action: { audioPlayer.clearPlaylist() }
            ),
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_CROP", selectedSprite: "PLAYLIST_CROP_SELECTED",
                help: "Remove all unselected entries from the playlist",
                action: { actions.cropPlaylist(audioPlayer: audioPlayer, interactionState: interactionState) }
            ),
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_REMOVE_SELECTED", selectedSprite: "PLAYLIST_REMOVE_SELECTED_SELECTED",
                help: "Remove selected entries from the playlist",
                action: { actions.removeSelected(audioPlayer: audioPlayer, interactionState: interactionState) }
            ),
        ]
    }

    private func showRemoveMiscMenu() {
        guard !UnitTestSupport.isActive else { return }
        Task { @MainActor in
            guard let window = WindowCoordinator.shared?.playlistWindow else { return }
            PlaylistSpritePopupHost.current?.dismiss()
            let menu = Self.makeRemoveMiscMenu(audioPlayer: audioPlayer, interactionState: interactionState)
            let origin = window.convertPoint(toScreen: NSPoint(x: 64, y: 84))
            menu.popUp(positioning: nil, at: origin, in: nil)
        }
    }

    static func makeRemoveMiscMenu(
        audioPlayer: AudioPlayer,
        interactionState: PlaylistWindowInteractionState
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuItemFactory.createMenuItem(title: "Remove missing files from playlist") {
            Task { @MainActor in
                await PlaylistWindowActions.shared.removeMissingFiles(
                    audioPlayer: audioPlayer, interactionState: interactionState
                )
            }
        })
        menu.addItem(MenuItemFactory.createMenuItem(title: "Physically remove selected file(s)") {
            Task { @MainActor in
                await PlaylistWindowActions.shared.physicallyRemoveSelectedFiles(
                    audioPlayer: audioPlayer, interactionState: interactionState
                )
            }
        })
        return menu
    }

    func showSelMenu() {
        present(tiles: Self.makeSelectionTiles(audioPlayer: audioPlayer, interactionState: interactionState),
                barSprite: "PLAYLIST_SELECT_MENU_BAR", tilesLeft: Self.selPopupLeft)
    }

    static func makeSelectionTiles(
        audioPlayer: AudioPlayer,
        interactionState: PlaylistWindowInteractionState,
        actions: PlaylistWindowActions = .shared
    ) -> [PlaylistSpritePopupTile] {
        func selectionTile(_ sprite: String, help: String, select: @escaping () -> Void) -> PlaylistSpritePopupTile {
            PlaylistSpritePopupTile(normalSprite: sprite, selectedSprite: sprite + "_SELECTED", help: help) {
                select()
                actions.selectedIndices = interactionState.selectedIndices
            }
        }
        return [
            selectionTile("PLAYLIST_INVERT_SELECTION", help: "Invert selection") {
                interactionState.invertSelection(playlistCount: audioPlayer.playlist.count)
            },
            selectionTile("PLAYLIST_SELECT_ZERO", help: "Select none") {
                interactionState.selectNone()
            },
            selectionTile("PLAYLIST_SELECT_ALL", help: "Select all") {
                interactionState.selectAll(playlistCount: audioPlayer.playlist.count)
            },
        ]
    }

    func showMiscMenu() {
        let tiles: [PlaylistSpritePopupTile] = [
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_SORT_LIST",
                selectedSprite: "PLAYLIST_SORT_LIST_SELECTED",
                help: "Open playlist sorting actions",
                action: { showSortMenu() }
            ),
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_FILE_INFO", selectedSprite: "PLAYLIST_FILE_INFO_SELECTED",
                help: "Open file information actions",
                action: { showFileInfoMenu() }
            ),
            PlaylistSpritePopupTile(
                normalSprite: "PLAYLIST_MISC_OPTIONS", selectedSprite: "PLAYLIST_MISC_OPTIONS_SELECTED",
                help: "Open miscellaneous playlist options",
                action: { showMiscOptionsMenu() }
            ),
        ]
        present(tiles: tiles, barSprite: "PLAYLIST_MISC_MENU_BAR", tilesLeft: Self.miscPopupLeft)
    }

    static func makeFileInfoMenu(
        audioPlayer: AudioPlayer,
        interactionState: PlaylistWindowInteractionState,
        actions: PlaylistWindowActions = .shared,
        editEntries: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuItemFactory.createMenuItem(title: "File info...") {
            actions.fileInfo(audioPlayer: audioPlayer, interactionState: interactionState)
        })
        menu.addItem(MenuItemFactory.createMenuItem(title: "Playlist entry...", action: editEntries))
        return menu
    }

    static func makeMiscOptionsMenu(
        generateHTML: @escaping () -> Void,
        rebuildTitles: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuItemFactory.createMenuItem(title: "Generate HTML playlist", action: generateHTML))
        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.createMenuItem(title: "Rebuild titles on selection", action: rebuildTitles))
        return menu
    }

    private func showMiscOptionsMenu() {
        guard !UnitTestSupport.isActive else { return }
        Task { @MainActor in
            guard let window = WindowCoordinator.shared?.playlistWindow else { return }
            PlaylistSpritePopupHost.current?.dismiss()
            let actions = PlaylistWindowActions.shared
            let menu = Self.makeMiscOptionsMenu(generateHTML: {
                actions.generateHTMLPlaylist(audioPlayer: audioPlayer)
            }, rebuildTitles: {
                actions.rebuildTitles(audioPlayer: audioPlayer, interactionState: interactionState)
            })
            let origin = window.convertPoint(toScreen: NSPoint(x: 122, y: 30))
            menu.popUp(positioning: nil, at: origin, in: nil)
        }
    }

    private func showFileInfoMenu() {
        guard !UnitTestSupport.isActive else { return }
        Task { @MainActor in
            guard let window = WindowCoordinator.shared?.playlistWindow else { return }
            PlaylistSpritePopupHost.current?.dismiss()
            let menu = Self.makeFileInfoMenu(audioPlayer: audioPlayer, interactionState: interactionState) {
                let editor = PlaylistEntryEditor()
                PlaylistWindowActions.shared.editPlaylistEntries(
                    audioPlayer: audioPlayer, interactionState: interactionState, prompt: editor.prompt
                )
            }
            let origin = window.convertPoint(toScreen: NSPoint(x: 122, y: 48))
            menu.popUp(positioning: nil, at: origin, in: nil)
        }
    }

    private func showSortMenu() {
        guard !UnitTestSupport.isActive else { return }
        Task { @MainActor in
            guard let window = WindowCoordinator.shared?.playlistWindow else { return }
            PlaylistSpritePopupHost.current?.dismiss()
            let contentHeight = windowHeight - PlaylistWindowSizeState.topBarHeight - PlaylistWindowSizeState.bottomBarHeight
            let menu = Self.makeSortMenu(
                audioPlayer: audioPlayer, interactionState: interactionState,
                visibleTrackCount: Int(contentHeight / PlaylistWindowSizeState.trackRowHeight)
            )
            let origin = window.convertPoint(toScreen: NSPoint(x: 122, y: 66))
            menu.popUp(positioning: nil, at: origin, in: nil)
        }
    }

    static func makeSortMenu(
        audioPlayer: AudioPlayer,
        interactionState: PlaylistWindowInteractionState,
        visibleTrackCount: Int
    ) -> NSMenu {
        let menu = NSMenu()
        for ordering in PlaylistOrdering.allCases {
            if ordering == .reverse { menu.addItem(.separator()) }
            menu.addItem(MenuItemFactory.createMenuItem(title: ordering.menuTitle) {
                PlaylistWindowActions.shared.sortList(
                    ordering, audioPlayer: audioPlayer, interactionState: interactionState,
                    visibleTrackCount: visibleTrackCount
                )
            })
        }
        return menu
    }

    func showListMenu() {
        let tiles: [PlaylistSpritePopupTile] = [
            tile("PLAYLIST_NEW_LIST", "PLAYLIST_NEW_LIST_SELECTED", "Clear the playlist and start an empty list",
                 PlaylistWindowActions.shared.newList),
            tile("PLAYLIST_SAVE_LIST", "PLAYLIST_SAVE_LIST_SELECTED", "Save the playlist to a file",
                 PlaylistWindowActions.shared.saveList),
            tile("PLAYLIST_LOAD_LIST", "PLAYLIST_LOAD_LIST_SELECTED", "Replace the current playlist from a file",
                 PlaylistWindowActions.shared.loadList),
        ]
        let tilesLeft = windowWidth - Self.listPopupRight - PlaylistSpritePopup.tileWidth
        present(tiles: tiles, barSprite: "PLAYLIST_LIST_BAR", tilesLeft: tilesLeft)
    }

    private func tile(
        _ normal: String,
        _ selected: String,
        _ help: String,
        _ action: @escaping (NSMenuItem) -> Void
    ) -> PlaylistSpritePopupTile {
        let player = audioPlayer
        return PlaylistSpritePopupTile(
            normalSprite: normal,
            selectedSprite: selected,
            help: help,
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
