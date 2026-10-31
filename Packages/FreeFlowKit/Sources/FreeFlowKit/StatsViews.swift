import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The words on the stats cards. Plain functions so tests can check every state, day one included.
public enum StatsText {
    public static func number(_ n: Int) -> String { n.formatted(.number) }

    /// A duration as a big value and its unit, e.g. ("2.4", "hours"), ("14", "min"), ("38", "sec").
    public static func duration(_ seconds: Double) -> (value: String, unit: String) {
        let s = max(0, seconds).rounded()
        if s >= 3600 {
            let h = s / 3600
            return (h >= 100 ? number(Int(h.rounded())) : String(format: "%.1f", h), "hours")
        }
        if s >= 60 { return (String(Int((s / 60).rounded(.down))), "min") }
        return (String(Int(s)), "sec")
    }

    public static func durationLine(_ seconds: Double) -> String {
        let d = duration(seconds)
        return "\(d.value) \(d.unit)"
    }

    public static func booksLine(_ words: Int) -> String {
        let basis = "a \(number(StatsMath.bookWords))-word book"
        if words == 0 { return "Your first dictation starts the count." }
        let books = Double(words) / Double(StatsMath.bookWords)
        if books < 0.01 { return "Under 1% of \(basis) so far." }
        if books < 1 { return "That's \(Int((books * 100).rounded(.down)))% of \(basis)." }
        let whole = Int(books.rounded(.down))
        return "That's \(whole) complete book\(whole == 1 ? "" : "s"), at \(number(StatsMath.bookWords)) words a book."
    }

    public static func streakLine(_ s: StatsSnapshot) -> String {
        if s.currentStreak == 0 {
            return s.bestStreak > 0 ? "Best so far: \(days(s.bestStreak)). Dictate today to start a new run."
                                    : "Dictate on two days in a row to start a streak."
        }
        let best = s.bestStreak > s.currentStreak ? " Best: \(days(s.bestStreak))." : ""
        if !s.dictatedToday { return "In a row. Dictate today to keep it going.\(best)" }
        if s.currentStreak == 1 { return "Day one. Dictate tomorrow to make it two.\(best)" }
        return "In a row, today included.\(best)"
    }

    public static func days(_ n: Int) -> String { "\(n) day\(n == 1 ? "" : "s")" }

    public static func speedLine(_ s: StatsSnapshot) -> String {
        guard s.wpm != nil else {
            return s.isEmpty ? "Your speaking speed shows after your first dictation."
                             : "Your speaking speed shows after your next dictation."
        }
        return "Your speaking speed, over \(durationLine(s.speechSeconds)) of speech. Pauses of a second or more are left out."
    }

    public static func savedValue(_ s: StatsSnapshot) -> (value: String, unit: String) {
        duration(max(0, s.savedSeconds))
    }

    public static func savedLine(_ s: StatsSnapshot) -> String {
        if s.isEmpty { return "Saved against typing on a phone. Estimate." }
        if s.savedSeconds <= 0 { return "No time saved yet against typing on a phone. Estimate." }
        return "Saved against typing on a phone. Estimate."
    }

    /// The short source line for the Home card; the page carries the full method.
    public static let savedSource = "Estimate at 36.2 wpm, the phone typing average in Palin et al., MobileHCI 2019."
    public static let savedFootnote = "Typing time uses 36.2 words a minute (5 characters a word), the phone average of 37,370 people in Palin et al., MobileHCI 2019. Dictating time counts your recording and the wait for text."

    public static func speed(_ x: Double?) -> String {
        guard let x else { return "–" }
        return x >= 10 ? "\(Int(x.rounded()))x" : String(format: "%.1fx", x)
    }

    public static func deviceLine(_ s: StatsSnapshot, device: String) -> String {
        "of audio turned into text on this \(device)."
    }

    public static func modelLine(_ s: StatsSnapshot) -> String {
        guard let m = s.mainModel else { return "Your speech model runs here, on the Neural Engine." }
        return "\(m.name) · \(speed(m.speed)) real time"
    }
}

public enum StatsCardKind: String, CaseIterable, Identifiable, Sendable {
    case words, streak, speed, saved, device
    public var id: String { rawValue }
}

