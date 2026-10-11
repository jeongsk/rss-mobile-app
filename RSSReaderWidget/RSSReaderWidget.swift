import WidgetKit
import SwiftUI

/// W0: 무료 계정 서명과 App Group 공유가 되는지 확인하기 위한 최소 위젯.
/// 앱이 App Group 에 쓴 "마지막 실행 시각"을 읽어 보여 준다. 실제 기능은 W1 이후에 만든다.
struct ProbeEntry: TimelineEntry {
    let date: Date
    let groupAvailable: Bool
    let appLastRun: Date?
}

struct ProbeProvider: TimelineProvider {
    private func entry() -> ProbeEntry {
        ProbeEntry(date: Date(), groupAvailable: AppGroup.isUsable, appLastRun: AppGroup.heartbeat)
    }

    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: Date(), groupAvailable: true, appLastRun: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct ProbeView: View {
    let entry: ProbeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(entry.groupAvailable ? "App Group 연결됨" : "App Group 없음",
                  systemImage: entry.groupAvailable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.caption.bold())
                .foregroundStyle(entry.groupAvailable ? .green : .red)
            if let last = entry.appLastRun {
                Text("앱 마지막 실행").font(.caption2).foregroundStyle(.secondary)
                Text(last, format: .dateTime.month().day().hour().minute()).font(.caption)
            } else {
                Text("앱에서 받은 값 없음").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ProbeWidget: Widget {
    let kind = "W0Probe"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProbeProvider()) { entry in
            ProbeView(entry: entry)
        }
        .configurationDisplayName("연결 확인")
        .description("앱과 위젯이 데이터를 나눌 수 있는지 확인합니다.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

@main
struct RSSReaderWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProbeWidget()
    }
}
