import SwiftUI

// MARK: - Links

/// Where Music lives online. Ko-fi is reached through the website, never linked from the app.
enum Links {
}

// MARK: - Website look

/// The website's palette (website/styles.css), for the welcome flow. Adapts to dark mode.
enum Site {
    /// #6e6e73: ledes and quiet buttons.
    static let ink2 = dynamic(0x6E6E73, 0xA1A1A6)
    /// White cards that lift off the page (the search pill).
    static let card = dynamic(0xFFFFFF, 0x2C2C2E)

    /// The provider runs on whatever thread SwiftUI renders on, so it must not be tied to the main actor.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? UIColor(siteRGB: dark) : UIColor(siteRGB: light)
        })
    }
}

private extension UIColor {
    nonisolated convenience init(siteRGB v: UInt32) {
        self.init(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// The website's headlines: bold with tight tracking.
    func siteHeadline(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: .bold)).tracking(-size * 0.04)
    }

    /// The grey lede under a headline.
    func siteLede(_ size: CGFloat = 18) -> some View {
        font(.system(size: size, weight: .medium)).tracking(-size * 0.016).foregroundStyle(Site.ink2)
    }
}

/// The website's top bar: the icon and the name on the left, one quiet action on the right.
struct SiteNav<Trailing: View>: View {
    @AppStorage(BrandStyle.key) private var brand = BrandStyle.red.rawValue
    /// On a red page the icon turns white with red letters and the name turns white.
    var onRed = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let brandColor = (BrandStyle(rawValue: brand) ?? .red).color
        HStack(spacing: 9) {
            AppIconMark(color: onRed ? .white : brandColor, ink: onRed ? brandColor : .white)
                .frame(width: 28, height: 28)
            Text("\(Brand.name)")
                .foregroundStyle(onRed ? .white : .primary)
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.36)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }
}

/// A small app mark: a music note on the brand colour.
struct AppIconMark: View {
    var color: Color = BrandStyle.current.color
    var ink: Color = .white

    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: g.size.width * 0.225, style: .continuous).fill(color)
                Image(systemName: "music.note")
                    .font(.system(size: g.size.width * 0.55, weight: .bold))
                    .foregroundStyle(ink)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The website's glass pill, centred rather than edge to edge: red with white type, or white with red type on red.
struct SitePill: View {
    let title: String
    var onRed = false
    let action: () -> Void
    init(_ title: String, onRed: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.onRed = onRed; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.17)
                .foregroundStyle(onRed ? Theme.accent : .white)
                .frame(minWidth: 150)
                .padding(.horizontal, 12)
                .contentTransition(.opacity)
        }
        .buttonStyle(.glassProminent)
        .tint(onRed ? .white : Theme.accent)
        .controlSize(.extraLarge)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: title)
    }
}

// MARK: - App Store look

/// The three page colors of the onboarding, as in the App Store screenshots.
enum PageTone {
    case paper, red, wine

    var colored: Bool { self != .paper }
    /// Headlines and ledes.
    var ink: Color { colored ? .white : .primary }
    var lede: Color { colored ? .white.opacity(0.86) : Site.ink2 }

    @ViewBuilder var background: some View {
        switch self {
        case .paper: Color(uiColor: .systemBackground)
        case .red:
            ZStack {
                LinearGradient(colors: [Theme.accent.mix(with: .white, by: 0.08), Theme.accent, Theme.accent.mix(with: .black, by: 0.12)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.6), startRadius: 0, endRadius: 360)
            }
        case .wine:
            ZStack {
                LinearGradient(colors: [Theme.accent.mix(with: .black, by: 0.32), Theme.accent.mix(with: .black, by: 0.58)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.accent.opacity(0.45), .clear], center: UnitPoint(x: 0.5, y: 0.62), startRadius: 0, endRadius: 340)
            }
        }
    }
}

extension View {
    /// The App Store headline: black weight, tight tracking.
    func heroHeadline(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: .black)).tracking(-size * 0.045)
    }
}

