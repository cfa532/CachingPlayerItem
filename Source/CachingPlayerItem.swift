//
//  CachingPlayerItem.swift
//  CachingPlayerItem
//
//  Created by Gorjan Shukov on 10/24/20.
//

import Foundation
import AVFoundation
import Network

/// Convenient delegate methods for `CachingPlayerItem` status updates.
@objc public protocol CachingPlayerItemDelegate {
    // MARK: Downloading delegate methods

    /// Called when the media file is fully downloaded.
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String)

    /// Called every time a new portion of data is received.
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int)

    /// Called on downloading error.
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error)

    // MARK: Playing delegate methods

    /// Called after initial prebuffering is finished, means we are ready to play.
    @objc optional func playerItemReadyToPlay(_ playerItem: CachingPlayerItem)

    /// Called when the player is unable to play the data/url.
    @objc optional func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?)

    /// Called when the data being downloaded did not arrive in time to continue playback.
    @objc optional func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem)
}

/// AVPlayerItem subclass that supports caching while playing.
public final class CachingPlayerItem: AVPlayerItem {
    private let cachingPlayerItemScheme = "cachingPlayerItemScheme"

    private var resourceLoaderDelegate: ResourceLoaderDelegate?
    private let url: URL
    private let initialScheme: String?
    private let saveFilePath: String
    private var customFileExtension: String?
    private let isHLS: Bool
    private let mediaID: String?
    /// HTTPHeaderFields set in avUrlAssetOptions using AVURLAssetHTTPHeaderFieldsKey
    internal var urlRequestHeaders: [String: String]?
    
    // Task management for proper cleanup
    private var activeTasks: Set<Task<Void, Never>> = []

    /// Useful for keeping relevant model associated with CachingPlayerItem instance. This is a **strong** reference, be mindful not to create a **retain cycle**.
    public var passOnObject: Any?
    /// `delegate` for status updates.
    public weak var delegate: CachingPlayerItemDelegate?
    
    deinit {
        // Cancel all active tasks to prevent weak reference crashes
        for task in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        
        removeObservers()
        
        // Clean up resource loader delegate to prevent weak reference issues
        if let urlAsset = asset as? AVURLAsset {
            urlAsset.resourceLoader.setDelegate(nil, queue: nil)
        }

        // Cancel download only for caching inits
        guard initialScheme != nil else { return }

        // Otherwise the ResourceLoaderDelegate wont deallocate and will keep downloading.
        resourceLoaderDelegate?.invalidateAndCancelSession(shouldResetData: false)
    }
    
    /// Helper method to remove completed task from tracking
    private func removeTask(_ task: Task<Void, Never>) {
        activeTasks.remove(task)
    }

    // MARK: Public init

    /**
     Play and cache remote media on a local file. `saveFilePath` is **randomly** generated. Requires `url.pathExtension` to not be empty otherwise the player will fail playing.

     - parameter url: URL referencing the media file.
     */
    public convenience init(url: URL) {
        self.init(url: url, saveFilePath: Self.randomFilePath(withExtension: url.pathExtension), customFileExtension: nil, avUrlAssetOptions: nil)
    }

    /**
     Play and cache remote media on a local file. `saveFilePath` is **randomly** generated. Requires `url.pathExtension` to not be empty otherwise the player will fail playing.

     - parameter url: URL referencing the media file.

     - parameter avUrlAssetOptions: A dictionary that contains options used to customize the initialization of the asset. For supported keys and values,
     see [Initialization Options.](https://developer.apple.com/documentation/avfoundation/avurlasset/initialization_options)
     */
    public convenience init(url: URL, avUrlAssetOptions: [String: Any]? = nil) {
        self.init(url: url, saveFilePath: Self.randomFilePath(withExtension: url.pathExtension), customFileExtension: nil, avUrlAssetOptions: avUrlAssetOptions)
    }

