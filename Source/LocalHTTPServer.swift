import Foundation
import Network

/// Local HTTP server to serve cached HLS content with proper HTTP responses
class LocalHTTPServer {
    static let shared = LocalHTTPServer()
    
    private let queue = DispatchQueue(label: "LocalHTTPServer", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16 = 8080
    private var isRunning = false
    
    // Cache of media IDs to their base paths for serving
    private var mediaPaths: [String: String] = [:]
    
    // Track which connection is associated with which mediaID
    private var connectionMediaMapping: [ObjectIdentifier: String] = [:]
    
    private init() {}
    
    /// Start the HTTP server
    func start() {
        guard !isRunning else { return }
        
        // Find an available port
        port = findAvailablePort()
        
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: queue)
            isRunning = true
            
            print("DEBUG: [LocalHTTPServer] Started HTTP server on port \(port)")
        } catch {
            print("DEBUG: [LocalHTTPServer] Failed to start server: \(error)")
        }
    }
    
    /// Stop the HTTP server
    func stop() {
        guard isRunning else { return }
        
        listener?.cancel()
        listener = nil
        isRunning = false
        mediaPaths.removeAll()
        connectionMediaMapping.removeAll()
        
        print("DEBUG: [LocalHTTPServer] Stopped HTTP server")
    }
    
    /// Register a media ID with its cache path
    func registerMedia(mediaID: String, cachePath: String) {
        mediaPaths[mediaID] = cachePath
        print("DEBUG: [LocalHTTPServer] Registered media \(mediaID) at path \(cachePath)")
    }
    
    /// Get the local URL for a media ID
    func getLocalURL(for mediaID: String) -> URL? {
        guard isRunning else { return nil }
        return URL(string: "http://localhost:\(port)/media/\(mediaID)")
    }
    
    /// Find an available port starting from 8080
    private func findAvailablePort() -> UInt16 {
        var port: UInt16 = 8080
        while port < 65535 {
            if isPortAvailable(port) {
                return port
            }
            port += 1
        }
        return 8080 // Fallback
    }
    
    /// Check if a port is available
    private func isPortAvailable(_ port: UInt16) -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY)
        
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        close(socket)
        return result == 0
    }
    
    /// Handle incoming HTTP connections
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleRequest(data, connection: connection)
            }
            
            if isComplete {
                // Clean up connection mapping when connection is complete
                self?.connectionMediaMapping.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
            }
        }
    }
    
    /// Handle HTTP requests
    private func handleRequest(_ data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Bad Request")
            return
        }
        
        print("DEBUG: [LocalHTTPServer] Received request: \(requestString.prefix(200))")
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Bad Request")
            return
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 3,
              components[0] == "GET",
              let path = components[1].removingPercentEncoding else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Bad Request")
            return
        }
        
        // Parse the media ID from the path
        if path.hasPrefix("/media/") {
            let remainingPath = String(path.dropFirst(7)) // Remove "/media/"
            
            // Check if this is a sub-playlist or TS segment request with mediaID in path
            if remainingPath.contains("/") && (remainingPath.hasSuffix("/playlist.m3u8") || remainingPath.hasSuffix(".ts")) {
                // Extract mediaID from path like "/media/VideoA/720p/playlist.m3u8"
                let pathComponents = remainingPath.components(separatedBy: "/")
                if pathComponents.count >= 3 {
                    let mediaID = pathComponents[0] // First component is the mediaID
                    let relativePath = pathComponents.dropFirst().joined(separator: "/") // Rest is the relative path
                    
                    // Track this connection as associated with this mediaID
                    connectionMediaMapping[ObjectIdentifier(connection)] = mediaID
                    
                    if remainingPath.hasSuffix("/playlist.m3u8") {
                        handleSubPlaylistRequestWithMediaID(path: path, mediaID: mediaID, relativePath: relativePath, connection: connection)
                    } else if remainingPath.hasSuffix(".ts") {
                        handleTSSegmentRequestWithMediaID(path: path, mediaID: mediaID, relativePath: relativePath, connection: connection)
                    }
                } else {
                    // Fallback to old logic for backwards compatibility
                    if remainingPath.hasSuffix("/playlist.m3u8") {
                        handleSubPlaylistRequest(path: path, connection: connection)
                    } else if remainingPath.hasSuffix(".ts") {
                        handleTSSegmentRequest(path: path, connection: connection)
                    }
                }
            } else {
                // This is a direct media request (e.g., "/media/QmX58Pz7mgZpok67RLgYqcCAoHi2hgLktFJqnJQ55aJ3zf")
                // Track this connection as associated with this mediaID
                connectionMediaMapping[ObjectIdentifier(connection)] = remainingPath
                serveMedia(mediaID: remainingPath, connection: connection, path: path)
            }
        } else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Not Found")
        }
    }
    
    /// Handle sub-playlist requests that include the mediaID in the path
    private func handleSubPlaylistRequestWithMediaID(path: String, mediaID: String, relativePath: String, connection: NWConnection) {
        print("DEBUG: [LocalHTTPServer] Handling sub-playlist request with mediaID: \(mediaID), relativePath: \(relativePath)")
        
        // Extract resolution from relativePath like "720p/playlist.m3u8"
        let pathComponents = relativePath.components(separatedBy: "/")
        if pathComponents.count >= 2 && pathComponents.last == "playlist.m3u8" {
            let resolution = pathComponents[0] // e.g., "720p"
            downloadSubPlaylistOnDemand(mediaID: mediaID, resolution: resolution, connection: connection)
        } else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Invalid sub-playlist request format")
        }
    }
    
    /// Handle TS segment requests that include the mediaID in the path
    private func handleTSSegmentRequestWithMediaID(path: String, mediaID: String, relativePath: String, connection: NWConnection) {
        print("DEBUG: [LocalHTTPServer] Handling TS segment request with mediaID: \(mediaID), relativePath: \(relativePath)")
        
        // Extract resolution and segment name from relativePath like "720p/segment.ts"
        let pathComponents = relativePath.components(separatedBy: "/")
        if pathComponents.count >= 2 && pathComponents.last?.hasSuffix(".ts") == true {
            let resolution = pathComponents[0] // e.g., "720p"
            let segmentName = pathComponents.last! // e.g., "segment.ts"
            downloadTSSegmentOnDemand(mediaID: mediaID, resolution: resolution, segmentName: segmentName, connection: connection)
        } else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Invalid TS segment request format")
        }
    }
    
    /// Handle sub-playlist requests that don't include the mediaID in the path (fallback)
    private func handleSubPlaylistRequest(path: String, connection: NWConnection) {
        let pathComponents = path.components(separatedBy: "/")
        guard pathComponents.count >= 4 && pathComponents[3] == "playlist.m3u8" else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Invalid sub-playlist request")
            return
        }
        
        let resolution = pathComponents[2] // e.g., "720p"
        print("DEBUG: [LocalHTTPServer] Handling sub-playlist request: \(resolution)/playlist.m3u8")
        
        // Use the mediaID associated with this connection
        if let mediaID = connectionMediaMapping[ObjectIdentifier(connection)] {
            print("DEBUG: [LocalHTTPServer] Using tracked mediaID: \(mediaID) for sub-playlist request")
            downloadSubPlaylistOnDemand(mediaID: mediaID, resolution: resolution, connection: connection)
        } else {
            print("DEBUG: [LocalHTTPServer] No mediaID tracked for connection, using fallback")
            // Fallback to most recent mediaID if no tracking available
            let mediaIDs = Array(mediaPaths.keys)
            if let mostRecentMediaID = mediaIDs.last {
                print("DEBUG: [LocalHTTPServer] Using fallback mediaID: \(mostRecentMediaID) for sub-playlist request")
                downloadSubPlaylistOnDemand(mediaID: mostRecentMediaID, resolution: resolution, connection: connection)
            } else {
                sendErrorResponse(connection: connection, statusCode: 404, message: "No media registered")
            }
        }
    }
    
    /// Handle TS segment requests that don't include the mediaID in the path
    private func handleTSSegmentRequest(path: String, connection: NWConnection) {
        let pathComponents = path.components(separatedBy: "/")
        guard pathComponents.count >= 4 && pathComponents.last?.hasSuffix(".ts") == true else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Invalid TS segment request")
            return
        }
        
        let resolution = pathComponents[2] // e.g., "720p"
        let segmentName = pathComponents.last! // e.g., "playlist_000.ts"
        print("DEBUG: [LocalHTTPServer] Handling TS segment request: \(resolution)/\(segmentName)")
        
        // Use the mediaID associated with this connection
        if let mediaID = connectionMediaMapping[ObjectIdentifier(connection)] {
            print("DEBUG: [LocalHTTPServer] Using tracked mediaID: \(mediaID) for TS segment request")
            downloadTSSegmentOnDemand(mediaID: mediaID, resolution: resolution, segmentName: segmentName, connection: connection)
        } else {
            print("DEBUG: [LocalHTTPServer] No mediaID tracked for connection, using fallback")
            // Fallback to most recent mediaID if no tracking available
            let mediaIDs = Array(mediaPaths.keys)
            if let mostRecentMediaID = mediaIDs.last {
                print("DEBUG: [LocalHTTPServer] Using fallback mediaID: \(mostRecentMediaID) for TS segment request")
                downloadTSSegmentOnDemand(mediaID: mostRecentMediaID, resolution: resolution, segmentName: segmentName, connection: connection)
            } else {
                sendErrorResponse(connection: connection, statusCode: 404, message: "No media registered")
            }
        }
    }
    
    /// Serve media content
    private func serveMedia(mediaID: String, connection: NWConnection, path: String) {
        guard let basePath = mediaPaths[mediaID] else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Media not found")
            return
        }
        
        print("DEBUG: [LocalHTTPServer] Serving media \(mediaID), path: \(path), basePath: \(basePath)")
        
        // Determine the file type and path based on the request
        let filePath: String
        let contentType: String
        
        if path.hasSuffix(".m3u8") {
            // HLS playlist request - check if it's a sub-playlist or master playlist
            if path.hasPrefix("/media/") && path.contains("/") && path.hasSuffix("/playlist.m3u8") {
                // This is a sub-playlist request (e.g., "/media/720p/playlist.m3u8")
                let pathComponents = path.components(separatedBy: "/")
                if pathComponents.count >= 4 && pathComponents[3] == "playlist.m3u8" {
                    let resolution = pathComponents[2] // e.g., "720p"
                    print("DEBUG: [LocalHTTPServer] Detected sub-playlist request: \(resolution)/playlist.m3u8 for mediaID: \(mediaID)")
                    downloadSubPlaylistOnDemand(mediaID: mediaID, resolution: resolution, connection: connection)
                    return
                }
            }
            
            // This is the master playlist request - use the base path directly
            filePath = basePath
            contentType = "application/vnd.apple.mpegurl"
        } else if path.hasSuffix(".ts") || path.hasSuffix(".m4s") {
            // HLS segment request
            let segmentName = String(path.split(separator: "/").last ?? "")
            let segmentsPath = CachingPlayerItem.hlsSegmentsPath(for: mediaID)
            filePath = "\(segmentsPath)/\(segmentName)"
            contentType = "video/mp2t"
        } else {
            // Default to master playlist
            filePath = basePath
            contentType = "application/vnd.apple.mpegurl"
        }
        
        print("DEBUG: [LocalHTTPServer] Final filePath: \(filePath), contentType: \(contentType)")
        serveFile(filePath: filePath, contentType: contentType, connection: connection)
    }
    
    /// Serve a file with proper HTTP headers
    private func serveFile(filePath: String, contentType: String, connection: NWConnection) {
        let fileURL = URL(fileURLWithPath: filePath)
        
        // Check if file exists
        if FileManager.default.fileExists(atPath: filePath) {
            do {
                let data = try Data(contentsOf: fileURL)
                
                // Debug: Log master playlist content for troubleshooting
                if filePath.hasSuffix(".m3u8") && !filePath.contains("/") {
                    if let content = String(data: data, encoding: .utf8) {
                        print("DEBUG: [LocalHTTPServer] Master playlist content:\n\(content)")
                    }
                }
                
                // Create HTTP response headers
                let contentLength = data.count
                let headers = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: \(contentType)",
                    "Content-Length: \(contentLength)",
                    "Cache-Control: no-cache, no-store, must-revalidate",
                    "Pragma: no-cache",
                    "Expires: 0",
                    "Accept-Ranges: bytes",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                
                let responseData = headers.data(using: .utf8)! + data
                
                connection.send(content: responseData, completion: .contentProcessed { error in
                    if let error = error {
                        print("DEBUG: [LocalHTTPServer] Send error: \(error)")
                    } else {
                        print("DEBUG: [LocalHTTPServer] Served cached file: \(filePath) (\(contentLength) bytes)")
                    }
                    connection.cancel()
                })
                
            } catch {
                print("DEBUG: [LocalHTTPServer] Failed to read file \(filePath): \(error)")
                sendErrorResponse(connection: connection, statusCode: 404, message: "File not found")
            }
        } else {
            print("DEBUG: [LocalHTTPServer] File does not exist, triggering on-demand download: \(filePath)")
            // File doesn't exist yet, trigger on-demand download
            downloadFileOnDemand(filePath: filePath, contentType: contentType, connection: connection)
        }
    }
    
    /// Download sub-playlist on-demand when HTTP server receives request
    private func downloadSubPlaylistOnDemand(mediaID: String, resolution: String, connection: NWConnection) {
        print("DEBUG: [LocalHTTPServer] Starting on-demand download for sub-playlist: \(resolution)/playlist.m3u8, mediaID: \(mediaID)")
        
        // Construct original URL - we'll need to store this mapping properly in the future
        let originalURL = "http://125.229.161.122:8080/ipfs/\(mediaID)/\(resolution)/playlist.m3u8"
        
        // Download the file asynchronously
        Task {
            do {
                let data = try await downloadData(from: URL(string: originalURL)!)
                
                // Create the file path for the sub-playlist
                let segmentsPath = CachingPlayerItem.hlsSegmentsPath(for: mediaID)
                let subPlaylistPath = "\(segmentsPath)/\(resolution)/playlist.m3u8"
                
                // Ensure directory exists
                let fileURL = URL(fileURLWithPath: subPlaylistPath)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                // Save the file
                try data.write(to: fileURL)
                print("DEBUG: [LocalHTTPServer] Downloaded and saved sub-playlist: \(subPlaylistPath)")
                
                // Now serve the file
                DispatchQueue.main.async { [weak self] in
                    self?.serveCachedFile(filePath: subPlaylistPath, contentType: "application/vnd.apple.mpegurl", connection: connection)
                }
                
            } catch {
                print("DEBUG: [LocalHTTPServer] Failed to download sub-playlist on-demand: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.sendErrorResponse(connection: connection, statusCode: 500, message: "Sub-playlist download failed")
                }
            }
        }
    }
    
    /// Download TS segment on-demand when HTTP server receives request
    private func downloadTSSegmentOnDemand(mediaID: String, resolution: String, segmentName: String, connection: NWConnection) {
        print("DEBUG: [LocalHTTPServer] Starting on-demand TS segment download for mediaID: \(mediaID), resolution: \(resolution), segment: \(segmentName)")
        
        Task {
            do {
                // Construct the original URL for the TS segment
                let originalURL = "http://125.229.161.122:8080/ipfs/\(mediaID)"
                
                // For TS segments, we need to use the base URL directly, not the resolved HLS URL
                // The resolved HLS URL points to master.m3u8, but TS segments are at /resolution/segment.ts
                let baseURL = URL(string: originalURL)!
                let tsSegmentURL = baseURL.appendingPathComponent(resolution).appendingPathComponent(segmentName)
                
                print("DEBUG: [LocalHTTPServer] Downloading TS segment from: \(tsSegmentURL)")
                
                // Download the TS segment
                let data = try await downloadData(from: tsSegmentURL)
                
                // Save the file
                let segmentsPath = CachingPlayerItem.hlsSegmentsPath(for: mediaID)
                let segmentPath = "\(segmentsPath)/\(resolution)/\(segmentName)"
                let fileURL = URL(fileURLWithPath: segmentPath)
                
                // Ensure directory exists
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                
                // Save the file
                try data.write(to: fileURL)
                print("DEBUG: [LocalHTTPServer] Downloaded and saved TS segment: \(segmentPath)")
                
                // Now serve the file
                DispatchQueue.main.async { [weak self] in
                    self?.serveCachedFile(filePath: segmentPath, contentType: "video/mp2t", connection: connection)
                }
                
            } catch {
                print("DEBUG: [LocalHTTPServer] Failed to download TS segment on-demand: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.sendErrorResponse(connection: connection, statusCode: 500, message: "TS segment download failed")
                }
            }
        }
    }
    
    /// Download file on-demand when HTTP server receives request
    private func downloadFileOnDemand(filePath: String, contentType: String, connection: NWConnection) {
        // Extract media ID from file path - look for the pattern in our mediaPaths
        var mediaID: String = ""
        var originalURL: String = ""
        
        // Find the media ID by matching the file path with our registered media paths
        for (id, basePath) in mediaPaths {
            if filePath.hasPrefix(basePath) {
                mediaID = id
                // Construct original URL - we'll need to store this mapping properly in the future
                originalURL = "http://125.229.161.122:8080/ipfs/\(mediaID)"
                break
            }
        }
        
        guard !mediaID.isEmpty && !originalURL.isEmpty else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Cannot determine media ID")
            return
        }
        
        print("DEBUG: [LocalHTTPServer] Starting on-demand download for mediaID: \(mediaID), originalURL: \(originalURL)")
        
        // Download the file asynchronously
        Task {
            do {
                let resolvedURL = await resolveHLSURL(URL(string: originalURL)!)
                let data = try await downloadData(from: resolvedURL)
                
                // Ensure directory exists
                let fileURL = URL(fileURLWithPath: filePath)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                // Save the file
                try data.write(to: fileURL)
                print("DEBUG: [LocalHTTPServer] Downloaded and saved file: \(filePath)")
                
                // Now serve the file
                DispatchQueue.main.async { [weak self] in
                    self?.serveCachedFile(filePath: filePath, contentType: contentType, connection: connection)
                }
                
            } catch {
                print("DEBUG: [LocalHTTPServer] Failed to download file on-demand: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.sendErrorResponse(connection: connection, statusCode: 500, message: "Download failed")
                }
            }
        }
    }
    
    /// Serve a cached file (helper method)
    private func serveCachedFile(filePath: String, contentType: String, connection: NWConnection) {
        let fileURL = URL(fileURLWithPath: filePath)
        
        do {
            let data = try Data(contentsOf: fileURL)
            
            // Debug: Print content of master playlists
            if contentType == "application/vnd.apple.mpegurl" && filePath.hasSuffix(".m3u8") {
                if let content = String(data: data, encoding: .utf8) {
                    print("DEBUG: [LocalHTTPServer] Master playlist content:\n\(content)")
                } else {
                    print("DEBUG: [LocalHTTPServer] Failed to decode master playlist as UTF-8")
                }
            }
            
            // Create HTTP response headers
            let contentLength = data.count
            let headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: \(contentType)",
                "Content-Length: \(contentLength)",
                "Cache-Control: no-cache, no-store, must-revalidate",
                "Pragma: no-cache",
                "Expires: 0",
                "Accept-Ranges: bytes",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")
            
            let responseData = headers.data(using: .utf8)! + data
            
            connection.send(content: responseData, completion: .contentProcessed { error in
                if let error = error {
                    print("DEBUG: [LocalHTTPServer] Send error: \(error)")
                } else {
                    print("DEBUG: [LocalHTTPServer] Served downloaded file: \(filePath) (\(contentLength) bytes)")
                }
                connection.cancel()
            })
            
        } catch {
            print("DEBUG: [LocalHTTPServer] Failed to read downloaded file \(filePath): \(error)")
            sendErrorResponse(connection: connection, statusCode: 404, message: "File not found")
        }
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
    
    /// Resolve HLS URL (master.m3u8 -> playlist.m3u8 -> fail)
    private func resolveHLSURL(_ baseURL: URL) async -> URL {
        // Try master.m3u8 first
        let masterURL = baseURL.appendingPathComponent("master.m3u8")
        if await urlExists(masterURL) {
            print("DEBUG: [LocalHTTPServer] Found master.m3u8 at: \(masterURL.absoluteString)")
            return masterURL
        }
        
        // Try playlist.m3u8
        let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
        if await urlExists(playlistURL) {
            print("DEBUG: [LocalHTTPServer] Found playlist.m3u8 at: \(playlistURL.absoluteString)")
            return playlistURL
        }
        
        // If neither exists, return the original URL (will fail gracefully)
        print("DEBUG: [LocalHTTPServer] No HLS playlist found, using original URL")
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
    
    /// Send HTTP error response
    private func sendErrorResponse(connection: NWConnection, statusCode: Int, message: String) {
        let response = [
            "HTTP/1.1 \(statusCode) \(message)",
            "Content-Type: text/plain",
            "Content-Length: \(message.count)",
            "Connection: close",
            "",
            message
        ].joined(separator: "\r\n")
        
        let responseData = response.data(using: .utf8)!
        
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("DEBUG: [LocalHTTPServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }
}