// MARK: - Welcome

/// First run, laid out like the website's hero: the record you can spin, a red kicker, the big line, a red pill.
/// "See what it can do" pages through four features first; both roads end at "Where's your music?".
struct OnboardingView: View {
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboarded") private var onboarded = false

    private enum Stage { case hello, tour, sources }
    @State private var stage: Stage = .hello

    // Choreography flags, flipped one after another.
    @State private var recordIn = false
    @State private var heroTitle = false
    @State private var heroLede = false
    @State private var ctaIn = false
    @State private var sourcesTitle = false
    @State private var sourcesLede = false
    @State private var rowsIn = false
    @State private var chosen: OnboardingSource?

    // Record physics.
    @State private var spin = SpinModel()
    @State private var dragAngle: Double?
    @State private var grab: (touch: Double, disc: Double, travelled: Double)?
    @State private var samples: [(t: Date, a: Double)] = []
    @State private var recordCenter: CGPoint = .zero
    @State private var tick = 0
    @State private var kick = 0

    var body: some View {
        ZStack {
            (stage == .hello ? PageTone.red : .paper).background
                .ignoresSafeArea()
                .animation(.smooth(duration: 0.5), value: stage)

            switch stage {
            case .hello:
                hero.transition(.opacity.combined(with: .offset(y: -40)))
            case .sources:
                sources.transition(.opacity.combined(with: .offset(y: 40)))
            case .tour:
                TourDeck(onFinish: { toSources() })
                    .transition(.move(edge: .bottom))
                    .zIndex(5)
            }
        }
        .sensoryFeedback(.selection, trigger: tick)
        .sensoryFeedback(.impact(weight: .medium), trigger: kick)
        .sensoryFeedback(.success, trigger: chosen) { _, now in now != nil }
        .task { await choreograph() }
    }

    // MARK: Hero