    /**
     Play and cache remote media on a local file. `saveFilePath` is **randomly** generated.

     - parameter url: URL referencing the media file.

     - parameter customFileExtension: Media file extension. E.g. mp4, mp3. This is required for the player to work correctly with the intended file type.

     - parameter avUrlAssetOptions: A dictionary that contains options used to customize the initialization of the asset. For supported keys and values,
     see [Initialization Options.](https://developer.apple.com/documentation/avfoundation/avurlasset/initialization_options)
     */
    public convenience init(url: URL, customFileExtension: String, avUrlAssetOptions: [String: Any]? = nil) {
        self.init(url: url, saveFilePath: Self.randomFilePath(withExtension: customFileExtension), customFileExtension: customFileExtension, avUrlAssetOptions: avUrlAssetOptions)
    }

    /**
     Play and cache remote media.

     - parameter url: URL referencing the media file.

     - parameter saveFilePath: The desired local save location. E.g. "video.mp4". **Must** be a unique file path that doesn't already exist. If a file exists at the path than it's **required** to be empty (contain no data).

     - parameter customFileExtension: Media file extension. E.g. mp4, mp3. This is required for the player to work correctly with the intended file type.

     - parameter avUrlAssetOptions: A dictionary that contains options used to customize the initialization of the asset. For supported keys and values,
     see [Initialization Options.](https://developer.apple.com/documentation/avfoundation/avurlasset/initialization_options)
     
     - parameter isHLS: Whether this is an HLS video that needs special handling.
     - parameter mediaID: Unique identifier for the media (used for HLS segment caching).
     */
    public init(url: URL, saveFilePath: String, customFileExtension: String?, avUrlAssetOptions: [String: Any]? = nil, isHLS: Bool = false, mediaID: String? = nil) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else {
            fatalError("CachingPlayerItem error: Urls without a scheme are not supported")
        }

        self.url = url
        self.saveFilePath = saveFilePath
        self.initialScheme = scheme
        self.isHLS = isHLS
        self.mediaID = mediaID

        // For HLS videos, use the local HTTP server URL instead of custom scheme
        let finalURL: URL
        if isHLS, let mediaID = mediaID {
            // Use local HTTP server URL for HLS
            if let localURL = LocalHTTPServer.shared.getLocalURL(for: mediaID) {
                finalURL = localURL
                print("DEBUG: [CachingPlayerItem] Using local HTTP server URL: \(localURL.absoluteString)")
            } else {
                fatalError("CachingPlayerItem error: Failed to get local HTTP server URL")
            }
        } else {
            // For progressive videos, use custom scheme
            guard var urlWithCustomScheme = url.withScheme(cachingPlayerItemScheme) else {
                fatalError("CachingPlayerItem error: Failed to create custom scheme URL")
            }

        if let ext = customFileExtension {
            urlWithCustomScheme.deletePathExtension()
            urlWithCustomScheme.appendPathExtension(ext)
            self.customFileExtension = ext
            } else {
            assert(url.pathExtension.isEmpty == false, "CachingPlayerItem error: url pathExtension empty, pass the extension in `customFileExtension` parameter")
            }
            
            finalURL = urlWithCustomScheme
        }

        if let headers = avUrlAssetOptions?["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] {
            self.urlRequestHeaders = headers
        }

