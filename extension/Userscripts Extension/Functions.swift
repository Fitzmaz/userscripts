import Foundation
import SafariServices

func getLogs() -> [String] {
    let logs = [] + LogMessages.logs
    LogMessages.logs.removeAll()
    return logs
}

// helpers
func getRequireLocation() -> URL {
    // simple helper in case required code save directory needs to change
    return getDocumentsDirectory().appendingPathComponent("require")
}

func dateToMilliseconds(_ date: Date) -> Int {
    let since1970 = date.timeIntervalSince1970
    return Int(since1970 * 1000)
}

func sanitize(_ str: String) -> String? {
    // removes dubious characters from strings (filenames)
    var sanitized = str
    if sanitized.first == "." {
        sanitized = "%2" + str.dropFirst()
    }
    let allowedCharacterSet = (CharacterSet(charactersIn: "/:\\").inverted)
    return sanitized.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet)
}

func unsanitize(_ str: String) -> String {
    var s = str
    if s.hasPrefix("%2") && !s.hasPrefix("%2F") {
        s = "." + s.dropFirst(2)
    }
    if s.removingPercentEncoding != s {
        s = s.removingPercentEncoding ?? s
    }
    return s
}

func normalizeWeight(_ weight: String) -> String {
    if let w = Int(weight) {
        if w > 999 {
            return "999"
        } else if w < 1 {
            return "1"
        } else {
            return weight
        }
    } else {
        return "1"
    }
}

func getSaveLocation() -> URL? {
    #if os(iOS)
        if
            let sharedBookmarkData = UserDefaults(suiteName: SharedDefaults.suiteName)?.data(forKey: SharedDefaults.keyName),
            let bookmarkUrl = readBookmark(data: sharedBookmarkData, isSecure: true)
        {
            return bookmarkUrl
        } else {
            return nil
        }
    #elseif os(macOS)
        let standardDefaults = UserDefaults.standard
        let userSaveLocationKey = "userSaveLocation"
        var defaultSaveLocation:URL

        // get the default save location, if key doesn't exist write it to user defaults
        if let saveLocationValue = standardDefaults.url(forKey: "saveLocation") {
            defaultSaveLocation = saveLocationValue
        } else {
            logText("default save location not set, writing to user defaults")
            let url = getDocumentsDirectory().appendingPathComponent("scripts")
            UserDefaults.standard.set(url, forKey: "saveLocation")
            defaultSaveLocation = url
        }

        // check if shared bookmark data exists
        // check if can get shared bookmark url
        // won't be able to if directory trashed
        guard
            let sharedBookmarkData = UserDefaults(suiteName: SharedDefaults.suiteName)?.data(forKey: SharedDefaults.keyName),
            let sharedBookmark = readBookmark(data: sharedBookmarkData, isSecure: false),
            directoryExists(path: sharedBookmark.path)
        else {
            // can't get shared bookmark, use default location and remove shared bookmark key from shared user defaults
            UserDefaults(suiteName: SharedDefaults.suiteName)?.removeObject(forKey: SharedDefaults.keyName)
            logText("removed sharedbookmark because it was either permanently deleted or in trash")
            return defaultSaveLocation
        }

        // at this point, it's known sharedbookmark exists
        // check local bookmark exists, can read url from bookmark and if bookmark url == shared bookmark url
        // if local bookmark exists, no need to check if directory exists for it
        // can't think of an instance where shared bookmark directory exists (checked above), yet local bookmark directory does not
        if
            let userSaveLocationData = standardDefaults.data(forKey: userSaveLocationKey),
            let userSaveLocation = readBookmark(data: userSaveLocationData, isSecure: true),
            sharedBookmark == userSaveLocation
        {
            return userSaveLocation
        }

        // at this point one of the following conditions met
        // - local bookmark data doesn't exist
        // - for some reason can't get url from local bookmark data
        // - local bookmark url != shared bookmark url (user updated save location)
        // when any of those conditions are met, create new local bookmark from shared bookmark
        if saveBookmark(url: sharedBookmark, isShared: false, keyName: userSaveLocationKey, isSecure: true) {
            // read the newly saved bookmark and return it
            guard
                let localBookmarkData = standardDefaults.data(forKey: userSaveLocationKey),
                let localBookmarkUrl = readBookmark(data: localBookmarkData, isSecure: true)
            else {
                err("reading local bookmark in getSaveLocation failed")
                return nil
            }
            return localBookmarkUrl
        } else {
            err("could not save local version of shared bookmark")
            return nil
        }
    #endif
}

func openSaveLocation() -> Bool {
    #if os(macOS)
        guard let saveLocation = getSaveLocation() else {
            return false
        }
        let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: saveLocation.path)
    #endif
    return true
}

func validateUrl(_ urlString: String) -> Bool {
    if
        (!urlString.hasPrefix("https://") && !urlString.hasPrefix("http://"))
        || (!urlString.hasSuffix(".css") && !urlString.hasSuffix(".js"))
    {
        return false
    }
    return true
}

func isVersionNewer(_ oldVersion: String, _ newVersion: String) -> Bool {
    let oldVersions = oldVersion.components(separatedBy: ".")
    let newVersions = newVersion.components(separatedBy: ".")
    for (index, version) in newVersions.enumerated() {
        let a = Int(version) ?? 0
        let oldVersionValue  = oldVersions.indices.contains(index) ? oldVersions[index] : "0"
        let b = Int(oldVersionValue) ?? 0
        if a > b {
            return true
        }
        if a < b {
            return false
        }
    }
    return false
}

// parser
func parse(_ content: String) -> [String: Any]? {
    // returns structured data from content of file
    // will fail to parse if metablock or required @name key missing
    let pattern = #"(?:(\/\/ ==UserScript==\r?\n([\S\s]*?)\r?\n\/\/ ==\/UserScript==)([\S\s]*)|(\/\* ==UserStyle==\r?\n([\S\s]*?)\r?\n==\/UserStyle== \*\/)([\S\s]*))"#
    // force try b/c pattern is known to be valid regex
    let regex = try! NSRegularExpression(pattern: pattern, options: [])
    let range = NSRange(location: 0, length: content.utf16.count)
    // return nil/fail if metablock missing
    guard let match = regex.firstMatch(in: content, options: [], range: range) else {
        return nil
    }

    // at this point the text content has passed initial validation, it contains valid metadata
    // the metadata can be in userscript or userstyle format, need to check for this and adjust group numbers
    // rather than being too strict, text content can precede the opening userscript tag, however it will be ignored
    // adjust start index of file content while assigning group numbers to account for any text content preceding opening tag
    let contentStartIndex = content.index(content.startIndex, offsetBy: match.range.lowerBound)
    var g1, g2, g3:Int
    if (content[contentStartIndex..<content.endIndex].starts(with: "//")) {
        g1 = 1; g2 = 2; g3 = 3
    } else {
        g1 = 4; g2 = 5; g3 = 6
    }

    // can force unwrap metablock since nil check was done above
    let metablock = content[Range(match.range(at: g1), in: content)!]
    // create var to store separated metadata keys/values
    var metadata = [:] as [String: [String]]
    // iterate through the possible metadata keys in file
    if let metas = Range(match.range(at: g2), in: content) {
        // split metadatas by new line
        let metaArray = content[metas].split(whereSeparator: \.isNewline)
        // loop through metadata lines and populate metadata dictionary
        for meta in metaArray {
            let p = #"^(?:[ \t]*(?:\/\/)?[ \t]*@)([\w-]+)[ \t]+([^\s]+[^\r\n\t\v\f]*)"#
            // this pattern checks for specific keys that won't have values
            let p2 = #"^(?:[ \t]*(?:\/\/)?[ \t]*@)(noframes)[ \t]*$"#
            // the individual meta string, ie. // @name File Name
            let metaString = String(meta)
            // force try b/c pattern is known to be valid regex
            let re = try! NSRegularExpression(pattern: p, options: [])
            let re2 = try! NSRegularExpression(pattern: p2, options: [])
            let range = NSRange(location: 0, length: metaString.utf16.count)
            // key lines not properly prefixed & without values will be skipped
            if let m = re.firstMatch(in: metaString, options: [], range: range) {
                // force unwrap key & value since matches regex above
                let key = metaString[Range(m.range(at: 1), in: metaString)!]
                let value = metaString[Range(m.range(at: 2), in: metaString)!]
                if metadata[String(key)] == nil {
                    // if key does not exist in metadata dict, add it
                    metadata[String(key)] = []
                }
                metadata[String(key)]?.append(String(value))
            } else if let m2 = re2.firstMatch(in: metaString, options: [], range: range) {
                // force unwrap key since matches regex above
                let key = metaString[Range(m2.range(at: 1), in: metaString)!]
                metadata[String(key)] = []
            }
        }
    }
    // return nil/fail if @name key is missing or @name has no value
    if metadata["name"] == nil {
        return nil
    }
    // get the code
    let code = content[Range(match.range(at: g3), in: content)!]
    let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
        "code": trimmedCode,
        "content": content,
        "metablock": metablock,
        "metadata": metadata
    ]
}

