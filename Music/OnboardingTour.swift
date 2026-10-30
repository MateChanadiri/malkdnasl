import SwiftUI

// MARK: - See what it can do

/// "See what it can do": five pages in the App Store look. One headline, one line, one thing to touch.
/// The page color changes from white to wine to red.
struct TourDeck: View {
    var onFinish: () -> Void
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @State private var page = 0

    private let pages = TourPage.allCases
    private var current: TourPage { TourPage(rawValue: page) ?? .themes }
    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            ZStack {
                ForEach(pages) { p in
                    p.tone.background.opacity(p == current ? 1 : 0)
                }
            }
            .ignoresSafeArea()
            .animation(.smooth(duration: 0.5), value: page)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(current.tone.colored ? .white.opacity(0.8) : Site.ink2)
                        .opacity(isLast ? 0 : 1)
                }
                .padding(.horizontal, 20)
                .frame(height: 54)

                TabView(selection: $page) {
                    ForEach(pages) { p in
                        TourPageView(page: p, active: page == p.rawValue).tag(p.rawValue)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                PageDots(count: pages.count, current: page, onRed: current.tone.colored)
                SitePill(isLast ? "Add my music" : "Next", onRed: current.tone.colored) {
                    if isLast {
                        onFinish()
                    } else {
                        advance()
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 12)
            }
        }
        .sensoryFeedback(.selection, trigger: page)
    }

    private func advance() {
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) { page += 1 }
    }
}

enum TourPage: Int, CaseIterable, Identifiable {
    case themes, lyrics, search, mix, leftOut
    var id: Int { rawValue }

    var tone: PageTone {
        switch self {
        case .themes, .mix: .paper
        case .lyrics: .wine
        case .search, .leftOut: .red
        }
    }

    var title: String {
        switch self {
        case .themes: "Customize the shit out of it."
        case .lyrics: "Lyrics, even when there aren’t any."
        case .search: "Search like you talk."
        case .mix: "No gaps. No awkward silences."
        case .leftOut: ""
        }
    }

    var text: String {
        switch self {
        case .themes: "Colors, fonts, the player and the lyrics. Make it yours."
        case .lyrics: "No lyrics in the file? \(Brand.name) listens and writes them, right on your iPhone."
        case .search: "“never played” or “favorites under 3 min”. It gets it."
        case .mix: "Track Mix locks the next beat onto the end of the song."
        case .leftOut: ""
        }
    }
}

private struct TourPageView: View {
    let page: TourPage
    let active: Bool
    @State private var shown = false

    var body: some View {
        Group {
            if page == .leftOut {
                LeftOutPage(active: active)
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 16) {
                        headline
                        Text(page.text)
                            .font(.system(size: 17, weight: page.tone.colored ? .semibold : .medium))
                            .tracking(-0.27)
                            .foregroundStyle(page.tone.lede)
                            .textRenderer(BlurReveal(progress: shown ? 1 : 0))
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)

                    Spacer(minLength: 24)
                    object
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 24)
                }
            }
        }
        .onChange(of: active, initial: true) { _, now in
            if now { withAnimation(.linear(duration: 0.8)) { shown = true } } else { shown = false }
        }
    }

    private var headline: some View {
        Text(page.title)
            .heroHeadline(38)
            .foregroundStyle(page.tone.ink)
            .textRenderer(BlurReveal(progress: shown ? 1 : 0))
    }

    @ViewBuilder private var object: some View {
        switch page {
        case .themes: CustomizeCard()
        case .lyrics: LyricsLines(active: active, onColor: true)
        case .search: SearchPill(active: active, onColor: true)
        case .mix: MixFader(active: active)
        case .leftOut: EmptyView()
        }
    }
}

/// The website's carousel dots: the current one stretches and turns red.
private struct PageDots: View {
    let count: Int
    let current: Int
    let onRed: Bool

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? (onRed ? Color.white : Theme.accent) : (onRed ? Color.white.opacity(0.4) : Color(uiColor: .systemGray4)))
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: - 1 · Themes

/// The first page: tap a colour and the whole app takes it; the colour wheel is one tap away.
private struct CustomizeCard: View {
    private let swatches: [String] = ["#FA2D48", "#FF9F0A", "#FFD60A", "#30D158", "#40C8E0", "#0A84FF", "#BF5AF2", "#FF5CA8"]
    @State private var picked: String = ThemeStore.shared.selected.accent

    private func choose(_ hex: String) {
        picked = hex
        var t: AppTheme = ThemeStore.shared.selected
        t.accent = hex
        ThemeStore.shared.commit(t)
    }