    private var hero: some View {
        GeometryReader { geo in
            // The record takes whatever height the copy leaves over.
            let disc = min(geo.size.width * 0.66, 270, max(150, geo.size.height - 490))
            VStack(spacing: 0) {
                SiteNav(onRed: true) { laterButton(onRed: true).opacity(ctaIn ? 1 : 0) }

                Spacer(minLength: 8)
                Text(Brand.name)
                    .font(.system(size: 64, weight: .bold))
                    .tracking(-2)
                    .foregroundStyle(.white)
                    .frame(height: 120)
                Spacer(minLength: 22)

                VStack(spacing: 0) {
                    Text("Free offline music player")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(-0.25)
                        .foregroundStyle(.white.opacity(0.86))
                        .textRenderer(BlurReveal(progress: heroTitle ? 1 : 0))
                    Text("Sound. Your way.")
                        .heroHeadline(38)
                        .foregroundStyle(.white)
                        .textRenderer(BlurReveal(progress: heroTitle ? 1 : 0))
                        .padding(.top, 10)
                    Text("Plays the music you actually own. No ads. No account.")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.27)
                        .foregroundStyle(.white.opacity(0.86))
                        .textRenderer(BlurReveal(progress: heroLede ? 1 : 0))
                        .padding(.top, 16)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 26)

                Spacer(minLength: 22)

                VStack(spacing: 18) {
                    SitePill("Play my music", onRed: true) { start() }
                    Button { showTour() } label: {
                        HStack(spacing: 5) {
                            Text("See what it can do")
                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .opacity(ctaIn ? 1 : 0)
                .offset(y: ctaIn ? 0 : 24)
                .blur(radius: ctaIn ? 0 : 6)
                .padding(.bottom, 12)
            }
        }
    }

    private func laterButton(onRed: Bool = false) -> some View {
        Button("Later") { finish {} }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(onRed ? .white.opacity(0.8) : Site.ink2)
    }

    /// The toy from the website: grab it, spin it, flick it. Floats like the website's hero icon, with the same red glow.
    private func record(size: CGFloat) -> some View {
        return TimelineView(.animation(paused: reduceMotion && dragAngle == nil)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = dragAngle ?? spin.angle(at: ctx.date)
            let float = reduceMotion ? 0 : 3 * (1 - cos(t * .pi / 3))
            ZStack {
                // Deep red shadow under the record, like the 3D objects on the red pages.
                Circle()
                    .fill(Color(red: 0.35, green: 0, blue: 0.08))
                    .frame(width: size * 0.78, height: size * 0.78)
                    .blur(radius: size * 0.16)
                    .offset(y: size * 0.16)
                    .opacity(recordIn ? 0.55 : 0)
                VinylDisc(angle: .degrees(angle), label: chosen?.color ?? Theme.accent, symbol: chosen?.symbol, light: false)
                    .frame(width: size, height: size)
            }
            .offset(y: -float)
        }
        .frame(width: size, height: size)
        .offset(y: recordIn || reduceMotion ? 0 : 460)
        .contentShape(Circle())
        .onGeometryChange(for: CGPoint.self) { p in
            let f = p.frame(in: .global)
            return CGPoint(x: f.midX, y: f.midY)
        } action: { recordCenter = $0 }
        .gesture(spinGesture)
        .accessibilityHidden(true)
    }

    /// Grab the record and spin it; it keeps the momentum and eases back to its idle turn.
    private var spinGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                let a = Double(atan2(v.location.y - recordCenter.y, v.location.x - recordCenter.x)) * 180 / Double.pi
                let now = Date()
                if grab == nil {
                    grab = (a, spin.angle(at: now), 0)
                    samples = []
                }
                guard var g = grab else { return }
                var delta = a - g.touch
                while delta > 180 { delta -= 360 }
                while delta < -180 { delta += 360 }
                g.touch = a
                g.disc += delta
                let before = Int(g.travelled / 24)
                g.travelled += abs(delta)
                if Int(g.travelled / 24) != before { tick += 1 }
                grab = g
                dragAngle = g.disc
                samples.append((now, g.disc))
                samples.removeAll { now.timeIntervalSince($0.t) > 0.1 }
            }
            .onEnded { _ in
                let now = Date()
                var velocity = 0.0
                if let first = samples.first, let last = samples.last, last.t > first.t {
                    velocity = (last.a - first.a) / last.t.timeIntervalSince(first.t)
                }
                spin.reset(at: now, angle: dragAngle ?? spin.angle(at: now), velocity: max(-1800, min(1800, velocity)))
                dragAngle = nil
                grab = nil
            }
    }

    // MARK: Sources

    /// The record from the start screen above four plain rows. Pick one and its symbol lands on the label.
    private var sources: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                SiteNav { laterButton().opacity(chosen == nil ? 1 : 0) }

                Spacer(minLength: 8)