// manifest
struct Manifest: Codable {
    var blacklist:[String]
    var disabled:[String]
    var exclude: [String: [String]]
    var excludeMatch: [String: [String]]
    var include: [String: [String]]
    var match: [String: [String]]
    var require: [String: [String]]
    var settings: [String: String]
    private enum CodingKeys : String, CodingKey {
        case blacklist, disabled, exclude, excludeMatch = "exclude-match", include, match, require, settings
    }
}

let defaultSettings = [
    "active": "true",
    "autoCloseBrackets": "true",
    "autoHint": "true",
    "descriptions": "true",
    "languageCode": Locale.current.languageCode ?? "en",
    "lint": "false",
    "log": "false",
    "sortOrder": "lastModifiedDesc",
    "showCount": "true",
    "showInvisibles": "true",
    "tabSize": "4"
]

func updateManifest(with data: Manifest) -> Bool {
    let content = data
    let url = getDocumentsDirectory().appendingPathComponent("manifest.json")
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let encoded = try encoder.encode(content)
        let fileContent = String(decoding: encoded, as: UTF8.self)
        try fileContent.write(to: url, atomically: false, encoding: .utf8)
        return true
    } catch {
        err("Failed to update manifest: \(error.localizedDescription)")
        return false
    }
}

func getManifest() -> Manifest {
    let url = getDocumentsDirectory().appendingPathComponent("manifest.json")
    if
        let content = try? String(contentsOf: url, encoding: .utf8),
        let data = content.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(Manifest.self, from: Data(data))
    {
        return decoded
    } else {
        // manifest missing, improperly formatted or missing key
        // create new manifest with default key/vals
        let manifest = Manifest(
            blacklist: [],
            disabled: [],
            exclude: [:],
            excludeMatch: [:],
            include: [:],
            match: [:],
            require: [:],
            settings: defaultSettings
        )
        _ = updateManifest(with: manifest)
        return manifest
    }
}

func updateManifestMatches(_ optionalFilesArray: [[String: Any]] = []) -> Bool {
    logText("updateManifestMatches started")
    // only get all files if files were not provided
    var files = [[String: Any]]()
    if optionalFilesArray.count < 1 {
        guard let getFiles = getAllFiles() else {return false}
        files = getFiles
    } else {
        files = optionalFilesArray
    }
    var manifest = getManifest()
    for file in files {
        // can be force unwrapped because getAllFiles didn't return nil
        let metadata = file["metadata"] as! [String: [String]]
        let filename = file["filename"] as! String
        // populate excludes & matches
        var excludeMatched = [String]()
        var matched = [String]()
        var excluded = [String]()
        var included = [String]()
        if metadata["exclude-match"] != nil {
            excludeMatched.append(contentsOf: metadata["exclude-match"]!)
        }
        if metadata["match"] != nil {
            matched.append(contentsOf: metadata["match"]!)
        }
        if metadata["include"] != nil {
            included.append(contentsOf: metadata["include"]!)
        }
        if metadata["exclude"] != nil {
            excluded.append(contentsOf: metadata["exclude"]!)
        }

        // update manifest values
        manifest.excludeMatch = updatePatternDict(filename, excludeMatched, manifest.excludeMatch)
        manifest.match = updatePatternDict(filename, matched, manifest.match)
        manifest.exclude = updatePatternDict(filename, excluded, manifest.exclude)
        manifest.include = updatePatternDict(filename, included, manifest.include)

        if !updateManifest(with: manifest) {
            err("failed to update manifest matches")
            return false
        }
    }
    logText("updateManifestMatches complete")
    return true
}

func updatePatternDict(_ filename: String, _ filePatterns: [String], _ manifestKeys: [String: [String]]) -> [String: [String]] {
    // will hold the exclude/match patterns in manifest that have file name as value
    var patternsInManifestForFile = [String]()
    // new var from func argument, so it can be manipulated
    var returnDictionary = manifestKeys
    // patterns from manifest
    let keys = returnDictionary.keys
    // determine what patterns already have this filename as a value
    for key in keys {
        // key is an array of filenames
        guard let filenames = returnDictionary[key] else {
            err("failed to get values for manifest key, \(key)")
            continue
        }
        for name in filenames {
            // name is a single filename
            // if name is same as filename, file already added for this pattern
            // add it to patternsInManifestForFile for later comparison
            if name == filename {
                patternsInManifestForFile.append(key)
            }
        }
    }
    // patterns in file metadata and patterns in manifest that have filename as a value
    // filename already present in manifest for these patterns, do nothing with these
    // let common = filePatterns.filter{patternsInManifestForFile.contains($0)}
    // patterns in file metadata, but don't have the filename as a value within the manifest
    // these are the manifest patterns that the filename needs to be added to
    let addFilenameTo = filePatterns.filter{!patternsInManifestForFile.contains($0)}

    // the patterns that have the filename as a value, but not present in file metadata
    // ie. these are the manifest patterns we need to remove the filename from
    let removeFilenameFrom = patternsInManifestForFile.filter{!filePatterns.contains($0)}

    // check if filename needs to be added or new key/val needs to be created
    for pattern in addFilenameTo {
        if returnDictionary[pattern] != nil {
            returnDictionary[pattern]?.append(filename)
        } else {
            returnDictionary[pattern] = [filename]
        }
    }

    for pattern in removeFilenameFrom {
        // get the index of the filename within the array
        let ind = returnDictionary[pattern]?.firstIndex(of: filename)
        // remove filename from array by index
        returnDictionary[pattern]?.remove(at: ind!)
        // if filename was the last item in array, remove the url pattern from dictionary
        if returnDictionary[pattern]!.count < 1 {
            returnDictionary.removeValue(forKey: pattern)
        }
    }

    return returnDictionary
}