    var body: some View {
        VStack(spacing: 26) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 14), count: 4), spacing: 14) {
                ForEach(swatches, id: \.self) { hex in
                    Button { choose(hex) } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 48, height: 48)
                            .overlay { Circle().strokeBorder(Color.white, lineWidth: picked.lowercased() == hex.lowercased() ? 4 : 0) }
                            .shadow(color: Color(hex: hex).opacity(0.45), radius: 10, y: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                }
            }
            ColorPicker("Pick any colour", selection: Binding<Color>(
                get: { Color(hex: picked) },
                set: { choose($0.hexString) }), supportsOpacity: false)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: 260)
            Text("More in Settings › Customize")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.75))
        }
    }
}

// MARK: - 2 · Lyrics

/// One big line on white lighting up word by word in red, the next one waiting underneath.
private struct LyricsLines: View {
    let active: Bool
    /// On a colored page the words light up white instead of red.
    var onColor = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var lit = 0

    private static let lines: [String] = ["Headphones on, the city goes quiet",
                                            "Midnight hums a melody for me",
                                            "Every note a light across the dark",
                                            "I'm not alone when the chorus starts",
                                            "One more song before the dawn"]

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 26) {
                line(step, current: true)
                line(step + 1, current: false)
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 24)),
                                    removal: .opacity.combined(with: .offset(y: -24))))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 30)
        .frame(height: 220, alignment: .top)
        .accessibilityHidden(true)
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                let count = Self.lines[mod(step)].split(separator: " ").count
                for w in 1...count {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 290))
                    if Task.isCancelled { return }
                    withAnimation(.easeOut(duration: 0.25)) { lit = w }
                }
                try? await Task.sleep(for: .milliseconds(1000))
                if Task.isCancelled { return }
                withAnimation(.smooth(duration: 0.55)) { step += 1; lit = 0 }
            }
        }
    }

    private func mod(_ k: Int) -> Int { ((k % Self.lines.count) + Self.lines.count) % Self.lines.count }

    private func line(_ k: Int, current: Bool) -> some View {
        let words = Self.lines[mod(k)].split(separator: " ")
        var text = AttributedString()
        for (i, word) in words.enumerated() {
            var a = AttributedString(String(word) + (i < words.count - 1 ? " " : ""))
            a.foregroundColor = current && i < lit ? (onColor ? Color.white : Theme.accent) : (onColor ? Color.white.opacity(0.24) : Color.primary.opacity(0.18))
            text += a
        }
        return Text(text)
            .font(.system(size: 31, weight: .heavy))
            .tracking(-1.1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 3 · Search

/// A query types itself into the search pill and comes back as one or two strips of embossed tape.
private struct SearchPill: View {
    let active: Bool
    /// On a red page: a white card with dark type, and black and white tapes instead of red ones.
    var onColor = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typed = ""
    @State private var tapes: [Tape] = []

    private struct Tape: Identifiable {
        let id = UUID()
        let text: String
        let red: Bool
    }

    private static let queries: [(String, [(String, Bool)])] = [
        ("never played", [("0 plays", true)]),
        ("favorites under 3 min", [("★ Favorites", true), ("Under 3:00", false)]),
        ("something calm for reading", [("Calm", true), ("Slow", false)])
    ]

    var body: some View {
        VStack(spacing: 30) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(typed)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(onColor ? Color.black : Color.primary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    Capsule().fill(Theme.accent)
                        .frame(width: 2, height: 22)
                        .opacity(active && Int(ctx.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(onColor ? Color.white : Site.card, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(onColor ? 0 : 0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(onColor ? 0.2 : 0.1), radius: 18, y: 12)
            .padding(.horizontal, 30)

            HStack(spacing: 10) {
                ForEach(Array(tapes.enumerated()), id: \.element.id) { k, tape in
                    DymoTape(text: tape.text, color: tape.red ? (onColor ? Color(white: 0.07) : Theme.accent) : (onColor ? Color.white : Color(white: 0.07)),
                             ink: !tape.red && onColor ? Theme.accent : .white)
                        .rotationEffect(.degrees(k.isMultiple(of: 2) ? -2.5 : 2))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(height: 40)
        }
        .accessibilityHidden(true)
        .task(id: active) {
            guard active else { return }
            var q = 0
            while !Task.isCancelled {
                let (query, parts) = Self.queries[q % Self.queries.count]
                for k in 1...query.count {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 55))
                    if Task.isCancelled { return }
                    typed = String(query.prefix(k))
                }
                try? await Task.sleep(for: .milliseconds(450))
                for part in parts {
                    try? await Task.sleep(for: .milliseconds(170))
                    if Task.isCancelled { return }
                    withAnimation(.spring(duration: 0.6, bounce: 0.4)) { tapes.append(Tape(text: part.0, red: part.1)) }
                }
                try? await Task.sleep(for: .milliseconds(2400))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.3)) { tapes = [] }
                for k in stride(from: query.count, through: 0, by: -1) {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 22))
                    if Task.isCancelled { return }
                    typed = String(query.prefix(k))
                }
                try? await Task.sleep(for: .milliseconds(300))
                q += 1
            }
        }
    }
}

/// Embossed label tape like the website's: uppercase, wide-spaced, raised letters on glossy plastic.
private struct DymoTape: View {
    let text: String
    let color: Color
    var ink: Color = .white

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 14, weight: .heavy))
            .tracking(14 * 0.14)
            .foregroundStyle(ink)
            .shadow(color: .black.opacity(0.7), radius: 0, x: 0, y: -1)
            .shadow(color: .white.opacity(0.28), radius: 0, x: 0, y: 1)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.14)).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.4)).frame(height: 2) }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .shadow(color: .black.opacity(0.35), radius: 7, y: 5)
    }
}

