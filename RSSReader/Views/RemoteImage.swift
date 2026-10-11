import SwiftUI
import UIKit

/// 썸네일 로더. 내려받은 이미지는 ImageCache 에 저장해 오프라인에서도 보인다.
enum ThumbnailLoader {
    nonisolated(unsafe) private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func load(_ urlString: String?, maxPixel: CGFloat = 600) async -> UIImage? {
        guard let urlString, urlString.hasPrefix("http") else { return nil }
        let memKey = "\(urlString)#\(Int(maxPixel))" as NSString
        if let cached = memory.object(forKey: memKey) { return cached }
        let file = ImageCache.fileURL(forKey: ImageCache.key(for: urlString))
        if !FileManager.default.fileExists(atPath: file.path) {
            await ImageCache.download([urlString], limit: 1)
        }
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixel / max(image.size.width, image.size.height))
        let thumb = await image.byPreparingThumbnail(
            ofSize: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
        memory.setObject(thumb, forKey: memKey)
        return thumb
    }
}

struct RemoteImage: View {
    let url: String?
    var maxPixel: CGFloat = 600
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: url) {
            image = await ThumbnailLoader.load(url, maxPixel: maxPixel)
        }
    }
}

struct FeedIcon: View {
    let feed: Feed?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let url = feed?.iconURL?.absoluteString {
                RemoteIcon(url: url, fallbackLetter: feed?.title.first)
            } else {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

private struct RemoteIcon: View {
    let url: String
    let fallbackLetter: Character?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.orange.gradient)
                Text(String(fallbackLetter ?? "•")).font(.caption2.bold()).foregroundStyle(.white)
            }
        }
        .task(id: url) { image = await ThumbnailLoader.load(url, maxPixel: 64) }
    }
}