func updateManifestRequired(_ optionalFilesArray: [[String: Any]] = []) -> Bool {
    logText("updateManifestRequired started")
    // only get all files if files were not provided
    var files = [[String: Any]]()
    if optionalFilesArray.count < 1 {
        guard let getFiles = getAllFiles() else {
            logText("updateManifestRequired count not get files")
            return false
        }
        files = getFiles
    } else {
        files = optionalFilesArray
    }
    logText("updateManifestRequired will loop through \(files.count)")
    var manifest = getManifest()
    for file in files {
        // can be force unwrapped because getAllFiles didn't return nil
        let filename = file["filename"] as! String
        let metadata = file["metadata"] as! [String: [String]]
        let type = file["type"] as! String
        let required = metadata["require"] ?? []
        logText("updateManifestRequired start \(filename)")
        // get required resources for file, if fail, skip updating manifest
        if !getRequiredCode(filename, required, type) {
            err("couldn't fetch remote content for \(filename) in updateManifestRequired")
            continue
        }

        // create filenames from sanitized resource urls
        // getRequiredCode does the same thing when saving to disk
        // populate array with entries for manifest
        var r = [String]()
        for resource in required {
            if let sanitizedResourceName = sanitize(resource) {
                r.append(sanitizedResourceName)
            }
        }

        // if there are values, write them to manifest
        // if failed to write to manifest, continue to next file & log error
        if r.count > 0 && r != manifest.require[filename] {
            manifest.require[filename] = r
            if !updateManifest(with: manifest) {
                err("couldn't update manifest when getting required resources")
            }
        }
        logText("updateManifestRequired end \(filename)")
    }
    logText("updateManifestRequired complete")
    return true
}

func purgeManifest(_ optionalFilesArray: [[String: Any]] = []) -> Bool {
    logText("purgeManifest started")
    // purge all manifest keys of any stale entries
    var update = false, manifest = getManifest(), allSaveLocationFilenames = [String]()
    // only get all files if files were not provided
    var allFiles = [[String: Any]]()
    if optionalFilesArray.count < 1 {
        // if getAllFiles fails to return, ignore and pass an empty array
        let getFiles = getAllFiles() ?? []
        allFiles = getFiles
    } else {
        allFiles = optionalFilesArray
    }
    // populate array with filenames
    for file in allFiles {
        if let filename = file["filename"] as? String {
            allSaveLocationFilenames.append(filename)
        }
    }
    // loop through manifest keys, if no file exists for value, remove value from manifest
    // if there are no more filenames in pattern, remove pattern from manifest
    for (pattern, filenames) in manifest.match {
        for filename in filenames {
            if !allSaveLocationFilenames.contains(filename) {
                if let index = manifest.match[pattern]?.firstIndex(of: filename) {
                    manifest.match[pattern]?.remove(at: index)
                    update = true
                    logText("Could not find \(filename) in save location, removed from match pattern - \(pattern)")
                }
            }
        }
        if let length = manifest.match[pattern]?.count {
            if length < 1, let ind = manifest.match.index(forKey: pattern) {
                manifest.match.remove(at: ind)
                logText("No more files for \(pattern) match pattern, removed from manifest")
            }
        }
    }
    for (pattern, filenames) in manifest.excludeMatch {
        for filename in filenames {
            if !allSaveLocationFilenames.contains(filename) {
                if let index = manifest.excludeMatch[pattern]?.firstIndex(of: filename) {
                    manifest.excludeMatch[pattern]?.remove(at: index)
                    update = true
                    logText("Could not find \(filename) in save location, removed from exclude-match pattern - \(pattern)")
                }
            }
        }
        if let length = manifest.excludeMatch[pattern]?.count {
            if length < 1, let ind = manifest.excludeMatch.index(forKey: pattern) {
                manifest.excludeMatch.remove(at: ind)
                logText("No more files for \(pattern) exclude-match pattern, removed from manifest")
            }
        }
    }
    for (pattern, filenames) in manifest.exclude {
        for filename in filenames {
            if !allSaveLocationFilenames.contains(filename) {
                if let index = manifest.exclude[pattern]?.firstIndex(of: filename) {
                    manifest.exclude[pattern]?.remove(at: index)
                    update = true
                    logText("Could not find \(filename) in save location, removed from exclude pattern - \(pattern)")
                }
            }
        }
        if let length = manifest.exclude[pattern]?.count {
            if length < 1, let ind = manifest.exclude.index(forKey: pattern) {
                manifest.exclude.remove(at: ind)
                logText("No more files for \(pattern) exclude pattern, removed from manifest")
            }
        }
    }
    for (pattern, filenames) in manifest.include {
        for filename in filenames {
            if !allSaveLocationFilenames.contains(filename) {
                if let index = manifest.include[pattern]?.firstIndex(of: filename) {
                    manifest.include[pattern]?.remove(at: index)
                    update = true
                    logText("Could not find \(filename) in save location, removed from exclude pattern - \(pattern)")
                }
            }
        }
        if let length = manifest.include[pattern]?.count {
            if length < 1, let ind = manifest.include.index(forKey: pattern) {
                manifest.include.remove(at: ind)
                logText("No more files for \(pattern) exclude pattern, removed from manifest")
            }
        }
    }
    // loop through manifest required
    for (filename, _) in manifest.require {
        if !allSaveLocationFilenames.contains(filename) {
            if let index = manifest.require.index(forKey: filename) {
                manifest.require.remove(at: index)
                // remove associated resources
                if !getRequiredCode(filename, [], (filename as NSString).pathExtension) {
                    err("failed to remove required resources when purging \(filename) from manifest required records")
                }
                update = true
                logText("No more required resources for \(filename), removed from manifest along with resource folder")
            }
        }
    }
    // loop through manifest disabled
    for filename in manifest.disabled {
        if !allSaveLocationFilenames.contains(filename) {
            if let index = manifest.disabled.firstIndex(of: filename) {
                manifest.disabled.remove(at: index)
                update = true
                logText("Could not find \(filename) in save location, removed from disabled")
            }
        }
    }
    // remove obsolete settings
    for setting in manifest.settings {
        if !defaultSettings.keys.contains(setting.key) {
            manifest.settings.removeValue(forKey: setting.key)
            update = true
            logText("Removed obsolete setting - \(setting.key)")
        }
    }
    if update, !updateManifest(with: manifest) {
        err("failed to purge manifest")
        return false
    }
    logText("purgeManifest complete")
    return true
}

// settings
func checkSettings() -> Bool {
    // iterate over default settings and individually check if each present
    // if missing add setting to manifest about to be returned
    // missing keys will occur when new settings introduced
    var manifest = getManifest()
    var update = false
    for (key, value) in defaultSettings {
        if manifest.settings[key] == nil {
            manifest.settings[key] = value
            update = true
        }
    }
    if update, !updateManifest(with: manifest) {
        err("failed to update manifest settings")
        return false
    }
    return true
}

func updateSettings(_ settings: [String: String]) -> Bool {
    var manifest = getManifest()
    manifest.settings = settings
    if updateManifest(with: manifest) != true {
        err("failed to update settings")
        return false
    }
    return true
}

// files
func getAllFiles() -> [[String: Any]]? {
    // returns all files of proper type with filenames, metadata & more
    var files = [[String: Any]]()
    let fm = FileManager.default
    let manifest = getManifest()
    guard let saveLocation = getSaveLocation() else {
        err("getAllFiles failed at (1)")
        return nil
    }
    // security scope
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    // get all file urls within save location
    guard let urls = try? fm.contentsOfDirectory(at: saveLocation, includingPropertiesForKeys: [])  else {
        err("getAllFiles failed at (2)")
        return nil
    }
    for url in urls {
        var fileData = [String: Any]()
        // only read contents for css & js files
        let filename = url.lastPathComponent
        if (!filename.hasSuffix(".css") && !filename.hasSuffix(".js")) {
            continue
        }
        // file will be skipped if metablock is missing
        guard
            let content = try? String(contentsOf: url, encoding: .utf8),
            let dateMod = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
            let parsed = parse(content),
            let metadata = parsed["metadata"] as? [String: [String]],
            let type = filename.split(separator: ".").last
        else {
            logText("ignoring \(filename), file missing or metadata missing from file contents")
            continue
        }
        fileData["canUpdate"] = false
        fileData["content"] = content
        fileData["disabled"] = manifest.disabled.contains(filename)
        fileData["filename"] = filename
        fileData["lastModified"] = dateToMilliseconds(dateMod)
        fileData["metadata"] = metadata
        // for unwrap name since parse ensure it exists
        fileData["name"] = metadata["name"]![0]
        fileData["type"] = "\(type)"
        if metadata["description"] != nil {
            fileData["description"] = metadata["description"]![0]
        }
        if metadata["version"] != nil && metadata["updateURL"] != nil {
            fileData["canUpdate"] = true
        }
        fileData["noframes"] = metadata["noframes"] != nil ? true : false
        files.append(fileData)
    }
    logText("getAllFiles completed")
    return files
}