// MARK: - 4 · Mix

/// Two songs as waveforms, one fading out as the other comes in. The fader moves on its own until you grab it.
private struct MixFader: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var value = 0.0
    @State private var touched = false

    var body: some View {
        VStack(spacing: 34) {
            ZStack {
                Waveform(seed: 3) { i, r in 18 + 78 * abs(sin(Double(i) * 0.45)) * (0.5 + r * 0.5) }
                    .foregroundStyle(Theme.accent)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.3), .init(color: .clear, location: 0.85)],
                                         startPoint: .leading, endPoint: .trailing))
                    .opacity(1 - 0.85 * value)
                Waveform(seed: 9) { i, r in 16 + 80 * abs(sin(Double(i) * 0.31 + 1)) * (0.45 + r * 0.55) }
                    .foregroundStyle(.primary)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.15), .init(color: .black, location: 0.7)],
                                         startPoint: .leading, endPoint: .trailing))
                    .opacity(0.15 + 0.85 * value)
            }
            .frame(height: 110)
            .padding(.horizontal, 30)

            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                        .overlay { Capsule().fill(Theme.accent).frame(width: 2).padding(.vertical, 7) }
                        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.15), lineWidth: 0.5) }
                        .frame(width: 52, height: 32)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                        .offset(x: w * value - 26)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    touched = true
                    value = min(1, max(0, v.location.x / w))
                })
            }
            .frame(height: 44)
            .padding(.horizontal, 56)
        }
        .sensoryFeedback(.selection, trigger: value > 0.5)
        .task(id: active) {
            guard active, !reduceMotion else { return }
            while !Task.isCancelled && !touched {
                withAnimation(.easeInOut(duration: 3)) { value = value < 0.5 ? 1 : 0 }
                try? await Task.sleep(for: .milliseconds(3600))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue(value < 0.5 ? "Song A" : "Song B")
    }
}

/// 48 bars with a fixed pseudo-random spread, so the same song always draws the same wave.
private struct Waveform: View {
    let seed: UInt64
    let height: (Int, Double) -> Double

    var body: some View {
        var state = seed &* 2_654_435_761 &+ 1
        let bars: [Double] = (0..<48).map { i in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return height(i, Double(state >> 33) / Double(UInt64(1) << 31))
        }
        return HStack(spacing: 3) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule().frame(height: 110 * bars[i] / 100)
            }
        }
    }
}

// MARK: - 5 · Things we left out

/// The website's red section: the lines light up one after another.
private struct LeftOutPage: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = 0

    private static let lines = ["No ads.", "No subscription.", "No account.", "Just your music."]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Things we left out")
                .font(.system(size: 17, weight: .semibold))
                .opacity(0.85)
                .padding(.bottom, 24)
            ForEach(Self.lines.indices, id: \.self) { i in
                Text(Self.lines[i])
                    .font(.system(size: 44, weight: .black))
                    .tracking(-2)
                    .opacity(i < lit ? 1 : 0.28)
                    .padding(.top, i == Self.lines.count - 1 ? 22 : 0)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .task(id: active) {
            guard active else { lit = 0; return }
            for i in 1...Self.lines.count {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : (i == 1 ? 350 : 420)))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.35)) { lit = i }
            }
        }
    }
}