                VStack(spacing: 12) {
                    Text("Where’s your music?")
                        .heroHeadline(36)
                        .textRenderer(BlurReveal(progress: sourcesTitle ? 1 : 0))
                    Text(chosen == nil ? "Pick one. You can add the rest later." : "Nice. Getting it ready…")
                        .siteLede(17)
                        .contentTransition(.opacity)
                        .textRenderer(BlurReveal(progress: sourcesLede ? 1 : 0))
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    ForEach(Array(OnboardingSource.allCases.enumerated()), id: \.element) { i, source in
                        sourceRow(source, index: i)
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 16)
            }
        }
    }

    private func sourceRow(_ source: OnboardingSource, index i: Int) -> some View {
        let isChosen = chosen == source
        let other = chosen != nil && !isChosen
        return Button { choose(source) } label: {
            HStack(spacing: 14) {
                Image(systemName: source.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(source.color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(.primary)
                    Text(source.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Site.ink2)
                }
                Spacer(minLength: 8)
                Image(systemName: isChosen ? "checkmark" : "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isChosen ? Theme.accent : Color(uiColor: .tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .frame(height: 66)
            .contentShape(Rectangle())
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScale())
        .opacity(rowsIn ? (other ? 0.35 : 1) : 0)
        .offset(y: rowsIn || reduceMotion ? 0 : 24)
        .animation(.spring(duration: 0.7, bounce: 0.25).delay(rowsIn && chosen == nil ? Double(i) * 0.06 : 0), value: rowsIn)
        .animation(.smooth(duration: 0.35), value: chosen)
        .allowsHitTesting(chosen == nil)
        .accessibilityLabel("\(source.title), \(source.detail)")
    }

    // MARK: Flow

    private func choreograph() async {
        if reduceMotion {
            recordIn = true; heroTitle = true; heroLede = true; ctaIn = true
            return
        }
        spin.reset(at: .now, angle: -40, velocity: 260)
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.spring(duration: 1.1, bounce: 0.22)) { recordIn = true }
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.linear(duration: 0.9)) { heroTitle = true }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.linear(duration: 1.0)) { heroLede = true }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.spring(duration: 0.7, bounce: 0.2)) { ctaIn = true }
    }

    /// "Play my music": the record spins up, then the sources come in.
    private func start() {
        kick += 1
        spin.reset(at: .now, angle: spin.angle(at: .now), velocity: reduceMotion ? 0 : 900)
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 280))
            toSources()
        }
    }

    /// "See what it can do": the feature pages slide up over the hero.
    private func showTour() {
        kick += 1
        withAnimation(.spring(duration: 0.6, bounce: 0.1)) { stage = .tour }
    }

    private func toSources() {
        kick += 1
        sourcesTitle = false
        sourcesLede = false
        rowsIn = false
        withAnimation(.spring(duration: 0.6, bounce: 0.12)) { stage = .sources }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220))
            withAnimation(.linear(duration: reduceMotion ? 0 : 0.7)) { sourcesTitle = true }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 160))
            withAnimation(.linear(duration: reduceMotion ? 0 : 0.8)) { sourcesLede = true }
            rowsIn = true
        }
    }

    /// The record takes the source's color and symbol and spins up, the other rows step back, then the real step opens.
    private func choose(_ source: OnboardingSource) {
        guard chosen == nil else { return }
        chosen = source
        spin.reset(at: .now, angle: spin.angle(at: .now), velocity: reduceMotion ? 0 : 900)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            finish {
                switch source {
                case .iphone: router.startImport(.audioFiles)
                case .folder: router.startImport(.musicFolder)
                case .server: router.openAddMusic(atServer: true)
                case .list: router.startSongListImport()
                }
            }
        }
    }

    private func finish(_ then: () -> Void) {
        onboarded = true
        router.showOnboarding = false
        then()
    }
}

// MARK: - Sources

enum OnboardingSource: String, CaseIterable, Identifiable {
    case iphone, folder, server, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iphone: "This iPhone"
        case .folder: "A Folder"
        case .server: "My Server"
        case .list: "A Song List"
        }
    }
    var detail: String {
        switch self {
        case .iphone: "Files & iCloud Drive"
        case .folder: "Stays in sync"
        case .server: "Jellyfin · Subsonic"
        case .list: "Paste “Artist – Title”"
        }
    }
    var symbol: String {
        switch self {
        case .iphone: "iphone"
        case .folder: "folder"
        case .server: "server.rack"
        case .list: "text.alignleft"
        }
    }
    var color: Color {
        switch self {
        case .iphone: Color(hex: "#66CCD6")
        case .folder: Color(hex: "#F7A34D")
        case .server: Color(hex: "#9E8CFA")
        case .list: Color(hex: "#F5738F")
        }
    }
}

// MARK: - Record

/// A vinyl record: grooves and rim drawn once, a label that turns with the disc,
/// and a sheen that stays put like light from a lamp above.
struct VinylDisc: View {
    var angle: Angle
    var label: Color
    var symbol: String? = nil
    var side = "SIDE A · 33⅓"
    var light = false
    /// Colored vinyl instead of black.
    var tint: Color? = nil

