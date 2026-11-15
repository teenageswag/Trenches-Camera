import AVFoundation
import Photos
import UIKit

struct SavedCapture: Identifiable {
    let url: URL
    let date: Date
    var id: URL { url }
    var isVideo: Bool { url.pathExtension == "mov" }
}

enum CaptureLibrary {
    static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func newURL(extension suffix: String) throws -> URL {
        try directory().appendingPathComponent("trenches-\(UUID().uuidString).\(suffix)")
    }
    static func items() throws -> [SavedCapture] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
            .filter { ["jpg", "mov"].contains($0.pathExtension) }
            .compactMap { url in
                guard let attributes = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]), (attributes.fileSize ?? 0) > 0 else { return nil }
                return SavedCapture(url: url, date: attributes.creationDate ?? .distantPast)
            }.sorted { $0.date > $1.date }
    }
    static func saveToPhotos(_ url: URL, completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("Сохранено в приложении. Доступ к «Фото» можно разрешить в Настройках.")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                if url.pathExtension == "mov" { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
            } completionHandler: { success, error in
                completion(success ? "Сохранено в «Фото» и в приложении" : "Сохранено в приложении. «Фото»: \(error?.localizedDescription ?? "ошибка сохранения")")
            }
        }
    }
    static func thumbnail(_ url: URL) async -> UIImage? {
        if url.pathExtension != "mov" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 500, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 500, height: 700)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image)
    }
}