func getRequiredCode(_ filename: String, _ resources: [String], _ fileType: String) -> Bool {
    let directory = getRequireLocation().appendingPathComponent(filename)
    // if file requires no resource but directory exists, trash it
    if resources.count < 1 && FileManager.default.fileExists(atPath: directory.path) {
        do {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        } catch {
            // failing to trash item won't break functionality, so log error and move on
            err("failed to trash directory in getRequiredCode \(error.localizedDescription)")
            return true
        }
    }
    // loop through resource urls and attempt to fetch it
    for resourceUrlString in resources {
        // get the path of the url string
        guard let resourceUrlPath = URLComponents(string: resourceUrlString)?.path else {
            // if path can not be obtained, skip and log
            logText("failed to get path on \(filename) for \(resourceUrlString)")
            continue
        }
        // skip urls pointing to files of different types
        if resourceUrlPath.hasSuffix(fileType) {
            guard let resourceFilename = sanitize(resourceUrlString) else {return false}
            let fileURL = directory.appendingPathComponent(resourceFilename)
            // only attempt to get resource if it does not yet exist
            if FileManager.default.fileExists(atPath: fileURL.path) {continue}
            // get the remote file contents
            guard let contents = getRemoteFileContents(resourceUrlString) else {continue}
            // check if file specific folder exists at requires directory
            if !FileManager.default.fileExists(atPath: directory.path) {
                guard ((try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)) != nil) else {
                    logText("failed to create required code directory for \(filename)")
                    return false
                }
            }
            // finally write file to directory
            guard ((try? contents.write(to: fileURL, atomically: false, encoding: .utf8)) != nil) else {
                logText("failed to write content to file for \(filename) from \(resourceUrlString)")
                return false
            }
        }
    }
    return true
}

func checkForRemoteUpdates(_ optionalFilesArray: [[String: Any]] = []) -> [[String: String]]? {
    // only get all files if files were not provided
    var files = [[String: Any]]()
    if optionalFilesArray.count < 1 {
        guard let getFiles = getAllFiles() else {
            err("checkForRemoteUpdates failed at (1)")
            return nil
        }
        files = getFiles
    } else {
        files = optionalFilesArray
    }

    var hasUpdates = [[String: String]]()
    for file in files {
        // can be force unwrapped because getAllFiles didn't return nil
        let filename = file["filename"] as! String
        let canUpdate = file["canUpdate"] as! Bool
        let metadata = file["metadata"] as! [String: [String]]
        let type = file["type"] as! String
        let name = metadata["name"]![0]
        logText("Checking for remote updates for \(filename)")
        if canUpdate {
            let currentVersion = metadata["version"]![0]
            let updateUrl = metadata["updateURL"]![0]
            // before fetching remote contents, ensure it points to a file of the same type
            if !updateUrl.hasSuffix(type) {continue}
            guard
                let remoteFileContents = getRemoteFileContents(updateUrl),
                let remoteFileContentsParsed = parse(remoteFileContents),
                let remoteMetadata = remoteFileContentsParsed["metadata"] as? [String: [String]],
                let remoteVersion = remoteMetadata["version"]?[0]
            else {
                err("failed to parse remote file contents in checkForRemoteUpdates")
                return nil
            }
            let remoteVersionNewer = isVersionNewer(currentVersion, remoteVersion)
            if remoteVersionNewer {
                hasUpdates.append(["name": name, "filename": filename, "type": type, "url": updateUrl])
            }
        }
    }
    logText("Finished checking for remote updates for \(files.count) files")
    return hasUpdates
}

func getRemoteFileContents(_ url: String) -> String? {
    logText("getRemoteFileContents for \(url) start")
    guard let solidURL = URL(string: url) else {return nil}
    var contents = ""
    // get remote file contents, synchronously
    let semaphore = DispatchSemaphore(value: 0)
    var task: URLSessionDataTask?
    task = URLSession.shared.dataTask(with: solidURL) { data, response, error in
        if let r = response as? HTTPURLResponse, data != nil, error == nil {
            if r.statusCode == 200 {
                contents = String(data: data!, encoding: .utf8) ?? ""
            }
        }
        semaphore.signal()
    }
    task?.resume()
    // wait 30 seconds before timing out
    if semaphore.wait(timeout: .now() + 30) == .timedOut {
        task?.cancel()
    }

    // if made it to this point and contents still an empty string, something went wrong with the request
    if contents.count < 1 {
        logText("something went wrong while trying to fetch remote file contents \(url)")
        return nil
    }
    logText("getRemoteFileContents for \(url) end")
    return contents
}

func updateAllFiles(_ optionalFilesArray: [[String: Any]] = []) -> Bool {
    // get names of all files with updates available
    guard
        let filesWithUpdates = checkForRemoteUpdates(optionalFilesArray),
        let saveLocation = getSaveLocation()
    else {
        err("failed to update files (1)")
        return false
    }
    // security scope
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    for file in filesWithUpdates {
        // can be force unwrapped because checkForRemoteUpdates didn't return nil
        let filename = file["filename"]!
        let fileUrl = saveLocation.appendingPathComponent(filename)
        guard
            let content = try? String(contentsOf: fileUrl, encoding: .utf8),
            let parsed = parse(content),
            let metadata = parsed["metadata"] as? [String: [String]],
            let updateUrl = metadata["updateURL"]?[0]
        else {
            err("failed to update files (2)")
            continue
        }
        let downloadUrl = metadata["downloadURL"] != nil ? metadata["downloadURL"]![0] : updateUrl
        guard
            let remoteFileContents = getRemoteFileContents(downloadUrl),
            ((try? remoteFileContents.write(to: fileUrl, atomically: false, encoding: .utf8)) != nil)
        else {
            err("failed to update files (3)")
            continue
        }
        logText("updated \(filename) with contents fetched from \(downloadUrl)")
    }
    return true
}

func toggleFile(_ filename: String,_ action: String) -> Bool {
    // if file doesn't exist return false
    guard let saveLocation = getSaveLocation() else {
        err("toggleFile failed at (1)")
        return false
    }
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    let path = saveLocation.appendingPathComponent(filename).path
    if !FileManager.default.fileExists(atPath: path) {
        err("toggleFile failed at (2)")
        return false
    }
    var manifest = getManifest()
    // if file is already disabled
    if action == "disable" && manifest.disabled.contains(filename) || action == "enabled" && !manifest.disabled.contains(filename) {
        return true
    }
    // add filename to disabled array if disabling
    if (action == "disable") {manifest.disabled.append(filename)}
    // remove filename from disabled array if enabling
    if (action == "enable") {
        guard let index = manifest.disabled.firstIndex(of: filename) else {
            err("toggleFile failed at (3)")
            return false
        }
        manifest.disabled.remove(at: index)
    }
    if !updateManifest(with: manifest) {
        err("toggleFile failed at (4)")
        return false
    }
    return true
}

func checkDefaultDirectories() -> Bool {
    let defaultSaveLocation = getDocumentsDirectory().appendingPathComponent("scripts")
    let requireLocation = getRequireLocation()
    let urls = [defaultSaveLocation, requireLocation]
    for url in urls {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                // could not create the save location directory, show error
                err("checkDefaultDirectories failed at (1) - \(url) - \(error.localizedDescription)")
                return false
            }
        }
    }
    return true
}

