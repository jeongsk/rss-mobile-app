import SwiftUI

struct ArticleMeta: View {
    let article: Article
    let feed: Feed?

    var body: some View {
        HStack(spacing: 5) {
            FeedIcon(feed: feed, size: 14)
            Text(feed?.title ?? article.feedTitle).lineLimit(1)
            Text("·")
            Text(article.publishedAt, format: .relative(presentation: .named))
                .lineLimit(1)
            Spacer(minLength: 4)
            if article.isStarred {
                Image(systemName: "star.fill").foregroundStyle(.orange)
            }
            if article.isCachedOffline {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("오프라인 저장됨")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct UnreadDot: View {
    let isRead: Bool
    var body: some View {
        Circle()
            .fill(isRead ? Color.clear : Color.accentColor)
            .frame(width: 8, height: 8)
    }
}

/// 리스트: 제목 + 요약 2줄 + 오른쪽 썸네일
struct ListRow: View {
    let article: Article
    let feed: Feed?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UnreadDot(isRead: article.isRead).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                ArticleMeta(article: article, feed: feed)
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .lineLimit(3)
                if !article.snippet.isEmpty {
                    Text(article.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if article.imageURL != nil {
                RemoteImage(url: article.imageURL, maxPixel: 240)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}

/// 매거진: 큰 대표 이미지 카드
struct MagazineCard: View {
    let article: Article
    let feed: Feed?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if article.imageURL != nil {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { RemoteImage(url: article.imageURL, maxPixel: 1000) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            ArticleMeta(article: article, feed: feed)
            Text(article.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(article.isRead ? .secondary : .primary)
                .lineLimit(3)
            if !article.snippet.isEmpty {
                Text(article.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 10)
        .opacity(article.isRead ? 0.75 : 1)
    }
}

/// 그리드: 정사각 이미지 + 제목 카드
struct GridCard: View {
    let article: Article
    let feed: Feed?
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 고정 비율 영역 위에 이미지를 덮어 씌워야 scaledToFill 이 카드 폭을 넘지 않는다
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if article.imageURL != nil {
                        RemoteImage(url: article.imageURL, maxPixel: 600)
                    } else {
                        ZStack {
                            LinearGradient(colors: [.orange.opacity(0.5), .pink.opacity(0.4)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(article.feedTitle).font(.caption.bold()).foregroundStyle(.white).padding(8)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(article.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(article.isRead ? .secondary : .primary)
                .lineLimit(3, reservesSpace: true)
            ArticleMeta(article: article, feed: feed)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 제목만: 한 줄 제목 + 시간
struct TitleRow: View {
    let article: Article
    let feed: Feed?

    var body: some View {
        HStack(spacing: 8) {
            UnreadDot(isRead: article.isRead)
            FeedIcon(feed: feed, size: 14)
            Text(article.title)
                .font(.body)
                .foregroundStyle(article.isRead ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(article.publishedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
