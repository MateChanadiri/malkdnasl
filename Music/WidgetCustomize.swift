import SwiftUI
import WidgetKit

/// Customize ▸ Widgets: the real widget views, live, above their options. Saved to the App Group on every change.
struct WidgetCustomizer: View {
    @State private var style = WidgetStyle.load()
    @State private var page = 0
    private let state: SharedNowPlaying = {
        let saved = SharedNowPlaying.load().settled()
        if saved.hasTrack { return saved }
        var s = SharedNowPlaying()
        s.hasTrack = true; s.title = "Glass Horizon"; s.artist = "Aurora Vale"; s.duration = 200; s.position = 80
        s.accentHex = ThemeStore.shared.current.accent
        return s
    }()

    var body: some View {
        VStack(spacing: 0) {
            previews
                .frame(height: 250)
                .background(wallpaper)
            Divider()
            form
        }
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: style) { _, s in
            s.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Preview

    private var wallpaper: some View {
        LinearGradient(colors: [Color(hex6: "#2B2F4A"), Color(hex6: "#0E1020")], startPoint: .top, endPoint: .bottom)
    }

    private var previews: some View {
        TabView(selection: $page) {
            frame(.systemSmall, width: 170, height: 170).tag(0)
            frame(.systemMedium, width: 360, height: 170).tag(1)
            lockScreen.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .animation(.smooth(duration: 0.35), value: style)
        .allowsHitTesting(true)
    }

    private func frame(_ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        NowPlayingWidgetContent(state: state, style: style, family: family)
            .padding(16)
            .frame(width: width, height: height)
            .background { WidgetBackground(state: state, style: style) }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 24)
    }

    private var lockScreen: some View {
        VStack(spacing: 12) {
            Text("9:41").font(.system(size: 56, weight: .bold, design: .rounded))
            HStack(spacing: 12) {
                NowPlayingWidgetContent(state: state, style: style, family: .accessoryCircular)
                    .frame(width: 60, height: 60)
                NowPlayingWidgetContent(state: state, style: style, family: .accessoryRectangular)
                    .padding(.horizontal, 10)
                    .frame(width: 170, height: 64)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    // MARK: Options

    private var form: some View {
        Form {
            Section("Background") {
                chips(WidgetStyle.Background.allCases, $style.background) { ($0.title, $0.icon) }
                Toggle("Own Color", isOn: Binding(get: { style.customAccent != nil }, set: { style.customAccent = $0 ? (style.customAccent ?? state.accentHex) : nil }))
                if let hex = style.customAccent {
                    ColorPicker("Color", selection: Binding(get: { Color(hex6: hex) }, set: { style.customAccent = $0.hexString }), supportsOpacity: false)
                }
            }
            Section("Cover") {
                Toggle("Show Cover", isOn: $style.showArtwork)
                if style.showArtwork { chips(WidgetStyle.ArtShape.allCases, $style.artShape) { ($0.title, $0.icon) } }
            }
            Section("Text") {
                chips(WidgetStyle.Font.allCases, $style.font) { ($0.title, "textformat") }
                Toggle("“Now Playing” / “Resume Music”", isOn: $style.showStatus)
                Toggle("Up Next", isOn: $style.showUpNext)
            }
            Section {
                Toggle("Progress Bar", isOn: $style.showProgress)
                Toggle("Back & Next Buttons", isOn: $style.showControls)
            } header: { Text("Controls") } footer: {
                Text("Back & Next show on the medium widget. When nothing is playing, the widgets offer the last song to resume.")
            }
            Section { Button("Reset Widgets") { withAnimation { style = WidgetStyle() } } }
        }
    }

    private func chips<T: Hashable & Identifiable>(_ options: [T], _ selection: Binding<T>, label: @escaping (T) -> (String, String)) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { o in
                    let on = selection.wrappedValue == o
                    let (name, icon) = label(o)
                    Button { withAnimation(.smooth(duration: 0.3)) { selection.wrappedValue = o } } label: {
                        Label(name, systemImage: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color(.systemBackground) : .primary)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Capsule().fill(on ? Color.primary : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }
}
