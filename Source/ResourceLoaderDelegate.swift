//
//  ResourceLoaderDelegate.swift
//  CachingPlayerItem
//
//  Created by Gorjan Shukov on 10/24/20.
//

import Foundation
import AVFoundation
import UIKit

/// Responsible for downloading media data and providing the requested data parts.
final class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    typealias PendingRequestId = Int

    private let lock = NSLock()

    private var bufferData = Data()
    private let downloadBufferLimit = CachingPlayerItemConfiguration.downloadBufferLimit
    private let readDataLimit = CachingPlayerItemConfiguration.readDataLimit

    private lazy var fileHandle = MediaFileHandle(filePath: saveFilePath)

    private var session: URLSession?
    private let operationQueue = {
        let queue = OperationQueue()
        queue.name = "CachingPlayerItemOperationQueue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var pendingContentInfoRequest: PendingContentInfoRequest? {
        didSet { oldValue?.cancelTask() }
    }
    private var contentInfoResponse: URLResponse?
    private var pendingDataRequests: [PendingRequestId: PendingDataRequest] = [:]
    private var fullMediaFileDownloadTask: URLSessionDataTask?
    private var isDownloadComplete = false

    private let url: URL
    private let saveFilePath: String
    private let isHLS: Bool
    private let mediaID: String?
    private weak var owner: CachingPlayerItem?

    // MARK: Init

    init(url: URL, saveFilePath: String, owner: CachingPlayerItem?, isHLS: Bool = false, mediaID: String? = nil) {
        self.url = url
        self.saveFilePath = saveFilePath
        self.isHLS = isHLS
        self.mediaID = mediaID
        self.owner = owner
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        print("DEBUG: [CachingPlayerItem] resourceLoader: isHLS = \(isHLS), requestURL = \(loadingRequest.request.url?.absoluteString ?? "nil")")
        print("DEBUG: [CachingPlayerItem] resourceLoader: original url = \(url.absoluteString)")
        
        // Handle HLS videos differently
        if isHLS {
            return handleHLSRequest(loadingRequest)
        }
        
        // Original logic for progressive videos
        if session == nil {
            startFileDownload(with: url)
        }

        assert(session != nil, "Session must be set before proceeding.")
        guard let session else { return false }

        if let _ = loadingRequest.contentInformationRequest {
            pendingContentInfoRequest = PendingContentInfoRequest(url: url, session: session, loadingRequest: loadingRequest, customHeaders: owner?.urlRequestHeaders)
            pendingContentInfoRequest?.startTask()
            return true
        } else if let _ = loadingRequest.dataRequest {
            let request = PendingDataRequest(url: url, session: session, loadingRequest: loadingRequest, customHeaders: owner?.urlRequestHeaders)
            request.delegate = self
            request.startTask()
            addOperationOnQueue { [weak self] in self?.pendingDataRequests[request.id] = request }
            return true
        } else {
            return false
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        addOperationOnQueue { [weak self] in
            guard let self else { return }
            guard let key = pendingDataRequests.first(where: { $1.loadingRequest.request.url == loadingRequest.request.url })?.key else { return }

            pendingDataRequests[key]?.cancelTask()
            pendingDataRequests.removeValue(forKey: key)
        }
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        addOperationOnQueue { [weak self] in
            guard let self else { return }

            pendingDataRequests[dataTask.taskIdentifier]?.respond(withRemoteData: data)
        }

        if fullMediaFileDownloadTask?.taskIdentifier == dataTask.taskIdentifier {
            bufferData.append(data)
            writeBufferDataToFileIfNeeded()

            guard let response = contentInfoResponse ?? dataTask.response else { return }

            DispatchQueue.main.async {
                self.owner?.delegate?.playerItem?(self.owner!,
                                                  didDownloadBytesSoFar: self.fileHandle.fileSize + self.bufferData.count,
                                                  outOf: Int(response.processedInfoData.expectedContentLength))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        addOperationOnQueue { [weak self] in
            guard let self else { return }

            let taskId = task.taskIdentifier
            
            if let error {
                guard (error as? URLError)?.code != .cancelled else { return }

                if pendingContentInfoRequest?.id == taskId {
                    finishLoadingPendingRequest(withId: taskId, error: error)
                    downloadFailed(with: error)
                } else if fullMediaFileDownloadTask?.taskIdentifier == taskId {
                    downloadFailed(with: error)
                }  else {
                    finishLoadingPendingRequest(withId: taskId, error: error)
                }

                return
            }

            if let response = task.response, pendingContentInfoRequest?.id == taskId {
                let insufficientDiskSpaceError = checkAvailableDiskSpaceIfNeeded(response: response)
                guard insufficientDiskSpaceError == nil else {
                    downloadFailed(with: insufficientDiskSpaceError!)
                    return
                }

                pendingContentInfoRequest?.fillInContentInformationRequest(with: response)
                finishLoadingPendingRequest(withId: taskId)
                contentInfoResponse = response
            } else {
                finishLoadingPendingRequest(withId: taskId)
            }

            guard fullMediaFileDownloadTask?.taskIdentifier == taskId else { return }

            if bufferData.count > 0 {
                writeBufferDataToFileIfNeeded(forced: true)
            }

            let error = verify(response: contentInfoResponse ?? task.response)

            guard error == nil else {
                downloadFailed(with: error!)
                return
            }

            downloadComplete()
        }
    }

    // MARK: Internal methods

    func startFileDownload(with url: URL) {
        guard session == nil else { return }

        createURLSession()

        var urlRequest = URLRequest(url: url)
        owner?.urlRequestHeaders?.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

        fullMediaFileDownloadTask = session?.dataTask(with: urlRequest)
        fullMediaFileDownloadTask?.resume()
    }

    func invalidateAndCancelSession(shouldResetData: Bool = true) {
        session?.invalidateAndCancel()
        session = nil
        operationQueue.cancelAllOperations()

        if shouldResetData {
            bufferData = Data()
            addOperationOnQueue { [weak self] in
                guard let self else { return }

                pendingContentInfoRequest = nil
                pendingDataRequests.removeAll()
            }

        }

        // We need to only remove the file if it hasn't been fully downloaded
        guard isDownloadComplete == false else { return }

        fileHandle.deleteFile()
    }

    // MARK: Private methods

    private func createURLSession() {
        guard session == nil else {
            assertionFailure("Session already created.")
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private func finishLoadingPendingRequest(withId id: PendingRequestId, error: Error? = nil) {
        if pendingContentInfoRequest?.id == id {
            pendingContentInfoRequest?.finishLoading(with: error)
            pendingContentInfoRequest = nil
        } else if pendingDataRequests[id] != nil {
            pendingDataRequests[id]?.finishLoading(with: error)
            pendingDataRequests.removeValue(forKey: id)
        }
    }

    private func writeBufferDataToFileIfNeeded(forced: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        guard bufferData.count >= downloadBufferLimit || forced else { return }

        fileHandle.append(data: bufferData)
        bufferData = Data()
    }

    private func downloadComplete() {
        isDownloadComplete = true

        DispatchQueue.main.async {
            self.owner?.delegate?.playerItem?(self.owner!, didFinishDownloadingFileAt: self.saveFilePath)
        }
    }

    private func verify(response: URLResponse?) -> NSError? {
        guard let response = response as? HTTPURLResponse else { return nil }

        let shouldVerifyDownloadedFileSize = CachingPlayerItemConfiguration.shouldVerifyDownloadedFileSize
        let minimumExpectedFileSize = CachingPlayerItemConfiguration.minimumExpectedFileSize
        var error: NSError?

        if response.statusCode >= 400 {
            error = NSError(domain: "Failed downloading asset. Reason: response status code \(response.statusCode).", code: response.statusCode, userInfo: nil)
        } else if shouldVerifyDownloadedFileSize && response.processedInfoData.expectedContentLength != -1 && response.processedInfoData.expectedContentLength != fileHandle.fileSize {
            error = NSError(domain: "Failed downloading asset. Reason: wrong file size, expected: \(response.expectedContentLength), actual: \(fileHandle.fileSize).", code: response.statusCode, userInfo: nil)
        } else if minimumExpectedFileSize > 0 && minimumExpectedFileSize > fileHandle.fileSize {
            error = NSError(domain: "Failed downloading asset. Reason: file size \(fileHandle.fileSize) is smaller than minimumExpectedFileSize", code: response.statusCode, userInfo: nil)
        }

        return error
    }

    private func checkAvailableDiskSpaceIfNeeded(response: URLResponse) -> NSError? {
        guard
            CachingPlayerItemConfiguration.shouldCheckAvailableDiskSpaceBeforeCaching,
            let response = response as? HTTPURLResponse,
            let freeDiskSpace = fileHandle.freeDiskSpace
        else { return nil }

        if freeDiskSpace < response.processedInfoData.expectedContentLength {
            return NSError(domain: "Failed downloading asset. Reason: insufficient disk space available.", code: NSFileWriteOutOfSpaceError, userInfo: nil)
        }

        return nil
    }

    private func downloadFailed(with error: Error) {
        invalidateAndCancelSession()

        DispatchQueue.main.async {
            self.owner?.delegate?.playerItem?(self.owner!, downloadingFailedWith: error)
        }
    }

    private func addOperationOnQueue(_ block: @escaping () -> Void) {
        let blockOperation = BlockOperation()
        blockOperation.addExecutionBlock({ [unowned blockOperation] in
            guard blockOperation.isCancelled == false else { return }

            block()
        })
        operationQueue.addOperation(blockOperation)
    }

    @objc private func handleAppWillTerminate() {
        invalidateAndCancelSession(shouldResetData: false)
    }
}

// MARK: PendingDataRequestDelegate

extension ResourceLoaderDelegate: PendingDataRequestDelegate {
    func pendingDataRequest(_ request: PendingDataRequest, hasSufficientCachedDataFor offset: Int, with length: Int) -> Bool {
        fileHandle.fileSize >= length + offset
    }

    func pendingDataRequest(_ request: PendingDataRequest,
                            requestCachedDataFor offset: Int,
                            with length: Int,
                            completion: @escaping ((_ continueRequesting: Bool) -> Void)) {
        addOperationOnQueue { [weak self] in
            guard let self else { return }

            let bytesCached = fileHandle.fileSize
            // Data length to be loaded into memory with maximum size of readDataLimit.
            let bytesToRespond = min(bytesCached - offset, length, readDataLimit)
            // Read data from disk and pass it to the dataRequest
            guard let data = fileHandle.readData(withOffset: offset, forLength: bytesToRespond) else {
                finishLoadingPendingRequest(withId: request.id)
                completion(false)
                return
            }

            request.respond(withCachedData: data)

            if data.count >= length {
                finishLoadingPendingRequest(withId: request.id)
                completion(false)
            } else {
                completion(true)
            }
        }
    }
    
    // MARK: HLS Support
    
    private func handleHLSRequest(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url else { 
            print("DEBUG: [CachingPlayerItem] handleHLSRequest: No request URL")
            return false 
        }
        
        print("DEBUG: [CachingPlayerItem] handleHLSRequest: requestURL = \(requestURL.absoluteString)")
        print("DEBUG: [CachingPlayerItem] handleHLSRequest: original url = \(url.absoluteString)")
        
        // Convert custom scheme URL back to original URL if needed
        var originalURL = requestURL
        if requestURL.scheme == "cachingPlayerItemScheme" {
            // For the initial playlist request, we need to resolve the HLS URL first
            // Check if this is a base URL request (ends with just the video ID, no .m3u8 or sub-paths)
            let requestPath = requestURL.path
            let baseUrlPath = url.path
            
            // If the request path is the base URL + .m3u8, this means AVFoundation auto-appended .m3u8
            // We need to resolve the proper HLS URL (master.m3u8 or playlist.m3u8)
            if requestPath == baseUrlPath + ".m3u8" {
                // This is the initial request with auto-appended .m3u8 - resolve HLS URL
                let resolvedURL = resolveHLSURLSync(url)
                print("DEBUG: [CachingPlayerItem] handleHLSRequest: resolved HLS URL to \(resolvedURL.absoluteString)")
                originalURL = resolvedURL
            } else if requestPath == "/" || requestPath.isEmpty || requestPath.hasSuffix("/") {
                // This is the initial request - resolve HLS URL synchronously
                let resolvedURL = resolveHLSURLSync(url)
                print("DEBUG: [CachingPlayerItem] handleHLSRequest: resolved HLS URL to \(resolvedURL.absoluteString)")
                originalURL = resolvedURL
            } else {
                // This is a sub-request (playlist or segment) - construct full URL by combining base URL with relative path
                let requestPath = requestURL.path
                let baseURLPath = url.path
                
                // For sub-requests like /720/playlist.m3u8, we need to construct the full URL
                // by combining the base video URL with the relative path
                if requestPath.hasPrefix("/") && requestPath != baseURLPath {
                    // This is a sub-request with a relative path (e.g., /ipfs/720/playlist.m3u8)
                    // We need to extract the actual relative path by removing the /ipfs/ prefix
                    let baseURLString = url.absoluteString
                    
                    // The requestPath contains /ipfs/720/playlist.m3u8, but we need just /720/playlist.m3u8
                    // Remove the /ipfs/ prefix from the request path
                    print("DEBUG: [CachingPlayerItem] handleHLSRequest: requestPath = \(requestPath)")
                    print("DEBUG: [CachingPlayerItem] handleHLSRequest: baseURLString = \(baseURLString)")
                    
                    // For sub-requests, we need to construct the full URL by combining the base URL with the relative path
                    // The requestPath is like /ipfs/QmUMinKZTSx9tPpqmiyTFoPVQbsdCLMHQ5kKaQAJ8bn4d9/480p/playlist.m3u8
                    // The base URL is like http://125.229.161.122:8080/ipfs/QmUMinKZTSx9tPpqmiyTFoPVQbsdCLMHQ5kKaQAJ8bn4d9/master.m3u8
                    // We need to extract the relative path from the requestPath and append it to the base URL without the filename
                    
                    let actualRelativePath: String
                    if requestPath.hasPrefix("/ipfs/") {
                        // The requestPath contains /ipfs/QmUMinKZTSx9tPpqmiyTFoPVQbsdCLMHQ5kKaQAJ8bn4d9/480p/playlist.m3u8
                        // We need to extract just 480p/playlist.m3u8 by removing /ipfs/QmUMinKZTSx9tPpqmiyTFoPVQbsdCLMHQ5kKaQAJ8bn4d9/
                        let ipfsPrefix = "/ipfs/"
                        let mediaID = String(requestPath.dropFirst(ipfsPrefix.count))
                        if let slashIndex = mediaID.firstIndex(of: "/") {
                            actualRelativePath = String(mediaID[slashIndex...].dropFirst()) // Remove the leading slash
                        } else {
                            actualRelativePath = mediaID
                        }
                        print("DEBUG: [CachingPlayerItem] handleHLSRequest: extracted relative path: \(actualRelativePath)")
                    } else {
                        // If the request path doesn't start with /ipfs/, use it as-is
                        actualRelativePath = requestPath
                        print("DEBUG: [CachingPlayerItem] handleHLSRequest: no /ipfs/ prefix, using requestPath as-is: \(actualRelativePath)")
                    }
                    
                    // Construct the full URL by using the base URL without the filename, then appending the relative path
                    let baseURLWithoutFilename = url.deletingLastPathComponent().absoluteString
                    let fullURLString = baseURLWithoutFilename + "/" + actualRelativePath
                    print("DEBUG: [CachingPlayerItem] handleHLSRequest: fullURLString = \(fullURLString)")
                    
                    if let fullURL = URL(string: fullURLString) {
                        originalURL = fullURL
                        print("DEBUG: [CachingPlayerItem] handleHLSRequest: constructed full sub-request URL = \(originalURL.absoluteString)")
                    } else {
                        // Fallback to scheme conversion
                        if let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) {
                            let originalScheme = url.scheme ?? "http"
                            var newComponents = components
                            newComponents.scheme = originalScheme
                            originalURL = newComponents.url ?? requestURL
                        } else {
                            originalURL = requestURL.withScheme(url.scheme ?? "http") ?? requestURL
                        }
                        print("DEBUG: [CachingPlayerItem] handleHLSRequest: fallback converted to originalURL = \(originalURL.absoluteString)")
                    }
                } else {
                    // This is a direct request - convert scheme while preserving path
                    if let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) {
                        let originalScheme = url.scheme ?? "http"
                        var newComponents = components
                        newComponents.scheme = originalScheme
                        originalURL = newComponents.url ?? requestURL
                    } else {
                        originalURL = requestURL.withScheme(url.scheme ?? "http") ?? requestURL
                    }
                    print("DEBUG: [CachingPlayerItem] handleHLSRequest: converted to originalURL = \(originalURL.absoluteString)")
                }
            }
        }
        
               // Check if this is a request for the main playlist or a segment
               if originalURL.absoluteString.contains(".m3u8") || requestURL.absoluteString.contains(".m3u8") {
                   print("DEBUG: [CachingPlayerItem] handleHLSRequest: Handling as playlist request")
                   return handlePlaylistRequest(loadingRequest, resolvedURL: originalURL)
               } else if originalURL.absoluteString.contains(".ts") || originalURL.absoluteString.contains(".m4s") ||
                         requestURL.absoluteString.contains(".ts") || requestURL.absoluteString.contains(".m4s") {
                   print("DEBUG: [CachingPlayerItem] handleHLSRequest: Handling as segment request")
                   return handleSegmentRequest(loadingRequest, resolvedURL: originalURL)
               }
        
        print("DEBUG: [CachingPlayerItem] handleHLSRequest: No matching request type found - falling back to original URL")
        
        // Fallback: if we can't handle this request, let the original URL be used
        // This ensures the video still plays even if caching fails
        if let dataRequest = loadingRequest.dataRequest {
            // Create a new request to the original URL
            let originalRequest = URLRequest(url: originalURL)
            let task = URLSession.shared.dataTask(with: originalRequest) { data, response, error in
                if let error = error {
                    print("DEBUG: [CachingPlayerItem] handleHLSRequest: Fallback request failed: \(error.localizedDescription)")
                    loadingRequest.finishLoading(with: error)
                    return
                }
                
                guard let data = data, let response = response else {
                    print("DEBUG: [CachingPlayerItem] handleHLSRequest: Fallback request returned no data")
                    let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                    loadingRequest.finishLoading(with: error)
                    return
                }
                
                print("DEBUG: [CachingPlayerItem] handleHLSRequest: Fallback request successful, serving original URL data")
                
                // Set the response
                loadingRequest.response = response
                
                // Set content information if available
                if let contentInfoRequest = loadingRequest.contentInformationRequest {
                    if let httpResponse = response as? HTTPURLResponse {
                        contentInfoRequest.contentType = httpResponse.mimeType
                        contentInfoRequest.contentLength = httpResponse.expectedContentLength
                        contentInfoRequest.isByteRangeAccessSupported = httpResponse.allHeaderFields["Accept-Ranges"] as? String == "bytes"
                    }
                }
                
                // Serve the data
                dataRequest.respond(with: data)
                loadingRequest.finishLoading()
            }
            task.resume()
            return true
        }
        
        return false
    }
    
    private func handlePlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest, resolvedURL: URL) -> Bool {
        guard let mediaID = mediaID else { 
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No mediaID - falling back to original URL")
            return fallbackToOriginalURL(loadingRequest, originalURL: resolvedURL)
        }
        
        guard loadingRequest.request.url != nil else {
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No request URL")
            return false
        }
        
        print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: mediaID = \(mediaID)")
        
        // Use the resolved HLS URL instead of converting from requestURL
        // The resolvedURL contains the properly resolved master.m3u8 or playlist.m3u8 URL
        let actualPlaylistURL = resolvedURL
        
        print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Actual playlist URL = \(actualPlaylistURL.absoluteString)")
        
        // Check if we have a cached playlist for this specific URL
        // Use host-agnostic cache key based on the path only
        let cacheKey = actualPlaylistURL.absoluteString
        let cachePath = getCachePath(for: cacheKey)
        
        if FileManager.default.fileExists(atPath: cachePath),
           let playlistData = FileManager.default.contents(atPath: cachePath) {
            
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Serving cached playlist from \(cachePath)")
            print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Playlist data size: \(playlistData.count) bytes")
            
            // Modify the playlist to point to local server URLs
            let modifiedPlaylistData = modifyPlaylistForLocalServer(playlistData, mediaID: mediaID)
            
            // Log first 200 characters of modified playlist content for debugging
            if let playlistString = String(data: modifiedPlaylistData, encoding: .utf8) {
                let preview = String(playlistString.prefix(200))
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Modified playlist preview: \(preview)")
            }
            
            // Create proper HTTP response FIRST - this is critical for AVPlayer
            if let requestURL = loadingRequest.request.url,
               let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                   "Content-Type": "application/vnd.apple.mpegurl",
                   "Content-Length": "\(modifiedPlaylistData.count)",
                   "Cache-Control": "no-cache, no-store, must-revalidate",
                   "Pragma": "no-cache",
                   "Expires": "0",
                   "Accept-Ranges": "none",
                   "Connection": "keep-alive"
               ]) {
                loadingRequest.response = response
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Set HTTP response headers for cached playlist")
            }
            
            // Set proper Content-Type header for M3U8 files
            if let contentInformationRequest = loadingRequest.contentInformationRequest {
                contentInformationRequest.contentType = "application/vnd.apple.mpegurl"
                contentInformationRequest.contentLength = Int64(modifiedPlaylistData.count)
                contentInformationRequest.isByteRangeAccessSupported = false
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Set Content-Type to application/vnd.apple.mpegurl, contentLength: \(modifiedPlaylistData.count)")
            } else {
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No contentInformationRequest available - using HTTP headers only")
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Request URL: \(loadingRequest.request.url?.absoluteString ?? "nil")")
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Request method: \(loadingRequest.request.httpMethod ?? "nil")")
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Request headers: \(loadingRequest.request.allHTTPHeaderFields ?? [:])")
                
                // When contentInformationRequest is nil, we rely entirely on HTTP response headers
                // The HTTP response headers we set above should be sufficient for AVPlayer
                print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Relying on HTTP response headers for content information")
            }
            
            // Handle byte range requests if present
            if let dataRequest = loadingRequest.dataRequest {
                let requestedOffset = dataRequest.requestedOffset
                let requestedLength = dataRequest.requestedLength
                
                if requestedOffset > 0 || requestedLength < modifiedPlaylistData.count {
                    // Byte range request
                    let startIndex = Int(requestedOffset)
                    let endIndex = min(startIndex + Int(requestedLength), modifiedPlaylistData.count)
                    let rangeData = modifiedPlaylistData.subdata(in: startIndex..<endIndex)
                    
                    print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: Serving byte range \(startIndex)-\(endIndex-1) of \(modifiedPlaylistData.count)")
                    dataRequest.respond(with: rangeData)
                } else {
                    // Full content request
                    dataRequest.respond(with: modifiedPlaylistData)
                }
            }
            
            loadingRequest.finishLoading()
            return true
        }
        
        print("DEBUG: [CachingPlayerItem] handlePlaylistRequest: No cached playlist, downloading from \(actualPlaylistURL.absoluteString)")
        // Download and cache playlist using the actual URL
        startHLSPlaylistDownload(loadingRequest, playlistURL: actualPlaylistURL, cachePath: cachePath)
        return true
    }
    
    private func getCachePath(for cacheKey: String) -> String {
        // Create a cache path based on the URL, but make it host-agnostic
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        
        guard let url = URL(string: cacheKey) else {
            // Fallback if URL parsing fails
            let sanitizedKey = cacheKey.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "?", with: "_")
                .replacingOccurrences(of: "=", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            // Only add .m3u8 extension if the key doesn't already have it
            let finalKey = sanitizedKey.hasSuffix(".m3u8") ? sanitizedKey : "\(sanitizedKey).m3u8"
            return cacheDir.appendingPathComponent(finalKey).path
        }
        
        // Extract the path part only (ignore host/domain/port)
        // This makes the cache host-agnostic - same video from different hosts will use same cache
        let pathOnly = url.path
        
        // Use only the path as the cache key, making it host-agnostic
        let sanitizedKey = pathOnly.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        
        print("DEBUG: [CachingPlayerItem] Cache path (host-agnostic): \(sanitizedKey)")
        
        // Only add .m3u8 extension if the key doesn't already have it
        let finalKey = sanitizedKey.hasSuffix(".m3u8") ? sanitizedKey : "\(sanitizedKey).m3u8"
        return cacheDir.appendingPathComponent(finalKey).path
    }
    
    private func resolveHLSURLSync(_ url: URL) -> URL {
        let urlString = url.absoluteString
        
        // If already an m3u8 file, return as-is
        if urlString.hasSuffix(".m3u8") {
            return url
        }
        
        // If it's a progressive video (mp4), return as-is - no HLS resolution needed
        if urlString.hasSuffix(".mp4") {
            return url
        }
        
        // HLS fallback strategy: master.m3u8 -> playlist.m3u8
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        print("DEBUG: [CachingPlayerItem] Resolving HLS URL: \(url.absoluteString)")
        
        // Try master.m3u8 first, then playlist.m3u8
        if urlExistsSync(masterURL, timeout: 2.0) {
            print("DEBUG: [CachingPlayerItem] Found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        if urlExistsSync(playlistURL, timeout: 2.0) {
            print("DEBUG: [CachingPlayerItem] Found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // If both attempts fail, return original URL and let it fail
        print("DEBUG: [CachingPlayerItem] HLS resolution failed for: \(url.absoluteString)")
        return url
    }
    
    private func resolveHLSURL(_ url: URL) async -> URL {
        let urlString = url.absoluteString
        
        // If already an m3u8 file, return as-is
        if urlString.hasSuffix(".m3u8") {
            return url
        }
        
        // If it's a progressive video (mp4), return as-is - no HLS resolution needed
        if urlString.hasSuffix(".mp4") {
            return url
        }
        
        // HLS fallback strategy: master.m3u8 -> playlist.m3u8 -> retry once -> fail
        let masterURL = url.appendingPathComponent("master.m3u8")
        let playlistURL = url.appendingPathComponent("playlist.m3u8")
        
        print("DEBUG: [CachingPlayerItem] Resolving HLS URL: \(url.absoluteString)")
        
        // First attempt: try master.m3u8, then playlist.m3u8
        if await urlExists(masterURL, timeout: 3.0) {
            print("DEBUG: [CachingPlayerItem] Found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        if await urlExists(playlistURL, timeout: 3.0) {
            print("DEBUG: [CachingPlayerItem] Found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // Second attempt: retry the combo once more
        print("DEBUG: [CachingPlayerItem] First attempt failed, retrying HLS URLs...")
        
        if await urlExists(masterURL, timeout: 3.0) {
            print("DEBUG: [CachingPlayerItem] Retry successful - found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        if await urlExists(playlistURL, timeout: 3.0) {
            print("DEBUG: [CachingPlayerItem] Retry successful - found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // If both attempts fail, return original URL and let it fail
        print("DEBUG: [CachingPlayerItem] HLS resolution failed for: \(url.absoluteString)")
        return url
    }
    
    private func urlExistsSync(_ url: URL, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var exists = false
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse {
                exists = httpResponse.statusCode == 200
            }
            semaphore.signal()
        }
        task.resume()
        
        _ = semaphore.wait(timeout: .now() + timeout)
        return exists
    }
    
    private func urlExists(_ url: URL, timeout: TimeInterval) async -> Bool {
        return await withCheckedContinuation { continuation in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = timeout
            
            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                if let httpResponse = response as? HTTPURLResponse {
                    continuation.resume(returning: httpResponse.statusCode == 200)
                } else {
                    continuation.resume(returning: false)
                }
            }
            task.resume()
        }
    }
    
    private func handleSegmentRequest(_ loadingRequest: AVAssetResourceLoadingRequest, resolvedURL: URL) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let mediaID = mediaID else { 
            print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Missing requestURL or mediaID - falling back to original URL")
            return fallbackToOriginalURL(loadingRequest, originalURL: resolvedURL)
        }
        
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: requestURL = \(requestURL.absoluteString)")
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: mediaID = \(mediaID)")
        
        // Use the resolved URL from the parent method
        let originalURL = resolvedURL
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: resolvedURL = \(originalURL.absoluteString)")
        
        let segmentName = requestURL.lastPathComponent
        let segmentsPath = CachingPlayerItem.hlsSegmentsPath(for: mediaID)
        let segmentPath = URL(fileURLWithPath: segmentsPath).appendingPathComponent(segmentName).path
        
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: segmentName = \(segmentName)")
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: segmentPath = \(segmentPath)")
        
        // Check if segment is cached
        if let segmentData = FileManager.default.contents(atPath: segmentPath) {
            print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Serving cached segment, size: \(segmentData.count) bytes")
            
            // Create proper HTTP response FIRST - this is critical for AVPlayer
            if let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "video/mp2t",
                "Content-Length": "\(segmentData.count)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0",
                "Connection": "keep-alive"
            ]) {
                loadingRequest.response = response
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Set HTTP response headers for cached segment")
            }
            
            // Set proper Content-Type for video segments
            if let contentInformationRequest = loadingRequest.contentInformationRequest {
                contentInformationRequest.contentType = "video/mp2t" // MIME type for .ts files
                contentInformationRequest.contentLength = Int64(segmentData.count)
                contentInformationRequest.isByteRangeAccessSupported = true
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Set Content-Type to video/mp2t, contentLength: \(segmentData.count)")
            } else {
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: No contentInformationRequest available - using HTTP headers only")
                
                // When contentInformationRequest is nil, we rely entirely on HTTP response headers
                // The HTTP response headers we set above should be sufficient for AVPlayer
                print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Relying on HTTP response headers for content information")
            }
            
            // Handle byte range requests if present
            if let dataRequest = loadingRequest.dataRequest {
                let requestedOffset = dataRequest.requestedOffset
                let requestedLength = dataRequest.requestedLength
                
                if requestedOffset > 0 || requestedLength < segmentData.count {
                    // Byte range request
                    let startIndex = Int(requestedOffset)
                    let endIndex = min(startIndex + Int(requestedLength), segmentData.count)
                    let rangeData = segmentData.subdata(in: startIndex..<endIndex)
                    
                    print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Serving byte range \(startIndex)-\(endIndex-1) of \(segmentData.count)")
                    dataRequest.respond(with: rangeData)
                } else {
                    // Full content request
                    dataRequest.respond(with: segmentData)
                }
            }
            loadingRequest.finishLoading()
            return true
        }
        
        print("DEBUG: [CachingPlayerItem] handleSegmentRequest: Segment not cached, downloading from \(originalURL.absoluteString)")
        // Download and cache segment
        downloadHLSSegment(from: originalURL, to: segmentPath, loadingRequest: loadingRequest)
        return true
    }
    
    private func startHLSPlaylistDownload(_ loadingRequest: AVAssetResourceLoadingRequest, playlistURL: URL, cachePath: String) {
        print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Starting download from \(playlistURL.absoluteString)")
        let session = URLSession.shared
        let task = session.dataTask(with: playlistURL) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data,
                  let playlistString = String(data: data, encoding: .utf8) else {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Failed to parse playlist data")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse playlist"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Successfully downloaded playlist, size: \(data.count) bytes")
            
            // Cache the playlist to the specific cache path
            do {
                try data.write(to: URL(fileURLWithPath: cachePath))
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Cached playlist to \(cachePath)")
            } catch {
                print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Failed to cache playlist: \(error.localizedDescription)")
            }
            
            // Parse segments and start downloading them (only for master playlists)
            let segments = self.parsePlaylistSegments(playlistString)
            if !segments.isEmpty {
                self.downloadHLSSegments(segments, originalPlaylist: playlistString)
            }
            
            // Modify the playlist to point to local server URLs
            let modifiedPlaylistData = self.modifyPlaylistForLocalServer(data, mediaID: self.mediaID ?? "")
            
            // Respond with modified playlist data immediately
            if let dataRequest = loadingRequest.dataRequest {
                dataRequest.respond(with: modifiedPlaylistData)
            }
            
                   // Set proper Content-Type header for M3U8 files
                   if let contentInformationRequest = loadingRequest.contentInformationRequest {
                       contentInformationRequest.contentType = "application/vnd.apple.mpegurl"
                       contentInformationRequest.contentLength = Int64(modifiedPlaylistData.count)
                       contentInformationRequest.isByteRangeAccessSupported = false
                       print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Set Content-Type to application/vnd.apple.mpegurl, contentLength: \(modifiedPlaylistData.count)")
                   } else {
                       print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: No contentInformationRequest available")
                   }
                   
                    // Create proper HTTP response for AVPlayer
                    if let response = HTTPURLResponse(url: playlistURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": "application/vnd.apple.mpegurl",
                        "Content-Length": "\(modifiedPlaylistData.count)",
                        "Cache-Control": "no-cache, no-store, must-revalidate",
                        "Pragma": "no-cache",
                        "Expires": "0",
                        "Accept-Ranges": "none",
                        "Connection": "keep-alive"
                    ]) {
                        loadingRequest.response = response
                        print("DEBUG: [CachingPlayerItem] startHLSPlaylistDownload: Set HTTP response headers for downloaded playlist")
                    }
            
            loadingRequest.finishLoading()
            
            // Notify owner about download completion
            DispatchQueue.main.async {
                self.owner?.delegate?.playerItem?(self.owner!, didFinishDownloadingFileAt: cachePath)
            }
        }
        
        task.resume()
    }
    
    private func downloadHLSSegment(from url: URL, to localPath: String, loadingRequest: AVAssetResourceLoadingRequest) {
        print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Starting download from \(url.absoluteString)")
        print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Saving to \(localPath)")
        
        let session = URLSession.shared
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data else {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Successfully downloaded segment, size: \(data.count) bytes")
            
            // Ensure directory exists
            let directory = URL(fileURLWithPath: localPath).deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Failed to create directory: \(error.localizedDescription)")
            }
            
            // Save segment to disk
            do {
                try data.write(to: URL(fileURLWithPath: localPath))
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Cached segment to \(localPath)")
                
                // Set proper Content-Type for video segments
                if let contentInformationRequest = loadingRequest.contentInformationRequest {
                    contentInformationRequest.contentType = "video/mp2t" // MIME type for .ts files
                    contentInformationRequest.contentLength = Int64(data.count)
                    contentInformationRequest.isByteRangeAccessSupported = true
                    print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Set Content-Type to video/mp2t, contentLength: \(data.count)")
                } else {
                    print("DEBUG: [CachingPlayerItem] downloadHLSSegment: No contentInformationRequest available for downloaded segment")
                }
                
                // Create proper HTTP response for AVPlayer
                if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": "video/mp2t",
                    "Content-Length": "\(data.count)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache, no-store, must-revalidate",
                    "Pragma": "no-cache",
                    "Expires": "0",
                    "Connection": "keep-alive"
                ]) {
                    loadingRequest.response = response
                    print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Set HTTP response headers for downloaded segment")
                }
                
                // Respond with segment data
                if let dataRequest = loadingRequest.dataRequest {
                    dataRequest.respond(with: data)
                }
                loadingRequest.finishLoading()
                
            } catch {
                print("DEBUG: [CachingPlayerItem] downloadHLSSegment: Failed to save segment: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
            }
        }
        
        task.resume()
    }
    
    private func parsePlaylistSegments(_ playlistContent: String) -> [String] {
        var segments: [String] = []
        let lines = playlistContent.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip comments and empty lines
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }
            
            // Check if it's a segment URL (not another playlist)
            if trimmedLine.hasSuffix(".ts") || trimmedLine.hasSuffix(".m4s") {
                segments.append(trimmedLine)
            }
        }
        
        return segments
    }
    
    private func downloadHLSSegments(_ segments: [String], originalPlaylist: String) {
        guard let mediaID = mediaID else { return }
        
        let segmentsPath = CachingPlayerItem.hlsSegmentsPath(for: mediaID)
        let downloadQueue = DispatchQueue(label: "hls.download", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: 3) // Limit concurrent downloads
        
        for (index, segmentURLString) in segments.enumerated() {
            downloadQueue.async {
                semaphore.wait()
                
                guard let segmentURL = URL(string: segmentURLString, relativeTo: self.url) else {
                    semaphore.signal()
                    return
                }
                
                let segmentName = "segment_\(index).ts"
                let segmentPath = URL(fileURLWithPath: segmentsPath).appendingPathComponent(segmentName).path
                
                // Skip if already cached
                if FileManager.default.fileExists(atPath: segmentPath) {
                    semaphore.signal()
                    return
                }
                
                // Download segment
                let session = URLSession.shared
                let task = session.dataTask(with: segmentURL) { data, response, error in
                    defer { semaphore.signal() }
                    
                    guard let data = data, error == nil else { return }
                    
                    try? data.write(to: URL(fileURLWithPath: segmentPath))
                }
                
                task.resume()
            }
        }
        
        // Create modified playlist with local segment paths
        var modifiedPlaylist = originalPlaylist
        let segmentsDir = URL(fileURLWithPath: segmentsPath)
        
        for (index, _) in segments.enumerated() {
            let segmentName = "segment_\(index).ts"
            let localSegmentPath = segmentsDir.appendingPathComponent(segmentName).path
            
            // Replace segment URL with local path
            if let range = modifiedPlaylist.range(of: segments[index]) {
                modifiedPlaylist.replaceSubrange(range, with: localSegmentPath)
            }
        }
        
        // Save modified playlist
        do {
            try modifiedPlaylist.write(toFile: saveFilePath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to save modified playlist: \(error)")
        }
    }
    
    private func modifyPlaylistForLocalServer(_ playlistData: Data, mediaID: String) -> Data {
        guard let playlistString = String(data: playlistData, encoding: .utf8) else {
            print("DEBUG: [CachingPlayerItem] modifyPlaylistForLocalServer: Failed to convert playlist data to string")
            return playlistData
        }
        
        var modifiedPlaylist = playlistString
        
        // Get the local HTTP server URL
        let localServerURL = "http://localhost:8080/media/\(mediaID)"
        
        // Replace relative segment URLs with local server URLs
        // Pattern: segment000.ts -> http://localhost:8080/media/{mediaID}/segment000.ts
        let segmentPattern = #"^([^#\n\r]+\.ts)$"#
        let regex = try! NSRegularExpression(pattern: segmentPattern, options: [.anchorsMatchLines])
        
        let matches = regex.matches(in: modifiedPlaylist, options: [], range: NSRange(location: 0, length: modifiedPlaylist.count))
        
        // Replace matches in reverse order to maintain string indices
        for match in matches.reversed() {
            if let range = Range(match.range, in: modifiedPlaylist) {
                let segmentName = String(modifiedPlaylist[range])
                let localSegmentURL = "\(localServerURL)/\(segmentName)"
                modifiedPlaylist.replaceSubrange(range, with: localSegmentURL)
                print("DEBUG: [CachingPlayerItem] modifyPlaylistForLocalServer: Replaced \(segmentName) with \(localSegmentURL)")
            }
        }
        
        // Replace relative playlist URLs with local server URLs
        // Pattern: 720p/playlist.m3u8 -> http://localhost:8080/media/{mediaID}/720p/playlist.m3u8
        let playlistPattern = #"^([^#\n\r]+\.m3u8)$"#
        let playlistRegex = try! NSRegularExpression(pattern: playlistPattern, options: [.anchorsMatchLines])
        
        let playlistMatches = playlistRegex.matches(in: modifiedPlaylist, options: [], range: NSRange(location: 0, length: modifiedPlaylist.count))
        
        // Replace matches in reverse order to maintain string indices
        for match in playlistMatches.reversed() {
            if let range = Range(match.range, in: modifiedPlaylist) {
                let playlistName = String(modifiedPlaylist[range])
                let localPlaylistURL = "\(localServerURL)/\(playlistName)"
                modifiedPlaylist.replaceSubrange(range, with: localPlaylistURL)
                print("DEBUG: [CachingPlayerItem] modifyPlaylistForLocalServer: Replaced \(playlistName) with \(localPlaylistURL)")
            }
        }
        
        guard let modifiedData = modifiedPlaylist.data(using: .utf8) else {
            print("DEBUG: [CachingPlayerItem] modifyPlaylistForLocalServer: Failed to convert modified playlist to data")
            return playlistData
        }
        
        print("DEBUG: [CachingPlayerItem] modifyPlaylistForLocalServer: Modified playlist for local server")
        return modifiedData
    }
    
    private func fallbackToOriginalURL(_ loadingRequest: AVAssetResourceLoadingRequest, originalURL: URL) -> Bool {
        print("DEBUG: [CachingPlayerItem] fallbackToOriginalURL: Falling back to original URL: \(originalURL.absoluteString)")
        
        guard let dataRequest = loadingRequest.dataRequest else {
            print("DEBUG: [CachingPlayerItem] fallbackToOriginalURL: No data request available")
            return false
        }
        
        // Create a new request to the original URL
        let originalRequest = URLRequest(url: originalURL)
        let task = URLSession.shared.dataTask(with: originalRequest) { data, response, error in
            if let error = error {
                print("DEBUG: [CachingPlayerItem] fallbackToOriginalURL: Request failed: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data = data, let response = response else {
                print("DEBUG: [CachingPlayerItem] fallbackToOriginalURL: No data received")
                let error = NSError(domain: "CachingPlayerItem", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                loadingRequest.finishLoading(with: error)
                return
            }
            
            print("DEBUG: [CachingPlayerItem] fallbackToOriginalURL: Successfully served original URL data")
            
            // Set the response
            loadingRequest.response = response
            
            // Set content information if available
            if let contentInfoRequest = loadingRequest.contentInformationRequest {
                if let httpResponse = response as? HTTPURLResponse {
                    contentInfoRequest.contentType = httpResponse.mimeType
                    contentInfoRequest.contentLength = httpResponse.expectedContentLength
                    contentInfoRequest.isByteRangeAccessSupported = httpResponse.allHeaderFields["Accept-Ranges"] as? String == "bytes"
                }
            }
            
            // Serve the data
            dataRequest.respond(with: data)
            loadingRequest.finishLoading()
        }
        task.resume()
        return true
    }
}
