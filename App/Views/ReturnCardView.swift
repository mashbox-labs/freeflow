import FreeFlowKit
import SwiftUI
import UIKit

/// Covers Free Flow while it records for a keyboard that opened it (FreeFlowKit ReturnCard): one full-screen card that
/// points at iOS's own back button at the top left ("◀ <your app>") and names the bottom-edge swipe. Observes the engine
/// on its own, so the tabs under it do not redraw when the card does.
struct ReturnCardHost: View {
    @EnvironmentObject private var engine: DictationEngine

    var body: some View {
        if engine.returnCard.shows(phase: engine.phase) {
            ReturnCardView(phase: engine.phase, live: engine.sessionLive) { engine.stayHere() }
                .transition(.opacity)
        }
    }
}

/// MASHBOX visual language v1: paper page, Big Shoulders head, Outfit text, the keyboard's own mic bar (ember fill,
/// centred mic, StatusDot: filled green = live, hollow = not yet), one secondary pill. No strokes.
struct ReturnCardView: View {
    let phase: SessionPhase
    let live: Bool
    let onStay: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                // Points straight up at iOS's own "◀ <your app>" button, which sits above this column at the top left (Air: x 12 to 73 pt).
                Image(systemName: "arrow.up")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Palette.brand)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(ReturnCard.title(phase).uppercased())
                        .font(FFFont.display(52))
                        .foregroundStyle(Palette.fg)
                    Text(ReturnCard.Words.head)
                        .font(FFFont.text(26, .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Palette.fg)
                    Text(ReturnCard.Words.how)
                        .font(FFFont.text(18))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ReturnCard.Words.spoken(phase))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("returnCard.text")
                micBar.padding(.top, 32)
                Text(ReturnCard.Words.finish)
                    .font(FFFont.text(15, .medium))
                    .foregroundStyle(Palette.faint)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
                Spacer(minLength: 24)
                Button(ReturnCard.Words.stay, action: onStay)
                    .buttonStyle(FFButtonStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("returnCard.stay")
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 28)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .foregroundStyle(Palette.fg)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("returnCard")
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }

    /// The keyboard's mic bar as KeyFace draws it: the same shape, mic and StatusDot.
    private var micBar: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.brand)
            .frame(height: 54)
            .overlay(Image(systemName: "mic.fill").font(.system(size: 24, weight: .semibold)))
            .overlay(alignment: .trailing) { StatusDot(ready: live, ring: Palette.accentInk).padding(.trailing, 18) }
            .foregroundStyle(Palette.accentInk)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Microphone")
            .accessibilityValue(ReturnCard.title(phase))
            .accessibilityIdentifier("returnCard.mic")
    }
}
