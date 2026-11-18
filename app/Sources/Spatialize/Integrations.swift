import AppIntents
import AppKit
import UniformTypeIdentifiers

// MARK: - Finder: right-click → Convert with Spatialize

/// The Services entry (Info.plist NSServices, message "convertMovies"): Finder offers it in the
/// right-click menu for movie files. The movies join the queue with the current settings.
final class ServiceProvider: NSObject {
    @objc func convertMovies(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error?.pointee = "No movie files were selected." as NSString
            return
        }
        MainActor.assumeIsolated { AppState.shared.convertFromOutside(urls) }
    }
}

// MARK: - Shortcuts

struct ConvertMoviesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Movies with Spatialize"
    static let description = IntentDescription("Adds movies to Spatialize's queue. They are converted one after another with the settings currently chosen in the app.")
    static let openAppWhenRun = true

    @Parameter(title: "Movies", supportedContentTypes: [.movie, .audiovisualContent, .item])
    var movies: [IntentFile]

    static var parameterSummary: some ParameterSummary { Summary("Convert \(\.$movies) with Spatialize") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let urls = movies.compactMap(\.fileURL)
        guard !urls.isEmpty else {
            throw Shell.Failure(message: "Spatialize needs movie files from Finder or Files, not their contents.")
        }
        AppState.shared.convertFromOutside(urls)
        return .result(dialog: "Added \(urls.count) movie\(urls.count == 1 ? "" : "s") to the Spatialize queue.")
    }
}

struct OpenMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Movie in Spatialize"
    static let description = IntentDescription("Opens a movie in Spatialize so you can choose its tracks and settings.")
    static let openAppWhenRun = true

    @Parameter(title: "Movie", supportedContentTypes: [.movie, .audiovisualContent, .item])
    var movie: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = movie.fileURL else {
            throw Shell.Failure(message: "Spatialize needs a movie file from Finder or Files.")
        }
        AppState.shared.open(url)
        return .result()
    }
}

struct SpatializeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertMoviesIntent(),
                    phrases: ["Convert movies with \(.applicationName)", "\(.applicationName) these movies"],
                    shortTitle: "Convert Movies", systemImageName: "airpodspro")
        AppShortcut(intent: OpenMovieIntent(),
                    phrases: ["Open a movie in \(.applicationName)"],
                    shortTitle: "Open Movie", systemImageName: "film")
    }
}
