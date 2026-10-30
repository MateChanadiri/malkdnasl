import SwiftUI

/// Add + search pills around the native tab bar.
/// Positions are plain animated coordinates (no structural layout changes), so collapsing and
/// expanding while scrolling is a smooth glide instead of a re-layout.
struct SearchLayer: View {
    @Environment(Router.self) private var router
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    /// The bar is on screen: the app is in front and no full-screen player covers it.
    @State private var watching = true

    /// Same height as the native tab bar (measured 62 pt) so all pills line up exactly.
    static let size: CGFloat = 62
    static let gap: CGFloat = 8
    /// Size and left margin of the native tab bar once it minimises while scrolling.
    static let minSize: CGFloat = 49
    static let minMargin: CGFloat = 27
    /// Width of the native two-tab bar with the default titles; the real bar is measured (`barFrame`).
    static let barWidth: CGFloat = 188

    /// Follows the real system tab bar (TabBarProbe), not the scroll direction.
    @State private var barMinimized = false
    /// The "+" only shows while the bar is fully expanded and has settled, so it never overlaps the bar mid-animation.
    @State private var addVisible = true
    @State private var settleToken = 0
    /// Where the expanded system bar really is. Its width depends on the tab titles (themes rename them,
    /// you can too) and the text size, so the pills go next to it instead of next to an assumed 188 pt.
    @State private var barFrame: CGRect?
    @State private var lastReading: CGRect?

    private var collapsed: Bool { barMinimized && !router.searchActive }

    private func barChanged(_ minimized: Bool) {
        settleToken += 1
        let token = settleToken
        if minimized {
            withAnimation(.easeOut(duration: 0.12)) { addVisible = false }
            withAnimation(.snappy(duration: 0.34)) { barMinimized = true }
        } else {
            withAnimation(.snappy(duration: 0.34)) { barMinimized = false }
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                if token == settleToken { withAnimation(.snappy(duration: 0.24)) { addVisible = true } }
            }
        }
    }

    var body: some View {
        @Bindable var router = router
        GeometryReader { geo in
            let W = geo.size.width
            let barInset = max(geo.safeAreaInsets.bottom - 12, 8)
            let searching = router.searchActive
            let sz = collapsed ? Self.minSize : Self.size

            // Target coordinates for the two pills: either side of the bar, kept on screen.
            let origin = geo.frame(in: .global).minX
            let barMinX = barFrame.map { $0.minX - origin } ?? (W - Self.barWidth) / 2
            let barMaxX = barFrame.map { $0.maxX - origin } ?? (W + Self.barWidth) / 2
            let left = max(8, barMinX - Self.gap - Self.size)
            let addX: CGFloat = searching ? 16 : collapsed ? Self.minMargin + Self.minSize + 11 : left
            let pillX: CGFloat = searching ? 16 + Self.size + Self.gap
                : collapsed ? W - Self.minMargin - Self.minSize
                : min(W - 8 - Self.size, barMaxX + Self.gap)
            let pillW: CGFloat = searching ? W - 32 - Self.size - Self.gap : sz
            let pillH: CGFloat = searching ? Self.size : sz
            let bottom: CGFloat = searching ? 8 : barInset + (Self.size - sz) / 2

            ZStack(alignment: .bottomLeading) {
                if searching {
                    NavigationStack {
                        SearchView().navigationDestination(for: Route.self) { RouteView(route: $0) }
                    }
                    .background(Color(.systemBackground))
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !searching, player.current != nil {
                    MiniPlayerCapsule()
                        .padding(.horizontal, 16)
                        .padding(.bottom, barInset + Self.size + 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ZStack(alignment: .bottomLeading) {
                    // Leading "+": outside the glass container so it never morphs into other glass while moving.
                    // It fades out where it was and fades in at its new spot once the system tab bar has resized.
                    if !searching && !collapsed && addVisible {
                        AddMusicMenu(size: Self.size)
                            .frame(width: Self.size, height: Self.size)
                            .offset(x: addX)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }

                    GlassEffectContainer(spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            if searching {
                                Button {
                                    router.closeSearch()
                                } label: {
                                    Image(systemName: "chevron.backward")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: Self.size, height: Self.size)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .frame(width: Self.size, height: Self.size)
                                .offset(x: addX)
                                .transition(.opacity)
                            }

                            // Trailing pill: magnifier, morphs into the search field.
                            searchPill(searching: searching, width: pillW, height: pillH)
                                .offset(x: pillX)
                        }
                    }
                }
                .padding(.bottom, bottom)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .ignoresSafeArea(.container, edges: searching ? [] : .bottom)
            .animation(.smooth(duration: 0.42), value: searching)
            .animation(.smooth, value: player.current == nil)
        }
        .onChange(of: router.searchActive) { _, on in
            guard on else { focused = false; return }
            // Bringing up the keyboard is heavy; doing it on the same frames as the pill morph made opening stutter.
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                if router.searchActive { focused = true }
            }
        }
        .onChange(of: scenePhase == .active && !router.showPlayer && !router.showFullLyrics, initial: true) { _, on in watching = on }
        .task {
            // Polling the bar 25 times a second is only worth it while it's visible; otherwise (in the background
            // while music plays, under the player) it just kept the CPU awake.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(watching ? 40 : 1000))
                guard watching else { continue }
                let sys = TabBarProbe.isMinimized() ?? router.collapsed
                if sys != barMinimized { barChanged(sys) }
                // Taken once the bar has stopped moving (two equal readings), never mid-animation.
                let reading = TabBarProbe.expandedFrame()
                if let r = reading, let last = lastReading, r.isApproximately(last),
                   !(barFrame.map { $0.isApproximately(r) } ?? false) {
                    barFrame = r
                }
                lastReading = reading
            }
        }
    }

    private func searchPill(searching: Bool, width: CGFloat, height: CGFloat) -> some View {
        @Bindable var router = router
        return ZStack {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.accent)
                    TextField("Songs, Artists, Albums", text: $router.searchText)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { focused = false }
                    if !router.searchText.isEmpty {
                        Button { router.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else if focused {
                        // Just browsing: put the keyboard away without leaving search.
                        Button { focused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide Keyboard")
                    }
                }
                .padding(.horizontal, 18)
                .frame(width: width, height: height)
                .transition(.opacity)
            } else {
                Button {
                    router.searchActive = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: width, height: height)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
                .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private extension CGRect {
    func isApproximately(_ o: CGRect) -> Bool {
        abs(minX - o.minX) < 0.5 && abs(maxX - o.maxX) < 0.5 && abs(minY - o.minY) < 0.5 && abs(maxY - o.maxY) < 0.5
    }
}
