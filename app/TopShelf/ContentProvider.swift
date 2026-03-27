#if os(tvOS)
import TVServices
import Foundation

class ContentProvider: TVTopShelfContentProvider {

    private static let appGroupId = "group.com.plaiy.app.tv"

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        let items = ResumeStore.allResumeItems()
        guard !items.isEmpty else { return nil }

        let section = TVTopShelfItemCollection(items: items.prefix(10).map { item in
            let tvItem = TVTopShelfSectionedItem(identifier: item.path)
            tvItem.title = item.title
            tvItem.setImageURL(nil, for: .screenScale1x)

            var components = URLComponents()
            components.scheme = "plaiy"
            components.host = "play"
            components.queryItems = [URLQueryItem(name: "path", value: item.path)]
            if let url = components.url {
                tvItem.displayAction = TVTopShelfAction(url: url)
                tvItem.playAction = TVTopShelfAction(url: url)
            }

            return tvItem
        })
        section.title = "Continue Watching"

        return TVTopShelfSectionedContent(sections: [section])
    }
}
#endif