// matching
func getUrlProps(_ url: String) -> [String: String]? {
    let pattern = #"^(.*:)\/\/((?:\*\.)?(?:[a-z0-9-:]+\.?)+(?:[a-z0-9]+))(\/.*)?$"#
    let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    guard
        let result = regex.firstMatch(in: url, options: [], range: NSMakeRange(0, url.utf16.count)),
        let ptclRange = Range(result.range(at: 1), in: url),
        let hostRange = Range(result.range(at: 2), in: url)
    else {
        return nil
    }
    let ptcl = String(url[ptclRange])
    let host = String(url[hostRange])
    var path = "/"
    if let pathRange = Range(result.range(at: 3), in: url) {
        path = String(url[pathRange])
    }
    return ["protocol": ptcl, "host": host, "pathname": path, "href": url]
}

func stringToRegex(_ stringPattern: String) -> NSRegularExpression? {
    let pattern = #"[\.|\?|\^|\$|\+|\{|\}|\[|\]|\||\\(|\)|\/]"#
    var patternReplace = "^\(stringPattern.replacingOccurrences(of: pattern, with: #"\\$0"#, options: .regularExpression))$"
    patternReplace = patternReplace.replacingOccurrences(of: "*", with: ".*")
    guard let regex = try? NSRegularExpression(pattern: patternReplace, options: .caseInsensitive) else {
        return nil
    }
    return regex
}

func match(_ ptcl: String,_ host: String,_ path: String,_ matchPattern: String) -> Bool {
    // matchPattern is the value from metatdata key @match or @exclude-match
    if (matchPattern == "<all_urls>") {
        return true
    }
    // currently only http/s supported
    if (ptcl != "http:" && ptcl != "https:") {
        return false
    }
    let partsPattern = #"^(http:|https:|\*:)\/\/((?:\*\.)?(?:[a-z0-9-]+\.)+(?:[a-z0-9]+)|\*\.[a-z]+|\*)(\/[^\s]*)$"#
    let partsPatternReg = try! NSRegularExpression(pattern: partsPattern, options: .caseInsensitive)
    let range = NSMakeRange(0, matchPattern.utf16.count)
    guard let parts = partsPatternReg.firstMatch(in: matchPattern, options: [], range: range) else {
        err("malformed regex match pattern")
        return false
    }
    // construct host regex from matchPattern
    let matchPatternHost = matchPattern[Range(parts.range(at: 2), in: matchPattern)!]
    var hostPattern = "^\(matchPatternHost.replacingOccurrences(of: ".", with: "\\."))$"
    hostPattern = hostPattern.replacingOccurrences(of: "^*$", with: ".*")
    hostPattern = hostPattern.replacingOccurrences(of: "*\\.", with: "(.*\\.)?")
    guard let hostRegEx = try? NSRegularExpression(pattern: hostPattern, options: .caseInsensitive) else {
        err("invalid host regex")
        return false
    }
    // construct path regex from matchPattern
    let matchPatternPath = matchPattern[Range(parts.range(at: 3), in: matchPattern)!]
    guard let pathRegEx = stringToRegex(String(matchPatternPath)) else {
        err("invalid path regex")
        return false
    }
    guard
        (hostRegEx.firstMatch(in: host, options: [], range: NSMakeRange(0, host.utf16.count)) != nil),
        (pathRegEx.firstMatch(in: path, options: [], range: NSMakeRange(0, path.utf16.count)) != nil)
    else {
        return false
    }

    return true
}

func include(_ url: String,_ pattern: String) -> Bool {
    var regex:NSRegularExpression
    if pattern.hasPrefix("/") && pattern.hasSuffix("/") {
        let p = String(pattern.dropFirst().dropLast())
        guard let exp = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else {
            err("invalid regex in include func")
            return false
        }
        regex = exp
    } else {
        guard let exp = stringToRegex(pattern) else {
            err("coudn't convert string to regex in include func")
            return false
        }
        regex = exp
    }
    if (regex.firstMatch(in: url, options: [], range: NSMakeRange(0, url.utf16.count)) == nil) {
        return false
    }
    return true
}

func getMatchedFiles(_ url: String) -> [String] {
    logText("Getting matched files for \(url)")
    let manifest = getManifest()
    guard
        let parts = getUrlProps(url),
        let ptcl = parts["protocol"],
        let host = parts["host"],
        let path = parts["pathname"],
        let href = parts["href"]
    else {
        err("getMatchedFiles failed at (1) for \(url)")
        return [String]()
    }
    // domains where loading is excluded for file
    var excludedFilenames:[String] = []
    // when code is loaded from a file, it's filename will be populated in the below array, to avoid duplication
    var matchedFilenames:[String] = []
    // all exclude-match patterns from manifest
    let excludeMatchPatterns = manifest.excludeMatch.keys
    // all match patterns from manifest
    let matchPatterns = manifest.match.keys
    // all include patterns from manifest
    let includeExpressions = manifest.include.keys
    // all exclude patterns from manifest
    let excludeExpressions = manifest.exclude.keys

    // loop through exclude patterns and see if any match against page url
    for pattern in excludeMatchPatterns {
        // if pattern matches page url, add filenames from page url to excludes array, code from those filenames won't be loaded
        if match(ptcl, host, path, pattern) {
            guard let filenames = manifest.excludeMatch[pattern] else {
                err("getMatchedFiles failed at (2)")
                continue
            }
            for filename in filenames {
                if !excludedFilenames.contains(filename) {
                    excludedFilenames.append(filename)
                }
            }
        }
    }
    // loop through exclude expressions and check for matches
    for exp in excludeExpressions {
        if include(href, exp) {
            guard let filenames = manifest.exclude[exp] else {
                err("getMatchedFiles failed at (3)")
                continue
            }
            for filename in filenames {
                if !excludedFilenames.contains(filename) {
                    excludedFilenames.append(filename)
                }
            }
        }
    }
    // loop through all match patterns from manifest to see if they match against the current page url
    for pattern in matchPatterns {
        if match(ptcl, host, path, pattern) {
            // the filenames listed for the pattern that match page url
            guard let filenames = manifest.match[pattern] else {
                err("getMatchedFiles failed at (4)")
                continue
            }
            // loop through matched filenames and populate matchedFilenames array
            for filename in filenames {
                // don't push to array if filename is in excludes or filename already exists in matchedFilenames array (to avoid duplication)
                if !excludedFilenames.contains(filename) && !matchedFilenames.contains(filename) {
                    matchedFilenames.append(filename)
                }
            }
        }
    }
    // loop through include expressions and check for matches
    for exp in includeExpressions {
        if include(href, exp) {
            guard let filenames = manifest.include[exp] else {
                err("getMatchedFiles failed at (5)")
                continue
            }
            for filename in filenames {
                if !excludedFilenames.contains(filename) && !matchedFilenames.contains(filename) {
                    matchedFilenames.append(filename)
                }
            }
        }
    }
    logText("Got \(matchedFilenames.count) matched files for \(url)")
    return matchedFilenames
}

