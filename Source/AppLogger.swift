//
//  AppLogger.swift
//  CachingPlayerItem
//
//  Created by Gorjan Shukov on 07/17/25.
//

import Foundation

public enum LogLevel: Int, Comparable, CustomStringConvertible {
    case none = 0
    case info
    case warning
    case error

    public var description: String {
        switch self {
        case .info:
            return "ℹ️"
        case .warning:
            return "⚠️"
        case .error:
            return "🔴"
        case .none:
            return ""
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

final class AppLogger {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static var currentLevel: LogLevel { CachingPlayerItemConfiguration.logLevel }

    static func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, message(), file: file, function: function, line: line)
    }

    static func warning(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, message(), file: file, function: function, line: line)
    }

    static func error(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, message(), file: file, function: function, line: line)
    }

    private static func log(_ level: LogLevel, _ message: @autoclosure () -> String, file: String, function: String, line: Int) {
        guard level >= currentLevel, currentLevel != .none else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())

        print("[CachingPlayerItem \(level)] [\(timestamp)] [\(fileName):\(line)] \(function) > \(message())")
    }
}
