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

        // For HLS videos, use a custom scheme that will be handled by ResourceLoaderDelegate
        let finalURL: URL
        if isHLS, let mediaID = mediaID {
            // Use custom scheme for HLS - ResourceLoaderDelegate will handle the download and serve from local server
            guard var urlWithCustomScheme = url.withScheme(cachingPlayerItemScheme) else {
                fatalError("CachingPlayerItem error: Failed to create custom scheme URL")
            }
            finalURL = urlWithCustomScheme
            print("DEBUG: [CachingPlayerItem] Using custom scheme URL for HLS: \(finalURL.absoluteString)")
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

        // Initialize resource loader delegate for all caching scenarios
        resourceLoaderDelegate = ResourceLoaderDelegate(url: url, saveFilePath: saveFilePath, owner: self, isHLS: isHLS, mediaID: mediaID)
        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: DispatchQueue.main)

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
    public static func hlsPlaylistPath(for mediaID: String) -> String {
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

