import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Your own pictures for the tab bar. A picture with a transparent background is drawn in the tab's colour
/// like a normal icon; any other picture is shown as it is.
enum TabIconStore {
    static let revisionKey = "tabIconRevision"

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "TabIcons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ id: String, template: Bool) -> URL {
        folder.appending(path: "\(id)-\(template ? "t" : "o").png")
    }

    /// The saved picture for a tab and whether it should be tinted.
    static func image(for id: String) -> (image: UIImage, template: Bool)? {
        for template in [true, false] {
            if let img = UIImage(contentsOfFile: file(id, template: template).path) { return (img, template) }
        }
        return nil
    }

    static func has(_ id: String) -> Bool { image(for: id) != nil }

    static func save(_ data: Data, id: String) -> Bool {
        guard let source = UIImage(data: data), let cg = source.cgImage else { return false }
        let alpha = cg.alphaInfo
        let transparent = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let side: CGFloat = 96
        let fit = min(side / source.size.width, side / source.size.height)
        let size = CGSize(width: source.size.width * fit, height: source.size.height * fit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        guard let png = rendered.pngData() else { return false }
        remove(id)
        do { try png.write(to: file(id, template: transparent)) } catch { return false }
        bump()
        return true
    }

    static func remove(_ id: String) {
        for template in [true, false] { try? FileManager.default.removeItem(at: file(id, template: template)) }
        bump()
    }

    private static func bump() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    /// The image a tab shows: the saved picture, sized for the tab bar.
    static func tabImage(for id: String) -> Image? {
        guard let found = image(for: id) else { return nil }
        let img = found.image.withRenderingMode(found.template ? .alwaysTemplate : .alwaysOriginal)
        return Image(uiImage: img).renderingMode(found.template ? .template : .original)
    }
}

/// Customize ▸ Fonts & Icons: one picture per tab.
struct TabIconsSection: View {
    @Environment(LayoutStore.self) private var layout
    @AppStorage(TabIconStore.revisionKey) private var revision = 0
    @State private var pickerItem: PhotosPickerItem?
    @State private var target: String?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var failed = false

    var body: some View {
        Section {
            ForEach(layout.tabs) { item in
                HStack(spacing: 14) {
                    preview(item)
                        .frame(width: 30, height: 30)
                    Text(item.title)
                    Spacer()
                    Menu {
                        Button { target = item.id; showPhotos = true } label: { Label("Choose Photo…", systemImage: "photo") }
                        Button { target = item.id; showFiles = true } label: { Label("Choose File…", systemImage: "folder") }
                        if TabIconStore.has(item.id) {
                            Button(role: .destructive) { TabIconStore.remove(item.id) } label: { Label("Use Default Icon", systemImage: "arrow.uturn.backward") }
                        }
                    } label: {
                        Text(TabIconStore.has(item.id) ? "Change" : "Add")
                    }
                }
            }
        } header: { Text("Tab Icons") } footer: {
            Text("Pick a picture for any tab. A PNG with a transparent background takes the tab's colour like the built-in icons.")
        }
        .id(revision)
        .photosPicker(isPresented: $showPhotos, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, new in
            guard let new, let id = target else { return }
            Task {
                if let data = try? await new.loadTransferable(type: Data.self) {
                    if !TabIconStore.save(data, id: id) { failed = true }
                }
                pickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard let id = target, case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), TabIconStore.save(data, id: id) {} else { failed = true }
        }
        .alert("Couldn't Use That Picture", isPresented: $failed) { Button("OK") {} }
    }

    @ViewBuilder private func preview(_ item: TabItemConfig) -> some View {
        if let img = TabIconStore.tabImage(for: item.id) {
            img.resizable().scaledToFit().foregroundStyle(Theme.accent)
        } else {
            Image(systemName: item.icon).font(.system(size: 20)).foregroundStyle(Theme.accent)
        }
    }
}