/// One stats card: paper-2, radius 22, no stroke. The big number is Big Shoulders, the unit ember.
public struct StatsCard: View {
    let kind: StatsCardKind
    let s: StatsSnapshot
    let device: String
    let compact: Bool

    /// `compact` (Home) shows the short source line under time saved; the page shows the full method.
    public init(_ kind: StatsCardKind, _ snapshot: StatsSnapshot, device: String = StatsDevice.name, compact: Bool = false) {
        self.kind = kind; self.s = snapshot; self.device = device; self.compact = compact
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(FFFont.display(64)).foregroundStyle(Palette.fg)
                    .lineLimit(1).minimumScaleFactor(0.4)
                Text(unit.uppercased()).font(FFFont.display(30)).foregroundStyle(Palette.accentText)
                    .lineLimit(1).fixedSize()
            }
            Text(line).font(FFFont.text(17)).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if kind == .device {
                Text(StatsText.modelLine(s)).font(FFFont.text(15, .semibold)).foregroundStyle(Palette.fg)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("0 bytes of audio or text sent")
                    .font(FFFont.text(13, .semibold, relativeTo: .caption)).foregroundStyle(Palette.accentText)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .ffStroke(999, Palette.lineStrong)
            }
            if kind == .saved {
                Text(compact ? StatsText.savedSource : StatsText.savedFootnote).font(FFFont.text(12.5, relativeTo: .caption)).foregroundStyle(Palette.faint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("stats.card.\(kind.rawValue)")
    }

    private var value: String {
        switch kind {
        case .words: StatsText.number(s.words)
        case .streak: StatsText.number(s.currentStreak)
        case .speed: s.wpm.map { StatsText.number(Int($0.rounded())) } ?? "–"
        case .saved: StatsText.savedValue(s).value
        case .device: StatsText.duration(s.recordedSeconds).value
        }
    }

    private var unit: String {
        switch kind {
        case .words: s.words == 1 ? "word" : "words"
        case .streak: s.currentStreak == 1 ? "day" : "days"
        case .speed: "wpm"
        case .saved: StatsText.savedValue(s).unit
        case .device: StatsText.duration(s.recordedSeconds).unit
        }
    }

    private var line: String {
        switch kind {
        case .words: s.isEmpty ? StatsText.booksLine(0) : "dictated so far. " + StatsText.booksLine(s.words)
        case .streak: StatsText.streakLine(s)
        case .speed: StatsText.speedLine(s)
        case .saved: StatsText.savedLine(s)
        case .device: StatsText.deviceLine(s, device: device)
        }
    }

    /// What VoiceOver reads: the number with its unit spelled out, then the line.
    private var spoken: String {
        switch kind {
        case .words: "\(StatsText.number(s.words)) \(unit) dictated. \(StatsText.booksLine(s.words))"
        case .streak: "Day streak: \(StatsText.days(s.currentStreak)). \(StatsText.streakLine(s))"
        case .speed: s.wpm.map { "\(Int($0.rounded())) words per minute. \(StatsText.speedLine(s))" } ?? StatsText.speedLine(s)
        case .saved: "Time saved, estimate: \(StatsText.durationLine(max(0, s.savedSeconds)).replacingOccurrences(of: "min", with: "minutes").replacingOccurrences(of: "sec", with: "seconds")). \(StatsText.savedLine(s)) \(StatsText.savedFootnote)"
        case .device: "\(StatsText.durationLine(s.recordedSeconds).replacingOccurrences(of: "min", with: "minutes").replacingOccurrences(of: "sec", with: "seconds")) of audio turned into text on this \(device). \(StatsText.modelLine(s).replacingOccurrences(of: " · ", with: ", ")). 0 bytes of audio or text sent."
        }
    }
}

public enum StatsDevice {
    public static var name: String {
        #if targetEnvironment(macCatalyst)
        "Mac"
        #elseif canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : (UIDevice.current.userInterfaceIdiom == .mac ? "Mac" : "iPhone")
        #else
        "Mac"
        #endif
    }
}

/// The swipeable row on Home: one card a page, dots under it, each card opens the Stats page.
public struct StatsCardRow<Destination: View>: View {
    @ObservedObject var store: StatsStore
    let destination: () -> Destination
    @State private var current: StatsCardKind? = .words