// injection
func getCode(_ filenames: [String], _ isTop: Bool)-> [String: [String: [String: Any]]]? {
    var allFiles = [String: [String: [String: Any]]]()
    var cssFiles = [String:[String:String]]()
    var jsFiles = [String: [String: [String: [String: Any]]]]()
    jsFiles["auto"] = ["document-start": [:], "document-end": [:], "document-idle": [:]]
    jsFiles["content"] = ["document-start": [:], "document-end": [:], "document-idle": [:]]
    jsFiles["page"] = ["document-start": [:], "document-end": [:], "document-idle": [:]]
    jsFiles["context-menu"] = ["auto": [:], "content": [:], "page": [:]]
    var auto_docStart = [String: [String: Any]]()
    var auto_docEnd = [String: [String: Any]]()
    var auto_docIdle = [String: [String: Any]]()
    var content_docStart = [String: [String: Any]]()
    var content_docEnd = [String: [String: Any]]()
    var content_docIdle = [String: [String: Any]]()
    var page_docStart = [String: [String: Any]]()
    var page_docEnd = [String: [String: Any]]()
    var page_docIdle = [String: [String: Any]]()
    
    var auto_context_scripts = [String: [String: Any]]()
    var content_context_scripts = [String: [String: Any]]()
    var page_context_scripts = [String: [String: Any]]()
    
    guard let saveLocation = getSaveLocation() else {
        err("getCode failed at (1)")
        return nil
    }

    for filename in filenames {
        guard
            let contents = getFileContentsParsed(saveLocation.appendingPathComponent(filename)),
            var code = contents["code"] as? String,
            let type = filename.split(separator: ".").last
        else {
            // if guard fails, log error continue to next file
            err("getCode failed at (2) for \(filename)")
            continue
        }
        // can force unwrap b/c getFileContentsParsed ensures metadata exists
        let metadata = contents["metadata"] as! [String: [String]]
        let name = metadata["name"]![0]

        // if metadata has noframes option and the url is not the top window, don't load
        if (metadata["noframes"] != nil && !isTop) {
            continue
        }

        // normalize weight
        var weight = metadata["weight"]?[0] ?? "1"
        weight = normalizeWeight(weight)

        // attempt to get require resource from disk
        // if required resource is inaccessible, log error and continue
        if let required = metadata["require"] {
            // reverse required metadata
            // if required is ["A", "B", "C"], C gets added above B which is above A, etc..
            // the reverse of that is desired
            for require in required.reversed() {
                let sanitizedName = sanitize(require) ?? ""
                let requiredFileURL = getRequireLocation().appendingPathComponent(filename).appendingPathComponent(sanitizedName)
                if let requiredContent = try? String(contentsOf: requiredFileURL, encoding: .utf8) {
                    code = "\(requiredContent)\n\(code)"
                } else {
                    err("getCode failed at (3) for \(requiredFileURL)")
                }
            }
        }
        
        // attempt to get all @grant value
        var grants = metadata["grant"] ?? []
        // remove duplicates, if any exist
        grants = Array(Set(grants))

        if type == "css" {
            cssFiles[filename] = ["code": code, "weight": weight]
        } else if type == "js" {
            var injectInto = metadata["inject-into"]?[0] ?? "auto"
            var runAt = metadata["run-at"]?[0] ?? "document-end"

            let injectVals = ["auto", "content", "page"]
            let runAtVals = ["context-menu", "document-start", "document-end", "document-idle"]
            // if inject/runAt values are not valid, use default
            if !injectVals.contains(injectInto) {
                injectInto = "page"
            }
            if !runAtVals.contains(runAt) {
                runAt = "document-end"
            }

            let data = ["code": code, "weight": weight, "grant": grants] as [String : Any]
            // add file data to appropriate dict
            if injectInto == "auto" && runAt == "document-start" {
                auto_docStart[filename] = data
            } else if injectInto == "auto" && runAt == "document-end" {
                auto_docEnd[filename] = data
            } else if injectInto == "auto" && runAt == "document-idle" {
                auto_docIdle[filename] = data
            } else if injectInto == "content" && runAt == "document-start" {
                content_docStart[filename] = data
            } else if injectInto == "content" && runAt == "document-end" {
                content_docEnd[filename] = data
            } else if injectInto == "content" && runAt == "document-idle" {
                content_docIdle[filename] = data
            } else if injectInto == "page" && runAt == "document-start" {
                page_docStart[filename] = data
            } else if injectInto == "page" && runAt == "document-end" {
                page_docEnd[filename] = data
            } else if injectInto == "page" && runAt == "document-idle" {
                page_docIdle[filename] = data
            }
            
            if runAt == "context-menu" && injectInto == "auto" {
                auto_context_scripts[filename] = ["code": code, "name": name, "grant": grants]
            }
            if runAt == "context-menu" && injectInto == "content" {
                content_context_scripts[filename] = ["code": code, "name": name, "grant": grants]
            }
            if runAt == "context-menu" && injectInto == "page" {
                page_context_scripts[filename] = ["code": code, "name": name, "grant": grants]
            }
        }
    }

    // construct the js specific dictionaries
    jsFiles["auto"]!["document-start"] = auto_docStart
    jsFiles["auto"]!["document-end"] = auto_docEnd
    jsFiles["auto"]!["document-idle"] = auto_docIdle
    jsFiles["content"]!["document-start"] = content_docStart
    jsFiles["content"]!["document-end"] = content_docEnd
    jsFiles["content"]!["document-idle"] = content_docIdle
    jsFiles["page"]!["document-start"] = page_docStart
    jsFiles["page"]!["document-end"] = page_docEnd
    jsFiles["page"]!["document-idle"] = page_docIdle
    // the context-menu dictionaries are constructed differently
    // they will need to be handled in a unique way on the JS side
    jsFiles["context-menu"]!["auto"] = auto_context_scripts
    jsFiles["context-menu"]!["content"] = content_context_scripts
    jsFiles["context-menu"]!["page"] = page_context_scripts

    // construct the returned dictionary
    allFiles["css"] = cssFiles
    allFiles["js"] = jsFiles

    return allFiles
}

func getFileContentsParsed(_ url: URL) -> [String: Any]? {
    guard let saveLocation = getSaveLocation() else {
        err("getFileContentsParsed failed at (1)")
        return nil
    }
    // security scope
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    // check that url is a valid path to a directory or single file
    guard
        FileManager.default.fileExists(atPath: url.path),
        let content = try? String(contentsOf: url, encoding: .utf8),
        let parsed = parse(content)
    else {
        return nil
    }
    return parsed
}

func getInjectionFilenames(_ url: String) -> [String]? {
    var filenames = [String]()
    let manifest = getManifest()
    let matched = getMatchedFiles(url)
    guard
        let active = manifest.settings["active"],
        let parts = getUrlProps(url),
        let ptcl = parts["protocol"],
        let host = parts["host"],
        let path = parts["pathname"]
    else {
        err("getInjectionFilenames failed at (1)")
        return nil
    }
    // if injection is disabled return empty array
    if active != "true" {
        return filenames
    }
    // url matches a pattern in blacklist, no injection for this url
    // return empty array
    for pattern in manifest.blacklist {
        if match(ptcl, host, path, pattern) {
            return filenames
        }
    }
    // filter out all disabled files
    filenames = matched.filter{!manifest.disabled.contains($0)}
    return filenames
}

// popup
func getPopupMatches(_ url: String, _ subframeUrls: [String]) -> [[String: Any]]? {
    var matches = [[String: Any]]()
    // if the url doesn't start with http/s return empty array
    if !url.starts(with: "http://") && !url.starts(with: "https://") {
        return matches
    }
    // get all the files saved to manifest that match the passed url
    let matched = getMatchedFiles(url)
    // get all the files at the save location
    guard
        let files = getAllFiles()
    else {
        err("getPopupMatches failed at (1)")
        return nil
    }
    // filter out the files that are present in both files and matched
    // force unwrap filename to string since getAllFiles always returns it
    matches = files.filter{matched.contains($0["filename"] as! String)}

    // get the subframe url matches
    var frameUrlsMatched = [[String: Any]]()
    var frameUrlsMatches = [String]()
    // filter out the top page url from the frame urls
    let frameUrls = subframeUrls.filter{$0 != url}
    // for each url just pushed to frameUrls, get all the files saved to manifest that match their url
    for frameUrl in frameUrls {
        let frameMatches = getMatchedFiles(frameUrl)
        for frameMatch in frameMatches {
            // for the match against the frameUrl, see if it has @noframes
            // if so, it should not be appended to frameUrlsMatches
            // filter all files for the first one that matches the frameMatch filename
            // can force unwrap filename b/c getAllFiles always returns it
            let frameMatchMetadata = files.filter{$0["filename"] as! String == frameMatch}.first
            // can force unwrap noframes b/c getAllFiles always returns it
            let noFrames = frameMatchMetadata!["noframes"] != nil ? true : false
            if !matched.contains(frameMatch) && !noFrames {
                frameUrlsMatches.append(frameMatch)
            }
        }
    }

    // filter out the files that are present in both files and frameUrlsMatches
    // force unwrap filename to string since getAllFiles always returns it
    frameUrlsMatched = files.filter{frameUrlsMatches.contains($0["filename"] as! String)}
    // loop through frameUrlsMatched and add subframe key/val
    for (index, var frameUrlsMatch) in frameUrlsMatched.enumerated() {
        frameUrlsMatch["subframe"] = true
        frameUrlsMatched[index] = frameUrlsMatch
    }
    // add frameUrlsMatched to matches array
    matches.append(contentsOf: frameUrlsMatched)
    return matches
}

