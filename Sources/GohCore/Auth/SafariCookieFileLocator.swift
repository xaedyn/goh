import Foundation

public enum SafariCookieFileLocator {
    public static func candidateURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appending(
                path: "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            homeDirectory.appending(path: "Library/Cookies/Cookies.binarycookies"),
        ]
    }

    public static func firstReadableCookieFile(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        candidateURLs(homeDirectory: homeDirectory).first { candidate in
            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory)
            return exists
                && !isDirectory.boolValue
                && fileManager.isReadableFile(atPath: candidate.path)
        }
    }
}
