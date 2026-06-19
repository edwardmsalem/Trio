//
//  WatchStateSnapshot.swift
//  Trio
//
//  Created by Cengiz Deniz on 18.04.25.
//
import Foundation

enum WatchStateSnapshot {
    private static let storageKey = "WatchStateSnapshot.latest"

    static func saveLatestDateToDisk(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: storageKey)
    }

    static func loadLatestDateFromDisk() -> Date {
        // Check if key exists to avoid returning 1970 date for first-time users
        guard UserDefaults.standard.object(forKey: storageKey) != nil else {
            return Date.distantPast
        }
        let interval = UserDefaults.standard.double(forKey: storageKey)
        return Date(timeIntervalSince1970: interval)
    }
}