        let asset = AVURLAsset(url: finalURL, options: avUrlAssetOptions)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)

        // Initialize resource loader delegate for progressive videos
        if !isHLS {
            resourceLoaderDelegate = ResourceLoaderDelegate(url: url, saveFilePath: saveFilePath, owner: self, isHLS: isHLS, mediaID: mediaID)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: DispatchQueue.main)
        } else if isHLS, let _ = mediaID {
            // For HLS with HTTP server, start downloading and caching the content
            startHLSDownloadAndCaching()
        }

        addObservers()
    }

    /**
     Play and cache HLS media (M3U8 playlists with TS segments).

     - parameter hlsURL: URL referencing the HLS playlist file (.m3u8).
     - parameter mediaID: Unique identifier for the media (used for cache key).
     - parameter avUrlAssetOptions: A dictionary that contains options used to customize the initialization of the asset.
     */
    public convenience init(hlsURL: URL, mediaID: String, avUrlAssetOptions: [String: Any]? = nil) {
        // Start the local HTTP server if not already running
        LocalHTTPServer.shared.start()
        
        // Create a unique save path for the HLS playlist
        let savePath = Self.hlsPlaylistPath(for: mediaID)
        
        // Register this media with the HTTP server
        LocalHTTPServer.shared.registerMedia(mediaID: mediaID, cachePath: savePath)
        
        self.init(url: hlsURL, saveFilePath: savePath, customFileExtension: "m3u8", avUrlAssetOptions: avUrlAssetOptions, isHLS: true, mediaID: mediaID)
    }

    /**
     Play remote media **without** caching.

     - parameter nonCachingURL: URL referencing the media file.

     - parameter avUrlAssetOptions: A dictionary that contains options used to customize the initialization of the asset. For supported keys and values,
     see [Initialization Options.](https://developer.apple.com/documentation/avfoundation/avurlasset/initialization_options)
     */
    public init(nonCachingURL url: URL, avUrlAssetOptions: [String: Any]? = nil) {
        self.url = url
        self.saveFilePath = ""
        self.initialScheme = nil
        self.isHLS = false
        self.mediaID = nil

        let asset = AVURLAsset(url: url, options: avUrlAssetOptions)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)

        addObservers()
    }

    /**
     Play from data.

     - parameter data: Media file represented in data.

     - parameter customFileExtension: Media file extension. E.g. mp4, mp3. This is required for the player to work correctly with the intended file type.

     - throws: An error in the Cocoa domain, if there is an error writing to the `URL`.
     */
    public convenience init(data: Data, customFileExtension: String) throws {
        let filePathURL = URL(fileURLWithPath: Self.randomFilePath(withExtension: customFileExtension))
        FileManager.default.createFile(atPath: filePathURL.path, contents: nil, attributes: nil)
        try data.write(to: filePathURL)
        self.init(filePathURL: filePathURL)
    }

    /**
     Play from file.

     - parameter filePathURL: The local file path of a media file.

     - parameter fileExtension: Media file extension. E.g. mp4, mp3. **Required**  if `filePathURL.pathExtension` is empty.
     */
    public init(filePathURL: URL, fileExtension: String? = nil) {
        if let fileExtension = fileExtension {
            let url = filePathURL.deletingPathExtension()
            self.url = url.appendingPathExtension(fileExtension)

            // Removes old SymLinks which cause issues
            try? FileManager.default.removeItem(at: self.url)

            try? FileManager.default.createSymbolicLink(at: self.url, withDestinationURL: filePathURL)
        } else {
            assert(filePathURL.pathExtension.isEmpty == false,
                   "CachingPlayerItem error: filePathURL pathExtension empty, pass the extension in `fileExtension` parameter")
            self.url = filePathURL
        }

        // Not needed properties when playing media from a local file.
        self.saveFilePath = ""
        self.initialScheme = nil
        self.isHLS = false
        self.mediaID = nil

        super.init(asset: AVURLAsset(url: url), automaticallyLoadedAssetKeys: nil)

        addObservers()
    }

    /**
     Play media using an AVAsset. Caching is **not** supported for this method.

     - parameter asset: An instance of AVAsset.
     - parameter automaticallyLoadedAssetKeys: An NSArray of NSStrings, each representing a property key defined by AVAsset.
     */
    override public init(asset: AVAsset, automaticallyLoadedAssetKeys: [String]?) {
        self.url = URL(fileURLWithPath: "")
        self.initialScheme = nil
        self.saveFilePath = ""
        self.isHLS = false
        self.mediaID = nil
        super.init(asset: asset, automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)

        addObservers()
    }


    // MARK: Public methods

    /// Downloads the media file. Works only with the initializers intended for play and cache.
    public func download() {
        // Make sure we are not initilalized with a filePath or non-caching init.
        guard initialScheme != nil else {
            assertionFailure("CachingPlayerItem error: `download` method used on a non caching instance")
            return
        }

        resourceLoaderDelegate?.startFileDownload(with: url)
    }

    /// Cancels the download of the media file and deletes the incomplete cached file. Works only with the initializers intended for play and cache.
    public func cancelDownload() {
        // Make sure we are not initilalized with a filePath or non-caching init.
        guard initialScheme != nil else {
            assertionFailure("CachingPlayerItem error: `cancelDownload` method used on a non caching instance")
            return
        }

        resourceLoaderDelegate?.invalidateAndCancelSession()
    }
    
    // MARK: HLS HTTP Server Support
    
    /// Start downloading and caching HLS content for HTTP server approach
    private func startHLSDownloadAndCaching() {
        guard isHLS, let mediaID = mediaID else { return }
        
        print("DEBUG: [CachingPlayerItem] Starting HLS download and caching for mediaID: \(mediaID)")
        
        // Start downloading the master playlist directly without using ResourceLoaderDelegate
        let task = Task<Void, Never> { [weak self] in
            guard let self = self else { return }
            await self.downloadHLSContent()
        }
        activeTasks.insert(task)
        
        // Don't create a separate cleanup task - let deinit handle cleanup
        // The task will be removed from activeTasks in deinit when the instance is deallocated
    }
    
    /// Download HLS content asynchronously
    private func downloadHLSContent() async {
        guard let mediaID = mediaID else { return }
        
        do {
            // Resolve the HLS URL (master.m3u8 or playlist.m3u8)
            let resolvedURL = await resolveHLSURL(url)
            print("DEBUG: [CachingPlayerItem] Resolved HLS URL: \(resolvedURL.absoluteString)")
            
            // Download the master playlist
            let playlistData = try await downloadData(from: resolvedURL)
            
            // Modify the playlist to include mediaID in sub-playlist URLs
            let modifiedPlaylistData = try modifyPlaylistForLocalServer(playlistData: playlistData, mediaID: mediaID)
            
            let playlistPath = saveFilePath
            try modifiedPlaylistData.write(to: URL(fileURLWithPath: playlistPath))
            print("DEBUG: [CachingPlayerItem] Downloaded and modified master playlist to: \(playlistPath)")
            
            // Parse and download segments
            await downloadHLSSegments(playlistData: playlistData, baseURL: resolvedURL, mediaID: mediaID)
            
        } catch {
            print("DEBUG: [CachingPlayerItem] Failed to download HLS content: \(error)")
            // Don't use weak self here to avoid weak reference crash
            // The delegate callback is optional and can be safely skipped if self is deallocated
        }
    }
    
    /// Modify playlist content to include mediaID in sub-playlist URLs for local server
    private func modifyPlaylistForLocalServer(playlistData: Data, mediaID: String) throws -> Data {
        guard let playlistContent = String(data: playlistData, encoding: .utf8) else {
            throw NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse playlist content"])
        }
        
        let lines = playlistContent.components(separatedBy: .newlines)
        var modifiedLines: [String] = []
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if this line contains a sub-playlist URL (ends with .m3u8 and doesn't start with http)
            if trimmedLine.hasSuffix(".m3u8") && !trimmedLine.hasPrefix("http") {
                // This is a relative sub-playlist URL, modify it to include mediaID
                let modifiedURL = "/media/\(mediaID)/\(trimmedLine)"
                modifiedLines.append(modifiedURL)
                print("DEBUG: [CachingPlayerItem] Modified sub-playlist URL: \(trimmedLine) -> \(modifiedURL)")
            } else {
                // Keep other lines unchanged
                modifiedLines.append(line)
            }
        }
        
        let modifiedContent = modifiedLines.joined(separator: "\n")
        guard let modifiedData = modifiedContent.data(using: .utf8) else {
            throw NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode modified playlist content"])
        }
        
        return modifiedData
    }
    
    /// Download HLS segments from playlist
    private func downloadHLSSegments(playlistData: Data, baseURL: URL, mediaID: String) async {
        guard let playlistContent = String(data: playlistData, encoding: .utf8) else {
            print("DEBUG: [CachingPlayerItem] Failed to parse playlist content")
            return
        }
        
        let lines = playlistContent.components(separatedBy: .newlines)
        let segmentsPath = Self.hlsSegmentsPath(for: mediaID)
        
        // Create segments directory
        try? FileManager.default.createDirectory(atPath: segmentsPath, withIntermediateDirectories: true)
        
        var segmentTasks: [Task<Void, Error>] = []
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip comments and empty lines
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }
            
            // This is a segment URL
            let segmentURL: URL
            if trimmedLine.hasPrefix("http") {
                // Absolute URL
                segmentURL = URL(string: trimmedLine)!
            } else {
                // Relative URL
                segmentURL = baseURL.deletingLastPathComponent().appendingPathComponent(trimmedLine)
            }
            
            let task = Task<Void, Error> {
                do {
                    // Use URLSession directly instead of self?.downloadData to avoid weak reference
                    let segmentData = try await Self.downloadDataDirectly(from: segmentURL)
                    let segmentName = segmentURL.lastPathComponent
                    let segmentPath = "\(segmentsPath)/\(segmentName)"
                    try segmentData.write(to: URL(fileURLWithPath: segmentPath))
                    print("DEBUG: [CachingPlayerItem] Downloaded segment: \(segmentName)")
                } catch {
                    print("DEBUG: [CachingPlayerItem] Failed to download segment \(segmentURL.absoluteString): \(error)")
                    throw error
                }
            }
            
            // Create a wrapper task for tracking
            var trackingTask: Task<Void, Never>!
            trackingTask = Task<Void, Never> {
                do {
                    try await task.value
                } catch {
                    // Error already logged in the main task
                }
                // Don't try to remove task here - let deinit handle cleanup
                // This avoids the weak reference crash when self is being deallocated
            }
            activeTasks.insert(trackingTask)
            
            segmentTasks.append(task)
        }
        
        // Wait for all segments to download
        for task in segmentTasks {
            do {
                try await task.value
            } catch {
                print("DEBUG: [CachingPlayerItem] Segment download failed: \(error)")
            }
        }
        
        print("DEBUG: [CachingPlayerItem] Completed HLS download and caching for mediaID: \(mediaID)")
    }
    
    /// Download data from URL
    private func downloadData(from url: URL) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
    
    /// Static version of downloadData that doesn't require self
    private static func downloadDataDirectly(from url: URL) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
    
    /// Resolve HLS URL (master.m3u8 -> playlist.m3u8 -> fail)
    private func resolveHLSURL(_ baseURL: URL) async -> URL {
        // Try master.m3u8 first
        let masterURL = baseURL.appendingPathComponent("master.m3u8")
        if await urlExists(masterURL) {
            print("DEBUG: [CachingPlayerItem] Found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        // Try playlist.m3u8
        let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
        if await urlExists(playlistURL) {
            print("DEBUG: [CachingPlayerItem] Found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // If neither exists, return the original URL (will fail gracefully)
        print("DEBUG: [CachingPlayerItem] No HLS playlist found, using original URL")
        return baseURL
    }
    
    /// Check if URL exists
    private func urlExists(_ url: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0
            
            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                let exists = (response as? HTTPURLResponse)?.statusCode == 200
                continuation.resume(returning: exists)
            }
            task.resume()
        }
    }

    // MARK: KVO

    private var playerItemContext = 0

    public override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?) {

        // Only handle observations for the playerItemContext
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }

        // We are only observing the status keypath
        guard keyPath == #keyPath(AVPlayerItem.status) else { return }

        let status: AVPlayerItem.Status
        if let statusNumber = change?[.newKey] as? NSNumber {
            status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
        } else {
            status = .unknown
        }

        // Switch over status value
        switch status {
        case .readyToPlay:
            // Player item is ready to play.
            AppLogger.info("CachingPlayerItem status: ready to play")
            DispatchQueue.main.async { self.delegate?.playerItemReadyToPlay?(self) }
        case .failed:
            // Player item failed. See error.
            AppLogger.error("CachingPlayerItem status: failed with error: \(String(describing: error))")
            DispatchQueue.main.async { self.delegate?.playerItemDidFailToPlay?(self, withError: self.error) }
        case .unknown:
            // Player item is not yet ready.
            AppLogger.error("CachingPlayerItem status: uknown with error: \(String(describing: error))")
        @unknown default:
            break
        }
    }

    // MARK: Private methods

    private func addObservers() {
        addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: .new, context: &playerItemContext)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStalledHandler), name: .AVPlayerItemPlaybackStalled, object: self)
    }

    private func removeObservers() {
        removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playbackStalledHandler() {
        DispatchQueue.main.async { self.delegate?.playerItemPlaybackStalled?(self) }
    }

    /// Generates a random file path in caches directory with the provided `fileExtension`.
    private static func randomFilePath(withExtension fileExtension: String) -> String {
        guard var cachesDirectory = try? FileManager.default.url(for: .cachesDirectory,
                                                                 in: .userDomainMask,
                                                                 appropriateFor: nil,
                                                                 create: true)
        else {
            fatalError("CachingPlayerItem error: Can't access default cache directory")
        }

        cachesDirectory.appendPathComponent(UUID().uuidString)
        cachesDirectory.appendPathExtension(fileExtension)

        return cachesDirectory.path
    }
    
    /// Generates a file path for HLS playlist in caches directory.
    private static func hlsPlaylistPath(for mediaID: String) -> String {
        guard var cachesDirectory = try? FileManager.default.url(for: .cachesDirectory,
                                                                 in: .userDomainMask,
                                                                 appropriateFor: nil,
                                                                 create: true)
        else {
            fatalError("CachingPlayerItem error: Can't access default cache directory")
        }
        
        let sanitizedFileName = mediaID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "hls_playlist"
        cachesDirectory.appendPathComponent("\(sanitizedFileName).m3u8")
        
        return cachesDirectory.path
    }
    
    /// Generates a directory path for HLS segments in caches directory.
    public static func hlsSegmentsPath(for mediaID: String) -> String {
        guard var cachesDirectory = try? FileManager.default.url(for: .cachesDirectory,
                                                                 in: .userDomainMask,
                                                                 appropriateFor: nil,
                                                                 create: true)
        else {
            fatalError("CachingPlayerItem error: Can't access default cache directory")
        }
        
        let sanitizedFileName = mediaID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "hls_segments"
        cachesDirectory.appendPathComponent("\(sanitizedFileName)_segments")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true, attributes: nil)
        
        return cachesDirectory.path
    }
    
    /// Check if HLS video is cached by mediaID
    public static func isHLSCached(for mediaID: String) -> Bool {
        let playlistPath = hlsPlaylistPath(for: mediaID)
        return FileManager.default.fileExists(atPath: playlistPath)
    }
    
    /// Get cached HLS playlist path by mediaID
    public static func getCachedHLSPath(for mediaID: String) -> String? {
        let playlistPath = hlsPlaylistPath(for: mediaID)
        return FileManager.default.fileExists(atPath: playlistPath) ? playlistPath : nil
    }
    
    /// Clear all cached HLS content for a specific mediaID
    public static func clearHLSCache(for mediaID: String) {
        let playlistPath = hlsPlaylistPath(for: mediaID)
        let segmentsPath = hlsSegmentsPath(for: mediaID)
        
        // Remove playlist file
        try? FileManager.default.removeItem(atPath: playlistPath)
        
        // Remove segments directory
        try? FileManager.default.removeItem(atPath: segmentsPath)
        
        print("DEBUG: [CachingPlayerItem] Cleared HLS cache for mediaID: \(mediaID)")
    }
    
    /// Clear all cached content (both HLS and progressive videos)
    public static func clearAllCache() {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            print("DEBUG: [CachingPlayerItem] Failed to access caches directory")
            return
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cachesDirectory, includingPropertiesForKeys: nil)
            
            for url in contents {
                let fileName = url.lastPathComponent
                
                // Remove files that look like cached media (contain mediaID patterns)
                if fileName.hasSuffix(".m3u8") || fileName.hasSuffix("_segments") || fileName.contains("Qm") {
                    try FileManager.default.removeItem(at: url)
                    print("DEBUG: [CachingPlayerItem] Removed cached file: \(fileName)")
                }
            }
            
            print("DEBUG: [CachingPlayerItem] Cleared all cache files")
        } catch {
            print("DEBUG: [CachingPlayerItem] Failed to clear cache: \(error)")
        }
    }
}

