//  MyPhoneView.swift — page « Mon iPhone » (infos temps réel)
import SwiftUI

struct MyPhoneView: View {
    @EnvironmentObject private var device: DeviceInfoModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let s = device.snap
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // En-tête
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: "iphone").font(.system(size: 34)).foregroundStyle(theme.accent.color)
                        Text(s.modelName).font(AuraFont.largeTitle)
                        Text("\(s.systemVersion) · build \(s.build)").font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).auraCard()

                    batteryCard(s)
                    storageCard(s)
                    memoryCard(s)

                    VStack(alignment: .leading, spacing: 10) {
                        title("Appareil", "info.circle")
                        row("Nom", s.deviceName)
                        row("Identifiant modèle", s.identifier)
                        row("ID fournisseur", s.vendorID)
                        row("UDID / n° de série", "Non accessible")
                        Text("iOS ne donne ni l'UDID ni le numéro de série aux apps (hors entreprise). Depuis iOS 16, le nom de l'appareil peut apparaître générique.")
                            .font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).auraCard()

                    VStack(alignment: .leading, spacing: 10) {
                        title("Musique", "arrow.triangle.2.circlepath")
                        row("Dernière synchronisation", library.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Jamais")
                        row("Titres", "\(library.tracks.count)")
                    }.frame(maxWidth: .infinity, alignment: .leading).auraCard()
                }.padding(16)
            }
            .background(AuraColor.background.ignoresSafeArea())
            .navigationTitle("Mon iPhone")
            .miniPlayerInset()
        }
    }

    private func batteryCard(_ s: DeviceInfoModel.Snapshot) -> some View {
        let level = max(Double(s.battery), 0)
        let charging = s.batteryState == .charging || s.batteryState == .full
        let color: Color = charging ? .green : (level <= 0.2 ? AuraColor.danger : theme.accent.color)
        return VStack(alignment: .leading, spacing: 10) {
            title("Batterie", charging ? "battery.100.bolt" : "battery.75")
            Text(s.battery < 0 ? "—" : "\(Int(level * 100)) %").font(AuraFont.largeTitle)
            Bar(segments: [(level, color)])
            row("État", charging ? (s.batteryState == .full ? "Pleine" : "En charge") : "Sur batterie")
            if s.lowPower { row("Mode économie", "Activé") }
        }
        .frame(maxWidth: .infinity, alignment: .leading).auraCard()
        .animation(AuraMotion.smooth, value: s.battery)
    }

    private func storageCard(_ s: DeviceInfoModel.Snapshot) -> some View {
        let total = Double(max(s.totalDisk, 1))
        let used = Double(max(s.totalDisk - s.freeDisk, 0))
        let aura = Double(library.auraBytes)
        return VStack(alignment: .leading, spacing: 10) {
            title("Stockage", "internaldrive")
            Bar(segments: [(aura / total, theme.accent.color), (max(used - aura, 0) / total, AuraColor.textSecondary.opacity(0.5))])
            row("Total", Fmt.bytes(s.totalDisk))
            row("Utilisé", Fmt.bytes(max(s.totalDisk - s.freeDisk, 0)))
            row("Disponible", Fmt.bytes(s.freeDisk))
            row("Dont Aura (musique)", Fmt.bytes(library.auraBytes))
        }
        .frame(maxWidth: .infinity, alignment: .leading).auraCard()
        .animation(AuraMotion.smooth, value: s.freeDisk)
    }

    private func memoryCard(_ s: DeviceInfoModel.Snapshot) -> some View {
        let total = Double(max(s.ramTotal, 1))
        return VStack(alignment: .leading, spacing: 10) {
            title("Mémoire (RAM)", "memorychip")
            Bar(segments: [(Double(s.ramSystem) / total, AuraColor.textSecondary.opacity(0.5)), (Double(s.ramApp) / total, theme.accent.color)])
            row("Totale", Fmt.bytes(Int64(s.ramTotal)))
            row("Utilisée (système)", Fmt.bytes(Int64(s.ramSystem)))
            row("Utilisée par Aura", Fmt.bytes(Int64(s.ramApp)))
        }
        .frame(maxWidth: .infinity, alignment: .leading).auraCard()
    }

    private func title(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(AuraFont.headline).foregroundStyle(theme.accent.color)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(AuraFont.body).foregroundStyle(AuraColor.textSecondary)
            Spacer()
            Text(v).font(AuraFont.body).multilineTextAlignment(.trailing)
        }
    }
}

/// Barre segmentée animée (fractions entre 0 et 1)
struct Bar: View {
    let segments: [(Double, Color)]
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AuraColor.surfaceRaised)
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { i in
                        Rectangle().fill(segments[i].1)
                            .frame(width: max(0, min(1, segments[i].0.isFinite ? segments[i].0 : 0)) * geo.size.width)
                    }
                }.clipShape(Capsule())
            }
        }.frame(height: 12)
    }
}