    public init(store: StatsStore, @ViewBuilder destination: @escaping () -> Destination) {
        self.store = store; self.destination = destination
    }

    public var body: some View {
        let s = store.snapshot()
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(StatsCardKind.allCases) { kind in
                        NavigationLink { destination() } label: { StatsCard(kind, s, compact: true) }
                            .buttonStyle(.plain)
                            .containerRelativeFrame(.horizontal)
                            .id(kind)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            .accessibilityIdentifier("stats.row")
            HStack(spacing: 6) {
                ForEach(StatsCardKind.allCases) { kind in
                    Capsule(style: .continuous)
                        .fill(kind == (current ?? .words) ? Palette.fg : Palette.lineStrong)
                        .frame(width: kind == (current ?? .words) ? 18 : 7, height: 7)
                        .animation(.easeOut(duration: 0.15), value: current)
                }
                Spacer()
                NavigationLink { destination() } label: {
                    Text("All stats").font(FFFont.text(15, .medium)).foregroundStyle(Palette.fg)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Palette.panel, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stats.all")
            }
        }
    }
}

/// The whole Stats page. Every number is worked out on this device from counts and timings.
public struct StatsPage: View {
    @ObservedObject var store: StatsStore
    let device: String

    public init(store: StatsStore = .shared, device: String = StatsDevice.name) {
        self.store = store; self.device = device
    }

    public var body: some View {
        let s = store.snapshot()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("YOUR STATS").font(FFFont.display(44)).accessibilityAddTraits(.isHeader)
                Text("Worked out on this \(device) from counts and timings. Your words are not stored here, and nothing is sent anywhere.")
                    .font(FFFont.text(17)).foregroundStyle(Palette.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(StatsCardKind.allCases) { StatsCard($0, s, device: device) }
                }
                details(s)
                if !s.models.isEmpty { modelsCard(s) }
                notes(s)
            }
            .padding(16)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.fg)
        .navigationTitle("Stats")
        .accessibilityIdentifier("stats.page")
    }

    private func details(_ s: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In numbers").font(FFFont.text(22, .semibold, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
            row("Dictations", StatsText.number(s.dictations))
            row("Words today", StatsText.number(s.wordsToday))
            row("Days you dictated", StatsText.number(s.activeDays))
            row("Best streak", StatsText.days(s.bestStreak))
            row("Audio recorded", StatsText.durationLine(s.recordedSeconds))
            row("Speech timed for speed", StatsText.durationLine(s.speechSeconds))
            row("Waiting for text", String(format: "%.1f sec", s.processSeconds))
            row("Typing the same at 36.2 wpm (estimate)", StatsText.durationLine(s.typingSeconds))
            row("Counting since", s.countingSince.formatted(date: .abbreviated, time: .omitted))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private func modelsCard(_ s: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech models on this \(device)").font(FFFont.text(22, .semibold, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
            ForEach(s.models) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(FFFont.text(17, .semibold))
                    Text("\(StatsText.speed(m.speed)) real time · \(StatsText.durationLine(m.audioSeconds)) of audio · \(StatsText.number(m.dictations)) dictation\(m.dictations == 1 ? "" : "s")")
                        .font(FFFont.text(15)).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
        .accessibilityIdentifier("stats.models")
    }

    private func notes(_ s: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How these are worked out").font(FFFont.text(17, .semibold)).accessibilityAddTraits(.isHeader)
            Group {
                Text("Books: \(StatsText.number(StatsMath.bookWords)) words make one book.")
                Text("Speed: words you said divided by your time speaking. Pauses of a second or more are left out.")
                Text("Time saved is an estimate. \(StatsText.savedFootnote)")
                Text("Real time: seconds of audio per second the model spent on it, after loading, timed on this \(device).")
                if s.fromHistory > 0 {
                    Text("\(StatsText.number(s.fromHistory)) earlier dictation\(s.fromHistory == 1 ? " was" : "s were") counted from your history. Speed counts only dictations since stats began, because older audio was never kept.")
                }
                Text("No comparisons with other people: Free Flow never collects anyone's data. Reset stats in Settings.")
            }
            .font(FFFont.text(14)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(FFFont.text(16)).foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            Text(value).font(FFFont.text(16, .semibold)).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