func popupUpdateAll() -> Bool {
    guard
        let files = getAllFiles(),
        updateAllFiles(files),
        updateManifestMatches(files),
        updateManifestRequired(files),
        purgeManifest(files)
    else {
        return false
    }
    return true
}

func getPopupBadgeCount(_ url: String, _ subframeUrls: [String]) -> Int? {
    if !url.starts(with: "http://") && !url.starts(with: "https://") {
        return 0
    }
    let manifest = getManifest()
    guard
        var matches = getPopupMatches(url, subframeUrls),
        let active = manifest.settings["active"],
        let showCount = manifest.settings["showCount"]
    else {
        err("getPopupBadgeCount failed at (1)")
        return nil
    }
    if showCount == "false" {
        return 0
    }
    if let parts = getUrlProps(url), let ptcl = parts["protocol"], let host = parts["host"], let path = parts["pathname"] {
        for pattern in manifest.blacklist {
            if match(ptcl, host, path, pattern) {
                return 0
            }
        }
    } else {
        return 0
    }
    if active != "true" {
        return 0
    }
    matches = matches.filter{!manifest.disabled.contains($0["filename"] as! String)}
    return matches.count
}

func popupUpdateSingle(_ filename: String, _ url: String, _ subframeUrls: [String]) -> [[String: Any]]? {
    guard let saveLocation = getSaveLocation() else {
        err("updateSingleItem failed at (1)")
        return nil
    }
    // security scope
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    let fileUrl = saveLocation.appendingPathComponent(filename)
    guard
        let content = try? String(contentsOf: fileUrl, encoding: .utf8),
        let parsed = parse(content),
        let metadata = parsed["metadata"] as? [String: [String]],
        let updateUrl = metadata["updateURL"]?[0]
    else {
        err("updateSingleItem failed at (2)")
        return nil
    }
    let downloadUrl = metadata["downloadURL"] != nil ? metadata["downloadURL"]![0] : updateUrl
    guard
        let remoteFileContents = getRemoteFileContents(downloadUrl),
        ((try? remoteFileContents.write(to: fileUrl, atomically: false, encoding: .utf8)) != nil)
    else {
        err("updateSingleItem failed at (3)")
        return nil
    }
    guard
        let files = getAllFiles(),
        updateManifestMatches(files),
        updateManifestRequired(files),
        purgeManifest(files),
        let matches = getPopupMatches(url, subframeUrls)
    else {
        err("updateSingleItem failed at (4)")
        return nil
    }
    return matches
}

// page
func getInitData() -> [String: Any]? {
    let manifest = getManifest()
    guard let saveLocation = getSaveLocation() else {
        err("getInitData failed at (1)")
        return nil
    }
    var data:[String: Any] = manifest.settings
    data["blacklist"] = manifest.blacklist
    data["saveLocation"] = saveLocation.path
    data["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return data
}

func saveFile(_ item: [String: Any],_ content: String) -> [String: Any] {
    var response = [String: Any]()
    let newContent = content
    guard let saveLocation = getSaveLocation() else {
        err("saveFile failed at (1)")
        return ["error": "failed to get save location when attempting to save"]
    }
    guard
        let oldFilename = item["filename"] as? String,
        let type = item["type"] as? String
    else {
        return ["error": "invalid argument in save function"]
    }
    guard
        let parsed = parse(newContent),
        let metadata = parsed["metadata"] as? [String: [String]],
        let n = metadata["name"]?[0],
        var name = sanitize(n)
    else {
        return ["error": "failed to parse argument in save function"]
    }
    
    // construct new file name
    let newFilename = "\(name).\(type)"
    
    // security scope
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    guard
        let allFilesUrls = try? FileManager.default.contentsOfDirectory(at: saveLocation, includingPropertiesForKeys: [])
    else {
        return ["error": "failed to read save urls in save function"]
    }
    
    // validate file before save
    var allFilenames:[String] = [] // stores the indv filenames for later comparison
    // old and new filenames are equal, overwriting and can skip
    if oldFilename.lowercased() != newFilename.lowercased() {
        // loop through all the file urls in the save location and save filename to var
        for fileUrl in allFilesUrls {
            // skip file if it is not of the proper type
            let filename = fileUrl.lastPathComponent
            if (!filename.hasSuffix(type)) {
                continue
            }
            // if file is of the proper type, add it to the allFilenames array
            allFilenames.append(filename.lowercased())
        }
    }
    
    if allFilenames.contains(newFilename.lowercased()) || newFilename.count > 250 {
        // filename taken or too long
        return ["error": "filename validation failed in save function"]
    }
    
    // file passed validation
    
    // attempt to save to disk
    let newFileUrl = saveLocation.appendingPathComponent(newFilename)
    do {
        try newContent.write(to: newFileUrl, atomically: false, encoding: .utf8)
    } catch {
        err("saveFile failed at (2)")
        return ["error": "failed to write file to disk"]
    }
    
    // saved to disk successfully
    
    // get the file last modified date
    guard
        let dateMod = try? FileManager.default.attributesOfItem(atPath: newFileUrl.path)[.modificationDate] as? Date
    else {
        err("saveFile failed at (3)")
        return ["error": "failed to read modified date in save function"]
    }
    
    // remove old file and manifest records for old file if they exist
    if oldFilename != newFilename {
        // if user changed the filename, remove file with old filename
        let oldFileUrl = saveLocation.appendingPathComponent(oldFilename)
        // however, when creating a new file, if user changes the temp given name by app...
        // oldFilename (the temp name in activeItem) and newFilename (@name in file contents) will differ
        // the file with oldFilename will not be on the filesystem and can not be deleted
        // for that edge case, using try? rather than try(!) to allow failures
        try? FileManager.default.trashItem(at: oldFileUrl, resultingItemURL: nil)
    }
    
    // update manifest for new file and purge anything from old file
    guard updateManifestMatches(), updateManifestRequired(), purgeManifest() else {
        err("saveFile failed at (4)")
        return ["error": "file save but manifest couldn't be updated"]
    }
    
    // un-santized name
    name = unsanitize(name)
    
    // build response dict
    response["canUpdate"] = false
    response["content"] = newContent
    response["filename"] = newFilename
    response["lastModified"] = dateToMilliseconds(dateMod)
    response["name"] = name
    if metadata["description"] != nil {
        response["description"] = metadata["description"]![0]
    }
    if metadata["version"] != nil && metadata["updateURL"] != nil {
        response["canUpdate"] = true
    }
    
    return response
}

func trashFile(_ item: [String: Any]) -> Bool {
    guard
        let saveLocation = getSaveLocation(),
        let filename = item["filename"] as? String
    else {
        err("trashFile failed at (1)")
        return false
    }
    // security scope
    let didStartAccessing = saveLocation.startAccessingSecurityScopedResource()
    defer {
        if didStartAccessing {saveLocation.stopAccessingSecurityScopedResource()}
    }
    let url = saveLocation.appendingPathComponent(filename)
    // if file is already removed from path, assume it was removed by user and return true
    if (FileManager.default.fileExists(atPath: url.path)) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            err(error.localizedDescription)
            return false
        }
    }
    // update manifest
    guard updateManifestMatches(), updateManifestRequired(), purgeManifest() else {
        err("trashFile failed at (2)")
        return false
    }
    return true;
}

