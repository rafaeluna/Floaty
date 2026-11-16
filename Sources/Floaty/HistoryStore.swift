import AppKit

/// Saves every capture as a plain PNG in ~/Pictures/Floaty and prunes old ones.
final class HistoryStore {
    static let shared = HistoryStore()

    static let filePrefix = "Floaty "
    var retentionDays: Int { Settings.retentionDays }

    private let queue = DispatchQueue(label: "floaty.history", qos: .utility)

    var folder: URL {
        if let custom = Settings.folderPath {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Floaty", isDirectory: true)
    }

    /// Returns the destination immediately; the file is written in the background.
    @discardableResult
    func save(_ image: CGImage, scale: CGFloat, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = Self.filePrefix + formatter.string(from: date)

        let folder = self.folder
        var url = folder.appendingPathComponent(base + ".png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).png")
            counter += 1
        }

        let destination = url
        queue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let data = ImageExport.pngData(image, scale: scale) else { return }
                try data.write(to: destination, options: .atomic)
            } catch {
                NSLog("Floaty: could not save capture: \(error.localizedDescription)")
            }
        }
        return url
    }

    struct Sidecar: Codable {
        var annotations: [Annotation]
        var crop: CGRect
    }

    /// Stores a capture's annotations in a hidden folder beside the PNGs, so
    /// the original image is never altered and marks stay editable.
    func saveSidecar(_ sidecar: Sidecar, for imageURL: URL) {
        let directory = imageURL.deletingLastPathComponent().appendingPathComponent(".floaty", isDirectory: true)
        let destination = directory.appendingPathComponent(imageURL.deletingPathExtension().lastPathComponent + ".json")
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(sidecar).write(to: destination, options: .atomic)
            } catch {
                NSLog("Floaty: could not save annotations: \(error.localizedDescription)")
            }
        }
    }

    /// Deletes Floaty's own captures older than the retention period. Files that
    /// do not carry Floaty's name prefix are never touched.
    func prune() {
        let folder = self.folder
        let days = retentionDays
        guard days > 0 else { return }
        queue.async {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
            )) ?? []
            for file in files
            where file.pathExtension == "png" && file.lastPathComponent.hasPrefix(Self.filePrefix) {
                guard let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      created < cutoff else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
