import AVKit
import SwiftUI

struct CaptureLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var captures: [SavedCapture] = []
    @State private var selected: SavedCapture?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if captures.isEmpty {
                    ContentUnavailableView("Пока тихо", systemImage: "camera", description: Text("Ваши фото и видео появятся здесь после съёмки."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                            ForEach(captures) { capture in
                                Button { selected = capture } label: { CaptureThumbnail(capture: capture) }.buttonStyle(.plain)
                            }
                        }.padding()
                    }
                }
            }
            .navigationTitle("Съёмки")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { do { captures = try CaptureLibrary.items() } catch { self.error = error.localizedDescription } }
            .sheet(item: $selected) { CaptureDetail(capture: $0) }
            .alert("Не удалось открыть съёмки", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Понятно", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct CaptureThumbnail: View {
    let capture: SavedCapture
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(TrenchesTheme.surface)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            Label(capture.isVideo ? "ВИДЕО" : "ФОТО", systemImage: capture.isVideo ? "play.fill" : "camera.fill")
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(8).background(.black.opacity(0.7), in: Capsule()).padding(8)
        }
        .frame(height: 220).clipped().clipShape(RoundedRectangle(cornerRadius: 18))
        .task(id: capture.id) { image = await CaptureLibrary.thumbnail(capture.url) }
        .accessibilityLabel("\(capture.isVideo ? "Видео" : "Фото"), \(capture.date.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct CaptureDetail: View {
    let capture: SavedCapture
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var editingDatamosh = false
    var body: some View {
        NavigationStack {
            Group {
                if capture.isVideo {
                    VideoPlayer(player: player)
                } else if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            .navigationTitle(capture.date.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: capture.url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Поделиться") }
                if capture.isVideo {
                    ToolbarItem(placement: .bottomBar) { Button("Открыть Datamosh") { player?.pause(); editingDatamosh = true } }
                }
            }
            .task {
                if capture.isVideo { player = AVPlayer(url: capture.url); player?.play() }
                else { image = UIImage(contentsOfFile: capture.url.path) }
            }
            .onDisappear { player?.pause(); player = nil }
            .fullScreenCover(isPresented: $editingDatamosh) { DatamoshEditor(url: capture.url) }
        }
    }
}