func getFileRemoteUpdate(_ content: String) -> [String: String] {
    guard
        let parsed = parse(content),
        let metadata = parsed["metadata"] as? [String: [String]]
    else {
        // can't parse editor contents
        return ["error": "Update failed, metadata missing"]
    }
    // editor contents missing version value
    guard let version = metadata["version"]?[0] else {
        return ["error": "Update failed, version value required"]
    }
    // editor contents missing updateURL
    guard let updateURL = metadata["updateURL"]?[0] else {
        return ["error": "Update failed, update url required"]
    }
    // set download url
    let downloadURL = (metadata["downloadURL"] != nil) ? metadata["downloadURL"]![0] : updateURL
    // basic url validation
    guard validateUrl(updateURL) else {
        return ["error": "Update failed, invalid updateURL"]
    }
    guard validateUrl(downloadURL) else {
        return ["error": "Update failed, invalid downloadURL"]
    }
    // get the remote file contents for checking version
    guard var remoteContent = getRemoteFileContents(updateURL) else {
        return ["error": "Update failed, updateURL unreachable"]
    }
    // parse remote file contents
    guard
        let remoteParsed = parse(remoteContent),
        let remoteMetadata = remoteParsed["metadata"] as? [String: [String]],
        let remoteVersion = remoteMetadata["version"]?[0]
    else {
        // can't parse editor contents
        return ["error": "Update failed, couldn't parse remote file contents"]
    }
    // check if update is needed
    if version >= remoteVersion {
        return ["info": "No updates found"]
    }
    // at this point it is known an update is available, get new code from downloadURL
    // is there's a specific downloadURL overwrite remoteContents with code from downloadURL
    if updateURL != downloadURL {
        guard let remoteDownloadContent = getRemoteFileContents(downloadURL) else {
            return ["error": "Update failed, downloadURL unreachable"]
        }
        remoteContent = remoteDownloadContent
    }
    return ["content": remoteContent]
}

func popupInit() -> [String: String]? {
    // check the default directories
    let checkDefaultDirectories = checkDefaultDirectories()
    // check the settings
    let checkSettings = checkSettings()
    // get all files to pass as arguments to function below
    guard let allFiles = getAllFiles() else {
        err("Failed to getAllFiles in popupInit")
        return nil
    }
    // purge the manifest of old records
    let purgeManifest = purgeManifest(allFiles)
    // update matches in manifest
    let updateManifestMatches = updateManifestMatches(allFiles)
    // update the required resources
    let updateManifestRequired = updateManifestRequired(allFiles)
    // verbose error checking
    if !checkDefaultDirectories {
        err("Failed to checkDefaultDirectories in popupInit")
        return nil
    }
    if !checkSettings {
        err("Failed to checkSettings in popupInit")
        return nil
    }
    if !purgeManifest {
        err("Failed to purgeManifest in popupInit")
        return nil
    }
    if !updateManifestMatches {
        err("Failed to updateManifestMatches in popupInit")
        return nil
    }
    if !updateManifestRequired {
        err("Failed to updateManifestRequired in popupInit")
        return nil
    }
    let manifest = getManifest()
    guard let active = manifest.settings["active"] else {
        err("Failed at getManifest active in popupInit")
        return nil
    }
    // pass some info in response
    guard let saveLocation = getSaveLocation() else {
        err("Failed at getSaveLocation in popupInit")
        return nil
    }
    let documentsDirectory = getDocumentsDirectory()
    let requireLocation = getRequireLocation()
    
    return [
        "active": active,
        "saveLocation": saveLocation.absoluteString,
        "documentsDirectory": documentsDirectory.absoluteString,
        "requireLocation": requireLocation.absoluteString
    ]
}

// userscript install
func installCheck(_ content: String) -> [String: String]? {
    // this func checks a userscript's metadata to determine if it's already installed
    
    guard let files = getAllFiles() else {
        err("installCheck failed at (1)")
        return nil
    }
    
    guard
        let parsed = parse(content),
        let metadata = parsed["metadata"] as? [String: [String]],
        let newName = metadata["name"]?[0]
    else {
        return ["error": "userscript metadata is invalid"]
    }
    
    // loop through all files nad get their names and filenames
    // we will check the new name/filename to see if this is a unique userscript
    // or if it will overwrite an existing userscript
    var names = [String]()
    for file in files {
        // can be force unwrapped because getAllFiles didn't return nil
        let name = file["name"] as! String
        
        // populate array
        names.append(name)
    }
    
    var directive = ""
    #if os(macOS)
        directive = "Click"
    #elseif os(iOS)
        directive = "Tap"
    #endif
    
    if names.contains(newName) {
        return ["success": "\(directive) to re-install"]
    }
    
    return ["success": "\(directive) to install"];
}

func installParse(_ content: String) -> [String: Any]? {
    guard
        let parsed = parse(content),
        let metadata = parsed["metadata"] as? [String: [String]]
    else {
        return ["error": "userscript metadata is invalid"]
    }
    return metadata
}

func installUserscript(_ content: String) -> [String: Any]? {
    guard
        let parsed = parse(content),
        let metadata = parsed["metadata"] as? [String: [String]],
        let n = metadata["name"]?[0],
        let name = sanitize(n)
    else {
        err("installUserscript failed at (1)")
        return nil
    }
    let filename = "\(name).js"
    
    let saved = saveFile(["filename": filename, "type": "js"], content)
    return saved
}
//func popupMatches(_ url: String, _ subframeUrls: [String]) -> [[String: Any]]? {
//    var matches = [[String: Any]]()
//    // if the url doesn't start with http/s return empty array
//    if !url.starts(with: "http://") && !url.starts(with: "https://") {
//        return matches
//    }
//    // get all the files saved to manifest that match the passed url
//    let matched = getMatchedFiles(url)
//    // get all the files at the save location
//    guard let files = getAllFiles() else {
//        err("popupMatches failed at (1)")
//        return nil
//    }
//    // filter out the files that are present in both files and matched
//    // force unwrap filename to string since getAllFiles always returns it
//    matches = files.filter{matched.contains($0["filename"] as! String)}
//
//    // get the subframe url matches
//    var frameUrlsMatched = [[String: Any]]()
//    var frameUrlsMatches = [String]()
//    // filter out the top page url from the frame urls
//    let frameUrls = subframeUrls.filter{$0 != url}
//    // for each url just pushed to frameUrls, get all the files saved to manifest that match their url
//    for frameUrl in frameUrls {
//        let frameMatches = getMatchedFiles(frameUrl)
//        for frameMatch in frameMatches {
//            if !matched.contains(frameMatch) {
//                frameUrlsMatches.append(frameMatch)
//            }
//        }
//    }
//    // filter out the files that are present in both files and frameUrlsMatches
//    // force unwrap filename to string since getAllFiles always returns it
//    frameUrlsMatched = files.filter{frameUrlsMatches.contains($0["filename"] as! String)}
//    // loop through frameUrlsMatched and add subframe key/val
//    for (index, var frameUrlsMatch) in frameUrlsMatched.enumerated() {
//        frameUrlsMatch["subframe"] = true
//        frameUrlsMatched[index] = frameUrlsMatch
//    }
//    // add frameUrlsMatched to matches array
//    matches.append(contentsOf: frameUrlsMatched)
//
//    return matches
//}
