//  AuraWidget.swift — widget : lecture en cours + batterie / stockage
import WidgetKit
import SwiftUI

struct AuraEntry: TimelineEntry {
    let date: Date
    let title: String?
    let artist: String?
    let playing: Bool
    let battery: Double
    let charging: Bool
    let free: Int64
    let total: Int64
}

struct AuraProvider: TimelineProvider {
    func placeholder(in context: Context) -> AuraEntry {
        AuraEntry(date: Date(), title: "Titre", artist: "Artiste", playing: true, battery: 0.8, charging: false, free: 64_000_000_000, total: 128_000_000_000)
    }
    func getSnapshot(in context: Context, completion: @escaping (AuraEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AuraEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func load() -> AuraEntry {
        let d = UserDefaults(suiteName: "group.com.aura.personal")
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return AuraEntry(date: Date(), title: d?.string(forKey: "title"), artist: d?.string(forKey: "artist"),
                         playing: d?.bool(forKey: "playing") ?? false,
                         battery: d?.double(forKey: "battery") ?? -1, charging: d?.bool(forKey: "charging") ?? false,
                         free: v?.volumeAvailableCapacityForImportantUsage ?? 0, total: Int64(v?.volumeTotalCapacity ?? 0))
    }
}

struct AuraWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AuraEntry

    var body: some View {
        let used = entry.total > 0 ? Double(entry.total - entry.free) / Double(entry.total) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.playing ? "waveform" : "music.note").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title ?? "Aura").font(.system(.headline, design: .serif)).lineLimit(1)
                    Text(entry.artist ?? "Rien en lecture").font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                Label(entry.battery < 0 ? "—" : "\(Int(entry.battery * 100)) %", systemImage: entry.charging ? "battery.100.bolt" : "battery.75")
                if family == .systemMedium {
                    Label("\(ByteCountFormatter.string(fromByteCount: entry.free, countStyle: .file)) libres", systemImage: "internaldrive")
                }
            }.font(.caption)
            ProgressView(value: min(max(used, 0), 1)).tint(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(for: .widget) { Color(UIColor.systemBackground) }
        } else {
            self.padding().background(Color(UIColor.systemBackground))
        }
    }
}

@main
struct AuraWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AuraWidget", provider: AuraProvider()) { entry in
            AuraWidgetView(entry: entry).widgetBackground()
        }
        .configurationDisplayName("Aura")
        .description("Lecture en cours, batterie et stockage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
