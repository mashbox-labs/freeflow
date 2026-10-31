import SwiftUI

/// The Listening view shared by the app and the keyboard: cancel, live waveform, finish.
public struct ListeningPanel: View {
    let levels: [Float]
    let title: String
    let subtitle: String
    let busy: Bool
    let onCancel: () -> Void
    let onFinish: () -> Void
    let idPrefix: String
    /// false: no finish button here; the keyboard draws it on its Dictate key, and the title goes under cancel.
    let finishInline: Bool
    let cancelTrailing: Bool

    public init(levels: [Float], title: String, subtitle: String, busy: Bool, idPrefix: String = "", finishInline: Bool = true,
                cancelTrailing: Bool = false, onCancel: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.levels = levels; self.title = title; self.subtitle = subtitle; self.busy = busy; self.idPrefix = idPrefix
        self.finishInline = finishInline; self.cancelTrailing = cancelTrailing
        self.onCancel = onCancel; self.onFinish = onFinish
    }

    private var cancel: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.fg)
                .frame(width: 54, height: 54).background(Circle().fill(Palette.panel))
        }
        .accessibilityIdentifier(idPrefix + "cancelButton").accessibilityLabel("Cancel")
    }

    private var heading: some View {
        VStack(spacing: 2) {
            Text(title).font(FFFont.text(20, .bold)).foregroundStyle(Palette.fg)
            Text(subtitle).font(FFFont.text(14)).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier(idPrefix + "listeningTitle")
    }

    /// The finish key's width in a row this wide: the keyboard's Dictate key share of the width (274 of 420 pt on the
    /// iPhone Air), leaving room for cancel.
    public static func finishWidth(row: Double) -> Double { max(120, min(row - 54 - 12, (row * 0.653).rounded())) }

    public var body: some View {
        VStack(spacing: finishInline ? 14 : 8) {
            if finishInline {
                // 2026-10-29: the check is not a small circle in the corner but a key the size of the
                // keyboard's Dictate key, from the right edge to past the middle. Cancel stays a circle on the left.
                GeometryReader { g in
                    HStack(spacing: 12) {
                        cancel
                        Spacer(minLength: 0)
                        Button(action: onFinish) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.brand)
                                .overlay(Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.accentInk))
                                .frame(width: Self.finishWidth(row: g.size.width), height: 54)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy).opacity(busy ? 0.5 : 1)
                        .accessibilityIdentifier(idPrefix + "finishButton").accessibilityLabel("Finish")
                    }
                }
                .frame(height: 54)
                heading
            } else {
                HStack {
                    if cancelTrailing { Spacer() }
                    cancel
                    if !cancelTrailing { Spacer() }
                }
                heading
            }
            ZStack {
                if busy {
                    ProgressView().tint(Palette.brand)
                } else {
                    WaveformView(levels: levels)
                }
            }
            .frame(height: 64)
        }
    }
}

/// Round mic button in the brand colour.
public struct MicButton: View {
    let size: CGFloat
    let id: String
    let action: () -> Void
    public init(size: CGFloat = 88, id: String = "micButton", action: @escaping () -> Void) { self.size = size; self.id = id; self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(Palette.accentInk)
                .frame(width: size, height: size).background(Circle().fill(Palette.brand))
                .shadow(color: Palette.brand.opacity(0.35), radius: 12, y: 4)
        }
        .accessibilityIdentifier(id).accessibilityLabel("Dictate")
    }
}