    /// Wider gaps between the grooves mark the tracks, as fractions of the radius.
    private static let gaps: [Double] = [0.86, 0.78, 0.7, 0.62, 0.54]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Canvas { ctx, size in
                    let r = min(size.width, size.height) / 2
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    let colors = tint.map { [$0.mix(with: .white, by: 0.25), $0, $0.mix(with: .black, by: 0.45)] } ?? [Color(white: 0.11), Color(white: 0.055)]
                    ctx.fill(disc, with: .radialGradient(Gradient(colors: colors), center: c, startRadius: 0, endRadius: r))
                    let inner = r * 0.38
                    var radius = inner
                    var i = 0
                    while radius < r - 5 {
                        // Slightly uneven grooves read as real vinyl; a few wider gaps mark the tracks.
                        let gap = Self.gaps.contains { abs(radius / r - $0) < 0.006 }
                        let o = gap ? 0.0 : 0.03 + 0.025 * (0.5 + 0.5 * sin(Double(i) * 1.7))
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                                   with: .color(.white.opacity(o)), lineWidth: 0.6)
                        radius += 1.9
                        i += 1
                    }
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r + 0.5, y: c.y - r + 0.5, width: r * 2 - 1, height: r * 2 - 1)),
                               with: .color(.white.opacity(0.14)), lineWidth: 1)
                }

                // Fixed light: two soft wedges across the grooves.
                Circle()
                    .fill(AngularGradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .white.opacity(0.13), location: 0.09),
                        .init(color: .clear, location: 0.2),
                        .init(color: .clear, location: 0.5),
                        .init(color: .white.opacity(0.08), location: 0.59),
                        .init(color: .clear, location: 0.7),
                        .init(color: .clear, location: 1.0)
                    ], center: .center, angle: .degrees(-30)))
                    .blendMode(.plusLighter)

                RecordLabel(color: label, symbol: symbol, side: side)
                    .frame(width: s * 0.35, height: s * 0.35)
                    .rotationEffect(angle)
            }
            .frame(width: s, height: s)
            .shadow(color: .black.opacity(light ? 0.28 : 0.6), radius: s * 0.08, y: s * 0.05)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The website's label: the side printed above the spindle, Music below, in white (black on a pale label).
private struct RecordLabel: View {
    let color: Color
    let symbol: String?
    var side = "SIDE A · 33⅓"

    @Environment(\.self) private var env

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let c = color.resolve(in: env)
            let pale = 0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue) > 0.72
            ZStack {
                Circle().fill(color)
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: s * 0.2, weight: .semibold))
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        VStack(spacing: 0) {
                            Text(side).font(.system(size: s * 0.072, weight: .heavy)).tracking(s * 0.009)
                            Spacer().frame(height: s * 0.3)
                            Text("\(Brand.name)").font(.system(size: s * 0.11, weight: .heavy)).tracking(s * 0.009)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: s * 0.8)
                        .transition(.scale(scale: 1.3).combined(with: .opacity))
                    }
                }
                .foregroundStyle(pale ? Color.black.opacity(0.78) : .white)
                Circle().fill(Color(white: 0.05)).frame(width: s * 0.09, height: s * 0.09)
            }
            .animation(.spring(duration: 0.5, bounce: 0.3), value: symbol)
            .animation(.easeOut(duration: 0.45), value: color)
        }
    }
}

/// Idle turn with momentum: after a flick the speed decays exponentially back to `idle`.
/// Pure function of time, so a TimelineView can draw it without mutating state.
struct SpinModel {
    private var base = 0.0
    private var anchor = Date()
    private var v0 = 0.0
    var idle = 22.0
    var friction = 1.5

    func angle(at t: Date) -> Double {
        let dt = max(0, t.timeIntervalSince(anchor))
        return base + idle * dt + (v0 - idle) * (1 - exp(-friction * dt)) / friction
    }

    mutating func reset(at t: Date, angle: Double, velocity: Double) {
        base = angle
        anchor = t
        v0 = velocity
    }
}

