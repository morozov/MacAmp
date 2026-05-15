import SwiftUI

struct PlaylistSpritePopupTile: Identifiable {
    let id = UUID()
    let normalSprite: String
    let selectedSprite: String
    let action: () -> Void
}

struct PlaylistSpritePopup: View {
    static let tileWidth: CGFloat = 22
    static let tileHeight: CGFloat = 18
    static let barWidth: CGFloat = 3

    let tiles: [PlaylistSpritePopupTile]
    let barSprite: String
    let onItemFired: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SimpleSpriteImage(
                barSprite,
                width: Self.barWidth,
                height: Self.tileHeight * CGFloat(tiles.count)
            )
            VStack(spacing: 0) {
                ForEach(tiles) { tile in
                    PlaylistSpritePopupTileView(tile: tile) {
                        tile.action()
                        onItemFired()
                    }
                }
            }
        }
        .fixedSize()
    }
}

private struct PlaylistSpritePopupTileView: View {
    let tile: PlaylistSpritePopupTile
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        SimpleSpriteImage(
            isHovered ? tile.selectedSprite : tile.normalSprite,
            width: PlaylistSpritePopup.tileWidth,
            height: PlaylistSpritePopup.tileHeight
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { onTap() }
    }
}
