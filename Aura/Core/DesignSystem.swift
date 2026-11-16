//
//  DesignSystem.swift
//  Aura — Core
//
//  Source unique pour les couleurs, la typographie, les espacements,
//  les animations et les composants visuels de base.
//

import SwiftUI
import UIKit

// MARK: - Couleur d'accent personnalisable

enum AuraAccent: String, CaseIterable, Identifiable {
    case ambre, corail, lavande, menthe, ciel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ambre: return "Ambre"
        case .corail: return "Corail"
        case .lavande: return "Lavande"
        case .menthe: return "Menthe"
        case .ciel: return "Ciel"
        }
    }

    var color: Color {
        switch self {
        case .ambre: return Color(hex: 0xF5A524)
        case .corail: return Color(hex: 0xFF6B6B)
        case .lavande: return Color(hex: 0xA78BFA)
        case .menthe: return Color(hex: 0x34D399)
        case .ciel: return Color(hex: 0x38BDF8)
        }
    }
}

enum AuraAppearance: String, CaseIterable, Identifiable {
    case sombre, clair, systeme
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sombre: return "Sombre"
        case .clair: return "Clair"
        case .systeme: return "Système"
        }
    }

    /// nil = suit le réglage système
    var colorScheme: ColorScheme? {
        switch self {
        case .sombre: return .dark
        case .clair: return .light
        case .systeme: return nil
        }
    }
}

// MARK: - Store du thème (persisté dans UserDefaults)

@MainActor
final class ThemeStore: ObservableObject {
    @Published var accent: AuraAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "aura.accent") }
    }
    @Published var appearance: AuraAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "aura.appearance") }
    }

    init() {
        let d = UserDefaults.standard
        accent = AuraAccent(rawValue: d.string(forKey: "aura.accent") ?? "") ?? .ambre
        // Mode sombre par défaut
        appearance = AuraAppearance(rawValue: d.string(forKey: "aura.appearance") ?? "") ?? .sombre
    }
}

// MARK: - Couleurs adaptatives

enum AuraColor {
    static let background = Color(light: 0xFAF7F2, dark: 0x0E0D0C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1A1816)
    static let surfaceRaised = Color(light: 0xF1ECE4, dark: 0x252220)
    static let textPrimary = Color(light: 0x1C1917, dark: 0xF5F1EA)
    static let textSecondary = Color(light: 0x78716C, dark: 0xA8A29E)
    static let separator = Color(light: 0xE7E0D5, dark: 0x2E2A27)
    static let danger = Color(hex: 0xEF4444)
}

// MARK: - Typographie (serif arrondi pour les titres = chaleureux)

enum AuraFont {
    static let largeTitle = Font.system(size: 34, weight: .bold, design: .serif)
    static let title = Font.system(size: 22, weight: .semibold, design: .serif)
    static let headline = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 16, weight: .regular, design: .rounded)
    static let caption = Font.system(size: 13, weight: .medium, design: .rounded)
    static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)
}

// MARK: - Espacements, rayons, animations

enum AuraSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum AuraRadius {
    static let s: CGFloat = 10
    static let m: CGFloat = 16
    static let l: CGFloat = 24
}

enum AuraMotion {
    /// Interactions courantes (boutons, cartes)
    static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// Transitions plus grandes (lecteur plein écran)
    static let smooth = Animation.spring(response: 0.55, dampingFraction: 0.85)
}

// MARK: - Retour haptique

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Composants

/// Carte standard (page « Mon iPhone », réglages, statistiques…)
struct AuraCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AuraSpacing.m)
            .background(AuraColor.surface, in: RoundedRectangle(cornerRadius: AuraRadius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AuraRadius.m, style: .continuous)
                    .stroke(AuraColor.separator, lineWidth: 0.5)
            )
    }
}

extension View {
    func auraCard() -> some View { modifier(AuraCard()) }
}

/// Bouton avec effet de pression + haptique
struct AuraPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AuraMotion.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { Haptics.tap() }
            }
    }
}

// MARK: - Helpers couleur

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Couleur qui s'adapte automatiquement au mode clair / sombre
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