// MARK: - Text reveal

/// Glyph-by-glyph reveal out of a soft blur, staggered left to right.
struct BlurReveal: TextRenderer, Animatable {
    var progress: Double
    var spread = 0.55

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var glyphs: [Text.Layout.RunSlice] = []
        for line in layout { for run in line { for slice in run { glyphs.append(slice) } } }
        let count = Double(max(1, glyphs.count))
        for (i, glyph) in glyphs.enumerated() {
            let start = Double(i) / count * spread
            let local = min(1, max(0, (progress - start) / (1 - spread)))
            let e = 1 - pow(1 - local, 3)
            var c = ctx
            c.opacity = e
            if e < 1 { c.addFilter(.blur(radius: (1 - e) * 7)) }
            c.translateBy(x: 0, y: (1 - e) * 9)
            c.draw(glyph)
        }
    }
}

// MARK: - Buttons

/// The full-width primary button: tinted red Liquid Glass on white, white glass on red.
struct GlassCTA: View {
    let title: String
    var onRed = false
    let action: () -> Void
    init(_ title: String, onRed: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.onRed = onRed; self.action = action
    }

    var body: some View {
        Group {
            if onRed {
                Button(action: action) { label.foregroundStyle(Theme.accent) }.buttonStyle(.glassProminent).tint(.white)
            } else {
                Button(action: action) { label }.buttonStyle(.glassProminent).tint(Theme.accent)
            }
        }
        .controlSize(.extraLarge)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: title)
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentTransition(.opacity)
    }
}

struct PrimaryPill: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        GlassCTA(title, action: action)
    }
}

// MARK: - Goodbye

/// From the icon's long-press menu: the record winds down to a stop. "Keep Listening" spins it back up.
struct GoodbyeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var spin: SpinModel = {
        var m = SpinModel()
        m.idle = 0
        m.friction = 0.5
        return m
    }()
    @State private var titleIn = false
    @State private var subtitleIn = false
    @State private var stayed = false
    @State private var kick = 0

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(paused: reduceMotion)) { ctx in
                VinylDisc(angle: .degrees(spin.angle(at: ctx.date)), label: Theme.accent, symbol: nil,
                          side: stayed ? "SIDE A · 33⅓" : "THE END", light: scheme == .light)
            }
            .frame(width: 200, height: 200)
            .padding(.top, 40)

            VStack(spacing: 10) {
                Text(stayed ? "Glad you’re staying." : "Goodbye — see you soon.")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)
                    .textRenderer(BlurReveal(progress: titleIn ? 1 : 0))
                    .id(stayed)
                    .transition(.opacity)
                Text("Thanks for listening. Removing \(Brand.name) also removes the music you imported into it — your original files and your server stay as they are.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .textRenderer(BlurReveal(progress: subtitleIn ? 1 : 0))
            }
            .multilineTextAlignment(.center)
            .padding(.top, 28)

            Spacer(minLength: 20)
            PrimaryPill("Keep Listening") { stay() }
                .disabled(stayed)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .background { ThemeBackgroundView() }
        .presentationDetents([.fraction(0.68)])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.impact(weight: .medium), trigger: kick)
        .task {
            // Starts turning, then runs out of momentum — the end of the side.
            spin.reset(at: .now, angle: 0, velocity: reduceMotion ? 0 : 240)
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 250))
            withAnimation(.linear(duration: reduceMotion ? 0 : 1.0)) { titleIn = true }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 300))
            withAnimation(.linear(duration: reduceMotion ? 0 : 1.4)) { subtitleIn = true }
        }
    }

    private func stay() {
        kick += 1
        let now = Date()
        let angle = spin.angle(at: now)
        spin.idle = 22
        spin.friction = 1.5
        spin.reset(at: now, angle: angle, velocity: reduceMotion ? 0 : 720)
        withAnimation(.smooth(duration: 0.4)) { stayed = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            dismiss()
        }
    }
}
